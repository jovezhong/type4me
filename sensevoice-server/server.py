#!/usr/bin/env python3
"""SenseVoice streaming ASR WebSocket server for Type4Me."""

import argparse
import asyncio
import json
import struct
import sys
import socket
from pathlib import Path

import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from sensevoice_model import load_model, StreamingSenseVoice

app = FastAPI()

# Global model (loaded once at startup)
_model: StreamingSenseVoice | None = None


def get_model():
    assert _model is not None, "Model not loaded"
    return _model


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await ws.accept()
    model = get_model()

    # Reset model state for new session
    model.reset()

    # Accumulate all audio for two-pass recognition
    all_samples: list[int] = []
    # Rolling re-scan: track when last full inference ran
    last_rescan_at = 0  # sample count at last rescan
    rescan_interval = 48000  # rescan every ~3 seconds of new audio (16kHz * 3)
    min_rescan_samples = 16000  # need at least 1s of audio before first rescan

    try:
        while True:
            data = await ws.receive_bytes()

            if len(data) == 0:
                # Empty frame = end of audio signal
                # Final full inference on complete audio
                if all_samples:
                    final_text = model.full_inference(all_samples)
                    if final_text:
                        await ws.send_json({
                            "type": "transcript",
                            "text": final_text,
                            "is_final": True,
                        })
                else:
                    for result in model.streaming_inference([], is_last=True):
                        await ws.send_json({
                            "type": "transcript",
                            "text": result.get("text", ""),
                            "is_final": True,
                        })
                await ws.send_json({"type": "completed"})
                break

            # Convert PCM16 little-endian bytes to int16-range float list
            sample_count = len(data) // 2
            samples = list(struct.unpack(f"<{sample_count}h", data))
            all_samples.extend(samples)

            # Run streaming inference (fast partial results)
            for result in model.streaming_inference(samples, is_last=False):
                text = result.get("text", "")
                if text:
                    await ws.send_json({
                        "type": "transcript",
                        "text": text,
                        "is_final": False,
                    })

            # Rolling re-scan: periodically run full_inference on all audio so far
            # to correct earlier predictions with expanded context
            samples_since_rescan = len(all_samples) - last_rescan_at
            if (len(all_samples) >= min_rescan_samples
                    and samples_since_rescan >= rescan_interval):
                corrected = await asyncio.get_event_loop().run_in_executor(
                    None, model.full_inference, all_samples
                )
                last_rescan_at = len(all_samples)
                if corrected:
                    await ws.send_json({
                        "type": "transcript",
                        "text": corrected,
                        "is_final": False,
                    })

    except WebSocketDisconnect:
        pass
    except Exception as e:
        try:
            await ws.send_json({"type": "error", "message": str(e)})
        except:
            pass


@app.get("/health")
async def health():
    return {"status": "ok", "model_loaded": _model is not None}


def find_free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def main():
    parser = argparse.ArgumentParser(description="SenseVoice ASR Server")
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--port", type=int, default=0, help="0 = auto-assign")
    parser.add_argument("--hotwords-file", default="")
    parser.add_argument("--beam-size", type=int, default=3)
    parser.add_argument("--context-score", type=float, default=6.0)
    parser.add_argument("--device", default="auto", help="auto, cpu, or mps")
    parser.add_argument("--language", default="auto", help="auto, zh, en, ja, ko, yue")
    parser.add_argument("--textnorm", action="store_true", default=True, help="Enable ITN (punctuation + number formatting)")
    parser.add_argument("--no-textnorm", dest="textnorm", action="store_false")
    parser.add_argument("--padding", type=int, default=8, help="Encoder context padding frames (higher = more accurate, slower)")
    parser.add_argument("--chunk-size", type=int, default=8, help="Encoder chunk size in LFR frames (~60ms each)")
    args = parser.parse_args()

    global _model

    # Load hotwords from file
    hotwords = None
    if args.hotwords_file and Path(args.hotwords_file).exists():
        lines = Path(args.hotwords_file).read_text().strip().splitlines()
        hotwords = [l.strip() for l in lines if l.strip()]
        if hotwords:
            print(f"Loaded {len(hotwords)} hotwords", flush=True)

    # Load model
    print(f"Loading model from {args.model_dir}...", flush=True)
    _model = load_model(
        model_dir=args.model_dir,
        contexts=hotwords,
        beam_size=args.beam_size,
        context_score=args.context_score,
        device=args.device,
        language=args.language,
        textnorm=args.textnorm,
        padding=args.padding,
        chunk_size=args.chunk_size,
    )
    print("Model loaded.", flush=True)

    # Find port
    port = args.port if args.port != 0 else find_free_port()

    # Print PORT line so Swift process can discover it
    print(f"PORT:{port}", flush=True)

    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")


if __name__ == "__main__":
    main()
