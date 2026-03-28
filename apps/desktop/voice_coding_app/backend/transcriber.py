from __future__ import annotations

import gc
from importlib import import_module
import os
import sys
import threading
from typing import Callable
from pathlib import Path

import numpy as np
from funasr import AutoModel
from funasr.utils.postprocess_utils import rich_transcription_postprocess
from huggingface_hub import snapshot_download

from voice_coding_app.backend.audio_types import RecordedAudio
from voice_coding_app.backend.config import AppConfig
from voice_coding_app.backend.paths import AppPaths
from voice_coding_app.backend.text_processing import apply_hotword_corrections


class SenseVoiceTranscriber:
    def __init__(self, config: AppConfig, paths: AppPaths) -> None:
        self.config = config
        self.paths = paths
        self.model_dir = self._resolve_model_dir()
        self._model: AutoModel | None = None
        self._init_lock = threading.Lock()
        self._infer_lock = threading.Lock()

    def _resolve_model_dir(self) -> Path:
        bundled_models_root = os.environ.get("VOICE_CODING_BUNDLED_MODELS_DIR", "").strip()
        if bundled_models_root:
            bundled_model_dir = Path(bundled_models_root).expanduser().resolve() / self.config.model_dirname
            if self._has_required_model_files(bundled_model_dir):
                return bundled_model_dir

        return self.paths.models_dir / self.config.model_dirname

    @property
    def is_ready(self) -> bool:
        return self._model is not None

    def _has_required_model_files(self, directory: Path) -> bool:
        required_files = ["model.pt", "config.yaml", "am.mvn", "chn_jpn_yue_eng_ko_spectok.bpe.model"]
        return all((directory / filename).exists() for filename in required_files)

    def _has_local_model(self) -> bool:
        return self._has_required_model_files(self.model_dir)

    def _prime_registry(self, log: Callable[[str], None]) -> None:
        # FunASR's model registry relies on import side effects. In the packaged
        # runtime these modules are available but are not always imported before
        # AutoModel tries to resolve `SenseVoiceSmall`.
        module_names = (
            "funasr.models.specaug.specaug",
            "funasr.frontends.wav_frontend",
            "funasr.tokenizer.sentencepiece_tokenizer",
            "funasr.models.normalize.global_mvn",
            "funasr.models.normalize.utterance_mvn",
            "funasr.models.sense_voice.model",
        )
        register_module = None
        original_getfile = None
        original_getsourcelines = None
        try:
            register_module = import_module("funasr.register")
            original_getfile = register_module.inspect.getfile
            original_getsourcelines = register_module.inspect.getsourcelines

            def _safe_getfile(target):
                try:
                    return original_getfile(target)
                except Exception:
                    module = sys.modules.get(getattr(target, "__module__", ""))
                    return getattr(module, "__file__", "funasr/frozen.py")

            def _safe_getsourcelines(target):
                try:
                    return original_getsourcelines(target)
                except Exception:
                    return ([""], 0)

            register_module.inspect.getfile = _safe_getfile
            register_module.inspect.getsourcelines = _safe_getsourcelines
            for module_name in module_names:
                sys.modules.pop(module_name, None)
                import_module(module_name)
        except Exception as exc:  # pragma: no cover - runtime integration path
            log(f"预加载 SenseVoice 注册表失败：{exc}")
        finally:
            if register_module is not None and original_getfile is not None:
                register_module.inspect.getfile = original_getfile
            if register_module is not None and original_getsourcelines is not None:
                register_module.inspect.getsourcelines = original_getsourcelines

    def ensure_ready(self, log: Callable[[str], None]) -> Path:
        if self._model is not None:
            return self.model_dir

        with self._init_lock:
            if self._model is not None:
                return self.model_dir

            if self._has_local_model():
                log(f"检测到本地 SenseVoice 模型，跳过网络下载：{self.model_dir}")
            else:
                log("本地未检测到完整模型，开始从 Hugging Face 下载 SenseVoice...")
                snapshot_download(
                    repo_id=self.config.repo_id,
                    local_dir=str(self.model_dir),
                )
                log(f"模型已下载到 {self.model_dir}")
            self._prime_registry(log)
            log("正在初始化本地识别引擎...")
            self._model = AutoModel(
                model=str(self.model_dir),
                hub="hf",
                device="cpu",
                disable_update=True,
            )
            log("识别引擎已就绪。")

        return self.model_dir

    def unload(self, log: Callable[[str], None]) -> bool:
        with self._init_lock:
            if self._model is None:
                return False
            with self._infer_lock:
                self._model = None
        gc.collect()
        log("识别模型已卸载。")
        return True

    def transcribe(
        self,
        audio: RecordedAudio,
        hotwords: list[str],
        log: Callable[[str], None],
    ) -> str:
        self.ensure_ready(log)
        with self._init_lock:
            model = self._model
        assert model is not None

        waveform = np.frombuffer(audio.raw_bytes, dtype=np.int16).astype(np.float32) / 32768.0
        min_samples = int(self.config.sample_rate * self.config.min_audio_seconds)
        if waveform.size == 0:
            log("没有采集到任何有效音频帧。")
            return ""
        if waveform.size < min_samples:
            log(f"录音样本过短：{waveform.size} 个采样点，已忽略。")
            return ""
        if float(np.max(np.abs(waveform))) < 1e-5:
            log("录音几乎是静音，已忽略本次识别。")
            return ""

        # Pass the waveform directly to FunASR so runtime does not depend on
        # torchcodec or a system ffmpeg binary for file decoding.
        with self._infer_lock:
            result = model.generate(
                input=waveform,
                cache={},
                language=self.config.language,
                use_itn=self.config.use_itn,
            )
        payload = result[0].get("text", "") if isinstance(result, list) and result else result
        cleaned = rich_transcription_postprocess(payload).strip()
        return apply_hotword_corrections(cleaned, hotwords)
