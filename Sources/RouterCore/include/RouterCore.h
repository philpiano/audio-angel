// RouterCore — the real-time part of Audio Angel.
//
// One Core Audio IOProc runs on a private aggregate device that contains every
// physical and loopback device in use. Each callback receives all inputs and all
// outputs on a single clock, so routing is a plain matrix mix with no ring buffers
// or resampling of our own in the path.
//
// Each input runs a fixed channel strip:  low-cut → compressor → fader → limiter.
// The effects have no adjustable parameters, only on/off, and add no latency.
//
// Threading contract:
//   * Topology (which buffer/channel each slot reads or writes) may only be
//     changed while the engine is stopped. The setters refuse otherwise.
//   * Gains, mutes, routes and effect switches may be changed from any thread at
//     any time. They are lock-free atomics, and the audio thread smooths every
//     change (~10 ms) so nothing clicks.
//   * The audio thread never allocates, locks, logs or calls into Swift.

#ifndef ROUTER_CORE_H
#define ROUTER_CORE_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#define AR_MAX_INPUTS 8
#define AR_MAX_OUTPUTS 8
#define AR_MAX_SLOT_CHANNELS 2

// Input effects, combined as flags. Everything is off in a new engine.
#define AR_FX_LIMITER    1u // ceiling -1 dBFS, instant attack, 100 ms release
#define AR_FX_COMPRESSOR 2u // 2:1 above -24 dBFS (RMS), 10 dB soft knee, 10/150 ms, +2 dB make-up
#define AR_FX_LOWCUT     4u // 80 Hz high-pass, 12 dB/octave Butterworth

typedef struct ar_engine ar_engine;

ar_engine *ar_engine_create(void);
void ar_engine_destroy(ar_engine *e);

// --- Topology (engine must be stopped) -------------------------------------
// A slot is mono (numChannels 1) or stereo (2). Each channel names a buffer
// index in the IOProc's AudioBufferList and a channel within that buffer.
// Pass -1 for unused references. Returns false if the engine is running.
bool ar_engine_clear_topology(ar_engine *e);
bool ar_engine_set_input_map(ar_engine *e, int slot, int numChannels, int buf0, int ch0, int buf1, int ch1);
bool ar_engine_set_output_map(ar_engine *e, int slot, int numChannels, int buf0, int ch0, int buf1, int ch1);
bool ar_engine_set_sample_rate(ar_engine *e, double sampleRate);

// --- Parameters (any thread, any time). Gains are linear. ------------------
void ar_engine_set_route(ar_engine *e, int in, int out, float gain); // 0 = not routed
void ar_engine_set_input_gain(ar_engine *e, int in, float gain);
void ar_engine_set_input_mute(ar_engine *e, int in, bool mute);
void ar_engine_set_input_effects(ar_engine *e, int in, uint32_t flags);
void ar_engine_set_output_gain(ar_engine *e, int out, float gain);
void ar_engine_set_output_mute(ar_engine *e, int out, bool mute);

// --- Metering (any thread). "take" returns the peak since the last call. ---
float ar_engine_take_input_peak(ar_engine *e, int in, int channel);
float ar_engine_take_output_peak(ar_engine *e, int out, int channel);
// Largest gain reduction in dB applied by AR_FX_LIMITER or AR_FX_COMPRESSOR since the last call.
float ar_engine_take_input_reduction(ar_engine *e, int in, uint32_t effect);
uint64_t ar_engine_callback_count(ar_engine *e);
uint64_t ar_engine_clip_count(ar_engine *e);

// --- The render function. Exposed so it can be tested without hardware. ----
void ar_engine_process(ar_engine *e, const AudioBufferList *in, AudioBufferList *out);

// --- Hardware glue ----------------------------------------------------------
OSStatus ar_engine_start(ar_engine *e, AudioObjectID device);
OSStatus ar_engine_stop(ar_engine *e);
bool ar_engine_is_running(ar_engine *e);

#endif
