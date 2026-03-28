# Open Source Notes

这份文档面向准备把 `TypeWave` 仓库公开发布的人。

## 当前已经完成的清理

- 删除了旧的 Electron 前端
- 删除了旧的 PySide 桌面 UI
- 删除了旧的 PyInstaller 打包配置
- 删除了内部调试目录、缓存目录和常见本地垃圾文件
- README 已改为只描述当前原生 macOS + Python helper 架构

## 发布前建议再确认

### 1. 许可证

仓库目前还没有正式 `LICENSE` 文件。

公开发布前请先决定许可证，例如：

- MIT
- Apache-2.0
- GPL-3.0

### 2. Git 仓库边界

发布前先确认当前工程本身就是独立 Git 仓库。

如果 `git rev-parse --show-toplevel` 指向的是外层工作区，而不是当前项目目录，那么公开发布前应先：

- 为当前项目创建独立仓库
- 或把当前项目单独迁出到新的 Git 仓库目录

否则 `git status` 会把同级其他项目一起算进去，后续提交和公开发布都会有风险。

### 3. 敏感信息

发布前再检查一次以下内容是否包含个人信息或本机路径：

- `README.md`
- `config/`
- `scripts/`
- `apps/macos-native/VoiceCodingNative/Info.plist`
- `apps/macos-native/VoiceCodingNative.xcodeproj/project.pbxproj`

### 4. 本地产物不要提交

这些目录是本地运行或下载产物，不应进入公开仓库：

- `models/`
- `runtime/`
- `apps/macos-native/build/`
- `.venv/`

### 5. macOS 发布策略

当前项目更适合：

- GitHub 开源
- 本地构建
- 或官网分发签名后的 `.app`

如果要上 Mac App Store，需要额外处理：

- App Sandbox
- Accessibility / Automation 权限边界
- 审核策略

### 6. 对外说明建议

建议在仓库首页明确写清：

- 这是一个 macOS-only 项目
- 识别在本地完成
- 首次运行需要系统权限
- 模型首次使用会下载到本地

## 建议的开源顺序

1. 再跑一轮构建和测试
2. 确认当前工程已经是独立 Git 仓库
3. 选定许可证并补 `LICENSE`
4. 检查 `git status`
5. 确认没有把 `models/`、`runtime/`、`.venv/`、`build/` 加进版本库
6. 再创建公开仓库
