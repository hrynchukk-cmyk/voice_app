# Step 0 — measure real-time latency on your Mac

Everything about Phase 3 depends on one number: **how long the conversion
actually takes on this machine**. Until it is measured, any plan is guesswork —
so measure it before investing in more recordings, more training, or native
integration.

RVC targets NVIDIA CUDA. On Apple Silicon it runs through MPS or CPU, and how
much slower that is cannot be predicted from spec sheets.

## The latency budget

| Component | Typical |
| --- | --- |
| Meeting network delay (Zoom/Meet) | 100–200 ms — outside our control |
| **Local conversion** | **what we are measuring** |
| Point where conversation feels awkward | ~300 ms total |

Turn-taking in conversation runs on ~200 ms gaps, so the local budget is roughly
100–150 ms. Real-time RVC often costs 150–300 ms on its own — which is why this
measurement decides the architecture.

---

## 1. Install Applio locally

The Colab notebook cannot do real time: it runs on a Google server that has no
microphone and no speakers, which is why its Realtime device lists are empty.

```bash
cd ~/Desktop
git clone https://github.com/IAHispano/Applio.git
cd Applio
chmod +x run-install.sh run-applio.sh
./run-install.sh          # several GB, 10–20 min
```

## 2. Put your trained model in place

```bash
mkdir -p ~/Desktop/Applio/logs/<model-name>
```

Copy in the two files from training — the weights (`*.pth`) and the retrieval
index (`*.index`). Both are needed.

## 3. Start it

```bash
cd ~/Desktop/Applio && ./run-applio.sh
```

Open the local URL it prints, go to **Realtime**, and configure:

| Field | Value |
| --- | --- |
| Input Device | your microphone |
| Output Device | **BlackHole 2ch** (what meeting apps will read) |
| Monitor Device | your headphones, so you can hear yourself |
| Enable VAD | on — skips silence, saves CPU |
| Exclusive Mode | try on; sometimes lower latency |
| Pitch | match the model — see below |

> **Pitch matters.** Set it so your speaking pitch lands on the model's pitch;
> a large shift is itself a source of artefacts. Measured on real files: a −8
> semitone shift produced clearly robotic output, while the same model at 0
> semitones moved the voice measurably *closer* to the target.

Then press **Start** and confirm you hear yourself converted in the monitor.

---

## 4. Record the measurement

The trick: capture the **dry microphone** and the **converted output** into two
channels of one file. The same speech appears in both, the converted one delayed
by exactly what we want to measure.

1. Open **Audio MIDI Setup** (Spotlight → "Audio MIDI Setup").
2. **+** at the bottom left → **Create Aggregate Device**.
3. Tick both **your microphone** and **BlackHole 2ch**. Note the channel order —
   the mic's channel is the "dry" one, BlackHole's is the "converted" one.
4. Record from that aggregate device for **10–20 seconds while speaking
   continuously** — QuickTime Player (New Audio Recording), Audacity, or any
   recorder that lets you pick the input device.

Speak normally and keep going; the tool needs varied loud/quiet passages to lock
on. Reading a paragraph aloud works well.

## 5. Get the number

```bash
cd ~/Desktop/voice_app/ml
source .venv/bin/activate
python measure_latency.py ~/Desktop/latency_test.wav
```

```
==========================================================
Recording        : 15.0 s @ 44100 Hz
Envelope match   : 0.991   (1.0 = perfect; < 0.3 = unreliable)
MEASURED LATENCY : 180 ms
==========================================================
VERDICT: VIABLE. Natural conversation should feel fine.
```

If the recorder produced two separate files instead of one stereo file, pass
them in order — dry first:

```bash
python measure_latency.py dry.wav converted.wav
```

### Why it correlates envelopes, not waveforms

Voice conversion resynthesises the audio: on a real converted pair the waveform
correlation measured **−0.20**, essentially unrelated, so lining up waveforms
would fail. The loudness envelope — when you were loud and when you paused —
survives conversion, so that is what gets aligned. Verified accurate to ±2 ms
against known delays from 0 to 800 ms.

An `Envelope match` below 0.3 means the result is not trustworthy: usually the
wrong device landed in a channel, too little speech was recorded, or the delay
is larger than the search window (`--max-lag`).

---

## 6. What the number means

| Measured | Verdict | What to do |
| --- | --- | --- |
| **< 250 ms** | Viable | Conversation feels fine. Invest in model quality: more training audio, then native Core ML inference. |
| **250–500 ms** | Marginal | Fine for talks and monologue; people will talk over you in fast discussion. Try smaller chunk/quality settings before concluding. |
| **> 500 ms** | Too slow | Not usable for live conversation here. Either trade quality for speed, or keep identity conversion for recorded audio and use the built-in changer (~16 ms) for live calls. |

Whatever the number, the reliability layer still matters for real meetings:
instant mute, bypass to your real voice, and automatic fallback when the
converter stalls mid-sentence. A raw conversion GUI has none of that — you
simply go silent or garbled in front of people.

## 7. If it is too slow

In rough order of effect:

1. **Shorter chunk / lower quality** in Realtime performance settings — the
   direct latency/quality trade.
2. **`w-okada/voice-changer`** — built specifically for real-time and separately
   optimised; the same `.pth` and `.index` work unchanged.
3. **Core ML** — convert the model and run it natively on the Apple Neural
   Engine, no Python (Track B in `ARCHITECTURE.md`). Best end state on a Mac,
   and the most work.
4. **Accept the split** — built-in pitch/formant changer for live calls, RVC for
   recorded audio.
