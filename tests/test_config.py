from voice_coding_app.backend.config import AppConfig


def test_default_config_matches_expected_defaults() -> None:
    config = AppConfig()
    assert config.hotkey == "cmd+shift+space"
    assert config.toggle_record_key == ""
    assert config.repo_id == "FunAudioLLM/SenseVoiceSmall"
    assert config.paste_mode == "clipboard"
