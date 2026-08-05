# Training a voice model (Phase 3, step 1)

This is the prerequisite for *identity* conversion — making VoiceBridge sound
like a **specific authorized person** rather than just shifting pitch. Nothing in
the app changes until a trained model exists, so this comes first.

The model format targeted here is **RVC v2** (`.pth` weights + `.index` retrieval
file), because it is the format real-time voice-changer runtimes accept.

---

## 0. Consent — not optional

Train a voice only with the **explicit permission of the person whose voice it
is**. Get it before collecting audio, not after.

- The speaker must know a model of their voice is being made, and what it will
  be used for.
- Everyone you later speak to with converted audio must be told it is in use.
- Keep a record. `EnrollmentView` stores this attestation next to the model
  (`consent.json`) and the store refuses models without it.

Using someone's voice to impersonate them to other people — without their
knowledge or the listener's — is not what this is for, and in many places it is
illegal. If you can't get permission, stop here and use the built-in voice
changer instead: it changes voice *character* without cloning an identity.

---

## 1. Collect the audio

| Amount of clean speech | Realistic outcome |
| --- | --- |
| < 1 min | Cannot train anything usable |
| 1–5 min | Poor, unstable, obviously artificial |
| 5–10 min | Trainable; limited quality |
| **10–30 min** | **Good — the sweet spot** |
| > 60 min | Diminishing returns; curation matters more than volume |

Quality beats quantity — **10 minutes of clean speech beats an hour of noisy
audio**. What "clean" means:

- **One speaker only.** No interviews, no overlapping voices, no background TV.
- **No music, no reverb.** A small quiet room; not a hall, not a car.
- **Consistent mic and distance.** One session with one mic is ideal.
- **Varied speech.** Natural sentences covering many sounds — not one phrase
  repeated, not reading numbers.
- **Not clipped.** Distorted peaks bake permanent artefacts into the model.
- **Normal speaking voice** — matching how it will be used in meetings.

A phone voice memo in a quiet room is genuinely fine. A podcast episode with
music beds is not.

---

## 2. Prepare the dataset

`ml/prepare_dataset.py` decodes anything ffmpeg reads (mp3/m4a/wav/flac/mp4/…),
converts to mono at the training rate, trims silence, splits into short clips,
drops clipped and near-silent junk, normalises levels — and tells you whether
there is enough material **before** you spend time on a GPU.

```bash
brew install ffmpeg
cd ~/Desktop/voice_app/ml
python3 -m venv .venv && source .venv/bin/activate
pip install numpy soundfile

python prepare_dataset.py \
    --input  ~/Desktop/yaroslav_raw \
    --output dataset/yaroslav
```

Output:

```
  interview.mp3: 42 segment(s)
  memo01.m4a: 18 segment(s)
==========================================================
Input audio      : 14.2 min across 2 file(s)
Usable speech    : 11.8 min in 60 clip(s)
Output folder    : dataset/yaroslav
==========================================================
VERDICT: GOOD. Enough material to train a solid model.
```

It exits non-zero when there isn't enough usable speech, so you get a clear
"go collect more" rather than a bad model later. Useful flags:

- `--sr 48000` — train at 48k instead of the 40k default.
- `--max-len 10` — clip length cap in seconds.
- `--top-db 35` — silence sensitivity; **lower** it (e.g. 25) if quiet speech is
  being cut off, raise it if background noise is being kept.
- `--overwrite` — clear the output folder first.

Listen to a few clips in `dataset/yaroslav/` before training. Whatever is wrong
in them will be faithfully learned by the model.

---

## 3. Train

Training needs a CUDA GPU to be practical. Two options:

### A. Google Colab via Applio (recommended — free GPU, no local setup)

[Applio](https://github.com/IAHispano/Applio) is an RVC distribution with a web
UI. Its Colab notebook is a **launcher**: the cells install it and start a Gradio
server; the actual training happens in that web UI (it has Dataset Path,
Preprocess, Extract, Train and Generate Index).

Notebook: <https://colab.research.google.com/github/iahispano/applio/blob/main/assets/Applio.ipynb>

1. Put the prepared clips where Colab can read them — simplest is Google Drive:
   upload the `dataset/<name>/` folder to your Drive.
2. Open the notebook, then **Runtime ▸ Change runtime type ▸ GPU**.
3. Run the cells in order: *Mount Drive* → *Setup Runtime Environment* (a few
   minutes) → *Start Server*. Open the URL it prints.
4. In the Applio UI, **Train** tab:
   - **Dataset Path**: the Drive folder from step 1.
   - **Sample rate**: `40k` — must match `--sr` from step 2 of this guide.
   - **Version**: `v2`
   - **f0 / pitch extraction**: `rmvpe` — best quality/robustness today.
   - **Epochs**: start at **150**. More is not better; it overfits.
   - **Batch size**: whatever fits the GPU (Colab T4: ~8).
5. Run **Preprocess** → **Extract Features** → **Train** → **Generate Index**.
   Roughly **40–90 min** for ~10–20 min of audio on a T4.
6. Download two files — you need **both**:
   - `<name>.pth` — the model weights
   - `added_*.index` — the retrieval index (improves similarity)

> Colab notebooks for RVC break often as Python/torch move. If the setup cell
> fails, [`webvijayi/rvc-free-colab`](https://github.com/webvijayi/rvc-free-colab)
> carries patches for training RVC v2 on current Colab (Python 3.12 / numpy 2.x
> / torch 2.x, fairseq removed), applied on top of the
> [`ardha27/AI-Song-Cover-RVC`](https://github.com/ardha27/AI-Song-Cover-RVC)
> notebook.

### B. Locally on Apple Silicon

Possible via PyTorch MPS, but slower and the tooling fights you. Use Colab for
the first model; revisit local training only if you'll retrain often.

---

## 4. Judge the result honestly

Before wiring anything up, convert a test clip and listen critically:

- Does it sound like the target person, or merely *not* like you?
- Are consonants smeared, is there warbling or metallic ringing?
- Does it hold up on words that weren't in the training data?

If it's poor, the fix is almost always **more/cleaner audio**, not more epochs.
Overtraining is a common cause of robotic output — try an earlier checkpoint.

**Set expectations:** a good RVC model is recognisable, not indistinguishable.
Real-time conversion adds **~150–300 ms** latency (versus ~16 ms for the built-in
changer) and quality varies with your mic, room, and how you speak.

---

## 5. Then what

With `.pth` + `.index` in hand, pick the integration path:

- **Fastest to hear it live:** run a mature real-time RVC runtime (e.g.
  `w-okada/voice-changer`) and route its output into **BlackHole** — the virtual
  mic you already have working. No new code; VoiceBridge's Phase 2 routing is
  what makes it usable in meetings.
- **Built into VoiceBridge:** implement `ExternalProcessConverter` against
  `ml/server.py` (the socket protocol is already defined there) and run RVC
  inference in that sidecar, or convert to Core ML for `CoreMLConverter`.

Store the model under the app's model folder with its consent record — see
[`VOICE_MODELS.md`](VOICE_MODELS.md).
