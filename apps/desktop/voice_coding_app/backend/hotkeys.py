from __future__ import annotations

from dataclasses import dataclass
from importlib import import_module
from functools import lru_cache
import sys
import threading
from typing import Any, Callable

MODIFIER_NAMES = {"ctrl", "alt", "shift", "cmd"}
ALIASES = {
    "control": "ctrl",
    "ctrl_l": "ctrl",
    "ctrl_r": "ctrl",
    "alt_l": "alt",
    "alt_r": "alt",
    "option": "alt",
    "option_l": "alt",
    "option_r": "alt",
    "shift_l": "shift",
    "shift_r": "shift",
    "cmd_l": "cmd",
    "cmd_r": "cmd",
    "super": "cmd",
    "windows": "cmd",
    "win": "cmd",
}
MACOS_MODIFIER_KEYCODES = {
    "ctrl": frozenset({59, 62}),
    "alt": frozenset({58, 61}),
    "shift": frozenset({56, 60}),
    "cmd": frozenset({54, 55}),
}


@lru_cache(maxsize=1)
def _keyboard_module():
    return import_module("pynput.keyboard")


@lru_cache(maxsize=1)
def _application_services_module():
    try:
        return import_module("ApplicationServices")
    except ImportError:  # pragma: no cover - optional macOS dependency
        return None


@lru_cache(maxsize=1)
def _quartz_module():
    try:
        return import_module("Quartz")
    except ImportError:  # pragma: no cover - optional macOS dependency
        return None


def _macos_modifier_flag(modifier: str) -> int:
    quartz = _quartz_module()
    if quartz is None:
        return 0

    flag_names = {
        "ctrl": "kCGEventFlagMaskControl",
        "alt": "kCGEventFlagMaskAlternate",
        "shift": "kCGEventFlagMaskShift",
        "cmd": "kCGEventFlagMaskCommand",
    }
    return int(getattr(quartz, flag_names[modifier]))


@dataclass(frozen=True)
class HoldHotkeySpec:
    expression: str
    modifiers: frozenset[str]
    trigger: str


def parse_hotkey(expression: str) -> HoldHotkeySpec:
    parts = [segment.strip().lower() for segment in expression.split("+") if segment.strip()]
    if len(parts) < 2:
        raise ValueError("热键至少要包含一个修饰键和一个触发键，例如 cmd+shift+space。")

    modifiers = []
    for token in parts[:-1]:
        normalized = ALIASES.get(token, token)
        if normalized not in MODIFIER_NAMES:
            raise ValueError(f"不支持的修饰键: {token}")
        modifiers.append(normalized)

    trigger = ALIASES.get(parts[-1], parts[-1])
    if trigger in MODIFIER_NAMES:
        raise ValueError("触发键不能和修饰键相同。")

    return HoldHotkeySpec(expression=expression, modifiers=frozenset(modifiers), trigger=trigger)


def normalize_pressed_key(key: object) -> str | None:
    char = getattr(key, "char", None)
    if isinstance(char, str):
        if char == " ":
            return "space"
        return char.lower() if char else None
    name = getattr(key, "name", None)
    if not name:
        return None
    return ALIASES.get(name, name)


class HoldHotkeyListener:
    def __init__(
        self,
        expression: str,
        on_start: Callable[[], None],
        on_stop: Callable[[], None],
    ) -> None:
        self.spec = parse_hotkey(expression)
        self.on_start = on_start
        self.on_stop = on_stop
        self._pressed: set[str] = set()
        self._active = False
        self._listener: Any | None = None

    def start(self) -> None:
        if self._listener is not None:
            return
        keyboard = _keyboard_module()
        self._listener = keyboard.Listener(on_press=self._on_press, on_release=self._on_release)
        self._listener.start()

    def stop(self) -> None:
        if self._listener is None:
            return
        self._listener.stop()
        self._listener = None
        self._pressed.clear()
        self._active = False

    def _on_press(self, key: object) -> None:
        token = normalize_pressed_key(key)
        if not token:
            return
        self._pressed.add(token)

        if self._active:
            return
        if token == self.spec.trigger and self.spec.modifiers.issubset(self._pressed):
            self._active = True
            self.on_start()

    def _on_release(self, key: object) -> None:
        token = normalize_pressed_key(key)
        if token and self._active and (token == self.spec.trigger or token in self.spec.modifiers):
            self._active = False
            self.on_stop()

        if token:
            self._pressed.discard(token)


class ModifierTapListener:
    def __init__(
        self,
        modifier: str,
        on_tap: Callable[[], None],
    ) -> None:
        normalized = ALIASES.get(modifier.strip().lower(), modifier.strip().lower())
        if normalized not in MODIFIER_NAMES:
            raise ValueError(f"不支持的单击修饰键: {modifier}")

        self.modifier = normalized
        self.on_tap = on_tap
        self.backend_name = "pynput"
        self._listener: Any | None = None
        self._event_tap = None
        self._run_loop = None
        self._run_loop_source = None
        self._thread: threading.Thread | None = None
        self._startup_ready = threading.Event()
        self._startup_error: Exception | None = None
        self._modifier_down = False
        self._chord_detected = False

    def start(self) -> None:
        if self._listener is not None or self._thread is not None:
            return
        if self._should_use_macos_event_tap():
            self._start_macos_listener()
            return
        self.backend_name = "pynput"
        keyboard = _keyboard_module()
        self._listener = keyboard.Listener(on_press=self._on_press, on_release=self._on_release)
        self._listener.start()

    def stop(self) -> None:
        if self._listener is not None:
            self._listener.stop()
            self._listener = None
        if self._thread is not None:
            run_loop = self._run_loop
            quartz = _quartz_module()
            if run_loop is not None and quartz is not None:
                quartz.CFRunLoopStop(run_loop)
                quartz.CFRunLoopWakeUp(run_loop)
            self._thread.join(timeout=1)
            self._thread = None
            self._event_tap = None
            self._run_loop = None
            self._run_loop_source = None
            self._startup_ready.clear()
            self._startup_error = None
        self._modifier_down = False
        self._chord_detected = False

    def _on_press(self, key: object) -> None:
        token = normalize_pressed_key(key)
        if not token:
            return
        self._handle_token_press(token)

    def _on_release(self, key: object) -> None:
        token = normalize_pressed_key(key)
        if not token:
            return
        self._handle_token_release(token)

    def _handle_token_press(self, token: str) -> None:
        if token == self.modifier:
            if not self._modifier_down:
                self._modifier_down = True
                self._chord_detected = False
            return
        if self._modifier_down:
            self._chord_detected = True

    def _handle_token_release(self, token: str) -> None:
        if token == self.modifier:
            should_fire = self._modifier_down and not self._chord_detected
            self._modifier_down = False
            self._chord_detected = False
            if should_fire:
                self.on_tap()
            return
        if self._modifier_down:
            self._chord_detected = True

    def _should_use_macos_event_tap(self) -> bool:
        return (
            sys.platform == "darwin"
            and _quartz_module() is not None
            and self.modifier in MACOS_MODIFIER_KEYCODES
        )

    def _start_macos_listener(self) -> None:
        quartz = _quartz_module()
        if quartz is not None and hasattr(quartz, "CGPreflightListenEventAccess"):
            if not quartz.CGPreflightListenEventAccess():
                if hasattr(quartz, "CGRequestListenEventAccess"):
                    try:
                        quartz.CGRequestListenEventAccess()
                    except Exception:
                        pass

        self.backend_name = "quartz"
        self._startup_ready.clear()
        self._startup_error = None
        self._thread = threading.Thread(
            target=self._run_macos_event_loop,
            daemon=True,
            name="modifier-tap-listener",
        )
        self._thread.start()
        self._startup_ready.wait(timeout=2)
        if self._startup_error is not None:
            startup_error = self._startup_error
            self.stop()
            raise startup_error
        if self._event_tap is None:
            self.stop()
            raise RuntimeError("macOS 全局键盘监听初始化失败。")

    def _run_macos_event_loop(self) -> None:
        quartz = _quartz_module()
        if quartz is None:
            self._startup_error = RuntimeError("当前环境缺少 Quartz，无法监听 Option 单击。")
            self._startup_ready.set()
            return

        self._run_loop = quartz.CFRunLoopGetCurrent()
        event_mask = quartz.CGEventMaskBit(quartz.kCGEventFlagsChanged) | quartz.CGEventMaskBit(
            quartz.kCGEventKeyDown
        )
        self._event_tap = quartz.CGEventTapCreate(
            quartz.kCGSessionEventTap,
            quartz.kCGHeadInsertEventTap,
            quartz.kCGEventTapOptionListenOnly,
            event_mask,
            self._macos_event_callback,
            None,
        )
        if self._event_tap is None:
            if hasattr(quartz, "CGPreflightListenEventAccess") and not quartz.CGPreflightListenEventAccess():
                self._startup_error = PermissionError("系统尚未授予输入监控权限，无法监听 Option 单击。")
            else:
                self._startup_error = RuntimeError("无法创建 macOS 全局键盘监听。")
            self._startup_ready.set()
            return

        self._run_loop_source = quartz.CFMachPortCreateRunLoopSource(None, self._event_tap, 0)
        if self._run_loop_source is None:
            self._startup_error = RuntimeError("无法创建 macOS 键盘监听事件源。")
            self._startup_ready.set()
            return

        quartz.CFRunLoopAddSource(self._run_loop, self._run_loop_source, quartz.kCFRunLoopCommonModes)
        quartz.CGEventTapEnable(self._event_tap, True)
        self._startup_ready.set()

        try:
            quartz.CFRunLoopRun()
        finally:
            if self._run_loop is not None and self._run_loop_source is not None:
                quartz.CFRunLoopRemoveSource(
                    self._run_loop,
                    self._run_loop_source,
                    quartz.kCFRunLoopCommonModes,
                )
            if self._event_tap is not None:
                quartz.CFMachPortInvalidate(self._event_tap)
            self._event_tap = None
            self._run_loop_source = None
            self._run_loop = None

    def _macos_event_callback(self, _proxy, event_type, event, _refcon):
        quartz = _quartz_module()
        if quartz is None:
            return event
        if event_type == quartz.kCGEventTapDisabledByTimeout and self._event_tap is not None:
            quartz.CGEventTapEnable(self._event_tap, True)
            return event
        if event_type == quartz.kCGEventTapDisabledByUserInput:
            return event

        if event_type == quartz.kCGEventKeyDown:
            if self._modifier_down:
                self._chord_detected = True
            return event

        if event_type != quartz.kCGEventFlagsChanged:
            return event

        key_code = int(quartz.CGEventGetIntegerValueField(event, quartz.kCGKeyboardEventKeycode))
        self._handle_macos_flags_changed(key_code, int(quartz.CGEventGetFlags(event)))
        return event

    def _handle_macos_flags_changed(self, key_code: int, flags: int) -> None:
        modifier_codes = MACOS_MODIFIER_KEYCODES[self.modifier]
        modifier_flag = _macos_modifier_flag(self.modifier)
        modifier_pressed = (flags & modifier_flag) != 0

        if key_code in modifier_codes:
            if modifier_pressed:
                self._handle_token_press(self.modifier)
            else:
                self._handle_token_release(self.modifier)
            return

        if self._modifier_down:
            self._chord_detected = True
