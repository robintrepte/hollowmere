#!/usr/bin/env python3
"""Writes the public, per-deployment values into an exported web build's index.html.

    GOOGLE_CLIENT_ID=... python3 tools/release/inject_web_config.py build/web/index.html

Environment (all optional; unset or empty leaves that feature off):
  GOOGLE_CLIENT_ID, APPLE_CLIENT_ID, DISCORD_CLIENT_ID   social sign-in buttons (public ids)

Run after the Godot export and before tools/release/fingerprint_web.sh. Values are validated so a
typo cannot inject markup into the page. Nothing here is secret: all of it ships to every browser.
"""
import os
import re
import sys

ID = re.compile(r"^[A-Za-z0-9._-]{1,200}$")
NAMES = ("GOOGLE_CLIENT_ID", "APPLE_CLIENT_ID", "DISCORD_CLIENT_ID")


def value(name, pattern):
    v = os.environ.get(name, "").strip()
    if v == "":
        return ""
    if not pattern.match(v):
        sys.exit("%s does not look right: %r" % (name, v))
    return v


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    html = open(path, encoding="utf-8").read()
    if not any("%" + name + "%" in html for name in NAMES):
        print("web config: %s was already configured, left as is" % path)
        return
    configured = []
    for name in NAMES:
        v = value(name, ID)
        html = html.replace("%" + name + "%", v)
        if v:
            configured.append(name)
    open(path, "w", encoding="utf-8").write(html)
    print("web config: %s" % (", ".join(configured) if configured else "no social sign-in ids"))


if __name__ == "__main__":
    main()
