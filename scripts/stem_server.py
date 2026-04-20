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
beat_model = None
device = None
current_job = None
job_lock = threading.Lock()
beat_lock = threading.Lock()

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


def load_beat_model():
    """Lazy-load beat_this — only first /analyze call pays the cost."""
    global beat_model
    if beat_model is not None:
        return beat_model
    from beat_this.inference import Audio2Beats
    print("Loading beat_this model...")
    beat_model = Audio2Beats(checkpoint_path="final0", device=device, dbn=False)
    print(f"beat_this loaded on {device}")
    return beat_model


def analyze_beats(input_path, cache_dir, drums_path=None):
    """Fluid Beatgrid approach: find the strong downbeats (top by onset strength),
    snap them to real transients, then interpolate 4 equal beats within each bar
    (4/4 assumption). Tempo can drift bar-by-bar; each bar is its own tempo section."""
    cache_path = Path(cache_dir) / "beats.json"
    want_source = "drums" if drums_path and os.path.exists(drums_path) else "mix"

    if cache_path.exists():
        with open(cache_path) as f:
            cached = json.load(f)
        if cached.get("beats") and cached.get("fluid"):
            cached_source = cached.get("source", "mix")
            if cached_source == want_source or cached_source == "drums":
                return cached

    audio_path = drums_path if want_source == "drums" else input_path
    a2b = load_beat_model()

    wav, sr = load_audio(audio_path)
    mono = wav.mean(dim=0).contiguous().to(torch.float32).numpy() if wav.shape[0] > 1 else wav.squeeze(0).to(torch.float32).numpy()

    with beat_lock:
        _, downbeats_arr = a2b(mono, int(sr))

    raw_downbeats = sorted(float(b) for b in downbeats_arr)
    beats, downbeats = _fluid_grid_from_downbeats(raw_downbeats, mono, int(sr))

    # BPM for display only (median inter-beat interval).
    bpm = 0.0
    if len(beats) >= 2:
        import numpy as np
        diffs = np.diff(np.asarray(beats))
        median = float(np.median(diffs))
        if median > 0:
            bpm = round(60.0 / median, 2)

    result = {
        "bpm": bpm,
        "beats": beats,
        "downbeats": downbeats,
        "source": want_source,
        "fluid": True,
    }

    Path(cache_dir).mkdir(parents=True, exist_ok=True)
    with open(cache_path, "w") as f:
        json.dump(result, f)

    return result


def _fluid_grid_from_downbeats(raw_downbeats, signal, sr):
    """
    1. Rank beat_this's downbeats by local onset strength; keep the strongest.
    2. Snap each kept downbeat to its nearest real transient onset (±80ms).
    3. Between consecutive strong downbeats, divide the span into N×4 equal beats
       where N = round(span / median_bar). Tempo floats bar-by-bar.
    4. Extrapolate backward from the first anchor (using the first observed bar
       length) and forward from the last anchor (using the last) so intros/outros
       and breakdowns don't leave dead zones.
    """
    if len(raw_downbeats) < 3:
        return raw_downbeats, raw_downbeats

    try:
        import librosa
        import numpy as np
    except ImportError:
        return raw_downbeats, raw_downbeats

    duration = len(signal) / sr
    hop = 256
    onset_env = librosa.onset.onset_strength(y=signal, sr=sr, hop_length=hop)
    onsets = _detect_onsets(signal, sr)

    win = max(1, int(0.06 * sr / hop))
    strengths = []
    for t in raw_downbeats:
        frame = int(t * sr / hop)
        lo = max(0, frame - win)
        hi = min(len(onset_env), frame + win + 1)
        strengths.append(float(onset_env[lo:hi].max()) if lo < hi else 0.0)

    keep_n = max(4, int(len(raw_downbeats) * 0.7))
    order_by_strength = sorted(range(len(raw_downbeats)), key=lambda i: strengths[i], reverse=True)
    keep = set(order_by_strength[:keep_n])
    strong = [raw_downbeats[i] for i in sorted(keep)]
    strong = _snap_list_to_onsets(strong, onsets, window=0.08)
    strong.sort()

    if len(strong) < 2:
        return strong, strong

    gaps = np.diff(np.asarray(strong))
    median_bar = float(np.median(gaps))
    if median_bar <= 0:
        return strong, strong

    beats = []
    downbeats = []

    # 1. Extrapolate backward from strong[0] using the first observed bar length.
    first_bar = max(strong[1] - strong[0], median_bar * 0.5)
    bar_start = strong[0] - first_bar
    back = []
    while bar_start + first_bar > 0:
        for k in range(4):
            t = bar_start + k * first_bar / 4
            if 0 <= t < strong[0]:
                back.append((t, k == 0))
        bar_start -= first_bar
    for t, is_down in sorted(back):
        beats.append(t)
        if is_down: downbeats.append(t)

    # 2. Fill between consecutive strong anchors (handles breakdown gaps via n_bars).
    for i, db in enumerate(strong):
        if i + 1 < len(strong):
            span = strong[i + 1] - db
            n_bars = max(1, round(span / median_bar))
            subdiv = 4 * n_bars
            for k in range(subdiv):
                t = db + k * span / subdiv
                beats.append(t)
                if k % 4 == 0:
                    downbeats.append(t)
        else:
            beats.append(db)
            downbeats.append(db)

    # 3. Extrapolate forward from strong[-1] using the last observed bar length.
    last_bar = max(strong[-1] - strong[-2], median_bar * 0.5)
    bar_start = strong[-1] + last_bar
    while bar_start < duration:
        for k in range(4):
            t = bar_start + k * last_bar / 4
            if t <= duration and t > strong[-1]:
                beats.append(t)
                if k == 0:
                    downbeats.append(t)
        bar_start += last_bar

    beats.sort()
    downbeats.sort()
    return beats, downbeats


def _detect_onsets(signal, sr):
    """Transient onset times (seconds) via librosa. Uses backtrack=True so positions
    land on the start of the attack, not the peak."""
    try:
        import librosa
    except ImportError:
        return []
    try:
        onset_env = librosa.onset.onset_strength(y=signal, sr=sr, hop_length=256)
        onset_frames = librosa.onset.onset_detect(
            onset_envelope=onset_env, sr=sr, hop_length=256,
            backtrack=True, units="frames",
        )
        return sorted(float(t) for t in librosa.frames_to_time(onset_frames, sr=sr, hop_length=256))
    except Exception:
        return []


def _snap_list_to_onsets(times, onsets, window=0.06):
    """For each time, return nearest onset within window. If none, keep original."""
    if not onsets or not times:
        return times
    import bisect
    out = []
    for t in times:
        idx = bisect.bisect_left(onsets, t)
        best = t
        best_d = window
        for j in (idx - 1, idx):
            if 0 <= j < len(onsets):
                d = abs(onsets[j] - t)
                if d <= best_d:
                    best_d = d
                    best = onsets[j]
        out.append(best)
    return out


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

        elif self.path == "/analyze":
            data = self.read_json()
            input_path = data.get("input_path")
            cache_dir = data.get("cache_dir")
            drums_path = data.get("drums_path")

            if not input_path or not cache_dir:
                self.send_json({"error": "input_path and cache_dir required"}, 400)
                return
            if not os.path.exists(input_path):
                self.send_json({"error": f"file not found: {input_path}"}, 400)
                return

            try:
                result = analyze_beats(input_path, cache_dir, drums_path=drums_path)
                self.send_json(result)
            except Exception as e:
                import traceback
                traceback.print_exc()
                self.send_json({"error": str(e)}, 500)

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
