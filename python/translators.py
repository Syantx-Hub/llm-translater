"""Machine-translation engines shared by eval.py and translate_server.py.

Every engine takes the language pair per call, so one loaded model serves any pair.
"""

from __future__ import annotations

import gc

MADLAD_ID = "google/madlad400-3b-mt"

# Whisper / MADLAD code -> (name, NLLB code). MADLAD's target prefix is "<2{code}>".
LANGS = {
    "my": ("Burmese", "mya_Mymr"),
    "en": ("English", "eng_Latn"),
    "ko": ("Korean", "kor_Hang"),
    "ja": ("Japanese", "jpn_Jpan"),
    "zh": ("Chinese", "zho_Hans"),
    "th": ("Thai", "tha_Thai"),
    "vi": ("Vietnamese", "vie_Latn"),
    "id": ("Indonesian", "ind_Latn"),
    "ms": ("Malay", "zsm_Latn"),
    "hi": ("Hindi", "hin_Deva"),
    "fr": ("French", "fra_Latn"),
    "es": ("Spanish", "spa_Latn"),
    "de": ("German", "deu_Latn"),
    "pt": ("Portuguese", "por_Latn"),
    "ru": ("Russian", "rus_Cyrl"),
    "ar": ("Arabic", "arb_Arab"),
}


def free_memory():
    gc.collect()
    try:
        import mlx.core as mx

        mx.clear_cache()
    except (ImportError, AttributeError):
        pass
    try:
        import torch

        if torch.backends.mps.is_available():
            torch.mps.empty_cache()
    except ImportError:
        pass


def torch_device():
    import torch

    return "mps" if torch.backends.mps.is_available() else "cpu"


class NLLB:
    """facebook/nllb-200 — CC-BY-NC, portfolio use only."""

    name = "nllb"

    def __init__(self, model_id: str = "facebook/nllb-200-distilled-600M"):
        import torch
        from transformers import AutoModelForSeq2SeqLM, AutoTokenizer

        self.torch = torch
        self.device = torch_device()
        self.tok = AutoTokenizer.from_pretrained(model_id)
        self.model = AutoModelForSeq2SeqLM.from_pretrained(model_id).to(self.device).eval()

    def translate(self, text: str, src: str, tgt: str) -> str:
        self.tok.src_lang = LANGS[src][1]
        batch = self.tok(text, return_tensors="pt").to(self.device)
        bos = self.tok.convert_tokens_to_ids(LANGS[tgt][1])
        with self.torch.inference_mode():
            out = self.model.generate(
                **batch, forced_bos_token_id=bos, num_beams=4, max_new_tokens=256
            )
        return self.tok.decode(out[0], skip_special_tokens=True)


class MadladHF:
    """google/madlad400-3b-mt via transformers on Metal — Apache 2.0.

    ~6 GB in bf16, so only practical on Macs with 16 GB or more. Otherwise use MadladCT2.
    """

    name = "madlad"

    def __init__(self):
        import torch
        from transformers import AutoModelForSeq2SeqLM, AutoTokenizer

        self.torch = torch
        self.device = torch_device()
        self.tok = AutoTokenizer.from_pretrained(MADLAD_ID)
        # T5-family models overflow in fp16; bf16 is safe.
        self.model = (
            AutoModelForSeq2SeqLM.from_pretrained(MADLAD_ID, dtype=torch.bfloat16)
            .to(self.device)
            .eval()
        )

    def translate(self, text: str, src: str, tgt: str) -> str:
        # MADLAD picks the target from the "<2xx>" prefix; the source is auto-detected.
        batch = self.tok(f"<2{tgt}> {text}", return_tensors="pt").to(self.device)
        with self.torch.inference_mode():
            out = self.model.generate(**batch, num_beams=4, max_new_tokens=256)
        return self.tok.decode(out[0], skip_special_tokens=True)


class MadladCT2:
    """MADLAD-400 converted to CTranslate2 int8 (~3 GB) — see README for conversion."""

    name = "madlad"

    def __init__(self, path: str):
        import ctranslate2
        from transformers import AutoTokenizer

        self.translator = ctranslate2.Translator(path, device="cpu", compute_type="int8")
        self.tok = AutoTokenizer.from_pretrained(MADLAD_ID)

    def translate(self, text: str, src: str, tgt: str) -> str:
        tokens = self.tok.convert_ids_to_tokens(self.tok.encode(f"<2{tgt}> {text}"))
        result = self.translator.translate_batch([tokens], beam_size=4, max_decoding_length=256)
        ids = self.tok.convert_tokens_to_ids(result[0].hypotheses[0])
        return self.tok.decode(ids, skip_special_tokens=True)


class Echo:
    """Returns the input unchanged — for testing the app pipeline without any model."""

    name = "echo"

    def translate(self, text: str, src: str, tgt: str) -> str:
        return text


def build_translator(name: str, *, nllb_model: str, madlad_ct2: str | None, ram_gb: float):
    if name == "nllb":
        return NLLB(nllb_model)
    if name == "madlad":
        if madlad_ct2:
            return MadladCT2(madlad_ct2)
        if ram_gb < 16:
            print(f"  warning: MADLAD bf16 needs ~6 GB; with {ram_gb:.0f} GB it will swap. "
                  "Use --madlad-ct2 (see README).")
        return MadladHF()
    if name == "echo":
        return Echo()
    raise ValueError(f"unknown model: {name}")
