// Thin C API over llama.cpp + mtmd for EmbeddingGemma 2.
// Every embed call returns SB_DIM floats, Matryoshka-truncated and L2-normalised.
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SB_DIM 512

typedef struct sb_ctx sb_ctx;

// mmproj_path may be NULL: text-only (what the bar itself loads).
sb_ctx * sb_init(const char * model_path, const char * mmproj_path, int n_ctx, int use_gpu);
void     sb_free(sb_ctx * c);

// 0 on success
int sb_embed_text (sb_ctx * c, const char * text, float * out);
int sb_embed_image(sb_ctx * c, const uint8_t * rgb, int w, int h, float * out);
int sb_embed_audio(sb_ctx * c, const float * pcm16k, size_t n_samples, float * out);

// out[i] = dot(q, docs[i]) for n int8-quantised rows of SB_DIM
void sb_scan_i8(const float * q, const int8_t * docs, size_t n, float * out);
// the plain float loop sb_scan_i8 must agree with (kept for checks)
void sb_scan_i8_ref(const float * q, const int8_t * docs, size_t n, float * out);
// out[i] = |docs[i]|
void sb_norms_i8(const int8_t * docs, size_t n, float * out);
// performance cores (fallback 4)
int sb_threads(void);

// Small generative model, used only to turn a sentence into a flat JSON command.
typedef struct sb_llm sb_llm;
sb_llm * sb_llm_init(const char * model_path, int n_ctx);
void     sb_llm_free(sb_llm * l);
// prompt is fully formatted; grammar is GBNF (root rule "root") or NULL. Returns bytes written, <0 on error.
int sb_llm_generate(sb_llm * l, const char * prompt, const char * grammar, int max_tokens, char * out, int out_len);
// Decodes a fixed prompt prefix once and keeps its state; later prompts that start with it only decode the rest.
// Returns the prefix length in tokens, <0 on error.
int sb_llm_cache_prefix(sb_llm * l, const char * prefix);

#ifdef __cplusplus
}
#endif
