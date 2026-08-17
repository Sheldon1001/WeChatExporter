# WeChatExporter

[![Release](https://img.shields.io/github/v/release/Sheldon1001/WeChatExporter?label=release)](https://github.com/Sheldon1001/WeChatExporter/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Windows-lightgrey)](https://github.com/Sheldon1001/WeChatExporter)

原生应用，用于在本地导出**自己的**微信聊天记录。完全离线运行，不上传数据或密钥。

**English README:** [README.en.md](README.en.md)

- **macOS 版**：Swift + SwiftUI，提供 DMG 安装包
- **Windows 版**：.NET 8 WPF，自包含 zip（无需安装 .NET）

![主界面预览](docs/screenshots/main-ui.png)

## 下载（推荐）

前往 **[GitHub Releases](https://github.com/Sheldon1001/WeChatExporter/releases/latest)** 下载最新版：

| 平台 | 文件 | 说明 |
|------|------|------|
| macOS (Apple Silicon) | `WeChatExporter-macOS-arm64.dmg` | 打开 DMG，拖到「应用程序」即可安装 |
| macOS (备用) | `WeChatExporter-macOS-arm64.zip` | 解压后打开 `.app` |
| Windows (64 位) | `WeChatExporter-Windows-x64.zip` | 解压后运行 `WeChatExporter.exe`，**自包含，无需安装 .NET** |

> 版本更新记录见 [CHANGELOG.md](CHANGELOG.md)

## 功能

- 图形界面：搜索、多选联系人/群聊
- **会话按类型分组**（macOS）：侧栏分为好友 / 群聊 / 公众号 / 其他四组，可折叠；点分组右侧的数量徽标即可整类全选或取消——公众号动辄几百个，逐个点不现实
- **内置 wx-cli**：安装即用，无需单独安装命令行工具
- **就绪状态提示**：界面顶部显示当前进度（是否已完成「准备数据」）
- **四种导出方式**（macOS，在设置中选择；Windows 固定输出网页）：
  - **分类导出**（默认）：文字、图片、视频、语音分别归档到独立文件夹
  - **只导出文字**：仅 txt / json / csv，速度最快
  - **全部导出**：文字加原始媒体文件，保持目录结构
  - **网页导出**：生成可用浏览器直接打开的 `.html`，图片、表情、语音内嵌，视频与大附件放进 `media/` 外链，链接可点击；单个网页最多 1000 条消息，超出自动分卷并带上下页导航
- **每次导出各自成夹**：每个会话落到 `<联系人>_<时间戳>/` 里，重复导出不会覆盖上一次；媒体按 图片 / 视频 / 语音 / 其他 分子目录存放
- **语音可播放**（macOS）：内置 ffmpeg 自动把微信的 SILK 语音转成 MP3，网页导出中直接可播
- **动态表情会动**（macOS）：WXGF 表情转码为动图 GIF，而非单帧静图
- **导出进度可见**：大会话导出时显示当前会话、阶段与已处理的媒体条数，而不是一个不动的「处理中」
- 自动检测微信数据目录
- 通过 LLDB / 内存扫描捕获密钥并解密（微信 4.x SQLCipher）

## 系统要求

### macOS

| 项目 | 要求 |
|------|------|
| 系统 | macOS 13 (Ventura) 或更高 |
| 芯片 | Apple Silicon (arm64)，暂不支持 Intel Mac |
| 微信 | Mac 版 4.x（已登录并同步过聊天记录） |
| 密钥捕获 | 需关闭 SIP（System Integrity Protection） |

### Windows

| 项目 | 要求 |
|------|------|
| 系统 | Windows 10 / 11（64 位） |
| 运行时 | 无需安装（v2.3.0+ Release 为自包含包） |
| 微信 | PC 版 4.x（已登录并同步过聊天记录） |
| 权限 | 首次「准备数据」建议以管理员身份运行 |

### 兼容说明

| 组件 | macOS | Windows |
|------|-------|---------|
| 内置 CLI | 仓库 `vendor/macos/wx-cli`（支持微信 4.1.7–4.1.11） | 仓库 `vendor/windows/wx.exe` |
| 微信版本 | 4.x（已验证 4.1.7–4.1.11） | 4.x（4.1.7+；4.1.11 内存扫密钥可能失效） |

> **隐私说明**：本工具仅在本地运行，不会上传任何聊天数据或密钥。

## 快速开始

### macOS

1. 下载并打开 **`WeChatExporter-macOS-arm64.dmg`**
2. 在弹出的安装窗口中，将 **WeChatExporter** 拖到右侧 **「应用程序」** 文件夹
3. 打开应用（若提示无法验证开发者，请 **右键 → 打开**）
4. 点击 **「准备数据」** → 选择联系人 → **「导出选中」**

### Windows

1. 解压 **`WeChatExporter-Windows-x64.zip`**
2. **右键以管理员身份运行** `WeChatExporter.exe`（首次推荐）
3. 点击 **「准备数据」** → 选择联系人 → **「导出选中」**

默认导出目录：
- macOS：`~/Downloads/微信聊天记录导出/`
- Windows：`%USERPROFILE%\Downloads\微信聊天记录导出\`

每个会话各自成夹，以「网页导出」为例（macOS）：

```
微信聊天记录导出/
├── 张三_20260817_105447/
│   ├── 张三_1.html          # 每卷 1000 条，单卷时不带编号
│   ├── 张三_2.html
│   └── media/               # 各卷共用，同一个视频不会拷多份
│       ├── 视频/
│       ├── 图片/
│       ├── 语音/
│       └── 其他/
├── 李四_20260817_105447/
└── 全部表情包_20260817_105447/
    ├── 全部表情包_1.html    # 每页 500 张
    └── media/图片/          # 表情外链，不内嵌
```

「分类导出」则是 `张三_20260817_105447/{文字,图片,视频,语音,其他}/`。

## 从源码构建

### macOS

```bash
git clone https://github.com/Sheldon1001/WeChatExporter.git
cd WeChatExporter
./install.sh                  # 构建并安装到桌面与 /Applications
# 或
./build_app.sh                # 仅生成 .app
bash scripts/create_dmg.sh    # 生成 DMG
CREATE_DMG=1 ./install.sh     # 安装同时生成 DMG
```

### Windows

详见 [`windows/README.md`](windows/README.md)。

```powershell
cd windows
./install.ps1    # 安装到桌面
./build.ps1      # 仅构建到 dist/
```

## 项目结构

**macOS**

```
Sources/WeChatExporter/     # SwiftUI 应用
vendor/macos/               # 随包分发的 wx-cli、ffmpeg、ffprobe
scripts/
├── bundle_wx_cli.sh        # 打包内置 wx-cli
├── build_ffmpeg_minimal.sh # 重建最小化 LGPL 静态 ffmpeg / ffprobe
├── create_dmg.sh           # 生成带自定义背景的 DMG
├── generate_dmg_background.py  # DMG 背景图生成
└── prepare_icon.sh         # 生成 AppIcon.icns
tests/fixtures/             # CI 自检用样本（WXGF 裸 HEVC 流）
assets/AppIcon.png          # 应用图标源文件
assets/dmg-background.png      # DMG 背景 1x（660×400 @72dpi）
assets/dmg-background@2x.png   # DMG 背景 2x（1320×800 @144dpi）
docs/screenshots/           # README 截图
```

**Windows** — 见 [`windows/README.md`](windows/README.md)

## 数据目录

| 用途 | macOS | Windows |
|------|-------|---------|
| 微信加密数据库 | `~/Library/Containers/.../xwechat_files/<账号>/db_storage/` | `%USERPROFILE%\Documents\xwechat_files\<账号>\db_storage\` |
| 应用工作目录 | `~/Library/Application Support/WeChatExporter/<账号>/` | `%USERPROFILE%\.wx-cli\` |
| 导出结果 | `~/Downloads/微信聊天记录导出/` | `%USERPROFILE%\Downloads\微信聊天记录导出\` |

## 常见问题

**提示 SQL 或数据库错误**

点击「准备数据」重新解密。若仍失败，请确认微信已登录且 SIP 已关闭（macOS）。

**密钥捕获失败**

1. 确认微信处于登录状态
2. macOS：确认 SIP 已关闭 `csrutil status`；Windows：以管理员身份运行
3. 重新点击「准备数据」

**应用打不开（macOS）**

```bash
xattr -cr /Applications/WeChatExporter.app
codesign --force --deep --sign - /Applications/WeChatExporter.app
```

**部分图片、视频、语音导出后打不开，只有一行说明文字**

微信客户端并不会把所有媒体都留在本机：过期的、没点开过的、被清理过的文件，数据库里只剩一条记录。导出时会在该条消息处标明媒体为何缺失，属于正常现象，不是导出失败。想补齐的话，先在微信里打开对应聊天让它重新下载，再重新导出。

**如何反馈问题**

请使用 [Bug Report 模板](https://github.com/Sheldon1001/WeChatExporter/issues/new?template=bug_report.yml) 提交 Issue。

## 参与贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 免责声明

- 本工具仅供个人备份**自己的**聊天记录，请勿用于非法用途
- 微信数据库格式可能随版本更新而变化，不保证兼容所有版本
- 使用本工具的风险由使用者自行承担

## License

MIT

### 第三方组件

发布包内附带以下预编译二进制，它们各自的许可与本项目的 MIT 许可相互独立：

| 组件 | 用途 | 许可 |
|---|---|---|
| `wx-cli` (macOS) | 微信数据库解密与导出 | 见 [vendor/README.md](vendor/README.md) |
| `wx.exe` (Windows) | 同上 | 见 [vendor/README.md](vendor/README.md) |
| `ffmpeg` (macOS) | 语音 SILK → MP3、WXGF 动态表情解码 | **LGPL v2.1** |

其中 ffmpeg 为最小化静态构建（FFmpeg 8.0.1 + LAME 3.100），**未启用 GPL**。
本项目以独立子进程方式调用它，不做链接，因此不构成衍生作品。

许可证全文见 `WeChatExporter.app/Contents/Resources/ffmpeg-COPYING.LGPLv2.1`。
如需重新构建或重新链接该二进制（LGPL v2.1 §6），执行：

```bash
bash scripts/build_ffmpeg_minimal.sh
```

该脚本锁定了上游版本与完整的 configure 参数，详见 [vendor/README.md](vendor/README.md)。
