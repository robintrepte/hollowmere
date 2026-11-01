#!/usr/bin/env python3
"""Writes the public, per-deployment values into an exported web build's index.html.

    GOOGLE_CLIENT_ID=... UMAMI_SRC=https://stats.tretu.de/script.js UMAMI_WEBSITE_ID=<uuid> \
      python3 tools/release/inject_web_config.py build/web/index.html

Environment (all optional; unset or empty leaves that feature off):
  GOOGLE_CLIENT_ID, APPLE_CLIENT_ID, DISCORD_CLIENT_ID   social sign-in buttons (public ids)
  UMAMI_SRC, UMAMI_WEBSITE_ID                           Umami analytics tag, only when both are set

Run after the Godot export and before tools/release/fingerprint_web.sh. Values are validated so a
typo cannot inject markup into the page. Nothing here is secret: all of it ships to every browser.
"""
import os
import re
import sys

ID = re.compile(r"^[A-Za-z0-9._-]{1,200}$")
URL = re.compile(r"^https://[A-Za-z0-9.-]+(:\d+)?(/[A-Za-z0-9._~/-]*)?$")
UUID = re.compile(r"^[0-9a-fA-F-]{8,64}$")
MARKER = re.compile(r"[ \t]*<!-- UMAMI:[^>]*-->\n?")


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
    if not MARKER.search(html) and "%GOOGLE_CLIENT_ID%" not in html:
        print("web config: %s was already configured, left as is" % path)
        return
    for name in ("GOOGLE_CLIENT_ID", "APPLE_CLIENT_ID", "DISCORD_CLIENT_ID"):
        html = html.replace("%" + name + "%", value(name, ID))
    src = value("UMAMI_SRC", URL)
    site = value("UMAMI_WEBSITE_ID", UUID)
    tag = ""
    if src and site:
        tag = '\t<script defer src="%s" data-website-id="%s"></script>\n' % (src, site)
    if not MARKER.search(html):
        sys.exit("analytics marker missing in %s (is it the Hollowmere shell?)" % path)
    html = MARKER.sub(lambda _m: tag, html, count=1)
    open(path, "w", encoding="utf-8").write(html)
    print("web config: analytics %s" % ("on" if tag else "off"))


if __name__ == "__main__":
    main()
