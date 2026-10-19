"""Shared helpers for the pronunciation pipeline (offline; no network here)."""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import wave
from pathlib import Path


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def sha256(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def ffmpeg():
    executable = os.environ.get('FFMPEG') or shutil.which('ffmpeg')
    if not executable:
        try:
            import imageio_ffmpeg
            executable = imageio_ffmpeg.get_ffmpeg_exe()
        except ImportError as exc:
            raise RuntimeError('Install ffmpeg or requirements-audio.txt in a venv') from exc
    return executable


def inspect_audio(path):
    """Fully decode to PCM; validate container magic independently of extension."""
    path = Path(path)
    with path.open('rb') as f:
        magic = f.read(16)
    fmt = path.suffix.lower().lstrip('.')
    checks = {'ogg': magic.startswith(b'OggS'),
              'wav': magic.startswith(b'RIFF') and magic[8:12] == b'WAVE',
              'mp3': magic.startswith(b'ID3') or (len(magic) > 1 and magic[0] == 255 and magic[1] & 224 == 224),
              'm4a': magic[4:8] == b'ftyp'}
    if not checks.get(fmt):
        raise ValueError(f'Invalid audio container: {path}')
    with tempfile.TemporaryDirectory() as tmp:
        decoded = Path(tmp) / 'decoded.wav'
        subprocess.run([ffmpeg(), '-nostdin', '-v', 'error', '-xerror', '-i', str(path),
                        '-map', '0:a:0', '-vn', '-c:a', 'pcm_s16le', str(decoded)],
                       check=True, capture_output=True, timeout=60)
        with wave.open(str(decoded)) as w:
            rate = w.getframerate()
            duration = w.getnframes() / rate
            if not 0.05 < duration < 30:
                raise ValueError(f'Unexpected pronunciation duration: {duration}')
    return {'duration': duration, 'sample_rate': rate, 'format': fmt}
