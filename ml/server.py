#!/usr/bin/env python3
"""VoiceBridge local conversion backend — STUB (Track A prototype).

This is a reference skeleton for the real-time voice-conversion server that the
macOS app supervises as a child process. It:

  * binds to a LOCAL Unix domain socket only (never the network),
  * speaks the simple length-prefixed float32 protocol described in README.md,
  * currently passes audio through unchanged (identity), so you can validate the
    transport before dropping in a real model.

Replace `Converter.convert()` with actual inference (ONNX Runtime / PyTorch).
Do NOT add any outbound network calls here — the whole point is local-only.
"""
from __future__ import annotations

import argparse
import os
import socket
import struct
import sys

MAGIC = b"VBRG"          # frame magic
HEADER = struct.Struct("<4sI")   # magic + float count


class Converter:
    """Wraps the voice-conversion model. Stub = identity passthrough."""

    def __init__(self, model_path: str):
        self.model_path = model_path
        # TODO: load your model here, e.g.
        #   import onnxruntime as ort
        #   self.session = ort.InferenceSession(
        #       model_path, providers=["CoreMLExecutionProvider", "CPUExecutionProvider"])
        # Keep any lookahead/state small for low latency.

    def convert(self, samples: bytes) -> bytes:
        """samples: little-endian float32 PCM (mono). Returns same length."""
        # TODO: run inference. For now, identity passthrough so the app can
        # verify the full pipeline end-to-end before a model exists.
        return samples


def recv_exactly(conn: socket.socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("backend peer closed")
        buf.extend(chunk)
    return bytes(buf)


def serve(socket_path: str, model_path: str) -> None:
    if os.path.exists(socket_path):
        os.unlink(socket_path)

    converter = Converter(model_path)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(socket_path)
    server.listen(1)

    # Handshake: the app waits for this line on stdout before sending audio.
    print("READY", flush=True)

    conn, _ = server.accept()
    try:
        while True:
            header = recv_exactly(conn, HEADER.size)
            magic, count = HEADER.unpack(header)
            if magic != MAGIC:
                raise ValueError("bad frame magic")
            payload = recv_exactly(conn, count * 4)   # float32
            out = converter.convert(payload)
            conn.sendall(HEADER.pack(MAGIC, count) + out)
    except (ConnectionError, ValueError) as exc:
        print(f"backend stopping: {exc}", file=sys.stderr, flush=True)
    finally:
        conn.close()
        server.close()
        if os.path.exists(socket_path):
            os.unlink(socket_path)


def main() -> None:
    parser = argparse.ArgumentParser(description="VoiceBridge local conversion backend (stub)")
    parser.add_argument("--model", required=True, help="path to the local, authorized model")
    parser.add_argument("--socket", required=True, help="Unix domain socket path (local only)")
    args = parser.parse_args()
    serve(args.socket, args.model)


if __name__ == "__main__":
    main()
