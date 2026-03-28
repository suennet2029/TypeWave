# TypeWave

`TypeWave` 是一个面向 macOS 的本地语音输入工具。

它常驻在菜单栏中，按下快捷键开始录音，使用本地 SenseVoice 模型完成识别，再把文本写回当前焦点输入框。当前仓库只保留最新实现：`macOS 原生菜单栏 app + Python 识别 helper`。

当前源码仓库名建议使用 `TypeWave`。  
现阶段打包产物中的应用名仍然是 `Voice Coding.app`，后续如需对外完全统一品牌名，可以再单独做一次重命名。

## 特性

- `SwiftUI + AppKit` 原生菜单栏应用
- 默认快捷键 `option+r`
- 本地语音识别，默认使用 `SenseVoiceSmall`
- 识别结果自动写回当前输入框
- 录音 HUD、波纹反馈、近实时转录预览
- 热词纠正与本地配置持久化

## 当前架构

主链路：

`macOS native app -> AVAudioEngine 录音 -> Python helper 转写 -> 原生文本注入`

模块职责：

- `apps/macos-native/`
  - 菜单栏 UI
  - 权限管理
  - 全局热键
  - 音频采集
  - HUD 与前台反馈
  - 文本注入
- `apps/desktop/voice_coding_app/`
  - Python helper 进程
  - 模型装载与卸载
  - 音频转写
  - 热词处理
- `config/`
  - 默认配置
  - 热词词表

## 仓库结构

```text
apps/
  desktop/
    voice_coding_app/
      backend/
      service.py
  macos-native/
    VoiceCodingNative.xcodeproj
    VoiceCodingNative/
config/
  app.yaml
  hotwords.txt
docs/
  OPEN_SOURCE.md
scripts/
  bootstrap.sh
  build_macos.sh
  build_macos_native.sh
tests/
  test_config.py
  test_hotkeys.py
  test_service.py
```

## 环境要求

- macOS 13+
- Xcode
- Python 3.11
- [`uv`](https://docs.astral.sh/uv/)

## 快速开始

安装依赖：

```bash
./scripts/bootstrap.sh
```

编译 Debug：

```bash
xcodebuild \
  -project apps/macos-native/VoiceCodingNative.xcodeproj \
  -target VoiceCodingNative \
  -configuration Debug \
  build CODE_SIGNING_ALLOWED=NO
```

Debug 产物：

```text
apps/macos-native/build/Debug/Voice Coding.app
```

运行测试：

```bash
PYTHONPATH=apps/desktop uv run pytest tests/test_config.py tests/test_hotkeys.py tests/test_service.py -q
```

## 模型说明

- 开源仓库默认不提交 `models/SenseVoiceSmall/model.pt` 这类大模型文件
- 源码运行时，首次点击“装载模型”或首次开始识别时，程序会自动把 `SenseVoiceSmall` 下载到本地 `models/SenseVoiceSmall/`
- 因此首次使用需要可访问 Hugging Face 的网络环境，并预留大约 `1 GB` 的磁盘空间
- 如果你准备本地打包 Release，打包前也需要先让 `models/SenseVoiceSmall/` 下载完整；构建脚本会把这份本地模型一起打进 `.app`
- 如果你直接下载已经打好的 Release 应用包，则不需要再单独下载模型

## 首次使用

1. 打开 `Voice Coding.app`
2. 授予麦克风权限
3. 授予辅助功能权限
4. 如果你启用了依赖输入监控的快捷键，再授予输入监控权限
5. 按 `option+r` 开始 / 停止录音

## 构建 Release

```bash
./scripts/build_macos.sh
```

当前 Release 构建会生成一个自带原生前端、内嵌 Python helper 和内嵌 SenseVoice 必需模型文件的独立 `.app`。

Release 产物：

```text
apps/macos-native/build/Release/Voice Coding.app
apps/macos-native/build/Release/Voice Coding.zip
```

说明：

- 当前分发脚本会把本地 `models/SenseVoiceSmall/` 中的必需模型文件打进 `.app`
- 由于仓库默认不包含 `models/SenseVoiceSmall/model.pt`，打包前请先在本地完成一次模型下载
- 当前预构建分发包按 Apple Silicon 路线打包

## 本地运行产物

以下目录是本地下载或运行产物，不应提交到开源仓库：

- `models/`
- `runtime/`
- `apps/macos-native/build/`
- `.venv/`

开发态首次装载模型时，应用会把 SenseVoice 下载到本地 `models/` 目录。

## 说明

- 当前项目是 `macOS-only`
- Python 部分是 helper，不是独立 GUI 应用
- 旧的 Electron、PySide、PyInstaller 链路已经移除
- `build_macos.sh` 产出的 Release 包是独立运行版本，不再依赖项目目录里的 `.venv`
- 公开发布前建议先阅读以下文档：
  [CONTRIBUTING.md](CONTRIBUTING.md)
  [SECURITY.md](SECURITY.md)
  [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)
  [docs/OPEN_SOURCE.md](docs/OPEN_SOURCE.md)
  [docs/GITHUB_PUBLISHING.md](docs/GITHUB_PUBLISHING.md)
