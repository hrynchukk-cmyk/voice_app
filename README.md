# VoiceBridge

**Consent-based, real-time voice conversion for macOS meetings.**

VoiceBridge lets you speak through your Mac's built-in microphone and route the
result — in the voice of a person who has **explicitly authorized** the use of
their voice — into Zoom, Google Meet, Microsoft Teams, Discord, or any app that
can pick a microphone.

All processing runs **locally by default**. Nothing is uploaded.

> ⚠️ **This project is for authorized, disclosed use only.**
> A voice model may only be built from recordings supplied by, or with the
> explicit permission of, the person whose voice is modeled. Whenever
> conversion is active, VoiceBridge shows a persistent indicator and reminds you
> to disclose to meeting participants that converted audio is in use. See
> [Consent & Safety](#consent--safety).

---

## Status

This repository is a **first-version scaffold + design**. It contains:

- A complete technical design (see [`docs/`](docs/)).
- Working, idiomatic Swift/SwiftUI example code for **Phase 1**: microphone
  capture, level metering, clipping detection, mute, and bypass, with a
  real-time-safe processing pipeline.
- A **built-in native voice changer** (`NativeVoiceConverter`, a real-time
  pitch/formant shifter) wired in as the default converter, so **Start
  immediately transforms your voice** — no ML model, Python, or driver needed
  to hear it. This changes voice *character*, not a specific person's identity.
- Protocol-level stubs for the parts that require a device/model/driver present
  on real hardware: **identity** voice conversion toward an authorized speaker
  (Phase 3, ML) and the virtual microphone driver (Phase 2).

The Swift code targets **macOS 13+** and Apple Silicon. It has **not** been
compiled inside this environment (no Xcode/macOS here) — treat it as a
ready-to-open starting point, not a shipped binary. See
[`docs/TESTING.md`](docs/TESTING.md) for how to validate it.

## Documentation map

| Document | What it covers |
| --- | --- |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Recommended architecture, audio flow, native-vs-Python split, latency budget |
| [`docs/DEVELOPMENT_PLAN.md`](docs/DEVELOPMENT_PLAN.md) | Phased plan (Phase 1–4) with acceptance criteria |
| [`docs/MVP.md`](docs/MVP.md) | Minimal viable product specification |
| [`docs/LIBRARIES.md`](docs/LIBRARIES.md) | Open-source libraries, licenses, commercial suitability |
| [`docs/PERMISSIONS_AND_SIGNING.md`](docs/PERMISSIONS_AND_SIGNING.md) | TCC permissions, code signing, sandboxing, virtual-driver notarization |
| [`docs/VOICE_MODELS.md`](docs/VOICE_MODELS.md) | Enrollment/import workflow and consent gating |
| [`docs/TESTING.md`](docs/TESTING.md) | Local recording-based test plan before any real meeting |
| [`VirtualDevice/README.md`](VirtualDevice/README.md) | Virtual audio device options (Audio Server Plug-In / DriverKit / BlackHole) |
| [`ml/README.md`](ml/README.md) | Reference real-time conversion backend (Python/ONNX) |

## Quick start (on a real Mac)

```bash
# 1. Install tools
brew install xcodegen        # generates the Xcode project from project.yml

# 2. Generate and open the Xcode project
xcodegen generate
open VoiceBridge.xcodeproj

# 3. Set your signing team in Xcode (Signing & Capabilities), then Run.
```

On first launch macOS will ask for **Microphone** permission. Grant it. Phase 1
lets you monitor your own mic through headphones and toggle mute/bypass. The
virtual microphone (Phase 2) and voice conversion (Phase 3) are wired as
selectable-but-inactive components until you install the driver and a model —
see the phase docs.

## Consent & Safety

VoiceBridge deliberately **includes** friction that protects the people whose
voices are used and the people you talk to:

- A voice model cannot be enrolled without an explicit **"I have permission"**
  confirmation, stored alongside the model (`ConsentManager`).
- A **persistent, obvious "Voice conversion ACTIVE" indicator** with a colored
  dot and a session timer is shown the entire time conversion runs.
- **One-click Mute** and **one-click Bypass** (send your real, unconverted
  voice) are always reachable, including via global keyboard shortcuts.
- If the conversion engine crashes or a device disappears, VoiceBridge **falls
  back to bypass automatically** and shows a clear error.
- A standing **disclosure reminder** ("Tell meeting participants that
  voice-converted audio is in use.") is visible in the main window.

VoiceBridge deliberately **does not** include, and this project will not add:
covert recording, a hidden/"stealth" conversion mode, automatic impersonation,
a fake "real microphone" indicator, or cloud upload by default. These are
out of scope by design — see the Non-Goals in the project brief and
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## License

No license is chosen yet. Note that some voice-conversion and virtual-audio
components are GPL-licensed, which constrains commercial redistribution — read
[`docs/LIBRARIES.md`](docs/LIBRARIES.md) before picking one.
