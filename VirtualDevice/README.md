# Virtual audio device ("VoiceBridge Microphone")

This is the separate audio-routing layer that presents VoiceBridge's output to
Zoom/Meet/Teams/Discord as a selectable microphone. It is **not** an injection
into those apps — the user picks it explicitly in the app's audio settings, so
its presence is transparent.

## Why this is its own layer

macOS has no public API to "become a microphone" from a normal app. A process
can only *play into* an output device. The bridge works like this:

```
VoiceBridge app  ──plays converted audio──▶  "VoiceBridge" output device
                                                     │ (loopback inside the driver)
Meeting app  ◀──reads as microphone input──  "VoiceBridge" input device
```

A loopback/aggregate virtual driver exposes an **output** side the app plays
into and an **input** side other apps read from, copying samples between them.

## Options (pick per phase — see docs/PERMISSIONS_AND_SIGNING.md §4)

### A. Audio Server Plug-In (recommended base for shipping)
A userland CoreAudio HAL plug-in (`.driver` bundle in
`/Library/Audio/Plug-Ins/HAL/`), loaded by `coreaudiod`.

- Start from Apple's **"NullAudio" / "SimpleAudioDriver"** sample (permissive
  sample-code license) and add loopback between the input and output streams.
- **BlackHole** is a working example of exactly this pattern — but it is
  **GPL-3.0**, so use it to prototype, not to bundle into a proprietary app.
- Must be **code-signed and notarized**; on Apple Silicon the signature is
  enforced by `coreaudiod`.
- Install needs admin rights (writing to `/Library`). Ship a privileged helper
  via `SMAppService`.

### B. AudioDriverKit / System Extension (modern, forward-looking)
A DriverKit `.dext` bundled in the app, approved by the user in System Settings.

- Requires the **`com.apple.developer.driverkit`** entitlement plus the audio
  driver family — **requested from Apple**, not self-granted. Plan lead time.
- Best long-term fit for Apple Silicon and future macOS versions.

### C. User-installed third-party device (fastest to demo)
Tell the user to install **BlackHole** or **Loopback** themselves and select it
as the VoiceBridge output. Zero driver work for you; not a polished UX, and you
cannot bundle BlackHole (GPL).

## Recommended path
Prototype with **C** → validate the whole pipeline → ship your own signed
**A** → evaluate **B** for longevity.

## Quick start with BlackHole (path C — works today)

```bash
brew install blackhole-2ch        # or download the installer from Existential Audio
```

Then in VoiceBridge:
1. Pick **BlackHole 2ch** in the *Virtual microphone* dropdown. The app routes
   converted audio to it (`AudioEngine.setOutputDevice`).
2. In Zoom/Meet/Teams, choose **BlackHole 2ch** as the microphone.

To **hear yourself** while a meeting also receives the audio, create a
**Multi-Output Device** (BlackHole + your headphones) in *Audio MIDI Setup* and
select that as the *Virtual microphone* instead — the app will drive both.

## What the app already does to support this
- `AudioDeviceManager.virtualOutput()` finds an installed virtual device
  (BlackHole, VB-Cable, Loopback, Soundflower, or a "VoiceBridge" driver);
  `isVirtual(_:)` tags the current selection.
- `AudioEngine.setOutputDevice(_:deviceID:)` points the output engine's AUHAL at
  the chosen device via `kAudioOutputUnitProperty_CurrentDevice`, with fallback
  to the system default if it can't be used.
- `MainView` shows install guidance, a "ready" state when a virtual device is
  selected, and a hint to select one otherwise.

## Install / uninstall UX to build (Phase 2)
- First-run checklist: detect the device, guide install + approval, link to
  System Settings ▸ Privacy & Security.
- Detect post-update removal at launch; re-guide if the device is gone.
- Uninstaller removes the driver bundle and offers to remove local models.

## Driver source
The actual driver source is **not** in this scaffold (it's a separate, signed
C/C++ build target). Add it here as `VoiceBridgeDriver/` when you start Phase 2,
based on Apple's sample, and wire its signing/notarization into your release
pipeline.
