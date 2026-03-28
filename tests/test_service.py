from voice_coding_app.service import _parse_command_line


def test_parse_command_line_accepts_json_object() -> None:
    command = _parse_command_line('{"type":"snapshot","payload":{}}\n')
    assert command == {"type": "snapshot", "payload": {}}


def test_parse_command_line_ignores_noise() -> None:
    assert _parse_command_line("") is None
    assert _parse_command_line("\n") is None
    assert _parse_command_line("\ufeff") is None
    assert _parse_command_line("psn_0_12345") is None
    assert _parse_command_line("[error] something") is None
