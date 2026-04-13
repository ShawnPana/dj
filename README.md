# dj

A native macOS app for real-time audio stem separation. Drop in any audio file and isolate drums, bass, vocals, and other instruments — powered by Meta's [Demucs](https://github.com/facebookresearch/demucs) model running on Apple Silicon GPU (MPS).

## How It Works

The app has two components:

1. **Swift/SwiftUI frontend** — native macOS app with waveform visualization, transport controls, and per-stem volume/mute/solo
2. **Python stem server** — a local HTTP server that loads the Demucs ML model into GPU memory once and processes audio in chunks

When you drop a track:
- The **original audio loads instantly** — you can play immediately
- Stem separation runs **in the background** on your GPU (~47s for a 7.5min track)
- Stem controls become active as chunks arrive (~3s for the first 10 seconds)
- When nothing is tweaked, the original track plays at full quality
- When you mute/solo/adjust a stem, it seamlessly switches to stem playback
- Stems are **cached** to `~/Music/dj/cache/` so repeat loads are instant

## Requirements

- **macOS 14+** (Sonoma or later)
- **Apple Silicon Mac** (M1/M2/M3/M4) — required for MPS GPU acceleration
- **Xcode** with Swift 6.0+ (for building)
- **Python 3.12** with the following packages:
  - PyTorch 2.6+
  - torchaudio 2.6+
  - Demucs 4.0+
  - soundfile
- **FFmpeg** (for audio format conversion)

## Setup

### 1. Install Python dependencies

If you don't have Python 3.12 installed, get it from [python.org](https://www.python.org/downloads/).

```bash
# Install PyTorch (if not already installed)
pip3 install torch torchaudio

# Install Demucs and soundfile
pip3 install demucs soundfile
```

### 2. Install FFmpeg

```bash
brew install ffmpeg
```

### 3. Verify your Python path

The app expects Python at `/Library/Frameworks/Python.framework/Versions/3.12/bin/python3`. If yours is elsewhere, update the path in `dj/djApp.swift` (the `startStemServer` function).

You can check your Python path with:
```bash
which python3
```

### 4. Clone and build

```bash
git clone https://github.com/ShawnPana/dj.git
cd dj
swift build
```

### 5. Run

```bash
swift run dj
```

On first run, Demucs will download the `htdemucs` model (~80MB). This only happens once.

## Usage

1. **Drop an audio file** onto the window (supports mp3, wav, m4a, flac, aiff) or click "Browse..."
2. **Play** the track — it loads instantly from the original file
3. **Wait a few seconds** for stem separation to begin (orange progress indicator in header)
4. **Mute/Solo/Adjust** individual stems:
   - **M** button — mute a stem
   - **S** button — solo a stem (only hear that stem)
   - **Slider** — adjust stem volume
5. The **overview waveform** reflects what you're hearing:
   - White waveform when playing the original
   - Colored stem layers when stems are active (red=drums, blue=bass, green=vocals, orange=other)
6. **Export** stems as WAV files once processing is complete

### Keyboard shortcuts

- **Space** — play/pause

## Architecture

```
┌─────────────────────────────────────┐
│         SwiftUI App (dj)            │
│                                     │
│  ┌───────────┐  ┌────────────────┐  │
│  │ Drop Zone │  │ Waveform View  │  │
│  └─────┬─────┘  └────────────────┘  │
│        │                             │
│  ┌─────▼─────────────────────────┐  │
│  │    AVAudioEngine              │  │
│  │  ┌──────────┐ ┌────────────┐  │  │
│  │  │ Original │ │ 4x Stem    │  │  │
│  │  │ Player   │ │ Players    │  │  │
│  │  └──────────┘ └────────────┘  │  │
│  └───────────────────────────────┘  │
│        │                             │
│  ┌─────▼─────────────────────────┐  │
│  │  StemSeparator (HTTP client)  │  │
│  └─────┬─────────────────────────┘  │
└────────┼────────────────────────────┘
         │ HTTP (localhost:8089)
┌────────▼────────────────────────────┐
│    stem_server.py                    │
│                                      │
│  ┌────────────────────────────────┐  │
│  │  Demucs htdemucs model (MPS)  │  │
│  │  Loaded once, kept in GPU RAM │  │
│  └────────────────────────────────┘  │
│                                      │
│  POST /separate → chunk processing   │
│  GET  /status   → progress polling   │
│  GET  /health   → server readiness   │
└──────────────────────────────────────┘
```

### Key files

| File | Purpose |
|------|---------|
| `scripts/stem_server.py` | Python HTTP server wrapping Demucs with MPS GPU acceleration |
| `dj/djApp.swift` | App entry point, launches/kills the Python server |
| `dj/ContentView.swift` | Main view orchestrating drop, processing, and playback states |
| `dj/ViewModels/AudioEngineManager.swift` | AVAudioEngine with 5 synchronized players (1 original + 4 stems) |
| `dj/ViewModels/StemSeparator.swift` | HTTP client polling the Python server for separation progress |
| `dj/ViewModels/CacheManager.swift` | SHA-256 hash-based stem caching to `~/Music/dj/cache/` |
| `dj/Views/WaveformView.swift` | Overview and per-stem waveform rendering |
| `dj/Views/StemControlView.swift` | Per-stem volume slider, mute, and solo controls |

### Caching

Separated stems are cached at `~/Music/dj/cache/<file-hash>/`. Each cached entry contains:
- `drums.wav`, `bass.wav`, `vocals.wav`, `other.wav` — the separated stems
- `chunks/` — intermediate chunk files (cleaned up after concatenation)
- `metadata.json` — original filename, model used, duration

To clear the cache:
```bash
rm -rf ~/Music/dj/cache/*
```

## Performance

Benchmarked on Apple Silicon with MPS GPU acceleration:

| Scenario | Time |
|----------|------|
| Load original track | **Instant** |
| First stem chunk ready (10s of audio) | **~3 seconds** |
| Full 7.5 min track separation | **~47 seconds** |
| Cached file reload | **Instant** |

## License

See [LICENSE](LICENSE) for details.
