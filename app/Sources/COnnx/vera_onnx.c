#include "vera_onnx.h"
#include "vendor/onnxruntime_c_api.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const OrtApi *api = NULL;
static OrtEnv *env = NULL;
static char error_text[512];

const char *vera_onnx_error(void) { return error_text; }

static int fail(OrtStatus *st) {
  if (!st) return 0;
  snprintf(error_text, sizeof error_text, "%s", api->GetErrorMessage(st));
  api->ReleaseStatus(st);
  return -1;
}

int vera_onnx_use(const void *ort_api_base) {
  if (api) return 0;
  const OrtApiBase *base = (const OrtApiBase *)ort_api_base;
  if (!base) { snprintf(error_text, sizeof error_text, "нет onnxruntime"); return -1; }
  const OrtApi *a = base->GetApi(ORT_API_VERSION);
  if (!a) {
    snprintf(error_text, sizeof error_text, "onnxruntime %s не даёт API %d", base->GetVersionString(), ORT_API_VERSION);
    return -1;
  }
  api = a;
  if (fail(api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "vera", &env))) { api = NULL; return -1; }
  return 0;
}

int vera_onnx_load(const char *dylib_path) {
  if (api) return 0;
  void *h = dlopen(dylib_path, RTLD_NOW | RTLD_LOCAL);
  if (!h) { snprintf(error_text, sizeof error_text, "%s", dlerror()); return -1; }
  const OrtApiBase *(*get)(void) = (const OrtApiBase *(*)(void))dlsym(h, "OrtGetApiBase");
  if (!get) { snprintf(error_text, sizeof error_text, "нет функции OrtGetApiBase"); return -1; }
  return vera_onnx_use(get());
}

void *vera_onnx_open(const char *model_path, int threads) {
  if (!api) { snprintf(error_text, sizeof error_text, "onnxruntime не загружен"); return NULL; }
  OrtSessionOptions *opt = NULL;
  OrtSession *s = NULL;
  if (fail(api->CreateSessionOptions(&opt))) return NULL;
  if (threads > 0) api->SetIntraOpNumThreads(opt, threads);
  api->SetSessionGraphOptimizationLevel(opt, ORT_ENABLE_ALL);
  OrtStatus *st = api->CreateSession(env, model_path, opt, &s);
  api->ReleaseSessionOptions(opt);
  if (fail(st)) return NULL;
  return s;
}

void vera_onnx_close(void *session) {
  if (api && session) api->ReleaseSession((OrtSession *)session);
}

void vera_onnx_free(float *data) { free(data); }

int vera_onnx_run(void *session, const vera_onnx_input *inputs, int input_count,
                  const char *const *output_names, vera_onnx_output *outputs, int output_count) {
  if (!api || !session) { snprintf(error_text, sizeof error_text, "нет сессии"); return -1; }
  if (input_count > 8 || output_count > 8) { snprintf(error_text, sizeof error_text, "слишком много тензоров"); return -1; }
  for (int i = 0; i < output_count; i++) outputs[i].data = NULL;
  OrtMemoryInfo *mem = NULL;
  if (fail(api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &mem))) return -1;
  OrtValue *in[8] = {0}, *out[8] = {0};
  const char *in_names[8];
  int rc = 0;
  for (int i = 0; i < input_count && rc == 0; i++) {
    const vera_onnx_input *t = &inputs[i];
    int64_t n = 1;
    for (int d = 0; d < t->rank; d++) n *= t->shape[d];
    size_t bytes = (size_t)n * (t->type == VERA_ONNX_INT64 ? sizeof(int64_t) : sizeof(float));
    ONNXTensorElementDataType ty = t->type == VERA_ONNX_INT64 ? ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64
                                                              : ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT;
    rc = fail(api->CreateTensorWithDataAsOrtValue(mem, (void *)t->data, bytes, t->shape, (size_t)t->rank, ty, &in[i]));
    in_names[i] = t->name;
  }
  if (rc == 0)
    rc = fail(api->Run((OrtSession *)session, NULL, in_names, (const OrtValue *const *)in, (size_t)input_count,
                       output_names, (size_t)output_count, out));
  for (int i = 0; i < output_count && rc == 0; i++) {
    OrtTensorTypeAndShapeInfo *info = NULL;
    if ((rc = fail(api->GetTensorTypeAndShape(out[i], &info)))) break;
    size_t dims = 0, count = 0;
    ONNXTensorElementDataType ty;
    api->GetDimensionsCount(info, &dims);
    api->GetTensorShapeElementCount(info, &count);
    api->GetTensorElementType(info, &ty);
    if (dims > 6 || ty != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
      snprintf(error_text, sizeof error_text, "выход %s: не float или больше 6 измерений", output_names[i]);
      api->ReleaseTensorTypeAndShapeInfo(info);
      rc = -1;
      break;
    }
    outputs[i].rank = (int)dims;
    api->GetDimensions(info, outputs[i].shape, dims);
    api->ReleaseTensorTypeAndShapeInfo(info);
    outputs[i].count = (int64_t)count;
    float *src = NULL;
    if ((rc = fail(api->GetTensorMutableData(out[i], (void **)&src)))) break;
    outputs[i].data = (float *)malloc(count * sizeof(float) + 1);
    memcpy(outputs[i].data, src, count * sizeof(float));
  }
  for (int i = 0; i < input_count; i++) if (in[i]) api->ReleaseValue(in[i]);
  for (int i = 0; i < output_count; i++) if (out[i]) api->ReleaseValue(out[i]);
  api->ReleaseMemoryInfo(mem);
  if (rc != 0)
    for (int i = 0; i < output_count; i++) { free(outputs[i].data); outputs[i].data = NULL; }
  return rc;
}
