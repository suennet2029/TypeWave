from __future__ import annotations

import os
import sys
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path


@dataclass(frozen=True)
class AppPaths:
    root: Path
    config_dir: Path
    runtime_dir: Path
    logs_dir: Path
    temp_dir: Path
    models_dir: Path


def _resolve_root() -> Path:
    override = os.environ.get("VOICE_CODING_APP_HOME")
    if override:
        return Path(override).expanduser().resolve()

    if getattr(sys, "frozen", False):
        executable = Path(sys.executable).resolve()
        if sys.platform == "darwin" and executable.parent.name == "MacOS":
            return executable.parents[3]
        return executable.parent

    return Path(__file__).resolve().parents[4]


@lru_cache(maxsize=1)
def get_app_paths() -> AppPaths:
    root = _resolve_root()
    config_dir = root / "config"
    runtime_dir = root / "runtime"
    logs_dir = runtime_dir / "logs"
    temp_dir = runtime_dir / "tmp"
    models_dir = root / "models"

    for directory in (config_dir, runtime_dir, logs_dir, temp_dir, models_dir):
        directory.mkdir(parents=True, exist_ok=True)

    return AppPaths(
        root=root,
        config_dir=config_dir,
        runtime_dir=runtime_dir,
        logs_dir=logs_dir,
        temp_dir=temp_dir,
        models_dir=models_dir,
    )
