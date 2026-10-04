#!/usr/bin/env python3
"""Appends translations for strings the catalog is missing.

    python3 tools/content/add_translations.py de path/to/new.json

new.json maps English msgids to translations. Entries the catalog already has are left alone, so
the file can be re-run. Ids with printf placeholders get the c-format flag.
"""
import io
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from extract_strings import parse_po_pairs  # noqa: E402

PLACEHOLDER = re.compile(r"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?[sdif]")


def main():
    locale, path = sys.argv[1], sys.argv[2]
    po = os.path.join(ROOT, "game", "i18n", "%s.po" % locale)
    have = parse_po_pairs(po)
    new = json.load(io.open(path, encoding="utf-8"))
    blocks = []
    for msgid, msgstr in new.items():
        if msgid in have and have[msgid] != "":
            continue
        if sorted(PLACEHOLDER.findall(msgid)) != sorted(PLACEHOLDER.findall(msgstr)):
            sys.exit("placeholders differ: %r -> %r" % (msgid, msgstr))
        flag = "#, c-format\n" if PLACEHOLDER.search(msgid) else ""
        blocks.append("%smsgid %s\nmsgstr %s\n" % (flag, json.dumps(msgid, ensure_ascii=False), json.dumps(msgstr, ensure_ascii=False)))
    if not blocks:
        print("nothing to add")
        return
    text = io.open(po, encoding="utf-8").read().rstrip("\n") + "\n\n" + "\n".join(blocks) + "\n"
    io.open(po, "w", encoding="utf-8").write(text)
    print("added %d entries to %s" % (len(blocks), os.path.relpath(po, ROOT)))


if __name__ == "__main__":
    main()
