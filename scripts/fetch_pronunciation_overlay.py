#!/usr/bin/env python3
"""Download audited Wikimedia recordings and build a file-based audio overlay.

Input : a discovery manifest (scripts/discover_pronunciations.py).
Output: <root>/original/<id>.<ext>, <root>/audio/<id>.mp3, <root>/manifest.json,
        <root>/ATTRIBUTION.txt.

Speed comes from reusing one HTTPS connection (keep-alive), NOT from concurrency:
several parallel requests get rate-limited by Wikimedia (HTTP 429). Serial +
keep-alive measured ~4 recordings/s, and already-converted files are skipped so
the run is resumable.
"""
import argparse
import hashlib
import http.client
import json
import re
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
from audio_common import ffmpeg, inspect_audio, sha256

UA = 'ECDICT-Pronunciation-PoC/0.1 (https://github.com/thisIsZs/ecdict-audio-dictionary)'
HOST = 'upload.wikimedia.org'

_conn = None


class RateLimited(Exception):
    def __init__(self, wait):
        super().__init__('rate limited')
        self.wait = wait


def _retry_after(resp, attempt):
    value = resp.getheader('Retry-After')
    if value and str(value).isdigit():
        return min(int(value), 120)
    return min(5 * (attempt + 1), 60)


def _connection():
    global _conn
    if _conn is None:
        _conn = http.client.HTTPSConnection(HOST, timeout=30)
    return _conn


def _reset():
    global _conn
    if _conn is not None:
        try:
            _conn.close()
        except Exception:
            pass
    _conn = None


def download(record, dest, interval, retries, timeout):
    if urlparse(record['file_url']).hostname != HOST:
        raise ValueError('Only reviewed Wikimedia media URLs are accepted')
    path = urlparse(record['file_url']).path
    tmp = Path(str(dest) + '.part')
    for attempt in range(retries + 1):
        if interval:
            time.sleep(interval)
        try:
            conn = _connection()
            conn.request('GET', path, headers={'User-Agent': UA})
            resp = conn.getresponse()
            if resp.status == 429:
                wait = _retry_after(resp, attempt)
                _reset()
                raise RateLimited(wait)
            if resp.status != 200:
                raise RuntimeError(f'HTTP {resp.status}')
            data = resp.read(10_000_001)
            if len(data) > 10_000_000:
                raise ValueError('Recording exceeds 10 MB limit')
            tmp.write_bytes(data)
            if record.get('source_sha1'):
                with tmp.open('rb') as f:
                    if hashlib.file_digest(f, 'sha1').hexdigest() != record['source_sha1']:
                        raise ValueError('Downloaded file does not match official SHA-1')
            tmp.replace(dest)
            return
        except RateLimited as exc:
            _reset()
            if attempt == retries:
                raise RuntimeError('rate limited (retries exhausted)')
            time.sleep(exc.wait)
        except Exception:
            _reset()
            if attempt == retries:
                raise
            time.sleep(min(2 ** attempt, 10))
        finally:
            tmp.unlink(missing_ok=True)


def convert(original, dest):
    probe = subprocess.run([ffmpeg(), '-nostdin', '-hide_banner', '-i', str(original),
                            '-af', 'volumedetect', '-f', 'null', '-'],
                           capture_output=True, text=True, check=True, timeout=60)
    match = re.search(r'max_volume: (-?[\d.]+) dB', probe.stderr)
    if not match:
        raise ValueError('Unable to measure peak')
    gain = min(6.0, -3.0 - float(match[1]))
    tmp = Path(str(dest) + '.part')
    cmd = [ffmpeg(), '-nostdin', '-v', 'error', '-xerror', '-y', '-i', str(original),
           '-map', '0:a:0', '-vn', '-map_metadata', '-1', '-af', f'volume={gain:.1f}dB',
           '-ac', '1', '-ar', '44100', '-c:a', 'libmp3lame', '-b:a', '128k',
           '-f', 'mp3', str(tmp)]
    try:
        subprocess.run(cmd, check=True, capture_output=True, timeout=60)
        tmp.replace(dest)
    finally:
        tmp.unlink(missing_ok=True)
    return gain


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('discovery', type=Path)
    p.add_argument('root', type=Path)
    p.add_argument('--exclude', type=Path, nargs='*', default=[],
                   help='overlay manifest(s) whose words are skipped (already covered)')
    p.add_argument('--interval', type=float, default=0.2)
    p.add_argument('--retries', type=int, default=6)
    p.add_argument('--timeout', type=float, default=30)
    args = p.parse_args()

    data = json.loads(args.discovery.read_text(encoding='utf-8'))
    excluded = set()
    for path in args.exclude:
        for r in json.loads(Path(path).read_text(encoding='utf-8'))['recordings']:
            excluded.add(r['word'])
    root = args.root
    (root / 'original').mkdir(parents=True, exist_ok=True)
    (root / 'audio').mkdir(parents=True, exist_ok=True)

    total = len(data['records'])
    recordings, errors = [], []
    started = time.time()
    for idx, record in enumerate(data['records'], 1):
        if record['word'] in excluded:
            continue
        try:
            ext = Path(record['original_filename']).suffix or '.ogg'
            original = root / 'original' / f'{record["id"]}{ext}'
            dest = root / 'audio' / f'{record["id"]}.mp3'
            if not original.exists():
                download(record, original, args.interval, args.retries, args.timeout)
            gain = None
            if not dest.exists():
                gain = convert(original, dest)
            meta = inspect_audio(dest)
            recordings.append({
                **record,
                'mp3_filename': f'audio/{record["id"]}.mp3',
                'sha256': sha256(dest),
                'duration': meta['duration'],
                'sample_rate': meta['sample_rate'],
                'format': 'mp3',
                'gain_db': gain,
                'transformation': (
                    f'peak normalization target -3 dBFS, gain {gain:.1f} dB (boost capped at 6 dB); '
                    f'mono 44100 Hz; no trimming' if gain is not None
                    else 'reused previously converted derivative; mono 44100 Hz'),
            })
        except Exception as exc:
            errors.append({'id': record['id'], 'error': str(exc)})
        if idx % 100 == 0:
            rate = idx / max(time.time() - started, 1e-9)
            print(f'  …{idx}/{total} (ok {len(recordings)}, err {len(errors)}) {rate:.2f}/s',
                  file=sys.stderr, flush=True)

    (root / 'manifest.json').write_text(
        json.dumps({'schema': 'audio-overlay-1', 'recordings': recordings}, indent=2, ensure_ascii=False),
        encoding='utf-8')
    lines = ['ECDICT Pronunciation overlay — audio credits',
             'Individual recordings retain their own licenses.', '']
    for r in recordings:
        lines += [f'{r["word"]} ({r["accent"]}) — {r["author"]}',
                  r['attribution'], r['source_url'], f'{r["license"]}: {r["license_url"]}',
                  'Original: ' + r['original_filename'], 'Changes: ' + r['transformation'], '']
    (root / 'ATTRIBUTION.txt').write_text('\n'.join(lines), encoding='utf-8')

    size = sum((root / 'audio' / f'{r["id"]}.mp3').stat().st_size for r in recordings)
    print(f'overlay recordings: {len(recordings)}  ({size/1048576:.1f} MiB)')
    print(f'errors            : {len(errors)}')
    for e in errors[:10]:
        print('  ', e)


if __name__ == '__main__':
    main()
