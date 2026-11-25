// Vera's thin bridge to the sherpa-onnx C API. The library is loaded at run time from the app bundle
// (dlopen), so Vera builds and tests without it; nothing is searched for on the machine.
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Loads libsherpa-onnx-c-api.dylib from `path`. 0 on success, otherwise -1 and `vera_sherpa_error()` says why.
int vera_sherpa_load(const char *path);
const char *vera_sherpa_error(void);
const char *vera_sherpa_version(void);
void vera_sherpa_free(char *text);

// Silero VAD: speech or not, for 512-sample windows at 16 kHz.
void *vera_vad_create(const char *model, float threshold, float min_silence, float min_speech, float max_speech);
void vera_vad_accept(void *vad, const float *samples, int32_t n);
int vera_vad_detected(void *vad);
/// Pops every finished speech segment; returns how many there were.
int vera_vad_pop_all(void *vad);
void vera_vad_reset(void *vad);
void vera_vad_destroy(void *vad);

// Non-streaming NeMo CTC (GigaAM): one call decodes a whole piece of audio. The text is malloc'd.
void *vera_offline_create_nemo_ctc(const char *model, const char *tokens, int32_t feature_dim, int32_t threads);
char *vera_offline_decode(void *recognizer, const float *samples, int32_t n, int32_t sample_rate);
void vera_offline_destroy(void *recognizer);

// Streaming T-one CTC: feed audio as it comes, read the text so far.
void *vera_online_create_tone(const char *model, const char *tokens, int32_t sample_rate, int32_t threads);
void *vera_online_stream(void *recognizer);
void vera_online_accept(void *recognizer, void *stream, const float *samples, int32_t n, int32_t sample_rate);
void vera_online_finish(void *recognizer, void *stream);
char *vera_online_text(void *recognizer, void *stream);
void vera_online_stream_destroy(void *stream);
void vera_online_destroy(void *recognizer);

// Speaker embedding (CAM++): one vector per phrase, to tell voices apart. The vector is malloc'd; free with
// vera_sherpa_free_floats. Returns NULL when the audio is too short.
void *vera_speaker_create(const char *model, int32_t threads);
int32_t vera_speaker_dim(void *extractor);
float *vera_speaker_embed(void *extractor, const float *samples, int32_t n, int32_t sample_rate);
void vera_sherpa_free_floats(float *v);
void vera_speaker_destroy(void *extractor);

#ifdef __cplusplus
}
#endif
