#!/usr/bin/env python3
"""Build a .dictionary from an exported XML + a file-based audio overlay.

Audio lives under Resources/Audio/<id>.mp3 (NOT embedded), so entries stay small
and the bundle can hold many recordings.
"""
import argparse
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from audio_common import read_json, sha256, write_json


def compile_dictionary(output, ddk):
    """Run the Apple Dictionary Development Kit and return the built bundle."""
    output, ddk = Path(output).resolve(), Path(ddk).resolve()
    tool = ddk / 'bin/build_dict.sh'
    if not tool.is_file():
        raise FileNotFoundError(f'Apple DDK missing: {tool}; obtain Additional Tools from Apple Developer')
    stats = read_json(output / 'statistics.json')
    env = {**os.environ, 'DICT_BUILD_TOOL_DIR': str(ddk), 'DICT_DEV_KIT_OBJ_DIR': str(output / 'objects')}
    result = subprocess.run([str(tool), '-v', '10.11', stats['bundle_name'], 'Dictionary.xml', 'Dictionary.css', 'Info.plist'],
                            cwd=output, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (output / 'ddk-build.log').write_text(result.stdout)
    if result.returncode:
        raise RuntimeError(f'DDK failed; see {output / "ddk-build.log"}')
    bundle = output / 'objects' / (stats['bundle_name'] + '.dictionary')
    resources = bundle / 'Contents/Resources'
    if not resources.is_dir() or not any(resources.glob('*.data')):
        raise RuntimeError('DDK did not produce dictionary data')
    shutil.copytree(output / 'resources', resources, dirs_exist_ok=True)
    for path in (output / 'resources').rglob('*'):
        if path.is_file() and sha256(path) != sha256(resources / path.relative_to(output / 'resources')):
            raise ValueError('Packaged resource mismatch')
    actual = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    if actual['CFBundleIdentifier'] != stats['bundle_identifier']:
        raise ValueError('Unexpected compiled bundle identifier')
    stats['dictionary_bytes'] = sum(p.stat().st_size for p in bundle.rglob('*') if p.is_file())
    write_json(output / 'statistics.json', stats)
    return bundle


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--xml', type=Path, required=True)
    p.add_argument('--overlay', type=Path, required=True, help='audio-overlay-1 manifest.json')
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--name', default='ECDICT Audio Sample')
    p.add_argument('--identifier', default='com.ecdict.dictionary.audio.sample')
    p.add_argument('--ddk', type=Path, default=Path('/Applications/Utilities/Dictionary Development Kit'))
    p.add_argument('--compile', action='store_true')
    args = p.parse_args()

    overlay = json.loads(args.overlay.read_text(encoding='utf-8'))
    recordings = overlay['recordings']
    overlay_root = args.overlay.parent

    out = args.output
    if out.exists() and any(out.iterdir()):
        raise ValueError(f'Output not empty: {out}')
    out.mkdir(parents=True, exist_ok=True)
    resources = out / 'resources'
    (resources / 'Audio').mkdir(parents=True)
    shutil.copy2(args.xml, out / 'Dictionary.xml')

    css = (ROOT / 'dictionary-source/MyDictionary.css').read_text(encoding='utf-8') + \
          (ROOT / 'dictionary-source/AudioPoC.css').read_text(encoding='utf-8')
    (out / 'Dictionary.css').write_text(css, encoding='utf-8')

    # audio files + helper manifest (id -> Audio/<id>.mp3 with SHA-256)
    helper = {'recordings': []}
    for r in recordings:
        src = overlay_root / r['mp3_filename']
        dest = resources / 'Audio' / f'{r["id"]}.mp3'
        shutil.copy2(src, dest)
        if sha256(dest) != r['sha256']:
            raise ValueError(f'Hash mismatch copying {src}')
        helper['recordings'].append({
            'id': r['id'], 'word': r['word'], 'accent': r.get('accent'),
            'part_of_speech': r.get('part_of_speech'),
            'derivatives': [{'format': 'mp3', 'sha256': r['sha256'],
                             'local_filename': f'Audio/{r["id"]}.mp3'}],
        })
    write_json(resources / 'audio-manifest.json', helper)
    shutil.copytree(ROOT / 'dictionary-source/Images', resources / 'Images', dirs_exist_ok=True)
    for name in ('MyDictionary.xsl', 'MyDictionary_prefs.html'):
        shutil.copy2(ROOT / 'dictionary-source' / name, resources / name)
    for name in ('LICENSE', 'NOTICE'):
        shutil.copy2(ROOT / name, resources / name)
    attribution = overlay_root / 'ATTRIBUTION.txt'
    if attribution.exists():
        shutil.copy2(attribution, resources / 'ATTRIBUTION.txt')

    plist = plistlib.loads((ROOT / 'dictionary-source/MyInfo.plist').read_bytes())
    plist.update(CFBundleName=args.name, CFBundleIdentifier=args.identifier,
                 CFBundleShortVersionString='0.1.0',
                 DCSDictionaryCopyright='ECDICT: MIT; individual audio licenses: see ATTRIBUTION.txt.')
    (out / 'Info.plist').write_bytes(re.sub(br'<!DOCTYPE[^>]*>\n', b'', plistlib.dumps(plist)))

    used = sum((resources / 'Audio' / f'{r["id"]}.mp3').stat().st_size for r in recordings)
    write_json(out / 'statistics.json', {
        'bundle_name': args.name, 'bundle_identifier': args.identifier,
        'entry_mode': 'sample' if '--limit' in sys.argv else 'full',
        'recordings': len(recordings), 'audio_bytes': used,
        'dictionary_bytes': None, 'source_sha256': sha256(out / 'Dictionary.xml'),
    })

    if args.compile:
        bundle = compile_dictionary(out, args.ddk)
        stats = json.loads((out / 'statistics.json').read_text())
        size = sum(f.stat().st_size for f in bundle.rglob('*') if f.is_file())
        print(f'bundle: {bundle}')
        print(f'size  : {size/1048576:.1f} MiB, recordings: {stats["recordings"]}')
    else:
        print(f'prepared: {out}')


if __name__ == '__main__':
    main()
