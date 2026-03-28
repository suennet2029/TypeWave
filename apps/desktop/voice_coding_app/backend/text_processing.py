from __future__ import annotations

import re


def _split_hotword(term: str) -> list[str]:
    expanded = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", term)
    expanded = re.sub(r"[._-]+", " ", expanded)
    expanded = re.sub(r"\s+", " ", expanded)
    return [chunk for chunk in expanded.lower().strip().split(" ") if chunk]


def hotword_variants(term: str) -> set[str]:
    parts = _split_hotword(term)
    if not parts:
        return set()

    spaced = " ".join(parts)
    collapsed = "".join(parts)
    return {term.lower(), spaced, collapsed}


def apply_hotword_corrections(text: str, hotwords: list[str]) -> str:
    corrected = text
    for hotword in sorted(hotwords, key=len, reverse=True):
        variants = hotword_variants(hotword)
        for variant in variants:
            if not variant:
                continue
            pattern = re.compile(rf"(?<!\w){re.escape(variant)}(?!\w)", re.IGNORECASE)
            corrected = pattern.sub(hotword, corrected)
    return corrected

