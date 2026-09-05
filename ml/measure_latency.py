#!/usr/bin/env python3
"""Measure real-time voice-conversion latency end to end.

You record ONE file with two channels:

    channel 1 (left)  = your dry microphone
    channel 2 (right) = the converted output (e.g. BlackHole)

The same speech appears in both, the converted one delayed by whatever the
converter costs. This tool reports that delay.

It correlates the ENERGY ENVELOPES, not the waveforms: voice conversion
resynthesises the audio, so the waveforms barely correlate at all (measured
r = -0.2 on a real pair), while the envelope — when you were loud and when you
were quiet — survives conversion intact.

Usage:
    python measure_latency.py recording.wav              # 2-channel file
    python measure_latency.py dry.wav converted.wav      # two mono files

Requires: pip install numpy soundfile scipy
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

ENV_RATE = 1000          # envelope sample rate (Hz) → 1 ms resolution
MAX_LAG_MS = 2000        # search window; beyond this it is not "real time"


def envelope(x: np.ndarray, sr: int, env_rate: int = ENV_RATE) -> np.ndarray:
    """Short-time RMS energy envelope, resampled to `env_rate` Hz."""
    hop = max(1, int(round(sr / env_rate)))
    win = hop * 4                                   # overlapping analysis
    n = 1 + max(0, (len(x) - win) // hop)
    if n <= 0:
        return np.zeros(0)
    idx = np.arange(n) * hop
    env = np.empty(n)
    for i, s in enumerate(idx):
        seg = x[s:s + win]
        env[i] = np.sqrt(np.mean(seg.astype(np.float64) ** 2)) if seg.size else 0.0
    return env


def normalise(e: np.ndarray) -> np.ndarray:
    """Zero-mean, unit-variance; log-compressed so loud parts don't dominate."""
    e = np.log1p(e / (np.median(e[e > 0]) + 1e-12)) if np.any(e > 0) else e
    e = e - e.mean()
    s = e.std()
    return e / s if s > 0 else e


def best_lag(dry: np.ndarray, wet: np.ndarray, env_rate: int,
             max_lag_ms: int) -> tuple[float, float]:
    """Return (lag_ms, correlation) for wet lagging behind dry."""
    a, b = normalise(dry), normalise(wet)
    n = max(len(a), len(b))
    size = 1 << int(np.ceil(np.log2(2 * n)))
    A = np.fft.rfft(a, size)
    B = np.fft.rfft(b, size)
    cc = np.fft.irfft(B * np.conj(A), size) / (len(a) * len(b)) ** 0.5

    max_lag = int(max_lag_ms * env_rate / 1000)
    pos = cc[:max_lag + 1]                    # wet delayed relative to dry
    k = int(np.argmax(pos))
    # Parabolic interpolation for sub-sample (sub-millisecond) precision.
    if 0 < k < len(pos) - 1:
        y0, y1, y2 = pos[k - 1], pos[k], pos[k + 1]
        denom = y0 - 2 * y1 + y2
        offset = 0.5 * (y0 - y2) / denom if denom != 0 else 0.0
    else:
        offset = 0.0
    lag_ms = (k + offset) * 1000.0 / env_rate
    return lag_ms, float(pos[k])


def verdict(ms: float) -> str:
    if ms < 250:
        return ("VIABLE. Natural conversation should feel fine. "
                "Worth investing in a better model.")
    if ms < 500:
        return ("MARGINAL. Usable for talks/monologue; expect people to talk "
                "over you in fast discussion.")
    return ("TOO SLOW for live conversation on this machine. Reduce quality "
            "for speed, or keep RVC for recorded audio only.")


def load_channels(paths: list[Path]) -> tuple[np.ndarray, np.ndarray, int]:
    if len(paths) == 1:
        data, sr = sf.read(paths[0], always_2d=True)
        if data.shape[1] < 2:
            raise SystemExit("ERROR: single file must have 2 channels "
                             "(ch1 = dry mic, ch2 = converted).")
        return data[:, 0], data[:, 1], sr
    d, sr1 = sf.read(paths[0], always_2d=True)
    w, sr2 = sf.read(paths[1], always_2d=True)
    if sr1 != sr2:
        raise SystemExit(f"ERROR: sample rates differ ({sr1} vs {sr2}).")
    return d.mean(axis=1), w.mean(axis=1), sr1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+", type=Path,
                    help="one 2-channel recording, or dry.wav then converted.wav")
    ap.add_argument("--max-lag", type=int, default=MAX_LAG_MS,
                    help=f"maximum delay to search, ms (default {MAX_LAG_MS})")
    args = ap.parse_args()

    for p in args.files:
        if not p.is_file():
            raise SystemExit(f"ERROR: no such file: {p}")

    dry, wet, sr = load_channels(args.files)
    dur = len(dry) / sr
    if dur < 3:
        print("WARNING: recording is very short; 10-20 s of speech is better.",
              file=sys.stderr)

    ed, ew = envelope(dry, sr), envelope(wet, sr)
    if ed.size == 0 or ew.size == 0:
        raise SystemExit("ERROR: recording too short to analyse.")

    # A channel that never gets loud means the routing is wrong.
    for name, ch in (("dry mic", dry), ("converted", wet)):
        if np.sqrt(np.mean(ch.astype(np.float64) ** 2)) < 1e-4:
            raise SystemExit(f"ERROR: the '{name}' channel is silent — check "
                             "which device is recorded into which channel.")

    lag_ms, corr = best_lag(ed, ew, ENV_RATE, args.max_lag)

    print("=" * 58)
    print(f"Recording        : {dur:.1f} s @ {sr} Hz")
    print(f"Envelope match   : {corr:.3f}   (1.0 = perfect; < 0.3 = unreliable)")
    print(f"MEASURED LATENCY : {lag_ms:.0f} ms")
    print("=" * 58)

    if corr < 0.3:
        print("Low confidence. The two channels don't line up well. Usually:")
        print("  - the converted channel isn't actually the converted audio,")
        print("  - you spoke too little (record 10-20 s of continuous speech),")
        print("  - or the delay exceeds --max-lag.")
        return 1

    print(f"VERDICT: {verdict(lag_ms)}")
    print()
    print("Note: this is the local processing delay only. A meeting adds")
    print("100-200 ms of network delay on top, and conversation starts to feel")
    print("awkward past roughly 300 ms total.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
