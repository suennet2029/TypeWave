# Contributing

感谢你愿意为 `TypeWave` 贡献代码。

## 项目结构

- `apps/macos-native/`
  macOS 原生菜单栏应用
- `apps/desktop/voice_coding_app/`
  Python 识别 helper
- `config/`
  默认配置与热词
- `scripts/`
  构建脚本
- `tests/`
  Python 侧基础测试

## 本地开发

安装依赖：

```bash
./scripts/bootstrap.sh
```

运行测试：

```bash
PYTHONPATH=apps/desktop uv run pytest tests/test_config.py tests/test_hotkeys.py tests/test_service.py -q
```

构建 Debug：

```bash
xcodebuild \
  -project apps/macos-native/VoiceCodingNative.xcodeproj \
  -target VoiceCodingNative \
  -configuration Debug \
  build CODE_SIGNING_ALLOWED=NO
```

## 提交前请确认

- 修改与当前原生架构一致，不要重新引入 Electron / PySide 前端
- 不提交本地模型、编译产物或缓存目录
- 新增行为变更时，同步更新 `README.md`
- 涉及 Python helper 协议变更时，同时检查原生端调用链

## 不要提交的内容

以下内容属于本地产物，不应提交：

- `models/`
- `runtime/`
- `apps/macos-native/build/`
- `.venv/`
- `__pycache__/`
- `.pytest_cache/`

## PR 说明建议

建议在提交说明中明确写清：

- 改动目的
- 用户可见行为变化
- 是否影响权限、热键、录音、模型加载或文本注入
- 本地验证方式
