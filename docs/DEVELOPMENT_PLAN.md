# Phased development plan

Each phase ends with a demoable, shippable-ish increment and explicit
acceptance criteria. Do not start a phase before the previous one's criteria
pass — especially the safety criteria.

## Phase 1 — Capture, monitoring, UI, mute/bypass  ✅ scaffolded here

**Goal:** speak into the built-in mic and hear yourself through headphones,
with working meters and instant mute/bypass. No conversion, no virtual device
yet.

Scope:
- Enumerate input devices; default to built-in mic (`AudioDeviceManager`).
- Capture via `AVAudioEngine` + `AVAudioSinkNode` (`AudioEngine`).
- Input **and** output level meters with peak + RMS (`LevelMeter`, `MeterView`).
- **Clipping detection** with a visible warning.
- **Input gain** slider.
- **Mute** and **Bypass** buttons + keyboard shortcuts.
- Persistent **"conversion ACTIVE" indicator** with dot + timer
  (`StatusIndicatorView`) — in Phase 1 it reflects "monitoring active".
- Disclosure reminder text.
- Route processed PCM to the **default output** (monitoring) via
  `AVAudioSourceNode`. In Phase 2 this destination becomes the virtual device.

**Acceptance:**
- [ ] Built-in mic auto-selected; other inputs selectable.
- [ ] Input meter tracks speech; clipping warning fires on loud input.
- [ ] Mute produces silence within one buffer; Bypass passes dry audio.
- [ ] Unplugging the selected device shows a clear error, no crash.
- [ ] Keyboard shortcuts toggle mute/bypass/start-stop.

## Phase 2 — Virtual microphone output

**Goal:** the processed audio appears as a selectable microphone in other apps.

Scope:
- Ship/install a virtual audio device (see `VirtualDevice/README.md`). Start by
  validating the whole app against **BlackHole** (GPL — prototype only), then
  build/sign your own **Audio Server Plug-In** or **AudioDriverKit** driver for
  distribution.
- Route `AVAudioSourceNode` output to the virtual device instead of (or in
  addition to, for local monitoring) the speakers.
- Output-device status/selector in the UI; detect if the driver is missing and
  guide the user to install it.
- Document the install steps and required approvals
  (`PERMISSIONS_AND_SIGNING.md`).

**Acceptance:**
- [ ] Zoom/Meet/Teams/Discord can pick "VoiceBridge Microphone".
- [ ] A test recording played through the app is heard by the meeting app.
- [ ] Removing the driver shows a clear, actionable error.

## Phase 3 — Real-time voice conversion

**Goal:** dry mic in, authorized converted voice out, low latency, local.

Scope:
- Implement `VoiceConverter` for real. Two tracks in parallel:
  - **Track A (prototype):** `ExternalProcessConverter` ↔ `ml/` Python/ONNX
    server. Gets a converted voice flowing fastest.
  - **Track B (ship):** `CoreMLConverter` running a converted model on the ANE.
- Off-thread chunked inference with the dry-fallback design from
  `ARCHITECTURE.md` §5.
- Latency display fed by real measured round-trip; CPU/GPU utilization display.
- **Automatic fallback to bypass** on converter failure (wire to the
  `bypassFallback` state).
- Model selector showing the currently active authorized model.
- Optional dry/wet control (default = fully wet).

**Acceptance:**
- [ ] Converted voice audibly differs from dry; latency display is truthful.
- [ ] Killing the converter drops to bypass automatically with a banner.
- [ ] Measured end-to-end latency documented; < 150 ms on the target Mac.

## Phase 4 — Model import/enrollment & polish

**Goal:** a user can bring an authorized voice into the app safely.

Scope:
- Import WAV/AIFF/M4A/FLAC (`VoiceModelStore`, `EnrollmentView`).
- **Consent gate**: mandatory permission attestation before enrollment
  (`ConsentManager`).
- Training-audio quality guidance in the UI.
- Progress + failure reporting for import/training.
- Preserve originals unless the user deletes them; per-model delete that wipes
  associated local data.
- Optional noise suppression / echo cancellation toggles in the safety stage.
- Preferences: input/output gain memory, shortcut customization,
  opt-in anonymized telemetry (off by default).
- Accessibility pass; the "do not claim identical voice" disclaimer.

**Acceptance:**
- [ ] Enrollment impossible without the permission confirmation.
- [ ] Import shows progress and clear failures; originals preserved.
- [ ] Deleting a model removes all its local files.
- [ ] Network indicator honestly reflects any connection (should read "local").

## Cross-cutting, every phase

- Keep the **ACTIVE indicator bound to real engine state**.
- Keep the **network entitlement absent** unless an online feature is
  explicitly added and disclosed.
- Add a regression test with the recorded fixtures from `docs/TESTING.md`.
