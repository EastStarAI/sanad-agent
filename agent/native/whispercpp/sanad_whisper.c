// Minimal C surface over whisper.cpp for the Sanad daemon.
//
// whisper.cpp returns `struct whisper_full_params` by value and keeps growing
// it, so binding that struct through dart:ffi would break on every upstream
// bump. This shim keeps the ABI to four flat functions: the daemon never sees a
// whisper struct, only an opaque handle.
//
// Build (macOS arm64):
//   see agent/tool/build_whispercpp.sh

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "whisper.h"

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
void* sanad_whisper_load(const char* path_model, int use_gpu, char* err, int err_cap) {
  whisper_log_set(sanad_whisper_quiet_log, NULL);
  struct whisper_context_params cparams = whisper_context_default_params();
  cparams.use_gpu = use_gpu != 0;
  cparams.flash_attn = use_gpu != 0;
  struct whisper_context* ctx = whisper_init_from_file_with_params(path_model, cparams);
  if (ctx == NULL && err != NULL && err_cap > 0) {
    snprintf(err, (size_t)err_cap, "whisper_init_from_file_with_params failed");
  }
  return ctx;
}

void sanad_whisper_free(void* handle) {
  if (handle == NULL) return;
  whisper_free((struct whisper_context*)handle);
}

// Transcribes one float32 buffer (16 kHz mono). Returns the number of bytes
// written into `out` (excluding the terminator), or -1 on failure.
//
// `out` receives the concatenated segment texts; the caller owns the buffer.
int sanad_whisper_run(void* handle,
                      const float* samples,
                      int n_samples,
                      const char* language,
                      int n_threads,
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

  if (whisper_full(ctx, params, samples, n_samples) != 0) return -1;

  const int n_segments = whisper_full_n_segments(ctx);
  int written = 0;
  for (int i = 0; i < n_segments; i++) {
    const char* text = whisper_full_get_segment_text(ctx, i);
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
  return written;
}

// Reports the ggml backend actually in use ("CPU" for the CPU-only build).
const char* sanad_whisper_system_info(void) {
  return whisper_print_system_info();
}
