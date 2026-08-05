#!/usr/bin/env python3
"""Prepare a speaker dataset for RVC training.

Takes raw recordings (mp3/m4a/wav/flac/...), and produces the clean, uniform
clips RVC expects: mono, fixed sample rate, silence trimmed, split into short
segments, peak-normalised, with near-silent and clipped junk dropped.

It also PRINTS A VERDICT on whether there is enough usable speech to train, so
you find out before spending an hour on a GPU instead of after.

Usage:
    python prepare_dataset.py --input ~/Desktop/yaroslav_raw --output dataset/yaroslav

Requires ffmpeg on PATH (decoding), plus: pip install numpy soundfile
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

AUDIO_SUFFIXES = {".mp3", ".m4a", ".wav", ".flac", ".aiff", ".aif", ".caf",
                  ".mp4", ".mov", ".ogg", ".opus", ".wma", ".aac"}

# RVC v2 trains at 40k (or 48k). 40k is the common default.
DEFAULT_SR = 40_000


def decode_to_mono(path: Path, sr: int) -> np.ndarray:
    """Decode any ffmpeg-readable file to a mono float32 array at `sr`."""
    cmd = [
        "ffmpeg", "-nostdin", "-v", "error",
        "-i", str(path),
        "-f", "f32le", "-acodec", "pcm_f32le",
        "-ac", "1", "-ar", str(sr),
        "-",
    ]
    proc = subprocess.run(cmd, capture_output=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.decode(errors="replace").strip())
    return np.frombuffer(proc.stdout, dtype=np.float32)


def frame_rms(audio: np.ndarray, frame: int) -> np.ndarray:
    """RMS per non-overlapping frame; trailing partial frame is dropped."""
    usable = len(audio) - (len(audio) % frame)
    if usable <= 0:
        return np.zeros(0, dtype=np.float32)
    frames = audio[:usable].reshape(-1, frame)
    return np.sqrt(np.mean(frames.astype(np.float64) ** 2, axis=1))


def bridge_short_gaps(voiced: np.ndarray, min_gap_frames: int) -> np.ndarray:
    """Fill internal silence runs shorter than `min_gap_frames` with speech.

    Speech is full of sub-second gaps — between words, before plosives, during
    unvoiced consonants. Splitting on every one of them shreds continuous
    speech into unusable slivers, so only a genuinely long pause separates two
    utterances. Leading and trailing silence is left alone.
    """
    out = voiced.copy()
    n = out.size
    i = 0
    while i < n:
        if out[i]:
            i += 1
            continue
        j = i
        while j < n and not out[j]:
            j += 1
        if i > 0 and j < n and (j - i) < min_gap_frames:
            out[i:j] = True          # internal, short → part of the utterance
        i = j
    return out


def split_on_silence(audio: np.ndarray, sr: int, *, top_db: float,
                     min_speech_s: float, max_len_s: float,
                     min_silence_s: float = 0.35, pad_s: float = 0.1,
                     silence_floor_db: float = -50.0) -> list[np.ndarray]:
    """Split into speech segments separated by *real* pauses.

    The threshold is relative to the clip's own loudness (top_db below the peak
    frame) so it adapts to quiet and loud recordings. A whole-file guard rejects
    recordings that are silent throughout — without it, a silent file's own
    noise sits above its own relative threshold and is mistaken for speech.
    """
    frame = max(1, sr // 100)                      # 10 ms analysis frames
    rms = frame_rms(audio, frame)
    if rms.size == 0:
        return []

    peak = float(rms.max())
    # Whole-file silence guard: if even the loudest frame is near-silent, there
    # is no speech here. Applied to the file, not per frame, so that quiet
    # speech endings are not mistaken for silence.
    if peak <= 0 or peak < 10.0 ** (silence_floor_db / 20.0):
        return []

    threshold = peak * (10.0 ** (-top_db / 20.0))
    voiced = bridge_short_gaps(rms > threshold,
                               max(1, int(min_silence_s * sr / frame)))

    segments: list[np.ndarray] = []
    max_len = int(max_len_s * sr)
    min_speech = int(min_speech_s * sr)
    pad = int(pad_s * sr)

    def flush(first_frame: int, last_frame: int) -> None:
        # Pad outward so word onsets and decays aren't clipped off.
        begin = max(0, first_frame * frame - pad)
        end = min(len(audio), last_frame * frame + pad)
        segments.extend(_emit(audio, begin, end, max_len, min_speech))

    start: int | None = None
    for i, is_voiced in enumerate(voiced):
        if is_voiced and start is None:
            start = i
        elif not is_voiced and start is not None:
            flush(start, i)
            start = None
    if start is not None:
        flush(start, voiced.size)
    return segments


def _emit(audio: np.ndarray, begin: int, end: int, max_len: int,
          min_speech: int) -> list[np.ndarray]:
    """Slice [begin, end) into <=max_len pieces, dropping too-short ones."""
    out = []
    for s in range(begin, end, max_len):
        piece = audio[s:min(s + max_len, end)]
        if len(piece) >= min_speech:
            out.append(piece)
    return out


def clipping_ratio(seg: np.ndarray) -> float:
    """Fraction of samples at/over full scale — a proxy for recording clipping."""
    if seg.size == 0:
        return 0.0
    return float(np.mean(np.abs(seg) >= 0.999))


def normalise(seg: np.ndarray, target_peak: float = 0.95) -> np.ndarray:
    peak = float(np.max(np.abs(seg))) if seg.size else 0.0
    if peak <= 0:
        return seg
    return (seg * (target_peak / peak)).astype(np.float32)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", required=True, type=Path,
                    help="folder of raw recordings (searched recursively)")
    ap.add_argument("--output", required=True, type=Path,
                    help="destination folder for prepared clips")
    ap.add_argument("--sr", type=int, default=DEFAULT_SR,
                    help=f"target sample rate (default {DEFAULT_SR}; RVC v2 uses 40k/48k)")
    ap.add_argument("--max-len", type=float, default=10.0,
                    help="max clip length in seconds (default 10)")
    ap.add_argument("--min-len", type=float, default=1.0,
                    help="drop speech segments shorter than this (default 1.0 s)")
    ap.add_argument("--top-db", type=float, default=35.0,
                    help="silence threshold in dB below the clip peak (default 35)")
    ap.add_argument("--min-silence", type=float, default=0.35,
                    help="a pause must last this long (s) to split an utterance "
                         "(default 0.35; raise it if clips come out chopped)")
    ap.add_argument("--pad", type=float, default=0.1,
                    help="seconds of context kept around each segment (default 0.1)")
    ap.add_argument("--overwrite", action="store_true",
                    help="clear the output folder first")
    args = ap.parse_args()

    if shutil.which("ffmpeg") is None:
        print("ERROR: ffmpeg not found on PATH. Install it: brew install ffmpeg",
              file=sys.stderr)
        return 2

    if not args.input.is_dir():
        print(f"ERROR: input folder not found: {args.input}", file=sys.stderr)
        return 2

    files = sorted(p for p in args.input.rglob("*")
                   if p.is_file() and p.suffix.lower() in AUDIO_SUFFIXES)
    if not files:
        print(f"ERROR: no audio files under {args.input}", file=sys.stderr)
        return 2

    if args.overwrite and args.output.exists():
        shutil.rmtree(args.output)
    args.output.mkdir(parents=True, exist_ok=True)

    total_in = 0.0
    kept_s = 0.0
    written = 0
    dropped_clipped = 0
    manifest = []

    for path in files:
        try:
            audio = decode_to_mono(path, args.sr)
        except RuntimeError as exc:
            print(f"  ! skipping {path.name}: {exc}")
            continue

        total_in += len(audio) / args.sr
        segments = split_on_silence(audio, args.sr, top_db=args.top_db,
                                    min_speech_s=args.min_len,
                                    max_len_s=args.max_len,
                                    min_silence_s=args.min_silence,
                                    pad_s=args.pad)
        for seg in segments:
            if clipping_ratio(seg) > 0.01:      # >1% samples pinned = distorted
                dropped_clipped += 1
                continue
            name = f"{written:05d}.wav"
            sf.write(args.output / name, normalise(seg), args.sr, subtype="PCM_16")
            manifest.append({"file": name,
                             "seconds": round(len(seg) / args.sr, 3),
                             "source": path.name})
            kept_s += len(seg) / args.sr
            written += 1
        print(f"  {path.name}: {len(segments)} segment(s)")

    (args.output / "manifest.json").write_text(
        json.dumps({"sample_rate": args.sr,
                    "clips": written,
                    "speech_seconds": round(kept_s, 1),
                    "items": manifest}, indent=2))

    minutes = kept_s / 60.0
    retention = (kept_s / total_in * 100.0) if total_in > 0 else 0.0
    avg_clip = (kept_s / written) if written else 0.0
    print("\n" + "=" * 58)
    print(f"Input audio      : {total_in / 60:.1f} min across {len(files)} file(s)")
    print(f"Usable speech    : {minutes:.1f} min in {written} clip(s) "
          f"({retention:.0f}% kept, avg {avg_clip:.1f}s)")
    if dropped_clipped:
        print(f"Dropped (clipped): {dropped_clipped} segment(s)")
    print(f"Output folder    : {args.output}")
    print("=" * 58)

    # Continuous speech should yield multi-second clips. Short ones mean the
    # splitter is cutting mid-utterance, which silently throws speech away.
    if written and (avg_clip < 2.0 or retention < 50.0):
        print("NOTE: clips are short / much audio was dropped — the recording is")
        print("      likely being split mid-sentence. Retry with a longer pause")
        print("      threshold, e.g. --min-silence 0.6 (and --min-len 0.7).")

    # The verdict — the reason this script exists.
    if minutes < 1:
        print("VERDICT: NOT ENOUGH. Under 1 minute cannot train a usable voice.")
        print("         Record more clean speech (aim for 10+ minutes).")
        return 1
    if minutes < 5:
        print("VERDICT: TOO LITTLE. Expect a poor, unstable clone.")
        print("         Aim for 10+ minutes; 20-30 min is comfortable.")
        return 1
    if minutes < 10:
        print("VERDICT: MARGINAL. Trainable, but quality will be limited.")
        print("         More audio is the cheapest quality win available.")
        return 0
    print("VERDICT: GOOD. Enough material to train a solid model.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
