#!/usr/bin/env python3
"""File-based pronunciation overlay for the full ECDICT dictionary.

The overlay is a manifest keyed by headword. For every matching word the exporter
inserts one speaker per recorded pronunciation. Audio is NOT embedded: the helper
plays ``Resources/Audio/<id>.mp3`` (Look Up panel) and Desktop Dictionary.app
plays the same file through a relative ``<audio>`` element.

Multiple recordings per word are supported (e.g. record-noun / record-verb).
Recordings whose audio bytes are identical are collapsed to a single speaker, so a
word only shows two speakers when the pronunciations actually differ.

Manifest shape (``audio-overlay-1``)::

    {"schema": "audio-overlay-1",
     "recordings": [{"id": "us-record-noun", "word": "record",
                     "part_of_speech": "noun", "mp3_filename": "audio/us-record-noun.mp3",
                     "sha256": "...", ...}]}
"""
from __future__ import annotations

import json
from pathlib import Path

ENDPOINT = 'http://127.0.0.1:17943/audio/play'
IDLE_BG = "url('data:image/gif;base64,R0lGODlhAQABAAAAACwAAAAAAQABAAA=')"

_SPEAKER = (
    '<span class="audio-speaker">'
    '<img class="audio-glyph-idle" src="Images/audio-speaker.svg" width="14" height="14" alt="播放"/>'
    '<img class="audio-glyph-active" src="Images/audio-speaker-blue.svg" width="14" height="14" alt=""/>'
    '</span>'
)


def load_overlay(path: Path) -> dict:
    """Return ``{word: [record, ...]}``.

    One speaker per part of speech, preferring US over UK per POS, and collapsing
    recordings whose audio bytes are identical. A word therefore shows two
    speakers only when it has distinct noun/verb recordings.
    """
    data = json.loads(Path(path).read_text(encoding='utf-8'))
    if data.get('schema') != 'audio-overlay-1':
        raise ValueError(f'Unsupported overlay schema in {path}')

    grouped: dict[str, dict[str, dict]] = {}
    for row in data['recordings']:
        bucket = grouped.setdefault(row['word'], {})
        key = row.get('part_of_speech') or ''
        current = bucket.get(key)
        if current is None or (current.get('accent') != 'US' and row.get('accent') == 'US'):
            bucket[key] = row

    result: dict[str, list] = {}
    for word, bucket in grouped.items():
        pos_records = [r for key, r in bucket.items() if key]
        if len(pos_records) >= 2:
            chosen = pos_records
        elif len(pos_records) == 1:
            chosen = pos_records
        else:
            chosen = [next(iter(bucket.values()))]
        unique, seen = [], set()
        for record in chosen:
            digest = record.get('sha256')
            if digest in seen:
                continue  # same pronunciation -> single speaker
            seen.add(digest)
            unique.append(record)
        result[word] = unique
    return result


def _title(record: dict) -> str:
    from html import escape
    accent = record.get('accent') or ''
    pos = record.get('part_of_speech') or ''
    text = '播放真人录音'
    if accent:
        text += ' ' + accent
    if pos:
        text += ' ' + pos
    return escape(text)


def _item(record: dict, show_pos: bool = False) -> str:
    from xml.sax.saxutils import quoteattr
    from html import escape

    clip_id = record['id']
    identity = 'audio-' + clip_id
    pos = record.get('part_of_speech') or ''
    label = f'<span>{escape(pos)}</span> ' if pos else ''
    # The panel anchor is icon-only unless this word has several parts of speech;
    # then show the POS so the two speakers can be told apart.
    panel_label = f'<span class="audio-pos">{escape(pos)}</span>' if (show_pos and pos) else ''
    title = quoteattr(_title(record))

    # Desktop Dictionary.app: play the bundle file directly (relative URL).
    app_js = (
        "var b=this,a=document.getElementById('" + identity + "');"
        "if(!a){return false;}"
        "var off=function(){b.classList.remove('is-playing');};"
        "a.onplaying=function(){b.classList.add('is-playing');};"
        "a.onended=off;a.onerror=off;"
        "try{a.currentTime=0;var p=a.play();"
        "if(p&&p.catch){p.catch(off);}}catch(e){off();}"
        "return false;"
    )
    # Look Up panel: the panel only forwards mouseover, and only in response to a
    # click. Playing immediately on mouseover gives "click to play" with no delay;
    # merely resting the pointer does nothing.
    over_js = (
        "var n=(window.__ecdictAudioCounter||0)+1;window.__ecdictAudioCounter=n;"
        "this.style.setProperty('--ecdict-audio-request',"
        f"'url(\\\"{ENDPOINT}/{clip_id}?event=over&counter='+Date.now()+'-'+n+'\\\")');"
    )

    return (
        '<span class="audio-item">'
        f'<button class="audio-play audio-app" type="button" title={title} '
        f'onclick={quoteattr(app_js)}>{label}{_SPEAKER}</button>'
        f'<a class="audio audio-trigger audio-lookup" data-h={quoteattr(clip_id)} title={title} '
        f'onmouseover={quoteattr(over_js)} '
        f'style={quoteattr("--ecdict-audio-request: " + IDLE_BG)}>{panel_label}{_SPEAKER}</a>'
        f'<audio id="{identity}" class="audio-media" preload="none" src="Audio/{clip_id}.mp3"></audio>'
        '<span class="audio-status" aria-live="polite"></span>'
        '</span>'
    )


def render_overlay(records) -> str:
    if isinstance(records, dict):
        records = [records]
    show_pos = len(records) > 1
    items = ''.join(_item(r, show_pos) for r in records)
    return ('<span class="audio-pronunciations" title="音标沿用 ECDICT 原数据；录音为真人录音。">'
            + items + '</span>')
