# Testing plan — validate with local recordings before any real meeting

Test in this order. Do not jump to a live meeting until §4 passes.

## 0. Fixtures

Record (or synthesize) a few short WAVs at 48 kHz mono into `ml/fixtures/` (git-
ignored) or a local scratch folder:
- `speech_normal.wav` — normal conversational speech.
- `speech_loud.wav` — deliberately loud, to trigger clipping.
- `silence.wav` — room tone, for the noise gate/VAD.
- `sweep.wav` — a sine sweep, for latency measurement.

## 1. Phase 1 — capture, meters, mute/bypass (headphones only)

Use **headphones** to avoid feedback.

- [ ] Launch; grant mic permission; confirm built-in mic is auto-selected.
- [ ] Speak: input meter tracks level; you hear yourself (monitoring).
- [ ] Play `speech_loud.wav` into the mic / raise input gain: **clipping warning
      appears**; output limiter prevents the output meter pinning at 0 dBFS.
- [ ] **Mute**: output goes silent within one buffer; input meter still moves.
- [ ] **Bypass**: you hear dry audio; toggling is instant.
- [ ] Keyboard shortcuts toggle mute/bypass/start-stop.
- [ ] Unplug/select-away the mic: clear error, no crash; reselect recovers.

## 2. Latency measurement (objective, no meeting)

Two ways:

**A. Loopback capture.** Route the app output to a file/virtual device while
feeding `sweep.wav` in, record both, and cross-correlate input vs. output in a
quick Python/Numpy script. The lag of the correlation peak = end-to-end
latency. Log it into the app's latency display for comparison.

**B. In-app estimate.** The engine already knows I/O buffer sizes and the
converter's measured per-chunk time; the latency display sums them. Cross-check
against method A so the display is *truthful*, not optimistic.

Record the number per Mac model (M1/M2/M3, buffer size, model). This is your
regression baseline.

## 3. Phase 2 — virtual device (still no meeting)

- [ ] Install the virtual driver (BlackHole for prototyping).
- [ ] In **QuickTime ▸ New Audio Recording**, pick "VoiceBridge Microphone" and
      record while the app runs — you should capture the app's output.
- [ ] Remove/disable the driver: app shows "driver not found", no crash.

## 4. Phase 3 — conversion, offline

- [ ] Feed `speech_normal.wav` (via mic or a virtual input) with a loaded
      authorized model; confirm the output voice audibly differs.
- [ ] Kill the converter process (Track A) or force a Core ML error (Track B):
      **app falls back to bypass automatically**, banner shows.
- [ ] Confirm no network traffic: run with **Little Snitch**/`nettop`/Charles —
      there should be **none** from the app. The network indicator reads
      "local".

## 5. Consent / privacy checks

- [ ] Try to enroll a model without confirming permission → **blocked**.
- [ ] Delete a model → its folder, originals, and consent record are gone.
- [ ] Inspect the container: models only under Application Support/VoiceBridge;
      nothing outside the sandbox.

## 6. Live meeting (last)

- [ ] In Zoom/Meet/Teams/Discord, pick "VoiceBridge Microphone".
- [ ] Use the app's **Test / echo** feature (or the meeting app's mic test).
- [ ] Verbally **disclose** to participants that converted audio is in use.
- [ ] Verify Mute and Bypass work mid-call; verify the ACTIVE indicator.
- [ ] Verify automatic bypass fallback doesn't drop the call.

## 7. Regression automation

- Unit-test `RingBuffer` (SPSC correctness, wrap-around, over/underrun).
- Unit-test `LevelMeter` (known RMS/peak for synthetic buffers).
- Unit-test `SafetyLimiter` (no output sample exceeds the ceiling).
- Unit-test `ProcessingMode` transitions and the bypass-fallback state machine.
- Snapshot-test that the ACTIVE indicator is visible whenever the engine
  reports running.
