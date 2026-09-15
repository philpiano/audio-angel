// Hardware-free tests for the mixing engine: feed hand-built buffer lists
// through ar_engine_process and check what comes out.
//
//   swift run -c release RouterCoreSelfTest

#include "RouterCore.h"

#include <mach/mach_time.h>
#include <math.h>
#include <stddef.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;

#define CHECK(cond, msg)                                   \
    do {                                                   \
        if (cond) printf("  ok    %s\n", msg);             \
        else { printf("  FAIL  %s  (line %d)\n", msg, __LINE__); failures++; } \
    } while (0)

static bool near(float a, float b) { return fabsf(a - b) < 1e-3f; }

static AudioBufferList *make_list(int nbuf, const int *chans, int frames) {
    AudioBufferList *l = calloc(1, offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * (size_t)nbuf);
    l->mNumberBuffers = (UInt32)nbuf;
    for (int b = 0; b < nbuf; b++) {
        l->mBuffers[b].mNumberChannels = (UInt32)chans[b];
        l->mBuffers[b].mDataByteSize = (UInt32)(frames * chans[b] * (int)sizeof(float));
        l->mBuffers[b].mData = calloc((size_t)(frames * chans[b]), sizeof(float));
    }
    return l;
}

static void free_list(AudioBufferList *l) {
    for (UInt32 b = 0; b < l->mNumberBuffers; b++) free(l->mBuffers[b].mData);
    free(l);
}

static void fill(AudioBufferList *l, int buf, int ch, float v) {
    AudioBuffer *b = &l->mBuffers[buf];
    int frames = (int)(b->mDataByteSize / (sizeof(float) * b->mNumberChannels));
    float *d = b->mData;
    for (int f = 0; f < frames; f++) d[f * (int)b->mNumberChannels + ch] = v;
}

static float at(AudioBufferList *l, int buf, int ch, int frame) {
    AudioBuffer *b = &l->mBuffers[buf];
    return ((float *)b->mData)[frame * (int)b->mNumberChannels + ch];
}

static float last(AudioBufferList *l, int buf, int ch) {
    AudioBuffer *b = &l->mBuffers[buf];
    int frames = (int)(b->mDataByteSize / (sizeof(float) * b->mNumberChannels));
    return at(l, buf, ch, frames - 1);
}

static void run(ar_engine *e, AudioBufferList *in, AudioBufferList *out, int callbacks) {
    for (int i = 0; i < callbacks; i++) ar_engine_process(e, in, out);
}

// --- Effects ------------------------------------------------------------------
// One mono input straight to one stereo output, fed sines or DC at 48 kHz.

enum { FX_FRAMES = 480 }; // 10 ms per callback

typedef struct { ar_engine *e; AudioBufferList *in, *out; double phase; } fx_rig;

static fx_rig fx_rig_make(uint32_t flags) {
    const int one[] = { 1 }, two[] = { 2 };
    fx_rig r = { ar_engine_create(), make_list(1, one, FX_FRAMES), make_list(1, two, FX_FRAMES), 0.0 };
    ar_engine_set_sample_rate(r.e, 48000);
    ar_engine_set_input_map(r.e, 0, 1, 0, 0, -1, -1);
    ar_engine_set_output_map(r.e, 0, 2, 0, 0, 0, 1);
    ar_engine_set_route(r.e, 0, 0, 1.0f);
    ar_engine_set_input_effects(r.e, 0, flags);
    return r;
}

static void fx_rig_free(fx_rig *r) {
    ar_engine_destroy(r->e);
    free_list(r->in);
    free_list(r->out);
}

// Runs `callbacks` callbacks of a sine (freq > 0) or DC (freq == 0) and
// returns the output's peak over the last 100 ms (or all of it, if shorter):
// long enough to hold two full cycles of 20 Hz.
static float fx_run(fx_rig *r, double freq, float amp, int callbacks) {
    float peak = 0.0f;
    const int measureFrom = callbacks > 10 ? callbacks - 10 : 0;
    for (int cb = 0; cb < callbacks; cb++) {
        float *d = r->in->mBuffers[0].mData;
        for (int f = 0; f < FX_FRAMES; f++) {
            d[f] = freq > 0 ? amp * (float)sin(r->phase) : amp;
            r->phase += 2.0 * M_PI * freq / 48000.0;
        }
        ar_engine_process(r->e, r->in, r->out);
        if (cb >= measureFrom) {
            for (int f = 0; f < FX_FRAMES; f++) {
                float a = fabsf(at(r->out, 0, 0, f));
                if (a > peak) peak = a;
            }
        }
    }
    return peak;
}

static float db(float x) { return 20.0f * log10f(x); }

static void test_effects(void) {
    printf("low-cut\n");
    {
        fx_rig r = fx_rig_make(AR_FX_LOWCUT);
        float p = fx_run(&r, 20, 0.5f, 100);
        CHECK(p < 0.5f * 0.1f, "20 Hz rumble is cut by more than 20 dB");
        p = fx_run(&r, 80, 0.5f, 100);
        CHECK(fabsf(db(p / 0.5f) + 3.0f) < 0.5f, "80 Hz is the -3 dB point");
        p = fx_run(&r, 1000, 0.5f, 50);
        CHECK(fabsf(db(p / 0.5f)) < 0.1f, "1 kHz passes untouched");
        p = fx_run(&r, 0, 0.5f, 100);
        CHECK(p < 0.001f, "DC offset is removed");
        fx_rig_free(&r);

        fx_rig off = fx_rig_make(0);
        p = fx_run(&off, 20, 0.5f, 100);
        CHECK(fabsf(p - 0.5f) < 0.005f, "with low-cut off, 20 Hz passes");
        fx_rig_free(&off);
    }

    printf("compressor\n");
    {
        fx_rig r = fx_rig_make(AR_FX_COMPRESSOR);
        // DC makes the RMS detector exact: -6 dBFS is 18 dB over, 2:1 takes 9, +2 make-up.
        float p = fx_run(&r, 0, 0.5f, 100);
        CHECK(fabsf(db(p / 0.5f) + 7.0f) < 0.1f, "a loud -6 dBFS input comes down 7 dB");
        p = fx_run(&r, 0, 0.01f, 150);
        CHECK(fabsf(db(p / 0.01f) - 2.0f) < 0.1f, "a quiet -40 dBFS input comes up 2 dB");
        p = fx_run(&r, 0, 0.1f, 150);
        CHECK(fabsf(db(p / 0.1f)) < 0.5f, "speech level (-20 dBFS) is left about where it was");
        fx_run(&r, 0, 0.5f, 100);
        CHECK(ar_engine_take_input_reduction(r.e, 0, AR_FX_COMPRESSOR) > 8.5f, "compressor reports its gain reduction");
        fx_rig_free(&r);
    }

    printf("limiter\n");
    {
        fx_rig r = fx_rig_make(AR_FX_LIMITER);
        ar_engine_set_input_gain(r.e, 0, 4.0f); // a 0.5 sine becomes 2.0: 6 dB over full scale
        fx_run(&r, 440, 0.5f, 20);
        uint64_t clips = ar_engine_clip_count(r.e);
        float p = fx_run(&r, 440, 0.5f, 50);
        CHECK(p <= 0.8913f, "nothing passes the -1 dBFS ceiling");
        CHECK(p > 0.85f, "and it isn't pumping far below it");
        CHECK(ar_engine_clip_count(r.e) == clips, "so the output never clips");
        CHECK(ar_engine_take_input_reduction(r.e, 0, AR_FX_LIMITER) > 6.0f, "limiter reports its gain reduction");
        CHECK(ar_engine_take_input_reduction(r.e, 0, AR_FX_LIMITER) == 0.0f, "taking the reduction resets it");

        ar_engine_set_input_gain(r.e, 0, 1.0f);
        fx_run(&r, 440, 0.5f, 100);                             // let it recover…
        ar_engine_take_input_reduction(r.e, 0, AR_FX_LIMITER); // …forget the recovery…
        fx_run(&r, 440, 0.5f, 20);                              // …then listen
        CHECK(ar_engine_take_input_reduction(r.e, 0, AR_FX_LIMITER) == 0.0f, "below the ceiling it does nothing");
        p = fx_run(&r, 440, 0.5f, 1);
        CHECK(fabsf(p - 0.5f) < 0.002f, "and the signal is untouched");
        fx_rig_free(&r);
    }

    printf("switching effects\n");
    {
        fx_rig r = fx_rig_make(0);
        fx_run(&r, 1000, 0.5f, 50);
        ar_engine_set_input_effects(r.e, 0, AR_FX_LIMITER | AR_FX_COMPRESSOR | AR_FX_LOWCUT);
        fx_run(&r, 1000, 0.5f, 1);
        float worst = 0.0f;
        for (int f = 1; f < FX_FRAMES; f++) {
            float jump = fabsf(at(r.out, 0, 0, f) - at(r.out, 0, 0, f - 1));
            if (jump > worst) worst = jump;
        }
        // A 1 kHz sine at 0.5 moves at most 0.065 per sample at 48 kHz.
        CHECK(worst < 0.07f, "switching all effects on mid-signal doesn't click");
        fx_rig_free(&r);
    }
}

// --- Diagnostics ----------------------------------------------------------------

static void test_diagnostics(void) {
    printf("diagnostics\n");
    fx_rig r = fx_rig_make(0);
    CHECK(ar_engine_last_callback_time(r.e) == 0, "no callback time before the first callback");

    fx_run(&r, 0, 0.0f, 1);
    uint64_t t1 = ar_engine_last_callback_time(r.e);
    CHECK(t1 != 0 && ar_engine_first_callback_time(r.e) == t1, "the first callback is timestamped");
    usleep(20000);
    fx_run(&r, 0, 0.0f, 1);
    CHECK(ar_engine_last_callback_time(r.e) > t1, "later callbacks move the timestamp on");
    CHECK(ar_engine_first_callback_time(r.e) == t1, "the first-callback time stays put");

    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    double gap_ms = (double)ar_engine_take_max_callback_interval(r.e) * tb.numer / tb.denom / 1e6;
    CHECK(gap_ms >= 19.0, "a 20 ms pause between callbacks is measured as the longest gap");
    CHECK(ar_engine_take_max_callback_interval(r.e) == 0, "taking the longest gap resets it");
    ar_engine_take_max_process_time(r.e);

    ar_engine_take_input_zero_run(r.e, 0);
    ar_engine_take_output_zero_run(r.e, 0);
    fx_run(&r, 0, 0.0f, 10);
    CHECK(ar_engine_take_input_zero_run(r.e, 0) == 12 * FX_FRAMES, "exact silence on an input is measured as a run");
    CHECK(ar_engine_take_output_zero_run(r.e, 0) >= 10 * FX_FRAMES, "and silence on an output too");
    fx_run(&r, 1000, 0.5f, 5);
    ar_engine_take_input_zero_run(r.e, 0);
    fx_run(&r, 1000, 0.5f, 5);
    CHECK(ar_engine_take_input_zero_run(r.e, 0) == 0, "real signal is never counted as silence");
    CHECK(ar_engine_missing_buffer_count(r.e) == 0, "a complete buffer list counts no missing buffers");
    fx_rig_free(&r);

    fx_rig bad = fx_rig_make(0);
    ar_engine_clear_topology(bad.e);
    ar_engine_set_input_map(bad.e, 0, 1, 3, 0, -1, -1); // buffer 3 doesn't exist
    ar_engine_set_output_map(bad.e, 0, 2, 0, 0, 0, 1);
    fx_run(&bad, 0, 0.5f, 4);
    CHECK(ar_engine_missing_buffer_count(bad.e) == 4, "every callback with a missing buffer is counted");
    fx_rig_free(&bad);
}

// Rig resembling the real thing (1500 frames: deliberately not a multiple of the block size):
//   in  buf0 2ch: interface  (ch0 = mic)
//   in  buf1 2ch: piano      (L, R)
//   in  buf2 2ch: Zoom loopback
//   out buf0 2ch: "To Zoom" loopback
//   out buf1 2ch: headphones
enum { FRAMES = 1500 };

int main(void) {
    const int inChans[] = { 2, 2, 2 };
    const int outChans[] = { 2, 2, 1 };
    AudioBufferList *in = make_list(3, inChans, FRAMES);
    AudioBufferList *out = make_list(3, outChans, FRAMES);
    fill(in, 0, 0, 0.5f);  // mic
    fill(in, 1, 0, 0.3f);  // piano L
    fill(in, 1, 1, 0.1f);  // piano R
    fill(in, 2, 0, 0.1f);  // zoom L
    fill(in, 2, 1, 0.1f);  // zoom R

    ar_engine *e = ar_engine_create();
    ar_engine_set_sample_rate(e, 48000);
    ar_engine_set_input_map(e, 0, 1, 0, 0, -1, -1); // mic, mono
    ar_engine_set_input_map(e, 1, 2, 1, 0, 1, 1);   // piano, stereo
    ar_engine_set_input_map(e, 2, 2, 2, 0, 2, 1);   // zoom, stereo
    ar_engine_set_output_map(e, 0, 2, 0, 0, 0, 1);  // to zoom
    ar_engine_set_output_map(e, 1, 2, 1, 0, 1, 1);  // headphones
    ar_engine_set_output_map(e, 2, 1, 2, 0, -1, -1); // a mono output

    printf("routing\n");
    run(e, in, out, 5);
    CHECK(last(out, 0, 0) == 0.0f && last(out, 1, 0) == 0.0f, "nothing routed -> silence");

    ar_engine_set_route(e, 0, 0, 1.0f); // mic -> to zoom
    ar_engine_process(e, in, out);
    CHECK(at(out, 0, 0, 0) < 0.05f && at(out, 0, 0, 0) >= 0.0f, "a new route fades in (no click)");
    run(e, in, out, 60);
    CHECK(near(last(out, 0, 0), 0.5f) && near(last(out, 0, 1), 0.5f), "mono mic lands on both sides of a stereo output");
    CHECK(near(at(out, 0, 0, 0), 0.5f), "settled gain is flat across the buffer");
    CHECK(last(out, 1, 0) == 0.0f, "unrouted output stays silent");

    ar_engine_set_route(e, 1, 1, 1.0f); // piano -> headphones
    run(e, in, out, 60);
    CHECK(near(last(out, 1, 0), 0.3f) && near(last(out, 1, 1), 0.1f), "stereo piano keeps left and right");

    ar_engine_set_route(e, 1, 2, 1.0f); // piano -> mono output
    run(e, in, out, 60);
    CHECK(near(last(out, 2, 0), 0.2f), "stereo into a mono output is averaged");

    ar_engine_set_route(e, 2, 0, 1.0f); // zoom -> to zoom (sums with mic)
    run(e, in, out, 60);
    CHECK(near(last(out, 0, 0), 0.6f), "two inputs into one output sum");
    ar_engine_set_route(e, 2, 0, 0.0f);

    printf("gain and mute\n");
    ar_engine_set_input_gain(e, 0, 0.5f);
    run(e, in, out, 60);
    CHECK(near(last(out, 0, 0), 0.25f), "input gain applies");
    ar_engine_set_input_gain(e, 0, 1.0f);
    ar_engine_set_output_gain(e, 0, 0.5f);
    run(e, in, out, 60);
    CHECK(near(last(out, 0, 0), 0.25f), "output gain applies");
    ar_engine_set_output_gain(e, 0, 1.0f);
    ar_engine_set_input_mute(e, 0, true);
    run(e, in, out, 60);
    CHECK(last(out, 0, 0) == 0.0f, "input mute silences it");
    ar_engine_set_input_mute(e, 0, false);
    ar_engine_set_output_mute(e, 1, true);
    run(e, in, out, 60);
    CHECK(last(out, 1, 0) == 0.0f, "output mute silences it");
    ar_engine_set_output_mute(e, 1, false);
    ar_engine_set_route(e, 0, 0, NAN);
    run(e, in, out, 60);
    CHECK(last(out, 0, 0) == 0.0f, "a NaN gain is treated as off");
    ar_engine_set_route(e, 0, 0, 1.0f);

    printf("meters\n");
    run(e, in, out, 60);
    float p = ar_engine_take_input_peak(e, 0, 0);
    CHECK(near(p, 0.5f), "input meter reads the mic level");
    CHECK(ar_engine_take_input_peak(e, 0, 0) == 0.0f, "taking a peak resets it");
    run(e, in, out, 1);
    CHECK(near(ar_engine_take_output_peak(e, 1, 1), 0.1f), "output meter reads the piano right channel");

    printf("safety\n");
    ar_engine_set_input_gain(e, 0, 4.0f); // 0.5 * 4 = 2.0 -> must be clipped
    uint64_t clipsBefore = ar_engine_clip_count(e);
    run(e, in, out, 60);
    CHECK(last(out, 0, 0) <= 1.0f && last(out, 0, 0) > 0.95f, "overs are soft-clipped to <= 1.0");
    CHECK(ar_engine_clip_count(e) > clipsBefore, "clip events are counted");
    ar_engine_set_input_gain(e, 0, 1.0f);

    fill(in, 0, 0, NAN);
    run(e, in, out, 5);
    CHECK(last(out, 0, 0) == 0.0f, "NaN on an input never reaches an output");
    fill(in, 0, 0, 0.5f);

    ar_engine_clear_topology(e);
    ar_engine_set_input_map(e, 0, 2, 7, 0, 0, 9);  // nonexistent buffer / channel
    ar_engine_set_output_map(e, 0, 2, 0, 0, 5, 0);
    ar_engine_set_route(e, 0, 0, 1.0f);
    run(e, in, out, 10);
    CHECK(last(out, 0, 0) == 0.0f, "bad channel references are silent, not a crash");

    ar_engine_process(e, NULL, out);
    ar_engine_process(e, in, NULL);
    ar_engine_process(e, NULL, NULL);
    CHECK(1, "missing buffer lists are survived");

    // Output buffer shorter than the input: must not write past its end.
    const int oneBuf[] = { 2 };
    AudioBufferList *shortOut = make_list(1, oneBuf, 100);
    ar_engine_clear_topology(e);
    ar_engine_set_input_map(e, 0, 1, 0, 0, -1, -1);
    ar_engine_set_output_map(e, 0, 2, 0, 0, 0, 1);
    run(e, in, shortOut, 60);
    CHECK(near(last(shortOut, 0, 0), 0.5f), "mismatched buffer sizes stay in bounds");
    free_list(shortOut);

    printf("topology\n");
    CHECK(ar_engine_set_input_map(e, 99, 1, 0, 0, -1, -1) == false, "out-of-range slot is refused");
    CHECK(ar_engine_callback_count(e) > 0, "callbacks are counted");

    ar_engine_destroy(e);
    free_list(in);
    free_list(out);

    test_effects();
    test_diagnostics();

    if (failures) {
        printf("\n%d FAILED\n", failures);
        return 1;
    }
    printf("\nall passed\n");
    return 0;
}
