#include "vera_sherpa.h"
#include "vendor/sherpa-onnx-c-api.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FN(name) static __typeof__(name) *p_##name
FN(SherpaOnnxGetVersionStr);
FN(SherpaOnnxCreateVoiceActivityDetector); FN(SherpaOnnxDestroyVoiceActivityDetector);
FN(SherpaOnnxVoiceActivityDetectorAcceptWaveform); FN(SherpaOnnxVoiceActivityDetectorDetected);
FN(SherpaOnnxVoiceActivityDetectorEmpty); FN(SherpaOnnxVoiceActivityDetectorPop); FN(SherpaOnnxVoiceActivityDetectorReset);
FN(SherpaOnnxCreateOfflineRecognizer); FN(SherpaOnnxDestroyOfflineRecognizer);
FN(SherpaOnnxCreateOfflineStream); FN(SherpaOnnxDestroyOfflineStream); FN(SherpaOnnxAcceptWaveformOffline);
FN(SherpaOnnxDecodeOfflineStream); FN(SherpaOnnxGetOfflineStreamResult); FN(SherpaOnnxDestroyOfflineRecognizerResult);
FN(SherpaOnnxCreateOnlineRecognizer); FN(SherpaOnnxDestroyOnlineRecognizer);
FN(SherpaOnnxCreateOnlineStream); FN(SherpaOnnxDestroyOnlineStream); FN(SherpaOnnxOnlineStreamAcceptWaveform);
FN(SherpaOnnxIsOnlineStreamReady); FN(SherpaOnnxDecodeOnlineStream); FN(SherpaOnnxGetOnlineStreamResult);
FN(SherpaOnnxDestroyOnlineRecognizerResult); FN(SherpaOnnxOnlineStreamInputFinished);
FN(SherpaOnnxCreateSpeakerEmbeddingExtractor); FN(SherpaOnnxDestroySpeakerEmbeddingExtractor);
FN(SherpaOnnxSpeakerEmbeddingExtractorDim); FN(SherpaOnnxSpeakerEmbeddingExtractorCreateStream);
FN(SherpaOnnxSpeakerEmbeddingExtractorIsReady); FN(SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding);
FN(SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding);

static char error_text[512];
static int loaded = 0;

const char *vera_sherpa_error(void) { return error_text; }

int vera_sherpa_load(const char *path) {
  if (loaded) return 0;
  void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (!h) { snprintf(error_text, sizeof error_text, "%s", dlerror()); return -1; }
#define LOAD(name) if (!(p_##name = (__typeof__(p_##name))dlsym(h, #name))) { \
    snprintf(error_text, sizeof error_text, "нет функции %s", #name); return -1; }
  LOAD(SherpaOnnxGetVersionStr);
  LOAD(SherpaOnnxCreateVoiceActivityDetector); LOAD(SherpaOnnxDestroyVoiceActivityDetector);
  LOAD(SherpaOnnxVoiceActivityDetectorAcceptWaveform); LOAD(SherpaOnnxVoiceActivityDetectorDetected);
  LOAD(SherpaOnnxVoiceActivityDetectorEmpty); LOAD(SherpaOnnxVoiceActivityDetectorPop); LOAD(SherpaOnnxVoiceActivityDetectorReset);
  LOAD(SherpaOnnxCreateOfflineRecognizer); LOAD(SherpaOnnxDestroyOfflineRecognizer);
  LOAD(SherpaOnnxCreateOfflineStream); LOAD(SherpaOnnxDestroyOfflineStream); LOAD(SherpaOnnxAcceptWaveformOffline);
  LOAD(SherpaOnnxDecodeOfflineStream); LOAD(SherpaOnnxGetOfflineStreamResult); LOAD(SherpaOnnxDestroyOfflineRecognizerResult);
  LOAD(SherpaOnnxCreateOnlineRecognizer); LOAD(SherpaOnnxDestroyOnlineRecognizer);
  LOAD(SherpaOnnxCreateOnlineStream); LOAD(SherpaOnnxDestroyOnlineStream); LOAD(SherpaOnnxOnlineStreamAcceptWaveform);
  LOAD(SherpaOnnxIsOnlineStreamReady); LOAD(SherpaOnnxDecodeOnlineStream); LOAD(SherpaOnnxGetOnlineStreamResult);
  LOAD(SherpaOnnxDestroyOnlineRecognizerResult); LOAD(SherpaOnnxOnlineStreamInputFinished);
  LOAD(SherpaOnnxCreateSpeakerEmbeddingExtractor); LOAD(SherpaOnnxDestroySpeakerEmbeddingExtractor);
  LOAD(SherpaOnnxSpeakerEmbeddingExtractorDim); LOAD(SherpaOnnxSpeakerEmbeddingExtractorCreateStream);
  LOAD(SherpaOnnxSpeakerEmbeddingExtractorIsReady); LOAD(SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding);
  LOAD(SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding);
  loaded = 1;
  return 0;
}

const char *vera_sherpa_version(void) { return loaded ? p_SherpaOnnxGetVersionStr() : ""; }
void vera_sherpa_free(char *text) { free(text); }
static char *copy(const char *s) { return strdup(s ? s : ""); }

void *vera_vad_create(const char *model, float threshold, float min_silence, float min_speech, float max_speech) {
  if (!loaded) return NULL;
  SherpaOnnxVadModelConfig c; memset(&c, 0, sizeof c);
  c.silero_vad.model = model;
  c.silero_vad.threshold = threshold;
  c.silero_vad.min_silence_duration = min_silence;
  c.silero_vad.min_speech_duration = min_speech;
  c.silero_vad.max_speech_duration = max_speech;
  c.silero_vad.window_size = 512;
  c.sample_rate = 16000;
  c.num_threads = 1;
  c.provider = "cpu";
  return (void *)p_SherpaOnnxCreateVoiceActivityDetector(&c, 30.0f);
}
void vera_vad_accept(void *v, const float *s, int32_t n) { p_SherpaOnnxVoiceActivityDetectorAcceptWaveform(v, s, n); }
int vera_vad_detected(void *v) { return p_SherpaOnnxVoiceActivityDetectorDetected(v); }
int vera_vad_pop_all(void *v) {
  int n = 0;
  while (!p_SherpaOnnxVoiceActivityDetectorEmpty(v)) { p_SherpaOnnxVoiceActivityDetectorPop(v); n++; }
  return n;
}
void vera_vad_reset(void *v) { p_SherpaOnnxVoiceActivityDetectorReset(v); }
void vera_vad_destroy(void *v) { if (v) p_SherpaOnnxDestroyVoiceActivityDetector(v); }

void *vera_offline_create_nemo_ctc(const char *model, const char *tokens, int32_t feature_dim, int32_t threads) {
  if (!loaded) return NULL;
  SherpaOnnxOfflineRecognizerConfig c; memset(&c, 0, sizeof c);
  c.feat_config.sample_rate = 16000;
  c.feat_config.feature_dim = feature_dim;
  c.model_config.nemo_ctc.model = model;
  c.model_config.tokens = tokens;
  c.model_config.num_threads = threads;
  c.model_config.provider = "cpu";
  c.decoding_method = "greedy_search";
  return (void *)p_SherpaOnnxCreateOfflineRecognizer(&c);
}
char *vera_offline_decode(void *r, const float *s, int32_t n, int32_t rate) {
  const SherpaOnnxOfflineStream *st = p_SherpaOnnxCreateOfflineStream(r);
  p_SherpaOnnxAcceptWaveformOffline(st, rate, s, n);
  p_SherpaOnnxDecodeOfflineStream(r, st);
  const SherpaOnnxOfflineRecognizerResult *res = p_SherpaOnnxGetOfflineStreamResult(st);
  char *text = copy(res ? res->text : "");
  if (res) p_SherpaOnnxDestroyOfflineRecognizerResult(res);
  p_SherpaOnnxDestroyOfflineStream(st);
  return text;
}
void vera_offline_destroy(void *r) { if (r) p_SherpaOnnxDestroyOfflineRecognizer(r); }

void *vera_online_create_tone(const char *model, const char *tokens, int32_t sample_rate, int32_t threads) {
  if (!loaded) return NULL;
  SherpaOnnxOnlineRecognizerConfig c; memset(&c, 0, sizeof c);
  c.feat_config.sample_rate = sample_rate;
  c.feat_config.feature_dim = 80;
  c.model_config.t_one_ctc.model = model;
  c.model_config.tokens = tokens;
  c.model_config.num_threads = threads;
  c.model_config.provider = "cpu";
  c.decoding_method = "greedy_search";
  return (void *)p_SherpaOnnxCreateOnlineRecognizer(&c);
}
void *vera_online_stream(void *r) { return (void *)p_SherpaOnnxCreateOnlineStream(r); }
static void drain(void *r, void *st) { while (p_SherpaOnnxIsOnlineStreamReady(r, st)) p_SherpaOnnxDecodeOnlineStream(r, st); }
void vera_online_accept(void *r, void *st, const float *s, int32_t n, int32_t rate) {
  p_SherpaOnnxOnlineStreamAcceptWaveform(st, rate, s, n);
  drain(r, st);
}
void vera_online_finish(void *r, void *st) { p_SherpaOnnxOnlineStreamInputFinished(st); drain(r, st); }
char *vera_online_text(void *r, void *st) {
  const SherpaOnnxOnlineRecognizerResult *res = p_SherpaOnnxGetOnlineStreamResult(r, st);
  char *text = copy(res ? res->text : "");
  if (res) p_SherpaOnnxDestroyOnlineRecognizerResult(res);
  return text;
}
void vera_online_stream_destroy(void *st) { if (st) p_SherpaOnnxDestroyOnlineStream(st); }
void vera_online_destroy(void *r) { if (r) p_SherpaOnnxDestroyOnlineRecognizer(r); }

void *vera_speaker_create(const char *model, int32_t threads) {
  if (!loaded) return NULL;
  SherpaOnnxSpeakerEmbeddingExtractorConfig c; memset(&c, 0, sizeof c);
  c.model = model; c.num_threads = threads; c.provider = "cpu";
  return (void *)p_SherpaOnnxCreateSpeakerEmbeddingExtractor(&c);
}
int32_t vera_speaker_dim(void *e) { return p_SherpaOnnxSpeakerEmbeddingExtractorDim(e); }
float *vera_speaker_embed(void *e, const float *s, int32_t n, int32_t rate) {
  const SherpaOnnxOnlineStream *st = p_SherpaOnnxSpeakerEmbeddingExtractorCreateStream(e);
  p_SherpaOnnxOnlineStreamAcceptWaveform(st, rate, s, n);
  p_SherpaOnnxOnlineStreamInputFinished(st);
  float *out = NULL;
  if (p_SherpaOnnxSpeakerEmbeddingExtractorIsReady(e, st)) {
    const float *v = p_SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(e, st);
    int32_t d = p_SherpaOnnxSpeakerEmbeddingExtractorDim(e);
    out = malloc(sizeof(float) * d);
    memcpy(out, v, sizeof(float) * d);
    p_SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(v);
  }
  p_SherpaOnnxDestroyOnlineStream(st);
  return out;
}
void vera_sherpa_free_floats(float *v) { free(v); }
void vera_speaker_destroy(void *e) { if (e) p_SherpaOnnxDestroySpeakerEmbeddingExtractor(e); }
