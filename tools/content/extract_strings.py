#!/usr/bin/env python3
"""Collects every player-facing string into game/i18n/hollowmere.pot (gettext template).

Sources:
  * data/*.json: names, descriptions, hints, story and villager dialogue
  * GDScript: tr("...") templates and literals handed to labels, buttons, dialogue and toasts

Translators copy the template to game/i18n/<locale>.po (e.g. de.po); Settings loads every
.po in that folder at startup and the Language option appears in Settings.

    python3 tools/content/extract_strings.py [--check]

--check exits non-zero if the template is out of date (for CI).
"""
import glob
import io
import json
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))
GAME = os.path.join(ROOT, "game")
OUT = os.path.join(GAME, "i18n", "hollowmere.pot")

TEXT_KEYS = {"name", "desc", "hint", "lines", "text", "title", "goal_text", "job_name", "job_desc", "role"}
TABLE_COLUMNS = {"name", "desc"}
DIALOGUE_FILES = {"villagers.json"}
SKIP_KEYS = {"id", "icon", "color", "schedule", "music", "biome", "type", "types", "season", "kind"}

STR = r'"((?:[^"\\\n]|\\.)*)"'
TR_CALL = re.compile(r'(?<![\w.])tr\(' + STR + r'\)')
UI_CALLS = re.compile(r'(?:UITheme\.(?:label|button)|_say|_ask|ui\.say|ui\.ask|toast\.emit|toast)\(\[?\s*' + STR)
LIST_LINE = re.compile(r'^\s*' + STR + r',?\s*\]?\)?\s*$')


def unescape(s):
    return bytes(s, "utf-8").decode("unicode_escape").encode("latin-1").decode("utf-8")


KEEP_IDS = {"resting", "spring", "summer", "fall", "winter"}


def worth(s):
    s = s.strip()
    if not s or not any(c.isalpha() for c in s):
        return False
    if s.lower() in KEEP_IDS:
        return True
    return not re.fullmatch(r"[a-z0-9_:.]+", s)


def add(found, s, ref):
    if worth(s):
        found.setdefault(s, set()).add(ref)


def walk_json(o, found, ref, key="", dialogue=False):
    if isinstance(o, dict):
        if set(o.keys()) == {"columns", "rows"}:
            cols = o["columns"]
            for row in o["rows"]:
                for c, v in zip(cols, row):
                    if c in TABLE_COLUMNS and isinstance(v, str):
                        add(found, v, ref)
            return
        for k, v in o.items():
            if k in SKIP_KEYS:
                continue
            walk_json(v, found, ref, k, dialogue)
    elif isinstance(o, list):
        for v in o:
            walk_json(v, found, ref, key, dialogue)
    elif isinstance(o, str):
        if key in TEXT_KEYS or (dialogue and " " in o):
            add(found, o, ref)


def scan_gd(path, found):
    rel = os.path.relpath(path, GAME)
    with io.open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    in_list = False
    for n, line in enumerate(lines, 1):
        s = line.strip()
        if s.startswith("#"):
            continue
        ref = "%s:%d" % (rel, n)
        for m in TR_CALL.finditer(line):
            add(found, unescape(m.group(1)), ref)
        for m in UI_CALLS.finditer(line):
            add(found, unescape(m.group(1)), ref)
        if in_list:
            m = LIST_LINE.match(line)
            if m:
                add(found, unescape(m.group(1)), ref)
        if re.search(r'(_say|ui\.say)\(\[\s*$', line) or re.search(r'(_say|ui\.say)\(\[.*,\s*$', line):
            in_list = True
        elif "])" in line or "]," in line:
            in_list = False


def po_escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")


def build():
    found = {}
    for f in sorted(glob.glob(os.path.join(GAME, "data", "*.json"))):
        name = os.path.basename(f)
        with io.open(f, encoding="utf-8") as fh:
            walk_json(json.load(fh), found, "data/" + name, dialogue=name in DIALOGUE_FILES)
    for f in sorted(glob.glob(os.path.join(GAME, "**", "*.gd"), recursive=True)):
        rel = os.path.relpath(f, GAME)
        if rel.startswith(("addons", "tests", ".godot")):
            continue
        scan_gd(f, found)
    out = ['msgid ""', 'msgstr ""', '"Content-Type: text/plain; charset=UTF-8\\n"', '"Project-Id-Version: Hollowmere\\n"', ""]
    for s in sorted(found):
        refs = sorted(found[s])
        out.append("#: " + " ".join(refs[:4]) + (" ..." if len(refs) > 4 else ""))
        if "%" in s:
            out.append("#, c-format")
        out.append('msgid "%s"' % po_escape(s))
        out.append('msgstr ""')
        out.append("")
    return "\n".join(out), len(found)


def main():
    text, n = build()
    if "--check" in sys.argv:
        old = io.open(OUT, encoding="utf-8").read() if os.path.exists(OUT) else ""
        if old != text:
            print("hollowmere.pot is out of date; run tools/content/extract_strings.py")
            sys.exit(1)
        print("hollowmere.pot is up to date (%d strings)" % n)
        check_catalog(os.path.join(GAME, "i18n", "de.po"), text)
        return
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with io.open(OUT, "w", encoding="utf-8") as f:
        f.write(text)
    print("wrote %s (%d strings)" % (os.path.relpath(OUT, ROOT), n))


def parse_po_msgids(text):
    import json as _json
    ids = []
    buf = []
    in_msgid = False
    for line in text.splitlines():
        if line.startswith("msgid "):
            in_msgid = True
            buf = [_json.loads(line[6:])]
        elif line.startswith("msgstr "):
            msgid = "".join(buf)
            if msgid:
                ids.append(msgid)
            in_msgid = False
            buf = []
        elif in_msgid and line.startswith('"'):
            buf.append(_json.loads(line))
    return ids


def parse_po_pairs(path):
    import json as _json
    pairs = {}
    msgid = None
    buf = []
    mode = None
    with io.open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("msgid "):
                if msgid is not None and mode == "msgstr":
                    pairs[msgid] = "".join(buf)
                mode = "msgid"
                buf = [_json.loads(line[6:])]
                msgid = None
            elif line.startswith("msgstr "):
                msgid = "".join(buf)
                mode = "msgstr"
                buf = [_json.loads(line[7:])]
            elif line.startswith('"') and mode:
                buf.append(_json.loads(line))
        if msgid is not None and mode == "msgstr":
            pairs[msgid] = "".join(buf)
    return pairs


def check_catalog(path, pot_text):
    if not os.path.exists(path):
        print("%s is missing" % os.path.relpath(path, ROOT))
        sys.exit(1)
    needed = set(parse_po_msgids(pot_text))
    pairs = parse_po_pairs(path)
    missing = sorted(needed - set(pairs))
    empty = sorted(s for s in needed if s in pairs and pairs[s] == "" and any(c.isalpha() for c in s))
    if missing or empty:
        print("%s is incomplete: %d missing, %d empty" % (os.path.relpath(path, ROOT), len(missing), len(empty)))
        for s in (missing + empty)[:12]:
            print("  - %s" % s.replace("\n", "\\n")[:80])
        sys.exit(1)
    print("%s covers %d strings" % (os.path.relpath(path, ROOT), len(needed)))


if __name__ == "__main__":
    main()
