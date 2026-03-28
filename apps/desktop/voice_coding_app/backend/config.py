from __future__ import annotations

from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable

import yaml

from voice_coding_app.backend.paths import AppPaths, get_app_paths

DEFAULT_HOTWORDS = [
    "TypeScript",
    "JavaScript",
    "React",
    "useState",
    "useEffect",
    "useMemo",
    "useCallback",
    "useRef",
    "useContext",
    "useDebounce",
    "Next.js",
    "TailwindCSS",
    "Cursor",
    "Claude",
    "Ollama",
]


@dataclass
class AppConfig:
    hotkey: str = "cmd+shift+space"
    toggle_record_key: str = ""
    paste_mode: str = "clipboard"
    paste_delay_ms: int = 180
    language: str = "auto"
    use_itn: bool = True
    quantize: bool = True
    repo_id: str = "FunAudioLLM/SenseVoiceSmall"
    model_dirname: str = "SenseVoiceSmall"
    sample_rate: int = 16000
    channels: int = 1
    min_audio_seconds: float = 0.2
    max_audio_seconds: int = 90
    auto_start_listening: bool = False


def _config_path(paths: AppPaths) -> Path:
    return paths.config_dir / "app.yaml"


def _hotwords_path(paths: AppPaths) -> Path:
    return paths.config_dir / "hotwords.txt"


def ensure_defaults(paths: AppPaths | None = None) -> None:
    paths = paths or get_app_paths()
    config_path = _config_path(paths)
    hotwords_path = _hotwords_path(paths)

    if not config_path.exists():
        save_config(AppConfig(), paths)
    if not hotwords_path.exists():
        save_hotwords(DEFAULT_HOTWORDS, paths)


def load_config(paths: AppPaths | None = None) -> AppConfig:
    paths = paths or get_app_paths()
    ensure_defaults(paths)
    with _config_path(paths).open("r", encoding="utf-8") as handle:
        raw = yaml.safe_load(handle) or {}
    raw["toggle_record_key"] = str(raw.get("toggle_record_key", "")).strip().lower()
    return AppConfig(**raw)


def save_config(config: AppConfig, paths: AppPaths | None = None) -> None:
    paths = paths or get_app_paths()
    with _config_path(paths).open("w", encoding="utf-8") as handle:
        yaml.safe_dump(asdict(config), handle, allow_unicode=True, sort_keys=False)


def load_hotwords(paths: AppPaths | None = None) -> list[str]:
    paths = paths or get_app_paths()
    ensure_defaults(paths)
    lines = _hotwords_path(paths).read_text(encoding="utf-8").splitlines()
    return [line.strip() for line in lines if line.strip()]


def save_hotwords(hotwords: Iterable[str], paths: AppPaths | None = None) -> None:
    paths = paths or get_app_paths()
    normalized = []
    for term in hotwords:
        clean = term.strip()
        if clean and clean not in normalized:
            normalized.append(clean)
    _hotwords_path(paths).write_text("\n".join(normalized) + "\n", encoding="utf-8")
