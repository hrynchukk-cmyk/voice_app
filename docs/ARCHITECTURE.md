# Architecture

## 1. Design priorities (in order)

1. **Reliable live audio routing** — the meeting must always hear *something*
   sensible (converted, bypassed, or muted), never a dropout or a crash.
2. **Consent and visible disclosure** — hard-gated enrollment, always-on
   "ACTIVE" indicator, disclosure reminder.
3. **Low latency** — target < 150 ms end-to-end, aim < 100 ms on capable
   Apple Silicon.
4. **Local processing** — no network by default.
5. **Simple, usable interface.**
6. **Apple Silicon performance.**

Everything below is shaped by putting (1) and (2) ahead of (3).

## 2. High-level component diagram

```
                          ┌───────────────────────────────────────────┐
                          │              VoiceBridge.app                │
                          │                (SwiftUI)                    │
                          │                                             │
  Built-in mic  ──HAL──▶  │  AudioEngine (AVAudioEngine / AUHAL)        │
  (Core Audio input)      │    • AVAudioSinkNode  → capture frames      │
                          │    • input level meter + clipping detect    │
                          │    • input gain                             │
                          │            │                                │
                          │            ▼                                │
                          │     VoiceActivityDetector (Silero / DSP)    │
                          │            │                                │
                          │            ▼   ┌── mode: MUTE → silence     │
                          │      ProcessingMode ─┼─ mode: BYPASS → dry   │
                          │            │       └── mode: CONVERT        │
                          │            ▼                                │
                          │     VoiceConverter (protocol)               │
                          │       • PassthroughConverter (Phase 1/3 dry)│
                          │       • CoreMLConverter  (native, Phase 3)  │
                          │       • ExternalProcessConverter ───────────┼──▶ ml/ backend
                          │            │        (Python/ONNX, Phase 3)  │     (localhost only)
                          │            ▼                                │
                          │     SafetyLimiter + output gain + normalize │
                          │            │                                │
                          │            ▼                                │
                          │     AVAudioSourceNode  (render to output)   │
                          │            │                                │
                          └────────────┼────────────────────────────────┘
                                       ▼
                    ┌──────────────────────────────────┐
                    │  Virtual audio device (driver)    │   ◀── separate routing layer,
                    │  "VoiceBridge Microphone"         │       NOT injected into apps
                    │  (Audio Server Plug-In / DriverKit)│
                    └──────────────────┬────────────────┘
                                       ▼
                     Zoom / Meet / Teams / Discord picks it as "microphone"
```

The full ASCII of the required audio flow is in
[`diagrams/audio-flow.md`](diagrams/audio-flow.md).

## 3. Two-process model

VoiceBridge is designed as **two cooperating pieces plus a driver**:

1. **The app (native, Swift)** — owns Core Audio, the UI, consent, safety, and
   routing. This is the part that must be rock-solid and real-time-safe.
2. **The conversion engine** — pluggable behind the `VoiceConverter` protocol.
   Two concrete strategies:
   - **Native Core ML** (preferred for shipping): the VC model is converted to
     Core ML and runs in-process on the Apple Neural Engine / GPU. Lowest
     latency, no IPC, no Python.
   - **External process** (fastest path to a *working* first version): a local
     Python/ONNX-Runtime server (see `ml/`) that the app talks to over a
     localhost socket or shared memory. Easy to iterate on models; higher
     latency and more moving parts.
3. **The virtual audio driver** — a system-level Core Audio plug-in that
   presents "VoiceBridge Microphone" to every app. It is a *separate routing
   layer*, deliberately not an injection into Zoom/Meet/etc. See
   [`../VirtualDevice/README.md`](../VirtualDevice/README.md).

### Why a separate driver instead of per-app injection?

Injecting audio into individual meeting apps would require fragile,
per-app hacks, would break on updates, and is exactly the kind of covert
technique this project rejects. A published virtual device is transparent: the
user *chooses* it in the meeting app's settings, and everyone can see it named
"VoiceBridge".

## 4. Native macOS vs. Python/ML — the split

This answers deliverable #7 directly.

| Concern | Where it must live | Why |
| --- | --- | --- |
| Core Audio capture, device enumeration, hot-plug detection | **Native Swift/C** | Real-time render callbacks; only native code can meet the deadline safely. |
| Ring buffer, mute/bypass, level metering, clipping detect | **Native Swift/C** | Runs inside/next to the audio callback; must be lock-free and allocation-free. |
| Safety limiter, gain, normalization | **Native Swift/C** | Same real-time path; trivial DSP. |
| UI, consent gating, model management, keyboard shortcuts | **Native Swift (SwiftUI)** | Platform integration. |
| Virtual microphone device | **Native (Audio Server Plug-In / DriverKit, C/C++)** | It's a system driver; there is no Python option. |
| Voice-activity detection | **Either** | Silero VAD via ONNX/Core ML natively, or a DSP energy+ZCR gate in Swift. |
| The voice-conversion model itself | **Either** | Core ML natively (ship path) **or** Python/ONNX in `ml/` (prototype path). |
| Model training / enrollment fine-tuning | **Python** (offline, not in the audio path) | Training frameworks are Python; runs once per model, never in real time. |

**Rule of thumb:** anything that runs *per audio buffer* must be native and
real-time-safe. Anything that runs *once* (load a model, import a file, train)
can be Python. The neural inference sits on the boundary — start in Python to
get it working, migrate to Core ML for latency and to drop the Python
dependency.

## 5. The real-time audio path

The example code (`Sources/VoiceBridge/Audio/AudioEngine.swift`) uses
`AVAudioSinkNode` (input) and `AVAudioSourceNode` (output) bridged by a
single-producer/single-consumer ring buffer:

```
[mic] → AVAudioSinkNode callback ──push──▶ [ring buffer] ──pull──▶ AVAudioSourceNode callback → [output/virtual mic]
             (produces frames)                                        (consumes frames)
```

Rules for the callback (hot) path — see `RingBuffer.swift`, `SafetyLimiter.swift`:

- **No allocations, no locks, no Swift ARC churn, no Obj-C messaging** in the
  render callbacks. Pre-allocate all buffers.
- Conversion inference does **not** run inside the render callback. Instead the
  sink callback hands fixed-size chunks to the converter on a dedicated
  high-priority worker; converted frames come back through a second ring buffer
  that the source callback drains. If a chunk isn't ready in time, the source
  callback emits the **dry (bypass)** frames it already has — never a gap.
- This "convert off-thread, fall back to dry" design is what makes the latency
  budget survivable and gives automatic graceful degradation.

## 6. Latency budget (honest version)

End-to-end latency = input buffering + algorithmic lookahead + inference +
output buffering + driver hops.

| Stage | Typical on M-series |
| --- | --- |
| Input I/O buffer (256 frames @ 48 kHz) | ~5.3 ms |
| Chunking / lookahead for VC model | 20–120 ms **(dominant, model-dependent)** |
| Neural inference (Core ML, ANE/GPU) | 10–40 ms per chunk |
| Safety/limiter/gain | < 1 ms |
| Output I/O buffer | ~5.3 ms |
| Virtual-device hop | ~3–10 ms |

- **< 100 ms is achievable only with a streaming, low-lookahead model** and
  small chunks, on M2/M3+ with Core ML on the ANE.
- Many popular VC models (RVC, so-vits-svc) are **not** natively streaming;
  real-time wrappers (e.g. w-okada voice-changer) reach ~120–300 ms. Treat
  sub-100 ms as a *stretch goal tied to model choice*, not a given.
- The single biggest lever is the **model and its chunk/lookahead size**, not
  the app plumbing. Pick the model with real-time in mind (see
  [`LIBRARIES.md`](LIBRARIES.md)).

See [`docs/PERMISSIONS_AND_SIGNING.md`](PERMISSIONS_AND_SIGNING.md) §latency for
why the App Sandbox and hardened runtime do **not** add meaningful latency.

## 7. State machine & failure handling

`AppState` owns a small state machine:

```
             start                 stop
  idle ───────────────▶ running ───────────▶ idle
                          │  ▲
             engineError  │  │ recovered
                          ▼  │
                      bypassFallback  (converted output unavailable →
                                       send dry mic + show error banner)
```

- **Mute** and **Bypass** are orthogonal toggles that apply in `running` and
  `bypassFallback`.
- Any converter exception, device removal, or missed real-time deadline streak
  transitions to `bypassFallback` without stopping the stream — the meeting
  keeps hearing your real voice.
- Device hot-unplug is observed via Core Audio property listeners
  (`AudioDeviceManager`) and surfaces a clear error; the engine reconfigures to
  the new default input/output.

## 8. Consent & disclosure as first-class components

- `ConsentManager` refuses to register a voice model unless an explicit
  permission attestation is recorded next to it.
- `StatusIndicatorView` renders the mandatory ACTIVE indicator (dot + label +
  session timer). It is bound directly to the audio engine's *actual* running
  state, so it cannot show "inactive" while audio is flowing.
- The disclosure reminder is a permanent, non-dismissible element of
  `MainView`.
- There is intentionally **no** API, flag, or hidden setting to suppress the
  indicator. See Non-Goals in the brief.

## 9. Non-goals (enforced, not just documented)

Covert recording, hidden/stealth conversion, automatic impersonation, a fake
"real microphone" label, and default cloud upload are **out of scope** and must
not be added. The indicator is bound to real state; the network entitlement is
absent; enrollment is consent-gated. These are structural choices, not just
policy text.
