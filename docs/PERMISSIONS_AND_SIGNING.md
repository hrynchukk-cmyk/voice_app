# macOS permissions, signing, sandboxing & the virtual driver

## 1. TCC / runtime permissions

| Permission | Trigger | Handling |
| --- | --- | --- |
| **Microphone** (`NSMicrophoneUsageDescription`) | First capture attempt | Prompted by macOS. App must have the usage string (see `App/Info.plist`) and the `com.apple.security.device.audio-input` entitlement. Check `AVCaptureDevice.authorizationStatus(for: .audio)` and request before starting the engine. |
| **User-selected files** (`...files.user-selected.read-write`) | Importing a recording | Sandbox-friendly: the open panel grants access to exactly the chosen files. |
| **Automation / screen / etc.** | — | Not needed. Do **not** request them. |

There is intentionally **no network permission**. If you ever add an online
feature, add `com.apple.security.network.client`, disclose it in-app, and update
the network-status indicator honestly.

## 2. App Sandbox

The app ships **sandboxed** (`com.apple.security.app-sandbox = true`). Sandbox
implications:

- Voice models live in the app's container:
  `~/Library/Containers/com.example.VoiceBridge/Data/Library/Application Support/VoiceBridge/Models/`.
  (`VoiceModelStore` resolves this via `FileManager` `.applicationSupportDirectory`.)
- Imported originals are copied into the container on import; the open-panel
  grant covers reading the source.
- The sandbox does **not** block Core Audio device I/O — HAL access is allowed
  with the audio-input entitlement.

## 3. Code signing & hardened runtime

- **Hardened Runtime** is enabled (`ENABLE_HARDENED_RUNTIME = true`). Required
  for notarization.
- Sign with a **Developer ID Application** certificate for distribution outside
  the App Store, then **notarize** (`notarytool`) and **staple**.
- If you embed a Core ML model, no extra entitlement is needed. If you use the
  Apple Neural Engine, that's automatic via Core ML.
- **App Store note:** an app that installs a system audio driver generally
  **cannot** ship on the Mac App Store — plan on Developer ID + notarization for
  the driver-bearing build.

## 4. The virtual audio driver — the hard part

You have three realistic options; see `VirtualDevice/README.md` for detail.

### Option A — Audio Server Plug-In (userland, based on Apple's sample)
- A `.driver` bundle placed in `/Library/Audio/Plug-Ins/HAL/`.
- Loaded by `coreaudiod`; **must be signed and notarized**, and on Apple
  Silicon the bundle's code signature is enforced.
- Installation requires admin (writing to `/Library/...`) — ship an installer
  or a privileged helper (`SMAppService` / `SMJobBless`).
- This is what BlackHole is. Great for prototyping; for shipping, build your own
  from Apple's sample so the license is clean.

### Option B — AudioDriverKit (DriverKit, modern)
- Runs as a system extension (`.dext`), user-approved in System Settings.
- Requires the **DriverKit + audio** entitlement, which you **request from
  Apple** (`com.apple.developer.driverkit` + audio family). Approval is not
  instant — plan for it.
- Better long-term fit for Apple Silicon and future macOS.

### Option C — Depend on a user-installed device (fastest to demo)
- Instruct the user to install **BlackHole** (or Loopback) themselves and
  select it. VoiceBridge just outputs to it.
- Zero driver-signing work for you; **not** a polished product experience, and
  BlackHole's GPL means you can't bundle it — the user installs it.

### Recommended path
Prototype with **C** (BlackHole, user-installed) → validate the full pipeline →
build **A** (your own signed Audio Server Plug-In) for the first real release →
evaluate **B** (DriverKit) for longevity.

## 5. System Extension / driver approval UX

- First install of a `.dext` or a HAL plug-in prompts the user in **System
  Settings ▸ Privacy & Security** to approve.
- Document this clearly in-app (Phase 2): show a checklist and a "driver not
  found / not approved" state that links to the setting.
- After macOS updates, a system extension may need re-approval — detect the
  device's presence at launch and guide the user if it's gone.

## 6. Latency vs. sandbox/hardened runtime

Neither the App Sandbox nor the Hardened Runtime adds meaningful audio latency —
they gate *capabilities*, not the real-time thread. Latency comes from buffer
sizes, model lookahead, and the extra device hop through the virtual driver
(§audio-flow), not from signing. Keep the I/O buffer small
(`kAudioDevicePropertyBufferFrameSize`, e.g. 128–256 frames) and the ANE warm.

## 7. Distribution checklist

- [ ] Developer ID Application cert; Hardened Runtime on.
- [ ] Entitlements minimal (audio-input, user-selected files, sandbox; **no
      network**).
- [ ] App notarized + stapled.
- [ ] Driver (if you ship one) signed, notarized, installed to
      `/Library/Audio/Plug-Ins/HAL/` via a privileged helper or `.dext`
      system-extension flow.
- [ ] First-run flow guides microphone permission + driver approval.
- [ ] Uninstaller removes the driver and offers to remove local models.
