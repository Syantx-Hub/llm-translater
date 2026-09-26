"""Translation sidecar for the Mac app: one JSON object per line over stdin/stdout.

Startup:  {"ready": true, "engine": "nllb"}
Request:  {"id": 1, "text": "Hello", "source": "en", "target": "my", "context": ["..."]}
Response: {"id": 1, "translation": "..."}  or  {"id": 1, "error": "..."}

stdout carries protocol messages only; logs go to stderr. `context` holds the previous
few source lines; the sentence-level MT engines here ignore it for now.

Usage:
    python translate_server.py --engine nllb
    python translate_server.py --engine madlad --madlad-ct2 models/madlad400-3b-ct2
    python translate_server.py --engine echo     # no model, for testing the app
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time

from translators import LANGS, build_translator


def send(message: dict):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def log(*parts):
    print(*parts, file=sys.stderr, flush=True)


def ram_gb() -> float:
    out = subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout
    return int(out.strip() or 0) / 2**30


def handle(translator, request: dict) -> dict:
    rid = request.get("id")
    text, src, tgt = request.get("text", ""), request.get("source"), request.get("target")
    if src not in LANGS or tgt not in LANGS:
        return {"id": rid, "error": f"unsupported language pair {src}->{tgt}"}
    if not text.strip() or src == tgt:
        return {"id": rid, "translation": text}
    t0 = time.perf_counter()
    translation = translator.translate(text, src, tgt)
    log(f"[{src}->{tgt}] {(time.perf_counter() - t0) * 1000:.0f} ms: {text!r} -> {translation!r}")
    return {"id": rid, "translation": translation}


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--engine", choices=["nllb", "madlad", "echo"], default="nllb")
    p.add_argument("--nllb-model", default="facebook/nllb-200-distilled-600M")
    p.add_argument("--madlad-ct2", help="path to a CTranslate2-converted MADLAD model")
    args = p.parse_args()

    log(f"loading {args.engine} ...")
    translator = build_translator(
        args.engine, nllb_model=args.nllb_model, madlad_ct2=args.madlad_ct2, ram_gb=ram_gb()
    )
    send({"ready": True, "engine": args.engine})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError as e:
            send({"id": None, "error": f"bad json: {e}"})
            continue
        try:
            send(handle(translator, request))
        except Exception as e:  # keep serving; one bad line must not kill the app's translator
            log(f"error: {e!r}")
            send({"id": request.get("id"), "error": str(e)})


if __name__ == "__main__":
    main()
