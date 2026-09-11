# Audio Angel v1.0

![Audio Angel's main window: four input strips (Vocal Mic, Yamaha Piano, Mac / iPad, Zoom) and two output strips (Teacher, Student)](docs/screenshot.png)

<sub>The main window on the author's lesson rig: a Focusrite interface, a Yamaha digital
piano, browser/iPad sound and the Zoom call, sent to the teacher's headphones and to
the student. Rendered by the app itself (`--snapshot --demo`) with every device
switched on.</sub>

A small Mac app that routes audio for lessons over Zoom. It gathers your **mic**
(USB interface), your **piano** (Yamaha USB), **browser music** and **the Zoom
call** into input strips, and sends each of them wherever you choose: **to Zoom**,
to your **headphones**, or anything else.

```
   INPUT ↓                                         ┃ OUTPUT ↑
   Mic      Piano     Mac/iPad   Zoom              ┃ Teacher    Student
   source   source    source     source            ┃ ← sends    ← sends
   effects  effects   effects    effects           ┃
   fader    fader     fader      fader             ┃ fader      fader
   sends:   sends:    sends:     sends:            ┃ device:    device:
   Teacher  Teacher   Teacher    Teacher           ┃ headphones BlackHole 2ch → Zoom
   Student  Student   Student    —                 ┃
```

Created by Philip Warda with the instrumental help of Claude Opus 5.0.

**Why it exists.** Teaching piano over Zoom means juggling a mic, a digital piano,
backing tracks in the browser and the call itself, and macOS has no way to mix them
and hand the result to Zoom. Audio Angel is that missing mixing desk: low latency,
built to stay up for a whole lesson, and simple enough to set once and forget.

**Requirements:** macOS 13 Ventura or later, the free
[BlackHole](https://github.com/ExistentialAudio/BlackHole) loopback driver, and
Apple's Command Line Tools to build it (no Xcode needed).

---

## First time

**1. Install the loopback devices.** macOS can't hand one app's sound to another by
itself, so we use BlackHole (free, open source): three virtual "cables".

```bash
brew install blackhole-2ch blackhole-16ch blackhole-64ch
```

Then log out and back in (or restart) so macOS picks them up. The number in each
name is its channel count; Audio Angel only uses channels 1+2 of each, so to us
they are just three separate cables.

**2. Get the code and build the app.** Only Apple's Command Line Tools are needed,
not Xcode (`xcode-select --install` if you don't have them).

```bash
git clone https://github.com/philpiano/audio-angel.git
cd audio-angel
./build.sh
```

That runs the audio engine's tests, then makes `build/Audio Angel.app`. Drag it to
Applications if you like.

**3. Open it** and allow microphone access when macOS asks. Without that, every
input is silent. macOS treats all audio inputs as "microphone", the loopbacks too.
The builds are signed ad hoc, so macOS may ask again after a rebuild.

---

## The three cables

| Device          | Who writes into it                 | Who listens              | Strip in Audio Angel  |
|-----------------|------------------------------------|--------------------------|-----------------------|
| BlackHole 2ch   | Audio Angel                        | Zoom (as its microphone) | output **Student**    |
| BlackHole 16ch  | Zoom (as its speaker)              | Audio Angel              | input **Zoom**        |
| BlackHole 64ch  | The Mac (set as the system output) | Audio Angel              | input **Mac / Browser** |

**In Zoom › Settings › Audio**
- Microphone: **BlackHole 2ch**
- Speaker: **BlackHole 16ch**
- Turn on **Original sound for musicians** in the settings, and in the meeting.
  Otherwise Zoom's noise suppression chews up the piano.
- Untick **Automatically adjust microphone volume**.

**The Mac's output** goes to **BlackHole 64ch** (Settings › "Send Mac sound to…").
From then on, anything the Mac plays (Chrome, YouTube, Spotify) arrives in the
**Mac / Browser** input.

**iPad sound** reaches the Mac only through the app that captures the iPad (OBS).
In OBS set **Settings › Audio › Advanced › Monitoring Device** to **BlackHole
64ch** and the iPad source's monitoring to **Monitor and Output**; it then arrives
in the same **Mac / Browser** input.

Never send the **Zoom** input to the output that feeds Zoom: your student would
hear themselves.

---

## Using it

Every strip reads top to bottom, the way sound flows.

**Input strips**
- **Source:** the device and its channels (mono, or a stereo pair).
- **Effects**, in signal order, each on by default:
  - **Low-cut:** removes rumble below 80 Hz (12 dB/octave), the standard
    mixing-desk low-cut. It slightly softens the piano's lowest octave; turn it off
    on the Piano strip if you miss that weight.
  - **Compressor:** a gentle leveller (2:1 above −24 dBFS, soft knee, +2 dB
    make-up). Normal speech is left about where it was, shouts come down, whispers
    come up 2 dB. Its light turns yellow while it's working.
  - **Limiter:** a safety net at −1 dBFS. Silent until a peak would overload; its
    light turns orange while it's catching one.
- **Fader** with its meter, the **level** in dB and **M** (mute). Click the dB box
  to type an exact level (`-6`, `+3.5`, `-inf`); right-click for +5 / 0 / −5 dB.
- **Send:** one button per output. Click to send this input there; the knob beside
  it sets how much (drag up or down, double-click for 0 dB). A send that would feed
  a loopback back into itself is blocked and shows ⚠.

**Output strips**
- **Source:** the name inputs send to. It's the first word of the output's name
  ("Teacher Headphones" → **Teacher**); double-click to rename it. Green when
  something is being sent here; hover to see what.
- **Fader**, **level**, **M**, then **Output:** the device it plays on.

**Everywhere**
- The dot next to a strip's name: green = connected, orange = device unplugged (it
  reconnects on its own), red = that device doesn't have those channels.
- **⋯** on a strip moves it left or right, or removes it.
- The window opens six strips wide and exactly as tall as the strips. Closing it
  **doesn't stop the audio**; the waveform icon in the menu bar reopens it or quits.
- Everything is saved automatically.

**The status bar**
- **≈ ms:** the delay through Audio Angel. Zoom adds its own on top.
- **⚠** next to the status: something needs attention, usually a device that isn't
  connected. Click it to read what.
- **ⓘ**: good to know, nothing to do. For example, the Yamaha's USB audio only runs
  at 44.1 kHz, so macOS converts it to 48 kHz on the way in.
- **Dropouts:** times the Mac couldn't prepare audio in time and a tiny click got
  through. An odd one is harmless; if it climbs while you play, raise the buffer
  size. The first two seconds after a start aren't counted.
- **Clipped:** times an output went over full scale and the final safety stage
  caught it — usually two loud sources adding up. Turn that output down a little.
- Click a counter to clear it; **↻** restarts the engine and clears both.
- **⚙ Settings** (⌘,): sample rate (**keep 48 kHz**, what Zoom uses), buffer size
  (**128** is a good start), the clock device, and the setup checklist. An orange
  dot on the gear means something in the checklist needs attention.

---

## How it works

**One clock, one callback.** Audio Angel builds a hidden, private *aggregate device*
out of every device you've assigned. Core Audio keeps them all in step (your USB
interface is the master clock; the others are drift-corrected against it). Then
one audio callback sees every input and every output at the same moment. Routing
is a plain matrix mix: no buffers between devices, no extra delay added.

**The audio thread is plain C** (`Sources/RouterCore`). It never allocates memory,
takes a lock, or calls into Swift. Each input runs low-cut → compressor → fader →
limiter; none of it adds latency, and every effect is crossfaded when switched so
nothing clicks. The UI changes levels through lock-free atomics, smoothed over
~10 ms. A soft safety stage on every output means nothing leaves the app above full
scale.

**The rest is Swift / SwiftUI** (`Sources/AudioAngel`):

| File                    | What it does |
|-------------------------|--------------|
| `EngineController.swift`| Builds the aggregate device, maps strips to channels, and heals itself (below). |
| `RouterModel.swift`     | App state, saving, meters at 30 fps. |
| `Mixer.swift`           | The strips: sources, effects, faders, sends, outputs. |
| `Views.swift`           | The window, status bar, and Settings. |
| `RouterConfig.swift`    | Strips and sends as saved, and the first-launch layout guessed from device names. |
| `CoreAudioUtils.swift`  | Typed wrappers for the Core Audio property API. |
| `Diagnostics.swift`     | Command-line checks (below). |

### Built to stay up

- **Plug and unplug freely.** The app listens for device changes. When a device it
  needs appears, disappears or changes, it rebuilds the engine automatically. The
  other devices keep their settings, and a missing device just goes quiet until it
  returns.
- **Changing channels doesn't rebuild.** The engine re-points the strips in a few
  milliseconds.
- **Sleep/wake:** it rebuilds after waking, once USB devices are back.
- **Watchdog:** if the audio callback stops for 3 seconds, the engine restarts.
- **If a build fails**, it retries with backoff (2, 4, 8, 15 s…) and says why.
- **If another app changes the sample rate** of a device in use, it puts it back.
- **App Nap is disabled** while it runs, so macOS never throttles the audio.
- The engine's aggregate device is *private*. It disappears when the app quits,
  even if it crashes, so it never clutters your Sound settings.

---

## Checks

```bash
./build.sh test                                               # engine tests only (no hardware)
"build/Audio Angel.app/Contents/MacOS/AudioAngel" --list-devices
"build/Audio Angel.app/Contents/MacOS/AudioAngel" --probe      # silent run on the speakers
"build/Audio Angel.app/Contents/MacOS/AudioAngel" --snapshot out.png           # the window, as a picture
"build/Audio Angel.app/Contents/MacOS/AudioAngel" --snapshot-settings out.png  # the Settings window
```

The engine tests cover routing, mixing, gain, mute, meters, garbage input, bad
channel maps, and each effect against its specification (the low-cut's −3 dB point,
the compressor's curve, the limiter's ceiling, switching without clicks).

`--probe` builds a real engine on the built-in speakers (output only: silent, and no
microphone prompt). It checks that callbacks arrive at the right rate, rebuilds at a
new buffer size, confirms the engine stays still when nothing changes, and confirms
nothing is left behind.

## Limits and next steps

- macOS 13 or later, up to 8 inputs and 8 outputs, mono or stereo.
- BlackHole's device names are fixed (2ch / 16ch / 64ch). A later version could
  ship its own virtual devices named "Audio Angel → Zoom" and so on. That's a
  Core Audio driver (AudioServerPlugIn), deliberately not in this version.
- A dedicated iPad input would mean capturing the iPad directly; it may compete
  with OBS for the device, so it needs testing outside a lesson first.

Hey, Philip here. I'm just writing a few words so Github registers me as an actual Author :p 
