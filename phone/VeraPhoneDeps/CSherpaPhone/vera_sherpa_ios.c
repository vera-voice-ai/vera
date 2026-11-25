#include "vera_sherpa_ios.h"
#include "sherpa_c_api.h"
#include <stdlib.h>
#include <string.h>

const char *vera_sherpa_version(void) { return SherpaOnnxGetVersionStr(); }
void vera_sherpa_free(char *text) { free(text); }
static char *copy(const char *s) { return strdup(s ? s : ""); }

void *vera_vad_create(const char *model, float threshold, float min_silence, float min_speech, float max_speech) {
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
  return (void *)SherpaOnnxCreateVoiceActivityDetector(&c, 30.0f);
}
void vera_vad_accept(void *v, const float *s, int32_t n) { SherpaOnnxVoiceActivityDetectorAcceptWaveform(v, s, n); }
int vera_vad_detected(void *v) { return SherpaOnnxVoiceActivityDetectorDetected(v); }
int vera_vad_pop_all(void *v) {
  int n = 0;
  while (!SherpaOnnxVoiceActivityDetectorEmpty(v)) { SherpaOnnxVoiceActivityDetectorPop(v); n++; }
  return n;
}
void vera_vad_reset(void *v) { SherpaOnnxVoiceActivityDetectorReset(v); }
void vera_vad_destroy(void *v) { if (v) SherpaOnnxDestroyVoiceActivityDetector(v); }

void *vera_offline_create_nemo_ctc(const char *model, const char *tokens, int32_t feature_dim, int32_t threads) {
  return vera_offline_create_nemo_ctc_on(model, tokens, feature_dim, threads, "cpu");
}
// `provider`: "cpu", or "coreml" (onnxruntime hands the parts it can to Core ML: the Neural Engine or the GPU).
void *vera_offline_create_nemo_ctc_on(const char *model, const char *tokens, int32_t feature_dim, int32_t threads,
                                      const char *provider) {
  SherpaOnnxOfflineRecognizerConfig c; memset(&c, 0, sizeof c);
  c.feat_config.sample_rate = 16000;
  c.feat_config.feature_dim = feature_dim;
  c.model_config.nemo_ctc.model = model;
  c.model_config.tokens = tokens;
  c.model_config.num_threads = threads;
  c.model_config.provider = provider;
  c.decoding_method = "greedy_search";
  return (void *)SherpaOnnxCreateOfflineRecognizer(&c);
}
char *vera_offline_decode(void *r, const float *s, int32_t n, int32_t rate) {
  const SherpaOnnxOfflineStream *st = SherpaOnnxCreateOfflineStream(r);
  SherpaOnnxAcceptWaveformOffline(st, rate, s, n);
  SherpaOnnxDecodeOfflineStream(r, st);
  const SherpaOnnxOfflineRecognizerResult *res = SherpaOnnxGetOfflineStreamResult(st);
  char *text = copy(res ? res->text : "");
  if (res) SherpaOnnxDestroyOfflineRecognizerResult(res);
  SherpaOnnxDestroyOfflineStream(st);
  return text;
}
void vera_offline_destroy(void *r) { if (r) SherpaOnnxDestroyOfflineRecognizer(r); }

// From onnxruntime_c_api.h: `const OrtApiBase *OrtGetApiBase(void)` — declared plainly to keep that header out.
extern const void *OrtGetApiBase(void);
const void *vera_ort_api_base(void) { return OrtGetApiBase(); }
