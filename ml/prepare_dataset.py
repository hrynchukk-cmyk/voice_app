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


def split_on_silence(audio: np.ndarray, sr: int, *, top_db: float,
                     min_speech_s: float, max_len_s: float,
                     noise_floor_db: float = -50.0) -> list[np.ndarray]:
    """Split into speech segments separated by silence.

    The threshold is relative to the clip's own loudness (top_db below the peak
    frame) so it adapts to quiet and loud recordings — but it is also floored at
    an absolute level, otherwise a silent recording's own noise sits above its
    own relative threshold and the whole file is mistaken for speech.
    """
    frame = max(1, sr // 100)                      # 10 ms analysis frames
    rms = frame_rms(audio, frame)
    if rms.size == 0:
        return []

    peak = float(rms.max())
    if peak <= 0:
        return []
    absolute_floor = 10.0 ** (noise_floor_db / 20.0)
    threshold = max(peak * (10.0 ** (-top_db / 20.0)), absolute_floor)
    voiced = rms > threshold

    segments: list[np.ndarray] = []
    max_len = int(max_len_s * sr)
    min_speech = int(min_speech_s * sr)

    start: int | None = None
    for i, is_voiced in enumerate(voiced):
        if is_voiced and start is None:
            start = i
        elif not is_voiced and start is not None:
            segments.extend(
                _emit(audio, start * frame, i * frame, max_len, min_speech))
            start = None
    if start is not None:
        segments.extend(
            _emit(audio, start * frame, len(voiced) * frame, max_len, min_speech))
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
    ap.add_argument("--noise-floor-db", type=float, default=-50.0,
                    help="absolute dBFS floor below which audio is never speech "
                         "(default -50; guards against all-silence files)")
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
                                    noise_floor_db=args.noise_floor_db)
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
    print("\n" + "=" * 58)
    print(f"Input audio      : {total_in / 60:.1f} min across {len(files)} file(s)")
    print(f"Usable speech    : {minutes:.1f} min in {written} clip(s)")
    if dropped_clipped:
        print(f"Dropped (clipped): {dropped_clipped} segment(s)")
    print(f"Output folder    : {args.output}")
    print("=" * 58)

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
