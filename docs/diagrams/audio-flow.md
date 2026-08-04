# Required audio flow

```
Mac built-in microphone
        │
        ▼
Audio capture and preprocessing         (AVAudioEngine / AUHAL, input gain)
        │
        ▼
Voice activity detection / noise handling   (Silero VAD or DSP gate)
        │
        ▼
Real-time speech-to-speech voice conversion (VoiceConverter: Core ML or ONNX)
        │
        ▼
Optional safety limiter and level normalization   (SafetyLimiter, output gain)
        │
        ▼
Virtual microphone audio output          ("VoiceBridge Microphone" driver)
        │
        ▼
Zoom / Meet / Teams / Discord / other meeting application
```

Control overrides that can short-circuit the middle stages:

- **Mute** → replaces the signal after VAD with silence (device stays alive).
- **Bypass** → skips the conversion stage; dry mic audio goes straight to the
  limiter and out to the virtual mic.
- **Fallback** → if conversion is unavailable, behaves exactly like Bypass and
  raises a visible error.
```
