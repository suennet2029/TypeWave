from __future__ import annotations

import wave
from dataclasses import dataclass
from pathlib import Path


@dataclass
class RecordedAudio:
    raw_bytes: bytes
    sample_rate: int
    channels: int
    duration_seconds: float

    def write_wav(self, path: Path) -> None:
        with wave.open(str(path), "wb") as wav_file:
            wav_file.setnchannels(self.channels)
            wav_file.setsampwidth(2)
            wav_file.setframerate(self.sample_rate)
            wav_file.writeframes(self.raw_bytes)
