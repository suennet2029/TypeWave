from __future__ import annotations

from importlib import import_module
import subprocess
import sys
import time
from typing import Any

import pyperclip


def _keyboard_module():
    return import_module("pynput.keyboard")


class TextInjector:
    def __init__(self, paste_mode: str, paste_delay_ms: int) -> None:
        self.paste_mode = paste_mode
        self.paste_delay_ms = paste_delay_ms
        self._controller: Any | None = None

    def _ensure_controller(self):
        if self._controller is not None:
            return self._controller
        keyboard = _keyboard_module()
        self._controller = keyboard.Controller()
        return self._controller

    def insert_text(self, text: str, target_app_name: str | None = None) -> None:
        if not text:
            return

        if target_app_name:
            self._activate_application(target_app_name)

        time.sleep(self.paste_delay_ms / 1000)
        controller = self._ensure_controller()
        if self.paste_mode == "type":
            controller.type(text)
            return

        pyperclip.copy(text)
        keyboard = _keyboard_module()
        modifier = keyboard.Key.cmd if sys.platform == "darwin" else keyboard.Key.ctrl
        with controller.pressed(modifier):
            controller.press("v")
            controller.release("v")

    def _activate_application(self, target_app_name: str) -> None:
        if sys.platform != "darwin" or not target_app_name:
            return

        escaped = target_app_name.replace('"', '\\"')
        try:
            subprocess.run(
                ["osascript", "-e", f'tell application "{escaped}" to activate'],
                check=True,
                capture_output=True,
                text=True,
            )
        except Exception:
            # Best effort only. If re-activation fails, keep the current focus instead
            # of crashing the whole transcription flow.
            return
