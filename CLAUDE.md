# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 发布流程（硬性约定）

`AGENTS.md` 规定：**任何一次代码修改完成后都必须走完整发布流程**。要点：

- 版本号三处同步：`build_app.sh` 的 `APP_VERSION`/`APP_BUILD`、`windows/WeChatExporter.Windows/WeChatExporter.Windows.csproj` 的 `<Version>`、`CHANGELOG.md` 顶部新条目
- 功能/UI 变化 → 次版本号 +1；纯修复 → 补丁号 +1；Build 号每次递增
- 提交后打 `vX.Y.Z` 标签并 `git push origin main --tags`，`.github/workflows/release.yml` 监听 `v*` 自动构建三平台产物并创建 Release，**不要手动上传资产**
- 必须用 `gh run watch` / `gh run list` 确认 build-macos / build-windows / release 三个 job 全绿

完整细节见 `AGENTS.md`。

## 常用命令

```bash
# macOS：编译（发布验证用这条，须 Build complete）
swift build --disable-sandbox -c release

# macOS：生成 .app（内含 wx-cli 与 Info.plist，版本号来自本脚本变量）
./build_app.sh

# macOS：打 DMG（需先有 .app；依赖 hdiutil/Finder，仅 macOS 可跑）
bash scripts/create_dmg.sh [输出名.dmg]

# macOS：构建 + 安装到桌面和 /Applications
./install.sh              # CREATE_DMG=1 ./install.sh 同时出 DMG

# Windows
dotnet build windows/WeChatExporter.Windows/WeChatExporter.Windows.csproj -c Release
cd windows && ./build.ps1              # 产物 windows/dist/WeChatExporter/
cd windows && ./build.ps1 -SelfContained   # Release 用的自包含包
```

仓库**没有测试代码**，CI 也不跑测试——验证靠编译通过 + 实际运行 `.app`。CI（`.github/workflows/ci.yml`）额外校验两个内置二进制：wx-cli 的 `doctor` 输出含 `All checks passed` 且 strings 里能找到 `4.1.11`；ffmpeg 含 `libmp3lame`/`gif` 编码器、`hevc` 解码器、`palettegen` 滤镜，能端到端跑通语音通路，且无非系统动态库依赖。**替换 `vendor/macos/` 下任一二进制时必须保持这些成立**，否则 CI 直接失败。

要验证纯逻辑（如 HTML 渲染、媒体归档）而不想开 GUI，可以用 `swiftc` 把相关源文件连同一个临时 `main.swift` 单独编成一个命令行程序跑——`SingleFileExporter` 的依赖闭包是 `ImageExporter`、`WXGFTranscoder`、`StickerPackExporter`、`WxCliService`、`AppPaths`、`DatImageDecoder`、`SQLiteDatabase`、`EmojiExporter` 加 `Models/`。

调试提示：`swift run` 跑出来的是裸可执行文件，没有 app bundle，因此拿不到 `Bundle.main.resourceURL` 里的 wx-cli（会退回 native backend），版本号也会读成 `0.0.0`。要验证真实行为必须 `./build_app.sh` 后打开 `.app`。

## 架构

### 两套独立实现，无共享代码

`Sources/`（Swift + SwiftUI，macOS）与 `windows/`（.NET 8 WPF）是**平行的两份实现**，文件名/职责刻意对齐（`WxCliService`、`SingleFileExporter`、`ImageExporter`、`StickerPackExporter`、`EmojiExporter`、`DatImageDecoder`、`WXGFTranscoder`），但没有任何代码共享。改动一侧的行为时要显式决定是否镜像到另一侧——两边已经存在实质性分叉（见下）。

### 核心：一切委托给随包分发的 CLI

真正的解密与导出能力来自 `vendor/` 里的预编译二进制，构建时被 `scripts/bundle_wx_cli.sh` / `windows/scripts/bundle_wx_cli.ps1` 拷进产物：

| | macOS | Windows |
|---|---|---|
| 二进制 | `vendor/macos/wx-cli`（pandorafuture/wx-cli 0.7.2，白名单扩到微信 4.1.7–4.1.11） | `vendor/windows/wx.exe`（沿用 v2.6.2 所带版本） |
| 子命令 | `doctor` / `status` / `key scan` / `key extract` / `decrypt` / `sessions --format json --limit --offset` / `export <id> --output --format` | `daemon status` / `init --force [--data-dir]` / `sessions --json -n` / `export …` |

**两个二进制的命令行文法不同**，不能互相套用参数。CLI 定位顺序（macOS `WxCliService.locateExecutable`）：bundle 内 → `~/.local/bin` → `/opt/homebrew/bin` → `/usr/local/bin`。

`WxCliService.run()` 是所有调用的唯一出口：`Process` + 双管道逐行读取，`timeout: nil` 表示不限时（解密和含媒体导出用它），stderr 逐行喂给 `onActivity` 驱动进度条，`isJSONOutputLine` 过滤掉 `sessions --format json` 的原始输出以免刷屏日志面板。

### macOS 还捆绑了 ffmpeg（v2.14.0 起）

`vendor/macos/ffmpeg` 是最小化 LGPL 静态构建（2.7 MB），由 `scripts/build_ffmpeg_minimal.sh` 产出，`build_app.sh` 拷进 `Contents/Resources/`。

**它不是给 Swift 用的，主要是喂给 wx-cli。** `WxCliService.childEnvironment()` 在现有环境上注入 `FFMPEG_PATH` 指向包内二进制——这就是语音功能的全部接线：wx-cli 的 `export` 通路本身就会转码语音，拿到 ffmpeg 后自动把 SILK 转成 MP3 写进 `media/`，并挂进该条消息的 `media_files`（两条均已实测确认）。找不到 ffmpeg 时 wx-cli 降级导出原始 `.silk` 并打 hint，不会报错中断。

改动这块时注意两条红线：

- **构建脚本不可加 `--enable-gpl` / `--enable-version3`**。`libmp3lame` 是 LGPL，不需要 GPL；一旦加了，MIT 的分发前提就不成立。详见 `vendor/README.md`
- ffmpeg 的组件清单是从 wx-cli 二进制里还原出的实际调用倒推的，`--disable-everything` 之下漏一个组件就是运行期才炸。CI 有端到端自检兜底

`WXGFTranscoder.locateFFmpeg()` 也会优先用包内这份，把 WXGF 动态表情转成动图 GIF；拿不到 ffmpeg 时退回 AVFoundation 只能取单帧静图。

### macOS 的第二后端（native fallback）

`AppViewModel.Backend` 是 `.wxCli` 或 `.native` 二选一，构造时若找不到任何 wx-cli 才落到 `.native`。native 路径是自研的完整实现，Windows 侧没有对应物：

`AppPaths.detect()` 定位 `~/Library/Containers/com.tencent.xinWeChat/…/xwechat_files/<账号>/db_storage`（按 `message_0.db` 修改时间挑最新账号）→ `KeyCaptureService` 用内嵌 LLDB Python 脚本在 `CCKeyDerivationPBKDF` 下断点抓密钥（会 `killall WeChat`）→ `CryptoService` 做 SQLCipher 页解密（PBKDF2 256000 轮、4096 页、HMAC 校验）→ `ContactStore` / `ChatExporter` 直接读解密后的 SQLite。

`AppPaths` 还负责：`PRAGMA quick_check` 健康检查（`isDecryptedHealthy`）、从 `~/Library/Caches/wx-cli/<账号>/db_storage` 同步解密结果（`syncFromWxCliCache`）、清理 `-wal`/`-shm`、迁移旧版 `~/wechat-export`。

### 导出管线

`AppViewModel.exportSelected()` 对每个会话：建临时目录 → `wx-cli export` 写 txt + json → 后处理 → 按 `ExportMode` 决定落盘形态 → 删临时目录。后处理链：`normalizeExportArtifacts`（把 `联系人_日期.json` 统一复制成 `chat.json`/`chat.txt`，并从 JSON 生成带 BOM 的 `chat.csv`）、含媒体时再跑 `EmojiExporter` → `ImageExporter`（内部调 `DatImageDecoder` 解 `.dat`、`WXGFTranscoder` 转 WXGF）。

`ExportMode`（持久化在 UserDefaults `export.mode`）：
- `categorized`（默认）→ `MediaOrganizer.organize` 归档到 `<联系人>/{文字,图片,视频,语音,其他}/`
- `textOnly` → 只拷 txt/json/csv，且 `includesMedia == false`（wx-cli 加 `--no-media`）
- `all` → 原样递归拷贝全部文件
- `singleFileHTML` → `SingleFileExporter.writeHTML`，表情包同时出一张 `writeStickerGallery` 画廊

新增 case 时注意 `includesMedia` 必须返回 `true`，否则 wx-cli 被加 `--no-media`，拿不到任何媒体。

`SingleFileExporter.embedMedia` **纯按文件扩展名分派**，与 msg_type 无关——语音只要是 `.mp3` 就渲染成 `<audio>`。视频与 >8 MB 的文件不做 base64，改由 `ExternalMediaSink` 拷到 HTML 同名的 `<名称>_<时间戳>_media/` 里相对路径外链（base64 会让含视频的 HTML 涨到 GB 级）。`renderOrphanMedia` 兜底渲染没被任何消息引用的媒体，但它们会堆在文档末尾而非按时间内联。

**两端分叉**：Windows 的 `SingleFileExporter.cs` 一直是主路径且只出 HTML；macOS 这边 HTML 只是四选一里的一种。两边的 HTML 结构和样式并不一致，改一侧不会自动同步到另一侧。

### 进度与日志

`LoadProgressTracker`（`Models/LoadProgress.swift`）合并「时间预估」与「真实分页进度」，保证进度条单调不回退：无总量时按耗时爬到 ≤30%，解密阶段 ≤35%，拿到 `paging.total` 后映射 35%–99%。所有回调都通过 `AppViewModel.logHandler()` / `progressHandler()` 切回主线程；日志数组上限 300 行。

### 自动更新（仅 macOS）

`UpdateService` 查 GitHub `releases/latest`，**优先选 ZIP 资产**（静默更新用，无需挂载），DMG 仅供手动下载。自动模式流程：后台下载 ZIP → `ditto` 解压到 `~/Library/Application Support/WeChatExporter/pending-update-<版本>/` → 写 `UpdatePreferences.pendingInstallPath` → 发系统通知（`NotificationService`，未授权则降级为应用内弹窗）。安装动作由 `replaceApp` 写一个临时 bash 脚本完成——脚本 quit 旧应用、`cp -R` 覆盖、`xattr -cr` + adhoc `codesign`、`open` 新版本，因为运行中的 app 不能覆盖自身。`AppDelegate.applicationDidFinishLaunching` 启动 1 秒后自动应用待安装更新。

版本号来源是 `Info.plist` 的 `CFBundleShortVersionString`，而该 plist 由 `build_app.sh` 内联生成——所以改版本号只能改 `build_app.sh`，源码里没有版本常量。

## 约定

- 用户可见文案、日志、代码注释统一用简体中文；错误通过 `AppError` / `UpdateError` 的 `errorDescription` 给出可操作的中文提示（例：提示关 SIP、以管理员身份运行）
- macOS 需要关闭 SIP；`WxCliService.tryAutoFixDevToolsSecurity` 会在 SIP 已关但 DevToolsSecurity 未启用时，用 `NSAppleScript` 弹系统授权框自动执行 `DevToolsSecurity -enable`（必须在主线程调用）
- 导出查询一律用 `contact.id`（wxid/username）而非 `displayName`，后者不唯一会导致导出错位
- `.gitignore` 已封掉 `raw_key.bin`、`all_keys.json`、`**/decrypted/`、`*.db`——不要放行这些
- 仓库为 `93857536-pixel/WeChatExporter`；仓库 About 信息由 `scripts/update_github_about.sh` 维护
