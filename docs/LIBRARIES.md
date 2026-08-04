# Libraries & frameworks — licenses and suitability

Licenses are summarized for orientation, **not legal advice**. Verify each
project's current license before shipping, and treat GPL/AGPL as
redistribution-constraining for a closed-source commercial product.

## Apple system frameworks (all fine for commercial use)

| Framework | Use | Notes |
| --- | --- | --- |
| **AVFoundation / AVAudioEngine** | Capture, monitoring, source/sink nodes | Simplest correct real-time-ish path. |
| **Core Audio (AudioToolbox, CoreAudio HAL)** | Device enumeration, hot-plug listeners, AUHAL for lowest latency | Drop to this when AVAudioEngine latency isn't enough. |
| **Audio Server Plug-In API / AudioDriverKit** | The virtual microphone device | AudioDriverKit (DriverKit) is the modern, Apple-Silicon-friendly path; needs a special Apple entitlement. |
| **Core ML + Metal Performance Shaders** | On-device neural inference (ANE/GPU) | Ship path for the converter; no Python dependency. |
| **Accelerate / vDSP** | FFT, RMS, filters, resampling | Fast native DSP for meters, limiter, features. |
| **SwiftUI + Combine** | UI, reactive state | Main window and controls. |

## Voice conversion models / engines

| Project | License | Real-time? | Suitability |
| --- | --- | --- | --- |
| **w-okada/voice-changer (VC Client)** | MIT | **Yes** (wraps RVC, so-vits-svc, DDSP-SVC, Beatrice) | Best *reference* for a real-time streaming pipeline and chunking. MIT is commercial-friendly, but **check each wrapped model's own license/weights**. |
| **RVC (Retrieval-based-Voice-Conversion)** | MIT (code) | With a wrapper | Popular, good quality. Weights/models you obtain may carry their own terms. |
| **Seed-VC** | check repo (research) | Streaming mode exists | Zero-shot + fine-tune; evaluate license before shipping. |
| **FreeVC** | MIT-style (built on VITS, MIT) | Not natively streaming | Good quality; needs a streaming wrapper for live use. |
| **so-vits-svc** | mixed / AGPL forks exist | With a wrapper | **License varies by fork — audit carefully**, some are copyleft. |
| **DDSP-SVC** | MIT | Lightweight, lower latency | Good candidate for low-latency real-time. |

**Guidance:** for a first *working* version, prototype with the w-okada
pipeline (Track A) because it already solves real-time chunking. For a
*shippable* product, pick a permissively licensed model whose **weights** you
are allowed to redistribute (or that the user brings themselves via enrollment),
and convert it to **Core ML** (Track B).

## Runtimes for the ML backend

| Project | License | Notes |
| --- | --- | --- |
| **ONNX Runtime** | MIT | Cross-platform inference for the Python backend; CoreML execution provider on macOS. |
| **PyTorch** | BSD-3 | Training and prototyping. Heavy; avoid shipping in the app. |
| **coremltools** | BSD-3 | Convert PyTorch/ONNX → Core ML for Track B. |

## Voice activity detection

| Project | License | Notes |
| --- | --- | --- |
| **Silero VAD** | MIT | Small, accurate; run via ONNX/Core ML. Recommended. |
| **WebRTC VAD** | BSD-3 | Very light, pure DSP, C. Good fallback. |
| DSP energy + zero-crossing gate | n/a (you write it) | Zero-dependency baseline; included conceptually in `VoiceActivityDetector.swift`. |

## Virtual audio device

| Project | License | Suitability |
| --- | --- | --- |
| **Apple "SimpleAudioDriver" / Audio Server Plug-In sample** | Apple sample-code license (permissive, commercial OK) | **Recommended base** for your own signed driver. |
| **AudioDriverKit** (Apple) | System framework | Modern DriverKit approach; requests the DriverKit + audio entitlement from Apple. |
| **BlackHole** | **GPL-3.0** | Excellent for **prototyping/testing** (Phase 2 validation). GPL makes bundling into a closed commercial app problematic — use for dev, don't redistribute inside a proprietary product. |
| **Loopback / Rogue Amoeba** | Commercial | Not embeddable; user-installed third-party option only. |

## Utilities

| Project | License | Notes |
| --- | --- | --- |
| **XcodeGen** | MIT | Generates `VoiceBridge.xcodeproj` from `project.yml`. Dev-time only. |
| **TPCircularBuffer** | MIT | Battle-tested lock-free SPSC ring buffer (C). Consider replacing the Swift `RingBuffer` in production. |
| **Swift Argument Parser / Log** | Apache-2.0 | Optional CLI/diagnostics. |

## License strategy summary

- **Safe to build a commercial product on:** Apple frameworks, MIT/BSD/Apache
  projects (ONNX Runtime, RVC *code*, FreeVC, DDSP-SVC, Silero, XcodeGen,
  TPCircularBuffer, coremltools).
- **Prototype-only / avoid embedding:** BlackHole (GPL-3.0), any AGPL/GPL VC
  fork.
- **Always separately verify:** the **model weights** you distribute — code
  license ≠ weights license. When in doubt, have the **user** supply the voice
  via enrollment so you never redistribute a third party's voice model.
