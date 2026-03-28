from __future__ import annotations

from dataclasses import asdict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import base64
import threading
import traceback
from typing import TYPE_CHECKING

from PySide6.QtCore import QObject, QTimer, Signal, Slot

from voice_coding_app.backend.audio_types import RecordedAudio
from voice_coding_app.backend.config import AppConfig, ensure_defaults, load_config, load_hotwords, save_config, save_hotwords
from voice_coding_app.backend.hotkeys import HoldHotkeyListener, ModifierTapListener, parse_hotkey
from voice_coding_app.backend.paths import get_app_paths

if TYPE_CHECKING:
    from voice_coding_app.backend.audio import QtAudioRecorder
    from voice_coding_app.backend.injector import TextInjector
    from voice_coding_app.backend.transcriber import SenseVoiceTranscriber


class AppController(QObject):
    log_emitted = Signal(str)
    status_changed = Signal(str)
    transcript_ready = Signal(str)
    preview_updated = Signal(str, int)
    service_state_changed = Signal(bool)
    hotkey_capture_start_requested = Signal()
    hotkey_capture_stop_requested = Signal()
    request_start_recording = Signal()
    request_stop_recording = Signal()
    toggle_recording_shortcut_requested = Signal()

    def __init__(
        self,
        *,
        enable_toggle_shortcut: bool = True,
        warmup_on_boot: bool = True,
        text_injection_enabled: bool = True,
    ) -> None:
        super().__init__()
        self.paths = get_app_paths()
        ensure_defaults(self.paths)
        self.config = load_config(self.paths)
        self.hotwords = load_hotwords(self.paths)
        self.recorder: QtAudioRecorder | None = None
        self.injector: TextInjector | None = None
        self.transcriber: SenseVoiceTranscriber | None = None
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="voice-coding")
        self.preview_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="voice-coding-preview")
        self._hotkey_listener: HoldHotkeyListener | None = None
        self._toggle_recording_listener: ModifierTapListener | None = None
        self._service_running = False
        self._status = "启动中"
        self._last_transcript = ""
        self._transcript_revision = 0
        self._warmup_requested = False
        self._external_capture_active = False
        self._pending_target_app_name: str | None = None
        self._preview_lock = threading.Lock()
        self._pending_preview_request: tuple[RecordedAudio, int] | None = None
        self._preview_worker_active = False
        self._enable_toggle_shortcut = enable_toggle_shortcut
        self._warmup_on_boot = warmup_on_boot
        self._text_injection_enabled = text_injection_enabled

        self.request_start_recording.connect(self._start_recording)
        self.request_stop_recording.connect(self._stop_recording)

    @property
    def is_service_running(self) -> bool:
        return self._service_running

    @property
    def status(self) -> str:
        return self._status

    @property
    def last_transcript(self) -> str:
        return self._last_transcript

    def bootstrap(self) -> None:
        self._log(f"工作目录：{self.paths.root}")
        self._log("依赖管理：uv")
        self._log(f"模型仓库：{self.config.repo_id}")
        if self.config.auto_start_listening:
            QTimer.singleShot(0, self.start_service)
        else:
            self._set_status(self._idle_status())
        if self._enable_toggle_shortcut:
            QTimer.singleShot(0, self._ensure_toggle_recording_listener)
        if self._warmup_on_boot:
            QTimer.singleShot(0, self.warmup_model)
            self._log("应用启动后会自动装载识别模型，可通过菜单栏手动卸载。")
        else:
            self._log("当前运行在 helper 模式，识别模型将按需装载。")

    def start_service(self) -> None:
        if self._service_running:
            return
        self._restart_listener()
        self._service_running = True
        self._set_status("监听中")
        self.service_state_changed.emit(True)
        self._log(f"全局热键已启动：{self.config.hotkey}")

    def stop_service(self) -> None:
        if not self._service_running:
            return
        if self._hotkey_listener is not None:
            self._hotkey_listener.stop()
            self._hotkey_listener = None
        if self.recorder is not None and self.recorder.is_recording:
            self.recorder.stop()
        self._service_running = False
        self._set_status("已停止")
        self.service_state_changed.emit(False)
        self._log("全局监听已停止。")

    def warmup_model(self) -> None:
        if self._is_model_ready():
            self._log("识别模型已经装载。")
            self._set_status(self._idle_status())
            return
        if self._warmup_requested:
            self._log("识别模型正在装载中。")
            return
        self._warmup_requested = True
        self._log("开始装载识别模型。")
        self._set_status("模型预热中")
        self.executor.submit(self._warmup_task)

    def unload_model(self) -> None:
        if self._warmup_requested and not self._is_model_ready():
            self._log("识别模型正在装载中，请稍后再卸载。")
            return
        if not self._is_model_ready():
            self._log("识别模型当前未加载。")
            self._set_status(self._idle_status())
            return
        self._log("开始卸载识别模型。")
        self._set_status("卸载模型中")
        self.executor.submit(self._unload_model_task)

    def start_manual_recording(self, target_app_name: str | None = None) -> bool:
        self._pending_target_app_name = target_app_name
        return self._begin_recording(allow_without_listener=True)

    def stop_manual_recording(self) -> bool:
        return self._finish_recording()

    def set_pending_target_app(self, target_app_name: str | None) -> None:
        self._pending_target_app_name = target_app_name

    def transcribe_external_audio(
        self,
        pcm_base64: str,
        sample_rate: int,
        channels: int,
        duration_seconds: float,
        target_app_name: str | None = None,
    ) -> None:
        raw_bytes = base64.b64decode(pcm_base64.encode("ascii"))
        self.transcribe_external_audio_bytes(
            raw_bytes=raw_bytes,
            sample_rate=sample_rate,
            channels=channels,
            duration_seconds=duration_seconds,
            target_app_name=target_app_name,
        )

    def transcribe_external_audio_bytes(
        self,
        raw_bytes: bytes,
        sample_rate: int,
        channels: int,
        duration_seconds: float,
        target_app_name: str | None = None,
    ) -> None:
        if target_app_name:
            self._pending_target_app_name = target_app_name
        self._external_capture_active = False
        self._handle_recorded_audio(
            RecordedAudio(
                raw_bytes=raw_bytes,
                sample_rate=sample_rate,
                channels=channels,
                duration_seconds=duration_seconds,
            ),
        )

    def preview_external_audio_bytes(
        self,
        raw_bytes: bytes,
        sample_rate: int,
        channels: int,
        duration_seconds: float,
        session_id: int,
    ) -> None:
        if not raw_bytes or duration_seconds < self.config.min_audio_seconds:
            return

        request = (
            RecordedAudio(
                raw_bytes=raw_bytes,
                sample_rate=sample_rate,
                channels=channels,
                duration_seconds=duration_seconds,
            ),
            session_id,
        )

        should_schedule_worker = False
        with self._preview_lock:
            self._pending_preview_request = request
            if not self._preview_worker_active:
                self._preview_worker_active = True
                should_schedule_worker = True

        if should_schedule_worker:
            self.preview_executor.submit(self._preview_loop_task)

    def mark_external_capture_started(self, target_app_name: str | None = None) -> None:
        if self._external_capture_active:
            return
        self._external_capture_active = True
        self._pending_target_app_name = target_app_name
        self._set_status("录音中")
        self._log("开始录音。")

    def mark_external_capture_finished(self) -> None:
        if not self._external_capture_active:
            return
        self._external_capture_active = False
        self._set_status(self._idle_status())

    def save_settings(
        self,
        hotkey: str,
        paste_mode: str,
        paste_delay_ms: int,
        hotwords_text: str,
    ) -> None:
        parse_hotkey(hotkey)
        self.config.hotkey = hotkey
        self.config.paste_mode = paste_mode
        self.config.paste_delay_ms = paste_delay_ms
        self.hotwords = [line.strip() for line in hotwords_text.splitlines() if line.strip()]
        save_config(self.config, self.paths)
        save_hotwords(self.hotwords, self.paths)
        if self.recorder is not None and self.recorder.is_recording:
            self.recorder.stop()
        self.recorder = None
        self.injector = None
        self.transcriber = None
        if self._service_running:
            self._restart_listener()
        self._log("设置已保存并应用。")

    def snapshot(self) -> dict:
        return {
            "status": self._status,
            "isServiceRunning": self._service_running,
            "isRecording": (self.recorder.is_recording if self.recorder is not None else False)
            or self._external_capture_active,
            "lastTranscript": self._last_transcript,
            "transcriptRevision": self._transcript_revision,
            "modelReady": self._is_model_ready(),
            "config": asdict(self.config),
            "hotwords": list(self.hotwords),
            "pendingTargetAppName": self._pending_target_app_name,
        }

    def shutdown(self) -> None:
        self.stop_service()
        if self._toggle_recording_listener is not None:
            self._toggle_recording_listener.stop()
            self._toggle_recording_listener = None
        self.executor.shutdown(wait=False, cancel_futures=True)
        self.preview_executor.shutdown(wait=False, cancel_futures=True)

    def _restart_listener(self) -> None:
        if self._hotkey_listener is not None:
            self._hotkey_listener.stop()
        self._hotkey_listener = HoldHotkeyListener(
            expression=self.config.hotkey,
            on_start=self.hotkey_capture_start_requested.emit,
            on_stop=self.hotkey_capture_stop_requested.emit,
        )
        self._hotkey_listener.start()

    def _ensure_toggle_recording_listener(self) -> None:
        if self._toggle_recording_listener is not None:
            return
        toggle_key = self.config.toggle_record_key.strip().lower()
        if not toggle_key:
            return
        listener = ModifierTapListener(
            modifier=toggle_key,
            on_tap=self.toggle_recording_shortcut_requested.emit,
        )
        try:
            listener.start()
        except Exception as exc:
            self._log(f"{toggle_key.title()} 单击快捷键启动失败：{exc}")
            return
        self._toggle_recording_listener = listener
        self._log(
            f"{toggle_key.title()} 单击快捷键已启用（{listener.backend_name}）。"
        )

    def _warmup_task(self) -> None:
        try:
            self._ensure_transcriber().ensure_ready(self._log)
        except Exception as exc:  # pragma: no cover - runtime integration path
            self._warmup_requested = False
            self._set_status("模型异常")
            self._log_exception(f"模型初始化失败：{exc}")
            return
        self._warmup_requested = False
        self._set_status(self._idle_status())

    def _unload_model_task(self) -> None:
        try:
            transcriber = self.transcriber
            unloaded = False if transcriber is None else transcriber.unload(self._log)
        except Exception as exc:  # pragma: no cover - runtime integration path
            self._warmup_requested = False
            self._set_status("模型异常")
            self._log_exception(f"模型卸载失败：{exc}")
            return
        self._warmup_requested = False
        self._set_status(self._idle_status())
        if not unloaded:
            self._log("识别模型当前未加载。")

    @Slot()
    def _start_recording(self) -> None:
        self._begin_recording(allow_without_listener=False)

    def _begin_recording(self, allow_without_listener: bool) -> bool:
        recorder = self._ensure_recorder()
        if recorder.is_recording:
            return True
        if not allow_without_listener and not self._service_running:
            return False
        try:
            recorder.start()
        except Exception as exc:
            self._set_status("录音失败")
            self._log(f"录音启动失败：{exc}")
            return False
        self._set_status("录音中")
        self._log("开始录音。")
        return True

    @Slot()
    def _stop_recording(self) -> None:
        self._finish_recording()

    def _finish_recording(self) -> bool:
        recorder = self.recorder
        if recorder is None or not recorder.is_recording:
            return False
        audio = recorder.stop()
        if audio is None:
            return False
        self._handle_recorded_audio(audio)
        return True

    def _handle_recorded_audio(self, audio: RecordedAudio) -> None:
        self._log(
            f"录音完成：{audio.duration_seconds:.2f}s，{len(audio.raw_bytes)} bytes。"
        )
        if not audio.raw_bytes:
            self._pending_target_app_name = None
            self._set_status(self._idle_status())
            self._log("麦克风没有返回有效音频数据，请检查系统输入设备、麦克风权限或采样设备。")
            return
        if audio.duration_seconds < self.config.min_audio_seconds:
            self._pending_target_app_name = None
            self._set_status(self._idle_status())
            self._log("录音时间过短，已忽略。")
            return
        self._set_status("识别中")
        self._log("录音结束，开始识别。")
        self.executor.submit(self._transcribe_task, audio)

    def _transcribe_task(self, audio) -> None:
        target_app_name = self._pending_target_app_name
        try:
            text = self._ensure_transcriber().transcribe(audio, self.hotwords, self._log)
        except Exception as exc:  # pragma: no cover - runtime integration path
            self._pending_target_app_name = None
            self._set_status("识别失败")
            self._log_exception(f"识别失败：{exc}")
            return

        if not text:
            self._pending_target_app_name = None
            self._set_status(self._idle_status())
            self._log("本次没有识别出有效文本。")
            return

        self._last_transcript = text
        self._transcript_revision += 1
        self.transcript_ready.emit(text)
        self._log(f"识别结果：{text}")
        self._pending_target_app_name = None
        if not self._text_injection_enabled:
            self._set_status(self._idle_status())
            self._log("识别完成，等待原生端注入。")
            return
        try:
            self._ensure_injector().insert_text(text, target_app_name=target_app_name)
        except Exception as exc:  # pragma: no cover - runtime integration path
            self._log(f"文本注入失败：{exc}")
            self._set_status(self._idle_status())
            return
        self._set_status(self._idle_status())
        self._log("结果已写入当前输入框。")

    def _preview_loop_task(self) -> None:
        silent_log = lambda _message: None

        while True:
            with self._preview_lock:
                request = self._pending_preview_request
                self._pending_preview_request = None
                if request is None:
                    self._preview_worker_active = False
                    return

            audio, session_id = request
            try:
                text = self._ensure_transcriber().transcribe(audio, self.hotwords, silent_log)
            except Exception as exc:  # pragma: no cover - runtime integration path
                self._log(f"实时预览失败：{exc}")
                continue

            self.preview_updated.emit(text, session_id)

    def _set_status(self, status: str) -> None:
        self._status = status
        self.status_changed.emit(status)

    def _log(self, message: str) -> None:
        timestamp = datetime.now().strftime("%H:%M:%S")
        self.log_emitted.emit(f"[{timestamp}] {message}")

    def _log_exception(self, message: str) -> None:
        self._log(message)
        for line in traceback.format_exc().strip().splitlines():
            self._log(f"TRACE {line}")

    def _idle_status(self) -> str:
        return "监听中" if self._service_running else "待命"

    def _ensure_recorder(self) -> QtAudioRecorder:
        if self.recorder is None:
            from voice_coding_app.backend.audio import QtAudioRecorder

            self.recorder = QtAudioRecorder(self.config.sample_rate, self.config.channels)
        return self.recorder

    def _ensure_injector(self) -> TextInjector:
        if self.injector is None:
            from voice_coding_app.backend.injector import TextInjector

            self.injector = TextInjector(self.config.paste_mode, self.config.paste_delay_ms)
        return self.injector

    def _ensure_transcriber(self) -> SenseVoiceTranscriber:
        if self.transcriber is None:
            from voice_coding_app.backend.transcriber import SenseVoiceTranscriber

            self.transcriber = SenseVoiceTranscriber(self.config, self.paths)
        return self.transcriber

    def _is_model_ready(self) -> bool:
        return self.transcriber.is_ready if self.transcriber is not None else False
