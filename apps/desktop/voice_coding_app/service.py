from __future__ import annotations

import json
import os
from pathlib import Path
import signal
import sys
import threading
from typing import Any

from PySide6.QtCore import QObject, QCoreApplication, QTimer, Signal

from voice_coding_app.backend.controller import AppController


class CommandBridge(QObject):
    command_received = Signal(dict)


def _parse_command_line(raw_line: str) -> dict[str, Any] | None:
    line = raw_line.strip().lstrip("\ufeff").strip("\x00")
    if not line or not line.startswith("{"):
        return None
    return json.loads(line)


class ServiceRuntime(QObject):
    def __init__(self, app: QCoreApplication) -> None:
        super().__init__()
        self.app = app
        helper_mode = os.environ.get("VOICE_CODING_HELPER_MODE") == "1"
        self.controller = AppController(
            enable_toggle_shortcut=not helper_mode,
            warmup_on_boot=not helper_mode,
            text_injection_enabled=not helper_mode,
        )
        self.command_bridge = CommandBridge()
        self.command_bridge.command_received.connect(self._handle_command)
        self._stdout_lock = threading.Lock()
        self._logs: list[str] = []

        self.controller.log_emitted.connect(self._on_log)
        self.controller.status_changed.connect(self._emit_state)
        self.controller.transcript_ready.connect(self._emit_state)
        self.controller.preview_updated.connect(self._emit_preview)
        self.controller.service_state_changed.connect(self._emit_state)
        self.controller.hotkey_capture_start_requested.connect(self._on_hotkey_capture_start)
        self.controller.hotkey_capture_stop_requested.connect(self._on_hotkey_capture_stop)
        self.controller.toggle_recording_shortcut_requested.connect(self._on_toggle_recording_shortcut)

    def start(self) -> None:
        self.controller.bootstrap()
        self._emit("ready", self._snapshot())
        threading.Thread(target=self._read_commands, daemon=True, name="service-stdin").start()

    def _snapshot(self) -> dict[str, Any]:
        snapshot = self.controller.snapshot()
        snapshot["logs"] = self._logs[-250:]
        return snapshot

    def _read_commands(self) -> None:
        for raw_line in sys.stdin:
            try:
                command = _parse_command_line(raw_line)
            except json.JSONDecodeError as exc:
                self._emit("error", {"message": f"无法解析命令：{exc}"})
                continue
            if command is None:
                continue
            self.command_bridge.command_received.emit(command)

        QTimer.singleShot(0, self.app.quit)

    def _handle_command(self, command: dict[str, Any]) -> None:
        command_type = command.get("type")
        payload = command.get("payload", {})

        try:
            if command_type == "snapshot":
                self._emit("state", self._snapshot())
            elif command_type == "start":
                self.controller.start_service()
                self._emit("ack", {"type": command_type})
            elif command_type == "stop":
                self.controller.stop_service()
                self._emit("ack", {"type": command_type})
            elif command_type == "warmup":
                self.controller.warmup_model()
                self._emit("ack", {"type": command_type})
            elif command_type == "unload_model":
                self.controller.unload_model()
                self._emit("ack", {"type": command_type})
            elif command_type == "record_start":
                raw_target = str(payload.get("target_app_name", "")).strip()
                started = self.controller.start_manual_recording(raw_target or None)
                if started:
                    self._emit("ack", {"type": command_type})
                else:
                    self._emit("error", {"message": "录音没有成功启动。", "type": command_type})
            elif command_type == "record_stop":
                raw_target = str(payload.get("target_app_name", "")).strip()
                self.controller.set_pending_target_app(raw_target or None)
                stopped = self.controller.stop_manual_recording()
                if not stopped:
                    self._emit("error", {"message": "当前没有正在进行的录音。", "type": command_type})
                    return
                self._emit("ack", {"type": command_type})
            elif command_type == "transcribe_audio":
                raw_target = str(payload.get("target_app_name", "")).strip()
                audio_file_path = str(payload.get("audio_file_path", "")).strip()
                if audio_file_path:
                    audio_path = Path(audio_file_path)
                    try:
                        self.controller.transcribe_external_audio_bytes(
                            raw_bytes=audio_path.read_bytes(),
                            sample_rate=int(payload.get("sample_rate", self.controller.config.sample_rate)),
                            channels=int(payload.get("channels", self.controller.config.channels)),
                            duration_seconds=float(payload.get("duration_seconds", 0)),
                            target_app_name=raw_target or None,
                        )
                    finally:
                        audio_path.unlink(missing_ok=True)
                else:
                    self.controller.transcribe_external_audio(
                        pcm_base64=str(payload.get("pcm_base64", "")),
                        sample_rate=int(payload.get("sample_rate", self.controller.config.sample_rate)),
                        channels=int(payload.get("channels", self.controller.config.channels)),
                        duration_seconds=float(payload.get("duration_seconds", 0)),
                        target_app_name=raw_target or None,
                        )
                self._emit("ack", {"type": command_type})
            elif command_type == "preview_audio":
                audio_file_path = str(payload.get("audio_file_path", "")).strip()
                if not audio_file_path:
                    self._emit("error", {"message": "缺少 preview_audio 的音频文件路径。", "type": command_type})
                    return
                audio_path = Path(audio_file_path)
                try:
                    self.controller.preview_external_audio_bytes(
                        raw_bytes=audio_path.read_bytes(),
                        sample_rate=int(payload.get("sample_rate", self.controller.config.sample_rate)),
                        channels=int(payload.get("channels", self.controller.config.channels)),
                        duration_seconds=float(payload.get("duration_seconds", 0)),
                        session_id=int(payload.get("session_id", 0)),
                    )
                finally:
                    audio_path.unlink(missing_ok=True)
                self._emit("ack", {"type": command_type})
            elif command_type == "save_settings":
                self.controller.save_settings(
                    hotkey=payload.get("hotkey", self.controller.config.hotkey),
                    paste_mode=payload.get("paste_mode", self.controller.config.paste_mode),
                    paste_delay_ms=int(payload.get("paste_delay_ms", self.controller.config.paste_delay_ms)),
                    hotwords_text=payload.get("hotwords_text", "\n".join(self.controller.hotwords)),
                )
                self._emit("ack", {"type": command_type})
                self._emit("state", self._snapshot())
            elif command_type == "shutdown":
                self.controller.shutdown()
                self._emit("ack", {"type": command_type})
                QTimer.singleShot(0, self.app.quit)
            else:
                self._emit("error", {"message": f"未知命令：{command_type}"})
        except Exception as exc:  # pragma: no cover - runtime integration path
            self._emit("error", {"message": str(exc), "type": command_type})

    def _on_log(self, message: str) -> None:
        self._logs.append(message)
        self._emit("state", self._snapshot())

    def _emit_state(self, *_args: Any) -> None:
        self._emit("state", self._snapshot())

    def _emit_preview(self, text: str, session_id: int) -> None:
        self._emit("preview", {"text": text, "sessionId": session_id})

    def _on_hotkey_capture_start(self) -> None:
        self._emit("hotkey_record_start", {})

    def _on_hotkey_capture_stop(self) -> None:
        self._emit("hotkey_record_stop", {})

    def _on_toggle_recording_shortcut(self) -> None:
        self._emit("toggle_recording_shortcut", {})

    def _emit(self, event_type: str, payload: dict[str, Any]) -> None:
        packet = json.dumps({"type": event_type, "payload": payload}, ensure_ascii=False)
        with self._stdout_lock:
            print(packet, flush=True)


def _install_signal_handlers(app: QCoreApplication, runtime: ServiceRuntime) -> None:
    def _handle_termination(_signum: int, _frame: Any) -> None:
        runtime.controller.shutdown()
        app.quit()

    signal.signal(signal.SIGTERM, _handle_termination)
    signal.signal(signal.SIGINT, _handle_termination)


def main() -> int:
    app = QCoreApplication(sys.argv)
    runtime = ServiceRuntime(app)
    _install_signal_handlers(app, runtime)
    runtime.start()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
