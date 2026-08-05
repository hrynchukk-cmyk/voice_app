# ML backend (prototype conversion engine — Track A)

This directory holds the **optional** local inference backend used to get voice
conversion working fast (Phase 3, Track A). It talks to the Swift app through
`ExternalProcessConverter` over a **localhost-only** channel and is launched and
supervised by the app as a child process.

> For a shipping build, prefer **Track B**: convert the model to **Core ML** and
> run it natively in-process (`CoreMLConverter`) — no Python, lower latency, one
> fewer moving part. See docs/ARCHITECTURE.md §4.

## Hard rules

- **No outbound network.** This backend binds to a Unix domain socket (or
  `127.0.0.1`) only. It never uploads audio or model data. The app itself has
  **no** network entitlement.
- Models are read from the app-managed local folder passed in on launch.
- The backend is stateless per session and holds no recordings after exit.

## Suggested stack

- **ONNX Runtime** (MIT) with the CoreML execution provider for on-device
  acceleration, or PyTorch for prototyping.
- A real-time-capable VC model — see docs/LIBRARIES.md. The chunk/lookahead size
  of the model dominates latency; keep it small.
- Reference implementation to study for real-time chunking:
  **w-okada/voice-changer** (MIT).

## Contract with the app

`ExternalProcessConverter` (Swift) ↔ `server.py`:

1. App launches `python server.py --model <path> --socket <uds>` (no net flags).
2. Server loads the model, prints a `READY` handshake line.
3. Per chunk: app sends `preferredChunkFrames` float32 mono samples; server
   returns the same number of converted samples within the deadline.
4. Any error / timeout → app throws → **automatic bypass** in the engine.

`server.py` here is a **stub** that documents the protocol and passes audio
through unchanged. Replace the `convert()` body with real inference.

## Dataset preparation

`prepare_dataset.py` turns raw recordings into the clean, uniform clips RVC
training expects, and reports whether there is enough usable speech before you
spend time on a GPU. See [`../docs/TRAINING_RVC.md`](../docs/TRAINING_RVC.md)
for the full training walkthrough.

```bash
pip install numpy soundfile        # plus ffmpeg on PATH
python prepare_dataset.py --input ~/Desktop/yaroslav_raw --output dataset/yaroslav
```

## Local setup

```bash
cd ml
python3 -m venv .venv && source .venv/bin/activate
pip install numpy onnxruntime   # add your model's deps
python server.py --help
```

Nothing here runs automatically; the app starts it only when you wire up
`ExternalProcessConverter.load(model:)` in Phase 3.
