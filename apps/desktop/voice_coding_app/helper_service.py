from __future__ import annotations

import json
import signal
import sys
import threading
from pathlib import Path
from typing import TYPE_CHECKING, Any

from voice_coding_app.backend.audio_types import RecordedAudio
from voice_coding_app.backend.config import AppConfig, DEFAULT_HOTWORDS, ensure_defaults
from voice_coding_app.backend.paths import get_app_paths

if TYPE_CHECKING:
    from voice_coding_app.backend.transcriber import SenseVoiceTranscriber


def _parse_command_line(raw_line: str) -> dict[str, Any] | None:
    line = raw_line.strip().lstrip("\ufeff").strip("\x00")
    if not line or not line.startswith("{"):
        return None
    return json.loads(line)


def _as_bool(value: Any, default: bool) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return default
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"true", "1", "yes", "on"}:
            return True
        if normalized in {"false", "0", "no", "off"}:
            return False
    return bool(value)


class HelperRuntime:
    def __init__(self) -> None:
        self.paths = get_app_paths()
        ensure_defaults(self.paths)
        self._stdout_lock = threading.Lock()
        self._logs: list[str] = []
        self._status = "待命"
        self._last_transcript = ""
        self._transcript_revision = 0
        self._transcriber: SenseVoiceTranscriber | None = None
        self._model_key: tuple[str, str] | None = None

    def start(self) -> int:
        self._emit("ready", self._snapshot())

        for raw_line in sys.stdin:
            try:
                command = _parse_command_line(raw_line)
            except json.JSONDecodeError as exc:
                self._emit("error", {"message": f"无法解析命令：{exc}"})
                continue

            if command is None:
                continue

            self._handle_command(command)

        return 0

    def shutdown(self) -> None:
        if self._transcriber is not None:
            try:
                self._transcriber.unload(self._log)
            except Exception:
                pass

    def _snapshot(self) -> dict[str, Any]:
        return {
            "status": self._status,
            "modelReady": self._transcriber.is_ready if self._transcriber is not None else False,
            "lastTranscript": self._last_transcript,
            "transcriptRevision": self._transcript_revision,
            "logs": self._logs[-250:],
        }

    def _config_from_payload(self, payload: dict[str, Any]) -> AppConfig:
        return AppConfig(
            hotkey="option+r",
            toggle_record_key="",
            paste_mode="clipboard",
            paste_delay_ms=180,
            language=str(payload.get("language", "auto")),
            use_itn=_as_bool(payload.get("use_itn"), True),
            quantize=True,
            repo_id=str(payload.get("repo_id", "FunAudioLLM/SenseVoiceSmall")),
            model_dirname=str(payload.get("model_dirname", "SenseVoiceSmall")),
            sample_rate=int(payload.get("sample_rate", 16000)),
            channels=int(payload.get("channels", 1)),
            min_audio_seconds=float(payload.get("min_audio_seconds", 0.2)),
            max_audio_seconds=int(payload.get("max_audio_seconds", 90)),
            auto_start_listening=False,
        )

    def _hotwords_from_payload(self, payload: dict[str, Any]) -> list[str]:
        raw_hotwords = payload.get("hotwords")
        if isinstance(raw_hotwords, list):
            hotwords = [str(item).strip() for item in raw_hotwords if str(item).strip()]
            if hotwords:
                return hotwords
        return list(DEFAULT_HOTWORDS)

    def _ensure_transcriber(self, config: AppConfig) -> SenseVoiceTranscriber:
        from voice_coding_app.backend.transcriber import SenseVoiceTranscriber

        model_key = (config.repo_id, config.model_dirname)
        if self._transcriber is None or self._model_key != model_key:
            self._transcriber = SenseVoiceTranscriber(config, self.paths)
            self._model_key = model_key
        else:
            self._transcriber.config = config
        return self._transcriber

    def _transcribe_audio(
        self,
        payload: dict[str, Any],
        *,
        preview_session_id: int | None = None,
    ) -> str:
        audio_file_path = str(payload.get("audio_file_path", "")).strip()
        if not audio_file_path:
            raise ValueError("缺少音频文件路径。")

        audio_path = Path(audio_file_path)
        raw_bytes = audio_path.read_bytes()
        audio_path.unlink(missing_ok=True)

        config = self._config_from_payload(payload)
        hotwords = self._hotwords_from_payload(payload)
        audio = RecordedAudio(
            raw_bytes=raw_bytes,
            sample_rate=int(payload.get("sample_rate", config.sample_rate)),
            channels=int(payload.get("channels", config.channels)),
            duration_seconds=float(payload.get("duration_seconds", 0)),
        )

        transcriber = self._ensure_transcriber(config)
        log = (lambda _message: None) if preview_session_id is not None else self._log
        return transcriber.transcribe(audio, hotwords, log)

    def _handle_command(self, command: dict[str, Any]) -> None:
        command_type = command.get("type")
        payload = command.get("payload", {})

        try:
            if command_type == "warmup":
                self._status = "模型预热中"
                self._emit("state", self._snapshot())
                config = self._config_from_payload(payload)
                self._ensure_transcriber(config).ensure_ready(self._log)
                self._status = "待命"
                self._emit("ack", {"type": command_type})
                self._emit("state", self._snapshot())
            elif command_type == "unload_model":
                self._status = "卸载模型中"
                self._emit("state", self._snapshot())
                unloaded = False
                if self._transcriber is not None:
                    unloaded = self._transcriber.unload(self._log)
                if unloaded:
                    self._transcriber = None
                    self._model_key = None
                self._status = "待命"
                self._emit("ack", {"type": command_type})
                self._emit("state", self._snapshot())
            elif command_type == "transcribe_audio":
                self._status = "识别中"
                self._emit("state", self._snapshot())
                text = self._transcribe_audio(payload)
                self._last_transcript = text
                if text:
                    self._transcript_revision += 1
                    self._log(f"识别结果：{text}")
                else:
                    self._log("本次没有识别出有效文本。")
                self._status = "待命"
                self._emit("ack", {"type": command_type})
                self._emit("state", self._snapshot())
            elif command_type == "preview_audio":
                session_id = int(payload.get("session_id", 0))
                text = self._transcribe_audio(payload, preview_session_id=session_id)
                self._emit("ack", {"type": command_type})
                self._emit("preview", {"text": text, "sessionId": session_id})
            elif command_type == "shutdown":
                self.shutdown()
                self._emit("ack", {"type": command_type})
                raise SystemExit(0)
            else:
                self._emit("error", {"message": f"未知命令：{command_type}"})
        except SystemExit:
            raise
        except Exception as exc:
            self._status = "识别失败" if command_type in {"transcribe_audio", "preview_audio"} else "模型异常"
            self._emit("error", {"message": str(exc), "type": command_type})
            self._emit("state", self._snapshot())

    def _log(self, message: str) -> None:
        packet = self._snapshot()
        self._logs.append(message)
        packet["logs"] = self._logs[-250:]
        self._emit("state", packet)

    def _emit(self, event_type: str, payload: dict[str, Any]) -> None:
        packet = json.dumps({"type": event_type, "payload": payload}, ensure_ascii=False)
        with self._stdout_lock:
            print(packet, flush=True)


def main() -> int:
    runtime = HelperRuntime()

    def _handle_termination(_signum: int, _frame: Any) -> None:
        runtime.shutdown()
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, _handle_termination)
    signal.signal(signal.SIGINT, _handle_termination)

    return runtime.start()


if __name__ == "__main__":
    raise SystemExit(main())
