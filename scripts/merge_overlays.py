#!/usr/bin/env python3
"""Merge several audio-overlay manifests into one overlay directory.

Later layers are skipped for a word already provided by an earlier layer, so a
delta layer (e.g. tech, already excluding core) simply extends the first one.
MP3 files are symlinked into ``<output>/audio/`` to avoid duplicating bytes.
"""
import argparse
import json
import os
import shutil
from pathlib import Path


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('output', type=Path)
    p.add_argument('overlays', type=Path, nargs='+')
    args = p.parse_args()

    out = args.output
    if out.exists():
        shutil.rmtree(out)
    (out / 'audio').mkdir(parents=True)

    records, seen = [], set()
    for manifest in args.overlays:
        root = manifest.parent
        data = json.loads(manifest.read_text(encoding='utf-8'))
        for record in data['recordings']:
            # Deduplicate by clip id, not by word: one word may legitimately have
            # several recordings (e.g. record-noun and record-verb).
            if record['id'] in seen:
                continue
            seen.add(record['id'])
            source = (root / 'audio' / f"{record['id']}.mp3").resolve()
            dest = out / 'audio' / f"{record['id']}.mp3"
            if not dest.exists():
                os.symlink(source, dest)
            records.append(record)

    (out / 'manifest.json').write_text(
        json.dumps({'schema': 'audio-overlay-1', 'recordings': records},
                   ensure_ascii=False, indent=1),
        encoding='utf-8')
    print(f'merged {len(records)} recordings -> {out}')


if __name__ == '__main__':
    main()
