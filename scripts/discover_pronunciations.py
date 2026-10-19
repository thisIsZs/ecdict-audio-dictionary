#!/usr/bin/env python3
"""Discover Wikimedia Commons pronunciations for a word list and audit licenses.

Writes a candidate manifest (no download). Only records whose Commons license is
one of the approved set are kept, so a later download step is license-audited.
"""
import argparse
import json
import re
import sys
import time
from pathlib import Path
from urllib.parse import quote
from urllib.request import Request, urlopen

UA = 'ECDICT-Pronunciation-PoC/0.1 (https://github.com/thisIsZs/ecdict-audio-dictionary)'
API = 'https://commons.wikimedia.org/w/api.php'
APPROVED = {
    'CC0': ('CC0-1.0', 'https://creativecommons.org/publicdomain/zero/1.0/'),
    'CC BY-SA 3.0': ('CC-BY-SA-3.0', 'https://creativecommons.org/licenses/by-sa/3.0/'),
    'CC BY-SA 4.0': ('CC-BY-SA-4.0', 'https://creativecommons.org/licenses/by-sa/4.0/'),
    'Public domain': ('LicenseRef-PD-self', 'https://commons.wikimedia.org/wiki/Commons:Licensing'),
}
TITLE_RE = re.compile(r'^File:En-(us|uk)-(.+)\.(ogg|oga)$', re.I)


def api(titles, retries=3):
    params = ('action=query&format=json&prop=imageinfo'
              '&iiprop=url|extmetadata|sha1|size|mime&titles=' + quote('|'.join(titles), safe=''))
    last = None
    for attempt in range(retries + 1):
        try:
            with urlopen(Request(f'{API}?{params}', headers={'User-Agent': UA}), timeout=30) as r:
                return json.load(r)
        except Exception as exc:  # transient connection resets happen
            last = exc
            time.sleep(2 ** attempt)
    raise last


def main():
    p = argparse.ArgumentParser()
    p.add_argument('words', type=Path)
    p.add_argument('output', type=Path)
    p.add_argument('--limit', type=int, default=60)
    p.add_argument('--sleep', type=float, default=0.4)
    args = p.parse_args()

    words = [w.strip() for w in args.words.read_text(encoding='utf-8').splitlines()]
    words = [w for w in words if w][:args.limit]

    records, missing = [], []
    # per word: case variants x 2 accents x (base + noun/verb/adj/adv) x (ogg, oga)
    SUFFIXES = (('', None), ('-noun', 'noun'), ('-verb', 'verb'),
                ('-adjective', 'adjective'), ('-adverb', 'adverb'))
    EXTENSIONS = ('ogg', 'oga')
    def variants(w):
        out = [w]
        if w.lower() != w:
            out.append(w.lower())
        return out
    def word_titles(w):
        out = []
        for v in variants(w):
            for pref in ('us', 'uk'):
                for suffix, _pos in SUFFIXES:
                    for ext in EXTENSIONS:
                        out.append(f'File:En-{pref}-{v}{suffix}.{ext}')
        return out
    per_word = len(word_titles('x'))
    batch = max(1, 45 // per_word)
    for i in range(0, len(words), batch):
        chunk = words[i:i + batch]
        titles = []
        for w in chunk:
            titles += word_titles(w)
        try:
            data = api(titles)
        except Exception as exc:
            print('API error:', exc, file=sys.stderr)
            time.sleep(2)
            continue
        pages = {p.get('title'): p for p in data.get('query', {}).get('pages', {}).values()}
        if (i // batch) % 50 == 0:
            print(f'  …{i + len(chunk)}/{len(words)} words probed', file=sys.stderr, flush=True)
        for w in chunk:
            def find(pref, suffix, ext):
                for v in variants(w):
                    page = pages.get(f'File:En-{pref}-{v}{suffix}.{ext}')
                    if page and 'missing' not in page and page.get('imageinfo'):
                        return v, page['imageinfo'][0]
                return None, None
            # per accent: prefer POS-suffixed files (noun/verb/...) so every
            # pronunciation is captured; fall back to the plain file only when
            # there is no POS-specific recording.
            hits = []
            for pref, accent in (('us', 'US'), ('uk', 'UK')):
                found_pos = False
                for suffix, pos in SUFFIXES[1:]:
                    for ext in EXTENSIONS:
                        variant, info = find(pref, suffix, ext)
                        if info:
                            hits.append((accent, suffix, pos, ext, info, variant))
                            found_pos = True
                            break
                if not found_pos:
                    for ext in EXTENSIONS:
                        base_variant, base_info = find(pref, '', ext)
                        if base_info:
                            hits.append((accent, '', None, ext, base_info, base_variant))
                            break
            if not hits:
                missing.append(w)
                continue
            for accent, suffix, pos, ext, info, variant in hits:
                meta = info.get('extmetadata', {})
                short = (meta.get('LicenseShortName', {}).get('value') or '').strip()
                mapped = APPROVED.get(short)
                if not mapped:
                    continue
                author = re.sub('<[^>]+>', '', meta.get('Artist', {}).get('value') or '').strip() or 'Wikimedia Commons contributor'
                clip_id = f'{accent.lower()}-{w}{suffix}'
                records.append({
                    'id': clip_id,
                    'word': w, 'accent': accent, 'part_of_speech': pos,
                    'source_url': f'https://commons.wikimedia.org/wiki/File:En-{accent.lower()}-{variant}{suffix}.{ext}',
                    'file_url': info['url'].split('?')[0],
                    'author': author, 'license': mapped[0], 'license_url': mapped[1],
                    'license_short': short,
                    'attribution': f'{author} / Wikimedia Commons',
                    'original_filename': f'En-{accent.lower()}-{variant}{suffix}.{ext}',
                    'local_filename': f'original/{clip_id}.{ext}',
                    'source_sha1': info.get('sha1'), 'bytes': info.get('size'),
                    'mime': info.get('mime'),
                })
        time.sleep(args.sleep)

    args.output.write_text(json.dumps({'records': records, 'missing': missing}, indent=2), encoding='utf-8')
    print(f'words probed      : {len(words)}')
    print(f'audited recordings: {len(records)}')
    print(f'no approved audio : {len(missing)}')
    from collections import Counter
    print('licenses:', dict(Counter(r['license'] for r in records)))
    print('accents :', dict(Counter(r['accent'] for r in records)))
    print('sample  :')
    for r in records[:8]:
        print('  ', r['id'], '|', r['license'], '|', r['author'][:30])


if __name__ == '__main__':
    main()
