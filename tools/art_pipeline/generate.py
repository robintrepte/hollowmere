#!/usr/bin/env python3
"""Generates a raw image through the Replicate HTTP API (for regenerating art outside the editor).

  REPLICATE_API_TOKEN=... generate.py <out.png> "<prompt>" [--model google/nano-banana-2-lite] [--aspect 1:1]

Prompt templates live in tools/art_pipeline/style.md. Raw output goes in tools/art_pipeline/raw/,
then run the matching process.py command (see build_all.sh).
"""
import argparse
import json
import os
import sys
import time
import urllib.request

API = "https://api.replicate.com/v1"


def call(method, url, token, body=None, wait=True):
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body else None)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    if wait:
        req.add_header("Prefer", "wait=60")
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("prompt")
    ap.add_argument("--model", default="google/nano-banana-2-lite")
    ap.add_argument("--aspect", default="1:1")
    a = ap.parse_args()
    token = os.environ.get("REPLICATE_API_TOKEN")
    if not token:
        sys.exit("REPLICATE_API_TOKEN is not set")
    pred = call("POST", f"{API}/models/{a.model}/predictions", token,
                {"input": {"prompt": a.prompt, "aspect_ratio": a.aspect, "output_format": "png"}})
    while pred.get("status") not in ("succeeded", "failed", "canceled"):
        time.sleep(2)
        pred = call("GET", pred["urls"]["get"], token, wait=False)
    if pred["status"] != "succeeded":
        sys.exit(f"prediction {pred['status']}: {pred.get('error')}")
    url = pred["output"][0] if isinstance(pred["output"], list) else pred["output"]
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    urllib.request.urlretrieve(url, a.out)
    print(a.out, url)


if __name__ == "__main__":
    main()
