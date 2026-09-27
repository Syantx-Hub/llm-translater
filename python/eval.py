"""Feasibility eval: audio/video file -> Silero VAD -> MLX Whisper -> NLLB / MADLAD.

Apple Silicon Macs only (any M-series chip). Burmese is the default target, but any
pair from LANGS works. Models are loaded one at a time and freed afterwards so the
run fits in 8 GB. Each segment is translated on its own (not batched) so the
per-line latency is close to what the live pipeline will see.

Usage:
    python eval.py clip.mp4 --source en
    python eval.py clip.mp4 --source ko --target th --models nllb
    python eval.py clip.mp4 --madlad-ct2 models/madlad400-3b-ct2
"""

from __future__ import annotations

import argparse
import json
import platform
import statistics
import subprocess
import time
from pathlib import Path

import numpy as np

from translators import LANGS, build_translator, free_memory

SAMPLE_RATE = 16_000


# --- Hardware ------------------------------------------------------------------


def mac_info() -> tuple[str, float]:
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("This app requires an Apple Silicon (M-series) Mac.")

    def sysctl(key):
        return subprocess.run(["sysctl", "-n", key], capture_output=True, text=True).stdout.strip()

    return sysctl("machdep.cpu.brand_string"), int(sysctl("hw.memsize")) / 2**30


# --- Audio + ASR ---------------------------------------------------------------


def load_audio(path: Path) -> np.ndarray:
    """Decode any audio/video file to 16 kHz mono float32 with PyAV (no ffmpeg binary)."""
    import av

    resampler = av.AudioResampler(format="flt", layout="mono", rate=SAMPLE_RATE)
    chunks = []
    with av.open(str(path)) as container:
        for frame in container.decode(container.streams.audio[0]):
            chunks += [f.to_ndarray().reshape(-1) for f in resampler.resample(frame)]
        chunks += [f.to_ndarray().reshape(-1) for f in resampler.resample(None)]
    return np.concatenate(chunks).astype(np.float32)


def speech_chunks(audio: np.ndarray, max_s: float = 25.0, pad_s: float = 0.2):
    """Group Silero VAD speech regions into chunks of at most `max_s` seconds.

    Only speech reaches Whisper, which prevents hallucinated text on silence/music.
    """
    import torch
    from silero_vad import get_speech_timestamps, load_silero_vad

    regions = get_speech_timestamps(
        torch.from_numpy(audio), load_silero_vad(), sampling_rate=SAMPLE_RATE
    )
    pad, limit = int(pad_s * SAMPLE_RATE), int(max_s * SAMPLE_RATE)
    chunks = []
    for r in regions:
        start, end = max(0, r["start"] - pad), min(len(audio), r["end"] + pad)
        if chunks and end - chunks[-1][0] <= limit:
            chunks[-1][1] = end
        else:
            chunks.append([start, end])
    return chunks


def transcribe(audio: np.ndarray, lang: str | None, model_repo: str):
    import mlx_whisper

    segs = []
    t0 = time.perf_counter()
    for start, end in speech_chunks(audio):
        offset = start / SAMPLE_RATE
        result = mlx_whisper.transcribe(
            audio[start:end],
            path_or_hf_repo=model_repo,
            language=lang,
            condition_on_previous_text=False,
        )
        # Lock in the language detected on the first chunk for the rest of the file.
        lang = lang or result["language"]
        segs += [
            {"start": offset + s["start"], "end": offset + s["end"], "text": s["text"].strip()}
            for s in result["segments"]
            if s["text"].strip()
        ]
    elapsed = time.perf_counter() - t0

    # mlx_whisper caches the model globally; drop it before loading a translator.
    mlx_whisper.transcribe.ModelHolder.model = None
    free_memory()
    return segs, lang, elapsed


# --- Output --------------------------------------------------------------------


def srt_time(seconds: float) -> str:
    ms = int(round(seconds * 1000))
    h, ms = divmod(ms, 3_600_000)
    m, ms = divmod(ms, 60_000)
    s, ms = divmod(ms, 1000)
    return f"{h:02}:{m:02}:{s:02},{ms:03}"


def write_srt(path: Path, segs: list[dict], key: str):
    blocks = [
        f"{i}\n{srt_time(s['start'])} --> {srt_time(s['end'])}\n{s[key]}\n"
        for i, s in enumerate(segs, 1)
    ]
    path.write_text("\n".join(blocks), encoding="utf-8")


def zawgyi_flags(texts: list[str]) -> int:
    """Count outputs that look like Zawgyi rather than Unicode Burmese."""
    try:
        from myanmartools import ZawgyiDetector
    except ImportError:
        return -1
    detector = ZawgyiDetector()
    return sum(detector.get_zawgyi_probability(t) > 0.95 for t in texts)


def latency_stats(ms: list[float]) -> str:
    if not ms:
        return "n/a"
    p95 = sorted(ms)[max(0, int(len(ms) * 0.95) - 1)]
    return f"mean {statistics.mean(ms):.0f} ms, p95 {p95:.0f} ms"


def write_comparison(path: Path, audio: Path, segs, models, report):
    cell = lambda t: t.replace("|", "\\|").replace("\n", " ")
    lines = [f"# {audio.name}", "", "## Summary", ""]
    lines += [f"- {line}" for line in report]
    lines += ["", "## Side by side", ""]
    lines.append("| time | source | " + " | ".join(models) + " |")
    lines.append("|---|---|" + "---|" * len(models))
    for s in segs:
        row = [srt_time(s["start"])[:8], cell(s["text"])]
        row += [cell(s.get(m, "")) for m in models]
        lines.append("| " + " | ".join(row) + " |")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


# --- Main ----------------------------------------------------------------------


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("audio", type=Path, help="audio or video file")
    p.add_argument("--source", choices=sorted(LANGS), help="spoken language (default: auto-detect)")
    p.add_argument("--target", choices=sorted(LANGS), default="my", help="subtitle language (default: my)")
    p.add_argument("--models", default="nllb,madlad", help="comma-separated: nllb,madlad,echo")
    p.add_argument("--whisper", default="mlx-community/whisper-large-v3-turbo", help="MLX Whisper repo")
    p.add_argument("--nllb-model", default="facebook/nllb-200-distilled-600M")
    p.add_argument("--madlad-ct2", help="path to a CTranslate2-converted MADLAD model")
    p.add_argument("--out", type=Path, default=Path("outputs"))
    args = p.parse_args()

    chip, ram_gb = mac_info()
    print(f"[hw] {chip}, {ram_gb:.0f} GB")
    if args.source == "my":
        print("  warning: Whisper's Burmese ASR is weak; expect poor transcripts.")

    out_dir = args.out / args.audio.stem
    out_dir.mkdir(parents=True, exist_ok=True)
    models = [m.strip() for m in args.models.split(",") if m.strip()]

    print(f"[asr] {args.whisper} on {args.audio.name} ...")
    audio = load_audio(args.audio)
    duration = len(audio) / SAMPLE_RATE
    segs, src, asr_s = transcribe(audio, args.source, args.whisper)
    if src not in LANGS:
        raise SystemExit(f"detected language '{src}' is not supported; pass --source")
    if src == args.target:
        raise SystemExit(f"source and target are both '{src}'")
    report = [
        f"Hardware: {chip}, {ram_gb:.0f} GB",
        f"ASR: {args.whisper}, {src} -> {args.target}, {len(segs)} segments, "
        f"{asr_s:.1f} s for {duration:.1f} s of audio (RTF {asr_s / max(duration, 1e-9):.2f})",
    ]
    print(f"[asr] {report[1]}")
    write_srt(out_dir / f"source.{src}.srt", segs, "text")

    for name in models:
        print(f"[mt] loading {name} ...")
        t0 = time.perf_counter()
        translator = build_translator(
            name, nllb_model=args.nllb_model, madlad_ct2=args.madlad_ct2, ram_gb=ram_gb
        )
        load_s = time.perf_counter() - t0

        per_line_ms = []
        for i, s in enumerate(segs, 1):
            t0 = time.perf_counter()
            s[name] = translator.translate(s["text"], src, args.target)
            per_line_ms.append((time.perf_counter() - t0) * 1000)
            print(f"  [{name} {i}/{len(segs)}] {s['text']}\n    -> {s[name]}")

        line = f"{name}: load {load_s:.1f} s, per line {latency_stats(per_line_ms)}"
        if args.target == "my":
            zg = zawgyi_flags([s[name] for s in segs])
            line += ", myanmartools not installed" if zg < 0 else f", {zg} Zawgyi-looking lines"
        report.append(line)
        print(f"[mt] {line}")
        write_srt(out_dir / f"{name}.{args.target}.srt", segs, name)

        del translator
        free_memory()

    (out_dir / "segments.json").write_text(
        json.dumps({"report": report, "segments": segs}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    write_comparison(out_dir / "comparison.md", args.audio, segs, models, report)
    print(f"\nDone. Open {out_dir / 'comparison.md'} to compare side by side.")


if __name__ == "__main__":
    main()
