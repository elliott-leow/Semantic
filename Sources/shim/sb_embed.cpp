#include "sb_embed.h"

#include "llama.h"
#include "mtmd.h"

#include <cmath>
#include <cstring>
#include <string>
#include <vector>

struct sb_ctx {
    llama_model *     model = nullptr;
    llama_context *   ctx   = nullptr;
    llama_batch_ext * batch = nullptr;
    mtmd_context *    mctx  = nullptr;
    int               n_ctx = 0;
    // media embeddings must outlive llama_process()
    std::vector<std::vector<float>> held;
};

static void quiet_log(enum ggml_log_level level, const char * text, void *) {
    if (level >= GGML_LOG_LEVEL_ERROR && getenv("SEMBAR_DEBUG")) fputs(text, stderr);
}

sb_ctx * sb_init(const char * model_path, const char * mmproj_path, int n_ctx, int use_gpu) {
    llama_log_set(quiet_log, nullptr);
    mtmd_log_set(quiet_log, nullptr);
    llama_backend_init();

    auto * c = new sb_ctx();
    c->n_ctx = n_ctx;

    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = use_gpu ? -1 : 0;
    c->model = llama_model_load_from_file(model_path, mp);
    if (!c->model) { sb_free(c); return nullptr; }

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx      = n_ctx;
    cp.n_batch    = n_ctx; // the encoder is non-causal: a sequence must fit one ubatch
    cp.n_ubatch   = n_ctx;
    cp.n_seq_max  = 1;
    cp.embeddings = true;
    cp.no_perf    = true;
    cp.n_threads       = 4;
    cp.n_threads_batch = 4;
    c->ctx = llama_init_from_model(c->model, cp);
    if (!c->ctx) { sb_free(c); return nullptr; }
    c->batch = llama_batch_ext_init(c->ctx);

    if (mmproj_path) {
        mtmd_context_params mm = mtmd_context_params_default();
        mm.use_gpu       = use_gpu != 0;
        mm.print_timings = false;
        mm.n_threads     = 4;
        mm.warmup        = false;
        c->mctx = mtmd_init_from_file(mmproj_path, c->model, mm);
        if (!c->mctx) { sb_free(c); return nullptr; }
    }
    return c;
}

void sb_free(sb_ctx * c) {
    if (!c) return;
    if (c->mctx)  mtmd_free(c->mctx);
    if (c->batch) llama_batch_ext_free(c->batch);
    if (c->ctx)   llama_free(c->ctx);
    if (c->model) llama_model_free(c->model);
    delete c;
}

// run the pending batch and write the pooled, truncated, normalised vector
static int finish(sb_ctx * c, float * out) {
    llama_memory_clear(llama_get_memory(c->ctx), true);
    int rc = llama_process(c->ctx, LLAMA_PROCESS_TYPE_DECODE, c->batch);
    c->held.clear();
    if (rc != 0) return rc;
    const float * e = llama_get_embeddings_seq(c->ctx, 0);
    if (!e) return -10;
    double n = 0;
    for (int i = 0; i < SB_DIM; i++) n += (double) e[i] * e[i];
    n = std::sqrt(n);
    if (n < 1e-9) return -11;
    for (int i = 0; i < SB_DIM; i++) out[i] = (float) (e[i] / n);
    return 0;
}

static bool add_tokens(sb_ctx * c, const llama_token * toks, size_t n, llama_pos & pos) {
    for (size_t i = 0; i < n; i++) {
        if (pos >= c->n_ctx) return true; // truncate silently
        int32_t idx = llama_batch_ext_add_token(c->batch, 0, toks[i]);
        if (idx < 0) return false;
        llama_pos p = pos++;
        llama_batch_ext_set_pos(c->batch, idx, &p);
        llama_batch_ext_set_output_embd(c->batch, idx, true);
    }
    return true;
}

int sb_embed_text(sb_ctx * c, const char * text, float * out) {
    const llama_vocab * vocab = llama_model_get_vocab(c->model);
    std::vector<llama_token> toks(c->n_ctx + 8);
    int len = (int) strlen(text);
    int n = llama_tokenize(vocab, text, len, toks.data(), (int) toks.size(), true, true);
    while (n < 0 && len > 16) {
        // too long for the context: cut the text (on a UTF-8 boundary) and retry
        len = len * 3 / 4;
        while (len > 0 && ((unsigned char) text[len] & 0xC0) == 0x80) len--;
        n = llama_tokenize(vocab, text, len, toks.data(), (int) toks.size(), true, true);
    }
    if (n <= 0) return -1;
    if (n > c->n_ctx) n = c->n_ctx;

    llama_batch_ext_clear(c->batch);
    llama_pos pos = 0;
    if (!add_tokens(c, toks.data(), n, pos)) return -2;
    return finish(c, out);
}

static int embed_media(sb_ctx * c, mtmd_bitmap * bmp, float * out) {
    if (!c->mctx) { mtmd_bitmap_free(bmp); return -20; }
    const char * marker = mtmd_default_marker();
    mtmd_input_text txt = { marker, strlen(marker), true, true };
    mtmd_input_chunks * chunks = mtmd_input_chunks_init();
    const mtmd_bitmap * bitmaps[1] = { bmp };
    int rc = mtmd_tokenize(c->mctx, chunks, &txt, bitmaps, 1);
    if (rc != 0) { mtmd_input_chunks_free(chunks); mtmd_bitmap_free(bmp); return -21; }

    const size_t n_embd   = llama_model_n_embd_inp(c->model);
    const bool   is_mrope = mtmd_decode_use_mrope(c->mctx);
    llama_batch_ext_clear(c->batch);
    llama_pos pos = 0;
    rc = 0;

    for (size_t ci = 0; ci < mtmd_input_chunks_size(chunks) && rc == 0; ci++) {
        const mtmd_input_chunk * ch = mtmd_input_chunks_get(chunks, ci);
        if (mtmd_input_chunk_get_type(ch) == MTMD_INPUT_CHUNK_TYPE_TEXT) {
            size_t nt = 0;
            const llama_token * t = mtmd_input_chunk_get_tokens_text(ch, &nt);
            if (!add_tokens(c, t, nt, pos)) rc = -22;
            continue;
        }
        if (mtmd_encode_chunk(c->mctx, ch) != 0) { rc = -23; break; }
        const size_t nt = mtmd_input_chunk_get_n_tokens(ch);
        const float * e = mtmd_get_output_embd(c->mctx);
        c->held.emplace_back(e, e + nt * n_embd);
        const float * held = c->held.back().data();
        const mtmd_image_tokens * img = mtmd_input_chunk_get_tokens_image(ch);
        const llama_pos pos_0 = pos;
        for (size_t i = 0; i < nt; i++) {
            if (pos_0 + (llama_pos) i >= c->n_ctx) break;
            llama_embd row = { held + i * n_embd, 1, n_embd };
            int32_t idx = llama_batch_ext_add_embd(c->batch, 0, row);
            if (idx < 0) { rc = -24; break; }
            llama_pos p = pos_0 + (llama_pos) i;
            llama_pos ps[4] = { p, p, p, p };
            if (is_mrope && img) {
                mtmd_decoder_pos rel = mtmd_image_tokens_get_decoder_pos(img, pos_0, i);
                ps[0] = rel.t; ps[1] = rel.y; ps[2] = rel.x; ps[3] = rel.z;
            }
            llama_batch_ext_set_pos(c->batch, idx, ps);
            llama_batch_ext_set_output_embd(c->batch, idx, true);
        }
        pos = pos_0 + mtmd_input_chunk_get_n_pos(ch);
    }

    mtmd_input_chunks_free(chunks);
    mtmd_bitmap_free(bmp);
    if (rc != 0) { c->held.clear(); return rc; }
    return finish(c, out);
}

int sb_embed_image(sb_ctx * c, const uint8_t * rgb, int w, int h, float * out) {
    return embed_media(c, mtmd_bitmap_init((uint32_t) w, (uint32_t) h, rgb), out);
}

int sb_embed_audio(sb_ctx * c, const float * pcm16k, size_t n_samples, float * out) {
    return embed_media(c, mtmd_bitmap_init_from_audio(n_samples, pcm16k), out);
}

void sb_scan_i8(const float * q, const int8_t * docs, size_t n, float * out) {
    for (size_t r = 0; r < n; r++) {
        const int8_t * d = docs + r * SB_DIM;
        float s = 0;
        for (int i = 0; i < SB_DIM; i++) s += q[i] * (float) d[i];
        out[r] = s;
    }
}

struct sb_llm {
    llama_model *   model = nullptr;
    llama_context * ctx   = nullptr;
    int             n_ctx = 0;
};

sb_llm * sb_llm_init(const char * model_path, int n_ctx) {
    llama_log_set(quiet_log, nullptr);
    llama_backend_init();
    auto * l = new sb_llm();
    l->n_ctx = n_ctx;
    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = -1;
    l->model = llama_model_load_from_file(model_path, mp);
    if (!l->model) { sb_llm_free(l); return nullptr; }
    llama_context_params cp = llama_context_default_params();
    cp.n_ctx   = n_ctx;
    cp.n_batch = n_ctx;
    cp.no_perf = true;
    cp.n_threads       = 4;
    cp.n_threads_batch = 4;
    l->ctx = llama_init_from_model(l->model, cp);
    if (!l->ctx) { sb_llm_free(l); return nullptr; }
    return l;
}

void sb_llm_free(sb_llm * l) {
    if (!l) return;
    if (l->ctx)   llama_free(l->ctx);
    if (l->model) llama_model_free(l->model);
    delete l;
}

int sb_llm_generate(sb_llm * l, const char * prompt, const char * grammar, int max_tokens, char * out, int out_len) {
    const llama_vocab * vocab = llama_model_get_vocab(l->model);
    std::vector<llama_token> toks(l->n_ctx);
    int n = llama_tokenize(vocab, prompt, (int) strlen(prompt), toks.data(), (int) toks.size(), true, true);
    if (n <= 0 || n + max_tokens > l->n_ctx) return -1;

    llama_sampler * smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    if (grammar) {
        llama_sampler * g = llama_sampler_init_grammar(vocab, grammar, "root");
        if (!g) { llama_sampler_free(smpl); return -2; }
        llama_sampler_chain_add(smpl, g);
    }
    llama_sampler_chain_add(smpl, llama_sampler_init_greedy());

    llama_memory_clear(llama_get_memory(l->ctx), true);
    std::string text;
    llama_batch batch = llama_batch_get_one(toks.data(), n);
    int rc = 0;
    for (int i = 0; i < max_tokens; i++) {
        if (llama_decode(l->ctx, batch) != 0) { rc = -3; break; }
        llama_token id = llama_sampler_sample(smpl, l->ctx, -1);
        if (llama_vocab_is_eog(vocab, id)) break;
        char piece[256];
        int len = llama_token_to_piece(vocab, id, piece, sizeof(piece), 0, false);
        if (len > 0) text.append(piece, len);
        toks[0] = id;
        batch = llama_batch_get_one(toks.data(), 1);
    }
    llama_sampler_free(smpl);
    if (rc != 0) return rc;
    int w = (int) text.size() < out_len - 1 ? (int) text.size() : out_len - 1;
    memcpy(out, text.data(), w);
    out[w] = 0;
    return w;
}
