// A small door to the onnxruntime C API (headers in vendor/, version 1.28.2 — the one sherpa-onnx brings).
// Nothing is linked: the Mac loads libonnxruntime.dylib from the box (`vera_onnx_load`), the phone hands over the
// OrtApiBase of the framework it links (`vera_onnx_use`). Only what Vera's voice needs: load a model, run it on
// float/int64 tensors, read float outputs.
#ifndef VERA_ONNX_H
#define VERA_ONNX_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Load onnxruntime from a dylib path (Mac). 0 on success; the error text in vera_onnx_error().
int vera_onnx_load(const char *dylib_path);
/// Use an already linked onnxruntime: pass OrtGetApiBase() (phone). 0 on success.
int vera_onnx_use(const void *ort_api_base);
const char *vera_onnx_error(void);

/// A model session; NULL on failure (see vera_onnx_error).
void *vera_onnx_open(const char *model_path, int threads);
void vera_onnx_close(void *session);

enum { VERA_ONNX_FLOAT = 1, VERA_ONNX_INT64 = 7 };

typedef struct {
  const char *name;
  int type;              // VERA_ONNX_FLOAT or VERA_ONNX_INT64
  const void *data;
  const int64_t *shape;
  int rank;
} vera_onnx_input;

typedef struct {
  float *data;           // malloc'd, free with vera_onnx_free
  int64_t shape[6];
  int rank;
  int64_t count;
} vera_onnx_output;

/// Run the session. Outputs must be float tensors. 0 on success.
int vera_onnx_run(void *session, const vera_onnx_input *inputs, int input_count,
                  const char *const *output_names, vera_onnx_output *outputs, int output_count);
void vera_onnx_free(float *data);

#ifdef __cplusplus
}
#endif

#endif
