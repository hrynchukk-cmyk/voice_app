# Minimal viable product specification

The MVP is the smallest build that satisfies the brief's **Definition of
Success**. Anything not listed here is deferred.

## MVP user story

> As an authorized user, I open VoiceBridge, pick my Mac's built-in microphone
> and one locally stored voice model I have permission to use, click **Start
> Conversion**, and my meeting app (Zoom/Meet/Teams/Discord) — set to the
> "VoiceBridge Microphone" input — carries my converted voice at conversational
> latency. I can instantly **Mute** or **Bypass**, and the window always shows
> that conversion is **ACTIVE**. Nothing leaves my Mac.

## In scope for MVP

**Input**
- List input devices; default to built-in mic; allow switching.
- Input level meter + clipping warning + input gain.

**Conversion**
- Load one locally stored, authorized voice model (via enrollment, Phase 4, or
  a pre-placed model folder).
- Real-time speech-to-speech conversion, local only.
- Show the active model name.
- Fully wet output by default (dry/wet optional).

**Output**
- Route converted audio to the "VoiceBridge Microphone" virtual device.
- Output-device status; detect missing driver.

**Controls**
- Large Start/Stop, Mute, Bypass buttons.
- Input + output meters, latency display, CPU/GPU display.
- Persistent ACTIVE indicator (dot + timer).
- Disclosure reminder text.
- Keyboard shortcuts: mute, bypass, start/stop.

**Safety**
- Output gain + limiter.
- Automatic fallback to bypass on converter/device failure.
- Clear error if mic or virtual output disappears.

**Privacy**
- No network by default; network status shown as "local".
- Models stored in an app-managed folder; per-model delete.

**Consent**
- Enrollment/import blocked without an explicit permission attestation.

## Out of scope for MVP (later)

- Multiple simultaneous models / hot-swapping mid-call.
- Noise suppression + echo cancellation toggles (nice-to-have).
- In-app model *training* (import + convert only at first).
- Telemetry (stays off; opt-in later).
- Non-English phonetic tuning UI.
- Menu-bar-only mode, presets, profiles.

## MVP acceptance = brief's Definition of Success

1. [ ] Choose built-in microphone.
2. [ ] Select an authorized, locally stored voice model.
3. [ ] Speak normally; converted speech routes at acceptable latency.
4. [ ] Zoom/Meet/Teams/Discord can select the virtual microphone.
5. [ ] Instant mute or bypass.
6. [ ] Window visibly states conversion is active.
7. [ ] All processing local by default.
