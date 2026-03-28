from __future__ import annotations

import time

import numpy as np
from PySide6.QtCore import QObject, Slot
from PySide6.QtMultimedia import QAudioFormat, QAudioSource, QMediaDevices

from voice_coding_app.backend.audio_types import RecordedAudio


class QtAudioRecorder(QObject):
    def __init__(self, sample_rate: int, channels: int) -> None:
        super().__init__()
        self.sample_rate = sample_rate
        self.channels = channels
        self._audio_source: QAudioSource | None = None
        self._stream = None
        self._buffer = bytearray()
        self._recording_started_at = 0.0
        self._capture_format = QAudioFormat()

    @property
    def is_recording(self) -> bool:
        return self._audio_source is not None

    @Slot()
    def start(self) -> None:
        if self.is_recording:
            return

        device = QMediaDevices.defaultAudioInput()
        if device.isNull():
            raise RuntimeError("没有检测到可用麦克风。")

        fmt = QAudioFormat()
        fmt.setSampleRate(self.sample_rate)
        fmt.setChannelCount(self.channels)
        fmt.setSampleFormat(QAudioFormat.Int16)

        preferred = device.preferredFormat()
        preferred_int16 = QAudioFormat(preferred)
        preferred_int16.setSampleFormat(QAudioFormat.Int16)
        if preferred_int16.sampleRate() > 0 and preferred_int16.channelCount() > 0 and device.isFormatSupported(preferred_int16):
            fmt = preferred_int16
        elif not device.isFormatSupported(fmt):
            fmt = preferred
        self._capture_format = fmt

        self._buffer = bytearray()
        self._audio_source = QAudioSource(device, fmt, self)
        self._stream = self._audio_source.start()
        if self._stream is None:
            self._audio_source = None
            raise RuntimeError("麦克风录音启动失败。")
        self._stream.readyRead.connect(self._drain_stream)
        self._recording_started_at = time.monotonic()

    @Slot(result=object)
    def stop(self) -> RecordedAudio | None:
        if not self.is_recording:
            return None

        self._drain_stream()
        assert self._audio_source is not None
        self._audio_source.stop()
        self._audio_source.deleteLater()
        self._audio_source = None
        self._stream = None
        raw_bytes = self._normalize_audio(bytes(self._buffer))
        bytes_per_second = max(1, self.sample_rate * self.channels * 2)
        captured_duration = len(raw_bytes) / bytes_per_second
        return RecordedAudio(
            raw_bytes=raw_bytes,
            sample_rate=self.sample_rate,
            channels=self.channels,
            duration_seconds=captured_duration,
        )

    def _drain_stream(self) -> None:
        if self._stream is None:
            return
        chunk = self._stream.readAll()
        if chunk:
            self._buffer.extend(bytes(chunk))

    def _normalize_audio(self, raw_bytes: bytes) -> bytes:
        if not raw_bytes:
            return b""

        sample_format = self._capture_format.sampleFormat()
        capture_channels = max(1, self._capture_format.channelCount())
        capture_rate = max(1, self._capture_format.sampleRate())

        if sample_format == QAudioFormat.UInt8:
            waveform = (np.frombuffer(raw_bytes, dtype=np.uint8).astype(np.float32) - 128.0) / 128.0
        elif sample_format == QAudioFormat.Int16:
            waveform = np.frombuffer(raw_bytes, dtype=np.int16).astype(np.float32) / 32768.0
        elif sample_format == QAudioFormat.Int32:
            waveform = np.frombuffer(raw_bytes, dtype=np.int32).astype(np.float32) / 2147483648.0
        elif sample_format == QAudioFormat.Float:
            waveform = np.frombuffer(raw_bytes, dtype=np.float32)
        else:
            return b""

        if capture_channels > 1:
            frame_count = waveform.size // capture_channels
            if frame_count <= 0:
                return b""
            waveform = waveform[:frame_count * capture_channels].reshape(frame_count, capture_channels).mean(axis=1)

        if capture_rate != self.sample_rate and waveform.size > 1:
            duration = waveform.size / capture_rate
            target_length = max(1, int(round(duration * self.sample_rate)))
            source_positions = np.linspace(0.0, waveform.size - 1, num=waveform.size, dtype=np.float32)
            target_positions = np.linspace(0.0, waveform.size - 1, num=target_length, dtype=np.float32)
            waveform = np.interp(target_positions, source_positions, waveform).astype(np.float32)

        waveform = np.clip(waveform, -1.0, 1.0)
        pcm = (waveform * 32767.0).astype(np.int16)
        return pcm.tobytes()
