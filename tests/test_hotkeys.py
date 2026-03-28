import pytest
from pynput import keyboard

from voice_coding_app.backend.hotkeys import ModifierTapListener, parse_hotkey
from voice_coding_app.backend.text_processing import apply_hotword_corrections

try:
    import Quartz  # type: ignore[import-not-found]
except ImportError:  # pragma: no cover - optional macOS dependency
    Quartz = None


def test_parse_hotkey_rejects_missing_modifier() -> None:
    with pytest.raises(ValueError):
        parse_hotkey("space")


def test_parse_hotkey_accepts_ctrl_space() -> None:
    spec = parse_hotkey("ctrl+space")
    assert spec.trigger == "space"
    assert spec.modifiers == frozenset({"ctrl"})


def test_hotword_corrections_promote_programming_terms() -> None:
    text = "please write a use debounce hook in type script"
    corrected = apply_hotword_corrections(text, ["useDebounce", "TypeScript"])
    assert "useDebounce" in corrected
    assert "TypeScript" in corrected


def test_modifier_tap_listener_fires_on_clean_option_tap() -> None:
    calls: list[str] = []
    listener = ModifierTapListener("option", lambda: calls.append("tapped"))

    listener._on_press(keyboard.Key.alt_l)
    listener._on_release(keyboard.Key.alt_l)

    assert calls == ["tapped"]


def test_modifier_tap_listener_ignores_option_chords() -> None:
    calls: list[str] = []
    listener = ModifierTapListener("option", lambda: calls.append("tapped"))

    listener._on_press(keyboard.Key.alt_l)
    listener._on_press(keyboard.KeyCode.from_char("a"))
    listener._on_release(keyboard.KeyCode.from_char("a"))
    listener._on_release(keyboard.Key.alt_l)

    assert calls == []


@pytest.mark.skipif(Quartz is None, reason="Quartz is only available on macOS")
def test_modifier_tap_listener_fires_on_macos_option_flags_changed() -> None:
    calls: list[str] = []
    listener = ModifierTapListener("option", lambda: calls.append("tapped"))

    listener._handle_macos_flags_changed(58, Quartz.kCGEventFlagMaskAlternate)
    listener._handle_macos_flags_changed(58, 0)

    assert calls == ["tapped"]


@pytest.mark.skipif(Quartz is None, reason="Quartz is only available on macOS")
def test_modifier_tap_listener_ignores_macos_option_with_other_modifier() -> None:
    calls: list[str] = []
    listener = ModifierTapListener("option", lambda: calls.append("tapped"))

    listener._handle_macos_flags_changed(58, Quartz.kCGEventFlagMaskAlternate)
    listener._handle_macos_flags_changed(
        55,
        Quartz.kCGEventFlagMaskAlternate | Quartz.kCGEventFlagMaskCommand,
    )
    listener._handle_macos_flags_changed(58, Quartz.kCGEventFlagMaskCommand)

    assert calls == []
