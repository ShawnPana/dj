#!/usr/bin/env python3
"""
Stem separation server — keeps Demucs model hot in MPS memory,
processes audio in chunks for near-instant first playback.
"""

import json
import os
import threading
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

import subprocess
import tempfile

import torch
import torchaudio
import soundfile as sf
import numpy as np

from demucs.pretrained import get_model
from demucs.apply import apply_model


def load_audio(path):
    """Load audio, using ffmpeg as fallback for formats soundfile can't handle (m4a, etc.)."""
    try:
        wav, sr = torchaudio.load(path)
        return wav, sr
    except Exception:
        # Fallback: convert to wav via ffmpeg
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            tmp_path = tmp.name
        try:
            subprocess.run(
                ["ffmpeg", "-y", "-i", path, "-ar", str(SAMPLE_RATE), "-ac", "2", tmp_path],
                capture_output=True, check=True,
            )
            wav, sr = torchaudio.load(tmp_path)
            return wav, sr
        finally:
            os.unlink(tmp_path)

# --- Global state ---
model = None
device = None
current_job = None
job_lock = threading.Lock()

STEM_NAMES = ["drums", "bass", "other", "vocals"]
DEFAULT_CHUNK_SECONDS = 10
SAMPLE_RATE = 44100


def load_model():
    global model, device
    print("Loading htdemucs model...")
    bag = get_model("htdemucs")
    model = bag.models[0]

    if torch.backends.mps.is_available():
        device = "mps"
    elif torch.cuda.is_available():
        device = "cuda"
    else:
        device = "cpu"

    model.to(device)
    model.eval()
    print(f"Model loaded on {device}")


class Job:
    def __init__(self, input_path, output_dir, chunk_seconds):
        self.input_path = input_path
        self.output_dir = Path(output_dir)
        self.chunk_seconds = chunk_seconds
        self.chunks_total = 0
        self.chunks_done = 0
        self.status = "loading"  # loading, processing, concatenating, done, error
        self.error = None
        self.duration = 0.0

    def to_dict(self):
        return {
            "status": self.status,
            "chunks_done": self.chunks_done,
            "chunks_total": self.chunks_total,
            "duration": self.duration,
            "error": self.error,
        }


def process_job(job):
    global current_job
    try:
        # Load audio
        wav, sr = load_audio(job.input_path)

        # Resample if needed
        if sr != SAMPLE_RATE:
            wav = torchaudio.functional.resample(wav, sr, SAMPLE_RATE)
            sr = SAMPLE_RATE

        # Ensure stereo
        if wav.shape[0] == 1:
            wav = wav.repeat(2, 1)
        elif wav.shape[0] > 2:
            wav = wav[:2]

        total_samples = wav.shape[1]
        job.duration = total_samples / sr
        chunk_samples = job.chunk_seconds * sr

        # Calculate chunks
        chunks = []
        start = 0
        while start < total_samples:
            end = min(start + chunk_samples, total_samples)
            chunks.append((start, end))
            start = end

        job.chunks_total = len(chunks)
        job.status = "processing"

        # Create output dirs
        chunks_dir = job.output_dir / "chunks"
        chunks_dir.mkdir(parents=True, exist_ok=True)

        # Process each chunk
        for i, (start, end) in enumerate(chunks):
            chunk_audio = wav[:, start:end].unsqueeze(0)  # (1, channels, samples)

            with torch.no_grad():
                sources = apply_model(model, chunk_audio.to(device), device=device)

            # sources: (1, 4, channels, samples)
            sources = sources.squeeze(0).cpu().numpy()

            # Write each stem chunk
            for stem_idx, stem_name in enumerate(STEM_NAMES):
                stem_audio = sources[stem_idx]  # (channels, samples)
                out_path = chunks_dir / f"{stem_name}_{i:03d}.wav"
                sf.write(str(out_path), stem_audio.T, sr)

            job.chunks_done = i + 1

        # Auto-concatenate
        job.status = "concatenating"
        concatenate_chunks(job)

        job.status = "done"

    except Exception as e:
        job.status = "error"
        job.error = str(e)
        import traceback
        traceback.print_exc()


def concatenate_chunks(job):
    chunks_dir = job.output_dir / "chunks"

    for stem_name in STEM_NAMES:
        # Gather all chunk files in order
        chunk_files = sorted(chunks_dir.glob(f"{stem_name}_*.wav"))
        if not chunk_files:
            continue

        # Read and concatenate
        all_audio = []
        for cf in chunk_files:
            data, sr = sf.read(str(cf))
            all_audio.append(data)

        combined = np.concatenate(all_audio, axis=0)
        out_path = job.output_dir / f"{stem_name}.wav"
        sf.write(str(out_path), combined, sr)

    # Write metadata
    metadata = {
        "input_path": str(job.input_path),
        "model": "htdemucs",
        "device": device,
        "duration": job.duration,
        "stems": STEM_NAMES,
        "sample_rate": SAMPLE_RATE,
        "timestamp": time.time(),
    }
    with open(job.output_dir / "metadata.json", "w") as f:
        json.dump(metadata, f, indent=2)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Quieter logging
        pass

    def send_json(self, data, status=200):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def read_json(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        return json.loads(body) if body else {}

    def do_GET(self):
        if self.path == "/health":
            self.send_json({"status": "ok", "device": device, "model": "htdemucs"})

        elif self.path == "/status":
            with job_lock:
                if current_job:
                    self.send_json(current_job.to_dict())
                else:
                    self.send_json({"status": "idle"})

        else:
            self.send_json({"error": "not found"}, 404)

    def do_POST(self):
        global current_job

        if self.path == "/separate":
            data = self.read_json()
            input_path = data.get("input_path")
            output_dir = data.get("output_dir")
            chunk_seconds = data.get("chunk_seconds", DEFAULT_CHUNK_SECONDS)

            if not input_path or not output_dir:
                self.send_json({"error": "input_path and output_dir required"}, 400)
                return

            if not os.path.exists(input_path):
                self.send_json({"error": f"file not found: {input_path}"}, 400)
                return

            with job_lock:
                job = Job(input_path, output_dir, chunk_seconds)
                current_job = job

            # Run in background thread
            thread = threading.Thread(target=process_job, args=(job,), daemon=True)
            thread.start()

            self.send_json({"status": "started", "chunks_seconds": chunk_seconds})

        else:
            self.send_json({"error": "not found"}, 404)


def main():
    load_model()

    port = int(os.environ.get("STEM_SERVER_PORT", "8089"))
    server = HTTPServer(("127.0.0.1", port), Handler)
    print(f"Stem server listening on http://127.0.0.1:{port}")
    print(f"  GET  /health  — check server status")
    print(f"  POST /separate — start stem separation")
    print(f"  GET  /status  — check job progress")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.server_close()


if __name__ == "__main__":
    main()
