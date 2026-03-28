# GitHub Publishing Guide

这份文档用于整理当前项目公开发布前需要准备的内容。

## 建议保留的仓库文档

建议至少保留：

- `README.md`
- `CONTRIBUTING.md`
- `SECURITY.md`
- `CODE_OF_CONDUCT.md`
- `docs/OPEN_SOURCE.md`
- `docs/GITHUB_PUBLISHING.md`

## 仍然建议补上的文件

最关键的是：

- `LICENSE`

仓库公开前应先确定许可证，例如：

- MIT
- Apache-2.0
- GPL-3.0

## 建议上传到 GitHub 的源码范围

建议提交：

- `apps/macos-native/`
- `apps/desktop/voice_coding_app/`
- `config/`
- `scripts/`
- `tests/`
- `docs/`
- `README.md`
- `CONTRIBUTING.md`
- `SECURITY.md`
- `CODE_OF_CONDUCT.md`
- `pyproject.toml`
- `uv.lock`
- `.gitignore`

## 不要上传的内容

这些属于本地运行或分发产物，不应进入源码仓库：

- `models/`
- `runtime/`
- `apps/macos-native/build/`
- `.venv/`

## 发布前检查

1. 确认当前项目是独立 Git 仓库，而不是外层工作区的一部分
2. 确认 `README.md` 与当前实现一致
3. 确认没有提交模型、缓存和编译产物
4. 重新跑测试
5. 重新构建一次原生应用
6. 确定许可证并补 `LICENSE`

## 对外说明建议

建议在 GitHub 首页明确说明：

- 这是一个 `macOS-only` 项目
- 默认交付形态是菜单栏应用
- 识别在本地完成
- 首次运行需要系统权限
- Release 分发包自带 helper 和必需模型文件
