// Minimal C surface over whisper.cpp for the Sanad daemon.
//
// whisper.cpp returns `struct whisper_full_params` by value and keeps growing
// it, so binding that struct through dart:ffi would break on every upstream
// bump. This shim keeps the ABI to five flat functions: the daemon never sees a
// whisper struct, only an opaque handle.
//
// Build (macOS arm64):
//   see agent/tool/build_whispercpp.sh

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "whisper.h"

// The daemon loads this shim through dart:ffi, so its five entry points must be
// exported. POSIX builds export them by default; MSVC exports nothing unless a
// function is marked, which is why the Windows runtime could be built, staged,
// and then fail to load with "procedure could not be found" (error 127).
#if defined(_WIN32)
#define SANAD_WHISPER_EXPORT __declspec(dllexport)
#else
#define SANAD_WHISPER_EXPORT __attribute__((visibility("default")))
#endif

// whisper.cpp prints model-load and progress lines to stderr. The daemon must
// not log audio or transcript content, and those lines are noise in the logs.
static void sanad_whisper_quiet_log(enum ggml_log_level level, const char* text, void* user_data) {
  (void)level;
  (void)text;
  (void)user_data;
}

// Loads the ggml model with mmap and returns an opaque context.
// Returns NULL on failure and writes a short reason into `err`.
//
// `use_gpu` selects Metal when the runtime was built with it. The switch lives
// at load time because whisper.cpp binds the backend when the model is
// created; a caller that loses the GPU falls back by reopening on the CPU.
SANAD_WHISPER_EXPORT void* sanad_whisper_load(const char* path_model, int use_gpu, char* err, int err_cap) {
  whisper_log_set(sanad_whisper_quiet_log, NULL);
  struct whisper_context_params cparams = whisper_context_default_params();
  cparams.use_gpu = use_gpu != 0;
  cparams.flash_attn = use_gpu != 0;
  struct whisper_context* ctx = whisper_init_from_file_with_params_no_state(path_model, cparams);
  if (ctx == NULL && err != NULL && err_cap > 0) {
    snprintf(err, (size_t)err_cap, "whisper_init_from_file_with_params_no_state failed");
  }
  return ctx;
}

SANAD_WHISPER_EXPORT void sanad_whisper_free(void* handle) {
  if (handle == NULL) return;
  whisper_free((struct whisper_context*)handle);
}

// Encoder window of the loaded model, in mel frames (1500 for the shipped 30 s
// checkpoints). The daemon clamps its computed window to this value, because
// whisper rejects any larger one. Returns 0 when `handle` is NULL.
SANAD_WHISPER_EXPORT int sanad_whisper_audio_ctx(void* handle) {
  if (handle == NULL) return 0;
  return whisper_n_audio_ctx((struct whisper_context*)handle);
}

// Transcribes one float32 buffer (16 kHz mono). Returns the number of bytes
// written into `out` (excluding the terminator), or -1 on failure.
//
// `out` receives the concatenated segment texts; the caller owns the buffer.
SANAD_WHISPER_EXPORT int sanad_whisper_run(void* handle,
                      const float* samples,
                      int n_samples,
                      const char* language,
                      int n_threads,
                      int audio_ctx,
                      bool translate,
                      bool no_timestamps,
                      int tail_paddings_ms,
                      char* out,
                      int out_cap,
                      int* audio_ms,
                      int* decode_ms) {
  if (handle == NULL || samples == NULL || n_samples <= 0) return -1;
  struct whisper_context* ctx = (struct whisper_context*)handle;

  struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
  params.print_realtime = false;
  params.print_progress = false;
  params.print_timestamps = false;
  params.print_special = false;
  params.translate = translate;
  params.no_context = true;
  params.single_segment = false;
  params.no_timestamps = no_timestamps;
  params.n_threads = n_threads > 0 ? n_threads : 4;
  params.language = language;

  // Encoder window, in mel frames. The daemon computes it from the utterance
  // length with a measured floor (lib/infrastructure/stt/stt_decode_params.dart);
  // 0 keeps whisper's own full window, which is what the repetition guard asks
  // for when a short window looped. whisper rejects a window larger than the
  // model's, so the clamp here is the last line of defence, not the policy.
  if (audio_ctx > 0) {
    const int model_audio_ctx = whisper_n_audio_ctx(ctx);
    params.audio_ctx = audio_ctx > model_audio_ctx ? model_audio_ctx : audio_ctx;
  } else {
    params.audio_ctx = 0;
  }

  // One candidate per temperature tier. whisper.cpp's greedy default asks for
  // five, which multiplies the cost of a temperature fallback five times and
  // never changed a measured transcript; at temperature 0 it is unused.
  params.greedy.best_of = 1;

  // Model weights stay warm in `ctx`, but decode state never crosses a call.
  // whisper.cpp v1.9.5 lays flash-attention K/V buffers out from audio_ctx and
  // does not mask every padded position, so reusing a state after the window
  // shrinks can expose bytes written by the preceding larger decode.
  struct whisper_state* state = whisper_init_state(ctx);
  if (state == NULL) return -1;

  int result = -1;
  if (whisper_full_with_state(ctx, state, params, samples, n_samples) != 0) {
    goto cleanup;
  }

  const int n_segments = whisper_full_n_segments_from_state(state);
  int written = 0;
  for (int i = 0; i < n_segments; i++) {
    const char* text = whisper_full_get_segment_text_from_state(state, i);
    if (text == NULL) continue;
    // Skip whisper's non-speech markers so the daemon never inserts them.
    if (strstr(text, "[BLANK_AUDIO]") != NULL) continue;
    if (strstr(text, "(silence)") != NULL) continue;
    size_t len = strlen(text);
    if (written + (int)len + 2 >= out_cap) break;
    if (written > 0) out[written++] = ' ';
    memcpy(out + written, text, len);
    written += (int)len;
  }
  out[written] = '\0';

  if (audio_ms != NULL) *audio_ms = (int)((int64_t)n_samples * 1000 / 16000);
  if (decode_ms != NULL) *decode_ms = 0;
  result = written;

cleanup:
  whisper_free_state(state);
  return result;
}

// Reports the ggml backend actually in use ("CPU" for the CPU-only build).
SANAD_WHISPER_EXPORT const char* sanad_whisper_system_info(void) {
  return whisper_print_system_info();
}
