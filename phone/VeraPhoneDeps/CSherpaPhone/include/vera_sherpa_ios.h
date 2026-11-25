// Vera's ears on the iPhone: the few sherpa-onnx calls the phone needs, linked statically (iOS allows no dlopen of
// our own libraries). Same shape as the Mac's app/Sources/CSherpa, without the loader.
#pragma once
#include <stdint.h>

const char *vera_sherpa_version(void);
void vera_sherpa_free(char *text);

void *vera_vad_create(const char *model, float threshold, float min_silence, float min_speech, float max_speech);
void vera_vad_accept(void *vad, const float *samples, int32_t n);
int vera_vad_detected(void *vad);
int vera_vad_pop_all(void *vad);
void vera_vad_reset(void *vad);
void vera_vad_destroy(void *vad);

void *vera_offline_create_nemo_ctc(const char *model, const char *tokens, int32_t feature_dim, int32_t threads);
void *vera_offline_create_nemo_ctc_on(const char *model, const char *tokens, int32_t feature_dim, int32_t threads,
                                      const char *provider);
char *vera_offline_decode(void *recognizer, const float *samples, int32_t n, int32_t rate);
void vera_offline_destroy(void *recognizer);

// onnxruntime's API base from the framework linked here, for Vera's voice (SileroVoice → COnnx in app/).
const void *vera_ort_api_base(void);
