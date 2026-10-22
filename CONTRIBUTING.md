# 参与 WindowHop

欢迎报告问题、完善文档或提交代码。提交贡献即表示同意将相应贡献以本项目的 [MIT 协议](LICENSE) 提供。

## 报告问题

请在 [Issues](https://github.com/marriannedagwwn-bot/WindowHop/issues) 中提供：

- WindowHop 版本、macOS 版本和芯片型号。
- 目标应用名称与版本，以及窗口是否最小化、隐藏、全屏或位于其他桌面。
- 复现步骤、预期结果、实际结果与相关设置。
- 辅助功能、屏幕录制权限状态；若与快捷键有关，请说明是否运行其他切换工具。

请使用测试窗口或示例内容录屏，避免公开私人窗口标题、文档内容、账号、文件路径或截图。诊断输出也请先检查再提交。

## 本地开发

需要 Apple Silicon Mac，以及 **Xcode 26 或包含 macOS 26 SDK 的对应 Command Line Tools**。构建脚本使用 Swift 5 语言模式，部署目标为 macOS 15；项目无第三方包依赖。

```sh
./Scripts/build.sh
./WindowHop.app/Contents/MacOS/WindowHop --self-test
open WindowHop.app
```

`Source/` 为应用源码，`Scripts/` 为构建与图标生成脚本，`Info.plist` 为应用元数据。更多说明见 [架构](docs/architecture.md) 和 [验证](docs/testing.md)。

应用内的「外观预览」无需读取真实窗口。也可生成一张使用隔离设置的示例截图：

```sh
./WindowHop.app/Contents/MacOS/WindowHop \
  --demo --snapshot "$PWD/preview.png" \
  --appearance icons --size medium --theme dark
```

实际操作窗口需要在系统设置中授权当前构建副本。请使用自己创建、内容可丢弃的测试窗口验证关闭与退出等操作。

## 提交改动

1. Fork 仓库，从 `main` 创建一个描述清楚的分支。
2. 将改动集中在一个问题或功能上，保持现有 Swift 风格。
3. 构建并运行自检。若修改窗口行为，补充对应的真实窗口测试；若修改外观，提供浅色、深色截图或短视频。
4. 提交 Pull Request，说明问题、改动后的行为、验证方式和未覆盖的场景。

对输入状态、排序、布局或身份匹配规则的修改，请在 `Source/SelfTest.swift` 中补充有意义的回归检查。单纯文档更正不要求运行窗口测试。

请勿提交 `.app`、临时构建、私人设置、真实窗口截图或诊断日志。面向用户的安装包通过 GitHub Releases 提供。
