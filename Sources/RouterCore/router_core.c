#include "RouterCore.h"

#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// Work in blocks so the scratch buffers are fixed-size, whatever buffer size
// the hardware hands us.
#define AR_BLOCK 256
// Time constant for gain changes and effect switches. Long enough to never
// click, short enough that a mute feels instant.
#define AR_SMOOTH_SECONDS 0.010f
#define AR_MAX_GAIN 16.0f
// Anything louder than this on an input is garbage (or NaN/Inf) and is dropped.
#define AR_INPUT_SANITY 64.0f
// The output safety clipper is transparent below this level and soft above it.
#define AR_CLIP_KNEE 0.95f

// Channel-strip effects. Deliberately fixed, conventional settings.
#define AR_LOWCUT_HZ 80.0            // the standard mixing-desk low-cut
#define AR_COMP_THRESHOLD_DB (-24.0f)
#define AR_COMP_RATIO 2.0f
#define AR_COMP_KNEE_DB 10.0f
#define AR_COMP_ATTACK_S 0.010f
#define AR_COMP_RELEASE_S 0.150f
#define AR_COMP_MAKEUP_DB 2.0f       // normal speech nets out near 0 dB
#define AR_LIMIT_CEILING 0.8912509f  // -1 dBFS
#define AR_LIMIT_RELEASE_S 0.100f

#define RLX memory_order_relaxed

typedef struct { int32_t buf, ch; } ar_ref;
typedef struct { int32_t n; ar_ref c[AR_MAX_SLOT_CHANNELS]; } ar_map;

// Per-input effect state, touched only by the audio thread.
typedef struct {
    double z1[AR_MAX_SLOT_CHANNELS], z2[AR_MAX_SLOT_CHANNELS]; // low-cut biquad
    float comp_env;   // mean-square level
    float lim_env;    // peak level
    float mix_lowcut, mix_comp, mix_limit; // 0 = bypassed, 1 = fully in
} ar_fx;

struct ar_engine {
    // Topology: written only while stopped, read by the audio thread.
    ar_map in_map[AR_MAX_INPUTS];
    ar_map out_map[AR_MAX_OUTPUTS];
    float sample_rate;
    double hp_b0, hp_b1, hp_b2, hp_a1, hp_a2;
    float comp_attack, comp_release, limit_release;

    // Parameters: written by the UI, read by the audio thread.
    _Atomic float route[AR_MAX_INPUTS][AR_MAX_OUTPUTS];
    _Atomic float in_gain[AR_MAX_INPUTS];
    _Atomic float out_gain[AR_MAX_OUTPUTS];
    _Atomic bool in_mute[AR_MAX_INPUTS];
    _Atomic bool out_mute[AR_MAX_OUTPUTS];
    _Atomic uint32_t fx_flags[AR_MAX_INPUTS];

    // Audio-thread state.
    float cur_in[AR_MAX_INPUTS];
    float cur_route[AR_MAX_INPUTS][AR_MAX_OUTPUTS];
    ar_fx fx[AR_MAX_INPUTS];
    float in_buf[AR_MAX_INPUTS][AR_MAX_SLOT_CHANNELS][AR_BLOCK];
    float mix_buf[AR_MAX_SLOT_CHANNELS][AR_BLOCK];

    // Meters and counters: written by the audio thread, taken by the UI.
    _Atomic float in_peak[AR_MAX_INPUTS][AR_MAX_SLOT_CHANNELS];
    _Atomic float out_peak[AR_MAX_OUTPUTS][AR_MAX_SLOT_CHANNELS];
    _Atomic float limit_gr[AR_MAX_INPUTS];
    _Atomic float comp_gr[AR_MAX_INPUTS];
    _Atomic uint64_t callbacks;
    _Atomic uint64_t clip_events;

    // Diagnostics: written by the audio thread, taken by the diagnostic log.
    _Atomic uint64_t last_cb_time;
    _Atomic uint64_t first_cb_time;
    _Atomic uint64_t max_cb_interval;
    _Atomic uint64_t max_process_time;
    _Atomic uint64_t missing_buffers;
    uint32_t in_zero_run[AR_MAX_INPUTS];   // audio thread only
    uint32_t out_zero_run[AR_MAX_OUTPUTS]; // audio thread only
    _Atomic uint32_t in_max_zero_run[AR_MAX_INPUTS];
    _Atomic uint32_t out_max_zero_run[AR_MAX_OUTPUTS];

    AudioObjectID device;
    AudioDeviceIOProcID proc;
    _Atomic bool running;
};

static inline float ldf(_Atomic float *p) { return atomic_load_explicit(p, RLX); }
static inline void stf(_Atomic float *p, float v) { atomic_store_explicit(p, v, RLX); }

// NaN, negative and absurd gains all become something safe.
static inline float clean_gain(float g) {
    if (!(g > 0.0f)) return 0.0f;
    return g > AR_MAX_GAIN ? AR_MAX_GAIN : g;
}

static inline bool valid_in(int i) { return i >= 0 && i < AR_MAX_INPUTS; }
static inline bool valid_out(int o) { return o >= 0 && o < AR_MAX_OUTPUTS; }
static inline bool valid_ch(int c) { return c >= 0 && c < AR_MAX_SLOT_CHANNELS; }

static void update_coefficients(ar_engine *e) {
    const double fs = e->sample_rate;
    // RBJ cookbook high-pass, Q = 1/sqrt(2) (Butterworth).
    const double w0 = 2.0 * M_PI * AR_LOWCUT_HZ / fs;
    const double cw = cos(w0), alpha = sin(w0) * M_SQRT1_2;
    const double a0 = 1.0 + alpha;
    e->hp_b0 = (1.0 + cw) / 2.0 / a0;
    e->hp_b1 = -(1.0 + cw) / a0;
    e->hp_b2 = e->hp_b0;
    e->hp_a1 = -2.0 * cw / a0;
    e->hp_a2 = (1.0 - alpha) / a0;
    e->comp_attack = 1.0f - expf(-1.0f / (AR_COMP_ATTACK_S * (float)fs));
    e->comp_release = 1.0f - expf(-1.0f / (AR_COMP_RELEASE_S * (float)fs));
    e->limit_release = expf(-1.0f / (AR_LIMIT_RELEASE_S * (float)fs));
}

// ---------------------------------------------------------------------------
// Lifecycle

ar_engine *ar_engine_create(void) {
    ar_engine *e = calloc(1, sizeof *e);
    if (!e) return NULL;
    e->sample_rate = 48000.0f;
    update_coefficients(e);
    for (int i = 0; i < AR_MAX_INPUTS; i++) {
        atomic_init(&e->in_gain[i], 1.0f);
        atomic_init(&e->in_mute[i], false);
        atomic_init(&e->fx_flags[i], 0u);
        atomic_init(&e->limit_gr[i], 0.0f);
        atomic_init(&e->comp_gr[i], 0.0f);
        for (int o = 0; o < AR_MAX_OUTPUTS; o++) atomic_init(&e->route[i][o], 0.0f);
        for (int c = 0; c < AR_MAX_SLOT_CHANNELS; c++) atomic_init(&e->in_peak[i][c], 0.0f);
    }
    for (int o = 0; o < AR_MAX_OUTPUTS; o++) {
        atomic_init(&e->out_gain[o], 1.0f);
        atomic_init(&e->out_mute[o], false);
        for (int c = 0; c < AR_MAX_SLOT_CHANNELS; c++) atomic_init(&e->out_peak[o][c], 0.0f);
    }
    atomic_init(&e->callbacks, 0);
    atomic_init(&e->clip_events, 0);
    atomic_init(&e->last_cb_time, 0);
    atomic_init(&e->first_cb_time, 0);
    atomic_init(&e->max_cb_interval, 0);
    atomic_init(&e->max_process_time, 0);
    atomic_init(&e->missing_buffers, 0);
    for (int i = 0; i < AR_MAX_INPUTS; i++) atomic_init(&e->in_max_zero_run[i], 0u);
    for (int o = 0; o < AR_MAX_OUTPUTS; o++) atomic_init(&e->out_max_zero_run[o], 0u);
    atomic_init(&e->running, false);
    return e;
}

void ar_engine_destroy(ar_engine *e) {
    if (!e) return;
    ar_engine_stop(e);
    free(e);
}

// ---------------------------------------------------------------------------
// Topology

bool ar_engine_clear_topology(ar_engine *e) {
    if (atomic_load(&e->running)) return false;
    memset(e->in_map, 0, sizeof e->in_map);
    memset(e->out_map, 0, sizeof e->out_map);
    // Start every gain from silence so a new topology fades in, and give the
    // effects fresh state.
    memset(e->cur_in, 0, sizeof e->cur_in);
    memset(e->cur_route, 0, sizeof e->cur_route);
    memset(e->fx, 0, sizeof e->fx);
    for (int i = 0; i < AR_MAX_INPUTS; i++)
        for (int c = 0; c < AR_MAX_SLOT_CHANNELS; c++) stf(&e->in_peak[i][c], 0.0f);
    for (int o = 0; o < AR_MAX_OUTPUTS; o++)
        for (int c = 0; c < AR_MAX_SLOT_CHANNELS; c++) stf(&e->out_peak[o][c], 0.0f);
    return true;
}

static bool set_map(ar_engine *e, ar_map *m, int n, int b0, int c0, int b1, int c1) {
    if (atomic_load(&e->running)) return false;
    m->n = (n == 1 || n == 2) ? n : 0;
    m->c[0] = (ar_ref){ b0, c0 };
    m->c[1] = (ar_ref){ b1, c1 };
    if (m->n >= 1 && (b0 < 0 || c0 < 0)) m->n = 0;
    if (m->n == 2 && (b1 < 0 || c1 < 0)) m->n = 0;
    return true;
}

bool ar_engine_set_input_map(ar_engine *e, int slot, int n, int b0, int c0, int b1, int c1) {
    return valid_in(slot) && set_map(e, &e->in_map[slot], n, b0, c0, b1, c1);
}

bool ar_engine_set_output_map(ar_engine *e, int slot, int n, int b0, int c0, int b1, int c1) {
    return valid_out(slot) && set_map(e, &e->out_map[slot], n, b0, c0, b1, c1);
}

bool ar_engine_set_sample_rate(ar_engine *e, double sr) {
    if (atomic_load(&e->running) || !(sr >= 8000.0 && sr <= 768000.0)) return false;
    e->sample_rate = (float)sr;
    update_coefficients(e);
    return true;
}

// ---------------------------------------------------------------------------
// Parameters

void ar_engine_set_route(ar_engine *e, int in, int out, float g) {
    if (valid_in(in) && valid_out(out)) stf(&e->route[in][out], clean_gain(g));
}
void ar_engine_set_input_gain(ar_engine *e, int in, float g) {
    if (valid_in(in)) stf(&e->in_gain[in], clean_gain(g));
}
void ar_engine_set_input_mute(ar_engine *e, int in, bool m) {
    if (valid_in(in)) atomic_store_explicit(&e->in_mute[in], m, RLX);
}
void ar_engine_set_input_effects(ar_engine *e, int in, uint32_t flags) {
    if (valid_in(in)) atomic_store_explicit(&e->fx_flags[in], flags, RLX);
}
void ar_engine_set_output_gain(ar_engine *e, int out, float g) {
    if (valid_out(out)) stf(&e->out_gain[out], clean_gain(g));
}
void ar_engine_set_output_mute(ar_engine *e, int out, bool m) {
    if (valid_out(out)) atomic_store_explicit(&e->out_mute[out], m, RLX);
}

// ---------------------------------------------------------------------------
// Meters

float ar_engine_take_input_peak(ar_engine *e, int in, int ch) {
    if (!valid_in(in) || !valid_ch(ch)) return 0.0f;
    return atomic_exchange_explicit(&e->in_peak[in][ch], 0.0f, RLX);
}
float ar_engine_take_output_peak(ar_engine *e, int out, int ch) {
    if (!valid_out(out) || !valid_ch(ch)) return 0.0f;
    return atomic_exchange_explicit(&e->out_peak[out][ch], 0.0f, RLX);
}
float ar_engine_take_input_reduction(ar_engine *e, int in, uint32_t effect) {
    if (!valid_in(in)) return 0.0f;
    if (effect == AR_FX_LIMITER) return atomic_exchange_explicit(&e->limit_gr[in], 0.0f, RLX);
    if (effect == AR_FX_COMPRESSOR) return atomic_exchange_explicit(&e->comp_gr[in], 0.0f, RLX);
    return 0.0f;
}
uint64_t ar_engine_callback_count(ar_engine *e) { return atomic_load_explicit(&e->callbacks, RLX); }
uint64_t ar_engine_clip_count(ar_engine *e) { return atomic_load_explicit(&e->clip_events, RLX); }

uint64_t ar_engine_last_callback_time(ar_engine *e) { return atomic_load_explicit(&e->last_cb_time, RLX); }
uint64_t ar_engine_first_callback_time(ar_engine *e) { return atomic_load_explicit(&e->first_cb_time, RLX); }
uint64_t ar_engine_take_max_callback_interval(ar_engine *e) { return atomic_exchange_explicit(&e->max_cb_interval, 0, RLX); }
uint64_t ar_engine_take_max_process_time(ar_engine *e) { return atomic_exchange_explicit(&e->max_process_time, 0, RLX); }
uint64_t ar_engine_missing_buffer_count(ar_engine *e) { return atomic_load_explicit(&e->missing_buffers, RLX); }

uint32_t ar_engine_take_input_zero_run(ar_engine *e, int in) {
    return valid_in(in) ? atomic_exchange_explicit(&e->in_max_zero_run[in], 0u, RLX) : 0u;
}
uint32_t ar_engine_take_output_zero_run(ar_engine *e, int out) {
    return valid_out(out) ? atomic_exchange_explicit(&e->out_max_zero_run[out], 0u, RLX) : 0u;
}

static inline void raise_u64(_Atomic uint64_t *p, uint64_t v) {
    if (v > atomic_load_explicit(p, RLX)) atomic_store_explicit(p, v, RLX);
}

static inline void track_zero_run(uint32_t *run, _Atomic uint32_t *max, bool silent, uint32_t n) {
    *run = silent ? (*run > UINT32_MAX - n ? UINT32_MAX : *run + n) : 0u;
    if (*run > atomic_load_explicit(max, RLX)) atomic_store_explicit(max, *run, RLX);
}

static inline void raise_peak(_Atomic float *p, float v) {
    if (v > ldf(p)) stf(p, v);
}

// ---------------------------------------------------------------------------
// Rendering

static inline uint32_t buf_frames(const AudioBuffer *b) {
    if (!b->mData || b->mNumberChannels == 0) return 0;
    return b->mDataByteSize / (uint32_t)(sizeof(float) * b->mNumberChannels);
}

static uint32_t list_frames(const AudioBufferList *l) {
    uint32_t f = 0;
    if (!l) return 0;
    for (UInt32 i = 0; i < l->mNumberBuffers; i++) {
        uint32_t n = buf_frames(&l->mBuffers[i]);
        if (n > f) f = n;
    }
    return f;
}

// Looks up a channel reference, returning NULL if the layout doesn't have it.
static inline const AudioBuffer *resolve(const AudioBufferList *l, ar_ref r) {
    if (!l || r.buf < 0 || (UInt32)r.buf >= l->mNumberBuffers) return NULL;
    const AudioBuffer *b = &l->mBuffers[r.buf];
    if (!b->mData || r.ch < 0 || (UInt32)r.ch >= b->mNumberChannels) return NULL;
    return b;
}

static inline float smooth_toward(float cur, float target, float coef) {
    float next = cur + (target - cur) * coef;
    if (fabsf(target - next) < 1e-5f) next = target;
    return next;
}

// De-interleave one input slot into in_buf, dropping garbage samples.
// Flags a missing or short buffer, and tracks runs of exact digital silence.
static void gather_input(ar_engine *e, int i, const AudioBufferList *in, uint32_t offset, uint32_t n,
                         bool *missing) {
    const ar_map *m = &e->in_map[i];
    bool silent = true;
    for (int c = 0; c < m->n; c++) {
        float *dst = e->in_buf[i][c];
        const AudioBuffer *b = resolve(in, m->c[c]);
        if (!b) {
            memset(dst, 0, n * sizeof(float));
            *missing = true;
            continue;
        }
        const uint32_t stride = b->mNumberChannels;
        const uint32_t avail = buf_frames(b);
        if (avail < offset + n) *missing = true;
        const float *src = (const float *)b->mData + m->c[c].ch;
        for (uint32_t k = 0; k < n; k++) {
            const uint32_t f = offset + k;
            float x = (f < avail) ? src[(size_t)f * stride] : 0.0f;
            if (!(fabsf(x) <= AR_INPUT_SANITY)) x = 0.0f; // also catches NaN/Inf
            if (x != 0.0f) silent = false;
            dst[k] = x;
        }
    }
    track_zero_run(&e->in_zero_run[i], &e->in_max_zero_run[i], silent, n);
}

// Compressor static curve: gain change in dB for a level in dB (soft knee).
static inline float comp_curve_db(float level_db) {
    const float over = level_db - AR_COMP_THRESHOLD_DB;
    const float slope = 1.0f / AR_COMP_RATIO - 1.0f;
    if (2.0f * over < -AR_COMP_KNEE_DB) return 0.0f;
    if (2.0f * fabsf(over) <= AR_COMP_KNEE_DB) {
        const float t = over + AR_COMP_KNEE_DB / 2.0f;
        return slope * t * t / (2.0f * AR_COMP_KNEE_DB);
    }
    return slope * over;
}

static inline void settle(double *z) {
    if (!isfinite(*z) || fabs(*z) < 1e-25) *z = 0.0;
}

// The channel strip: low-cut -> compressor -> fader -> limiter, in place on in_buf.
// Every effect runs all the time and is crossfaded in or out, so switching one
// never clicks and its state is always warm.
static void process_strip(ar_engine *e, int i, uint32_t n, float g0, float g1, float coef) {
    const int nc = e->in_map[i].n;
    ar_fx *s = &e->fx[i];
    const uint32_t flags = atomic_load_explicit(&e->fx_flags[i], RLX);

    const float h0 = s->mix_lowcut, c0 = s->mix_comp, l0 = s->mix_limit;
    const float h1 = smooth_toward(h0, (flags & AR_FX_LOWCUT) ? 1.0f : 0.0f, coef);
    const float c1 = smooth_toward(c0, (flags & AR_FX_COMPRESSOR) ? 1.0f : 0.0f, coef);
    const float l1 = smooth_toward(l0, (flags & AR_FX_LIMITER) ? 1.0f : 0.0f, coef);
    s->mix_lowcut = h1; s->mix_comp = c1; s->mix_limit = l1;

    const float inv = 1.0f / (float)n;
    const float dg = (g1 - g0) * inv, dh = (h1 - h0) * inv, dc = (c1 - c0) * inv, dl = (l1 - l0) * inv;
    float g = g0, h = h0, cm = c0, lm = l0;

    const double b0 = e->hp_b0, b1 = e->hp_b1, b2 = e->hp_b2, a1 = e->hp_a1, a2 = e->hp_a2;
    float comp_env = s->comp_env, lim_env = s->lim_env;
    float peak[AR_MAX_SLOT_CHANNELS] = { 0.0f, 0.0f };
    float most_comp = 0.0f, least_lim = 1.0f;

    for (uint32_t k = 0; k < n; k++) {
        g += dg; h += dh; cm += dc; lm += dl;
        float x[AR_MAX_SLOT_CHANNELS];
        float power = 0.0f;

        for (int c = 0; c < nc; c++) {
            const double in = e->in_buf[i][c][k];
            const double y = b0 * in + s->z1[c];
            s->z1[c] = b1 * in - a1 * y + s->z2[c];
            s->z2[c] = b2 * in - a2 * y;
            const float v = (float)in + h * ((float)y - (float)in);
            x[c] = v;
            power += v * v;
        }
        power /= (float)nc;

        comp_env += ((power > comp_env) ? e->comp_attack : e->comp_release) * (power - comp_env);
        float gain = g;
        if (cm > 0.0f) {
            const float curve = comp_curve_db(10.0f * log10f(comp_env + 1e-12f));
            if (-curve > most_comp) most_comp = -curve;
            const float gc = expf((curve + AR_COMP_MAKEUP_DB) * 0.11512925f); // dB -> linear
            gain *= 1.0f + cm * (gc - 1.0f);
        }

        float pk = 0.0f;
        for (int c = 0; c < nc; c++) {
            x[c] *= gain;
            const float a = fabsf(x[c]);
            if (a > pk) pk = a;
        }

        // Instant attack: the envelope is never below this sample's peak, so
        // with the limiter fully in, nothing can pass the ceiling.
        lim_env *= e->limit_release;
        if (pk > lim_env) lim_env = pk;
        const float gl = lim_env > AR_LIMIT_CEILING ? AR_LIMIT_CEILING / lim_env : 1.0f;
        if (lm > 0.5f && gl < least_lim) least_lim = gl;
        const float glim = 1.0f + lm * (gl - 1.0f);

        for (int c = 0; c < nc; c++) {
            const float v = x[c] * glim;
            e->in_buf[i][c][k] = v;
            const float a = fabsf(v);
            if (a > peak[c]) peak[c] = a;
        }
    }

    for (int c = 0; c < nc; c++) {
        settle(&s->z1[c]);
        settle(&s->z2[c]);
        raise_peak(&e->in_peak[i][c], peak[c]);
    }
    s->comp_env = isfinite(comp_env) ? comp_env : 0.0f;
    s->lim_env = isfinite(lim_env) ? lim_env : 0.0f;
    if (most_comp > 0.0f) raise_peak(&e->comp_gr[i], most_comp);
    if (least_lim < 1.0f) raise_peak(&e->limit_gr[i], -20.0f * log10f(least_lim));
}

// Mix every routed input into one output slot and add it to the hardware buffer.
static void mix_output(ar_engine *e, int o, AudioBufferList *out,
                       uint32_t offset, uint32_t n, float coef, bool *missing) {
    const ar_map *om = &e->out_map[o];
    const int no = om->n;
    const float og = atomic_load_explicit(&e->out_mute[o], RLX) ? 0.0f : clean_gain(ldf(&e->out_gain[o]));

    for (int c = 0; c < no; c++) memset(e->mix_buf[c], 0, n * sizeof(float));

    for (int i = 0; i < AR_MAX_INPUTS; i++) {
        const int ni = e->in_map[i].n;
        float target = 0.0f;
        if (ni > 0 && !atomic_load_explicit(&e->in_mute[i], RLX))
            target = clean_gain(ldf(&e->route[i][o])) * og;
        const float g0 = e->cur_route[i][o];
        const float g1 = smooth_toward(g0, target, coef);
        e->cur_route[i][o] = g1;
        if (ni == 0 || (g0 == 0.0f && g1 == 0.0f)) continue;

        const float dg = (g1 - g0) / (float)n;
        const float *l = e->in_buf[i][0];
        const float *r = ni > 1 ? e->in_buf[i][1] : l; // mono feeds both sides
        float g = g0;
        if (no == 1) {
            float *d = e->mix_buf[0];
            if (ni == 1) {
                for (uint32_t k = 0; k < n; k++) { g += dg; d[k] += l[k] * g; }
            } else {
                for (uint32_t k = 0; k < n; k++) { g += dg; d[k] += 0.5f * (l[k] + r[k]) * g; }
            }
        } else {
            float *dl = e->mix_buf[0], *dr = e->mix_buf[1];
            for (uint32_t k = 0; k < n; k++) { g += dg; dl[k] += l[k] * g; dr[k] += r[k] * g; }
        }
    }

    bool silent = true;
    for (int c = 0; c < no; c++) {
        const float *s = e->mix_buf[c];
        float peak = 0.0f;
        for (uint32_t k = 0; k < n; k++) {
            const float a = fabsf(s[k]);
            if (a > peak) peak = a;
        }
        if (peak != 0.0f) silent = false;
        raise_peak(&e->out_peak[o][c], peak > 1.0f ? 1.0f : peak);

        const AudioBuffer *cb = resolve(out, om->c[c]);
        if (!cb) {
            *missing = true;
            continue;
        }
        const uint32_t stride = cb->mNumberChannels;
        const uint32_t avail = buf_frames(cb);
        if (avail < offset + n) *missing = true;
        float *dst = (float *)cb->mData + om->c[c].ch;
        for (uint32_t k = 0; k < n; k++) {
            const uint32_t f = offset + k;
            if (f < avail) dst[(size_t)f * stride] += s[k];
        }
    }
    track_zero_run(&e->out_zero_run[o], &e->out_max_zero_run[o], silent, n);
}

// Transparent below the knee, smooth tanh saturation above it, never past 1.0.
// The last line of defence: several limited inputs can still sum past full scale.
static void safety_clip(ar_engine *e, AudioBufferList *out) {
    bool clipped = false;
    for (UInt32 b = 0; b < out->mNumberBuffers; b++) {
        float *d = out->mBuffers[b].mData;
        if (!d) continue;
        const uint32_t count = out->mBuffers[b].mDataByteSize / sizeof(float);
        for (uint32_t j = 0; j < count; j++) {
            const float x = d[j];
            const float a = fabsf(x);
            if (a > AR_CLIP_KNEE) {
                if (a > 1.0f) clipped = true;
                const float over = (a - AR_CLIP_KNEE) / (1.0f - AR_CLIP_KNEE);
                d[j] = copysignf(AR_CLIP_KNEE + (1.0f - AR_CLIP_KNEE) * tanhf(over), x);
            }
        }
    }
    if (clipped) atomic_fetch_add_explicit(&e->clip_events, 1, RLX);
}

static void render(ar_engine *e, const AudioBufferList *in, AudioBufferList *out);

void ar_engine_process(ar_engine *e, const AudioBufferList *in, AudioBufferList *out) {
    if (!e) return;
    // mach_absolute_time is a plain register read: safe on the audio thread.
    const uint64_t began = mach_absolute_time();
    const uint64_t previous = atomic_load_explicit(&e->last_cb_time, RLX);
    atomic_store_explicit(&e->last_cb_time, began, RLX);
    if (previous != 0 && began > previous) raise_u64(&e->max_cb_interval, began - previous);
    if (atomic_load_explicit(&e->first_cb_time, RLX) == 0) atomic_store_explicit(&e->first_cb_time, began, RLX);
    atomic_fetch_add_explicit(&e->callbacks, 1, RLX);

    render(e, in, out);

    const uint64_t ended = mach_absolute_time();
    if (ended > began) raise_u64(&e->max_process_time, ended - began);
}

static void render(ar_engine *e, const AudioBufferList *in, AudioBufferList *out) {

    // The HAL does not promise zeroed output buffers. Every channel we don't
    // write (including loopback devices we only read from) must be silence.
    if (out) {
        for (UInt32 b = 0; b < out->mNumberBuffers; b++)
            if (out->mBuffers[b].mData) memset(out->mBuffers[b].mData, 0, out->mBuffers[b].mDataByteSize);
    }

    uint32_t frames = list_frames(out);
    if (frames == 0) frames = list_frames(in);
    if (frames == 0) return;

    const float sr = e->sample_rate > 0.0f ? e->sample_rate : 48000.0f;
    bool missing = false;
    for (uint32_t offset = 0; offset < frames; offset += AR_BLOCK) {
        const uint32_t n = (frames - offset) < AR_BLOCK ? (frames - offset) : AR_BLOCK;
        const float coef = 1.0f - expf(-(float)n / (AR_SMOOTH_SECONDS * sr));

        for (int i = 0; i < AR_MAX_INPUTS; i++) {
            if (e->in_map[i].n == 0) continue;
            const float g0 = e->cur_in[i];
            const float g1 = smooth_toward(g0, clean_gain(ldf(&e->in_gain[i])), coef);
            e->cur_in[i] = g1;
            gather_input(e, i, in, offset, n, &missing);
            process_strip(e, i, n, g0, g1, coef);
        }
        for (int o = 0; o < AR_MAX_OUTPUTS; o++) {
            if (e->out_map[o].n == 0) continue;
            mix_output(e, o, out, offset, n, coef, &missing);
        }
    }

    if (missing) atomic_fetch_add_explicit(&e->missing_buffers, 1, RLX);
    if (out) safety_clip(e, out);
}

// ---------------------------------------------------------------------------
// Hardware glue

static OSStatus ar_ioproc(AudioObjectID device, const AudioTimeStamp *now,
                          const AudioBufferList *inData, const AudioTimeStamp *inTime,
                          AudioBufferList *outData, const AudioTimeStamp *outTime,
                          void *ctx) {
    (void)device; (void)now; (void)inTime; (void)outTime;
    ar_engine_process((ar_engine *)ctx, inData, outData);
    return noErr;
}

OSStatus ar_engine_start(ar_engine *e, AudioObjectID device) {
    if (atomic_load(&e->running)) return kAudioHardwareIllegalOperationError;
    AudioDeviceIOProcID proc = NULL;
    OSStatus s = AudioDeviceCreateIOProcID(device, ar_ioproc, e, &proc);
    if (s != noErr) return s;
    e->device = device;
    e->proc = proc;
    atomic_store(&e->first_cb_time, 0);
    atomic_store(&e->running, true); // before start, so topology setters refuse
    s = AudioDeviceStart(device, proc);
    if (s != noErr) {
        AudioDeviceDestroyIOProcID(device, proc);
        e->proc = NULL;
        e->device = kAudioObjectUnknown;
        atomic_store(&e->running, false);
    }
    return s;
}

OSStatus ar_engine_stop(ar_engine *e) {
    if (!atomic_load(&e->running)) return noErr;
    // Called from outside the IOProc, AudioDeviceStop returns once the proc has
    // stopped running. If the device has vanished it may fail; clean up anyway.
    OSStatus s = AudioDeviceStop(e->device, e->proc);
    AudioDeviceDestroyIOProcID(e->device, e->proc);
    e->proc = NULL;
    e->device = kAudioObjectUnknown;
    atomic_store(&e->running, false);
    return s;
}

bool ar_engine_is_running(ar_engine *e) { return atomic_load(&e->running); }
