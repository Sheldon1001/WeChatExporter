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

仓库**没有测试代码**，CI 也不跑测试——验证靠编译通过 + 实际运行 `.app`。CI（`.github/workflows/ci.yml`）额外校验两个内置二进制：wx-cli 的 `doctor` 输出含 `All checks passed` 且 strings 里能找到 `4.1.11`；ffmpeg / ffprobe 则逐项核对编解码器、滤镜、封装器，再端到端跑通语音（PCM→MP3）、WXGF 静图（HEVC→PNG）、WXGF 动图（palettegen→GIF）与 ffprobe 数帧四条通路，并确认无非系统动态库依赖。WXGF 三条通路的输入样本是仓库里的 `tests/fixtures/wxgf-sample.h265`（12 帧、3.4 KB）——**不要改回用系统 ffmpeg 现造**，macos runner 镜像里没有预装 ffmpeg，那样整步会 `exit 127`。**替换 `vendor/macos/` 下任一二进制时必须保持这些成立**，否则 CI 直接失败。

### 怎么验证

三种手段，按代价从低到高：

1. **`swiftc` 单编命令行程序**——验证纯逻辑（HTML 渲染、媒体归档、分类、并发下载）最快。把相关源文件连同一个临时 `main.swift` 一起编即可。`SingleFileExporter` 的依赖闭包是 `ImageExporter`、`WXGFTranscoder`、`StickerPackExporter`、`WxCliService`、`AppPaths`、`DatImageDecoder`、`SQLiteDatabase`、`EmojiExporter`、`MediaOrganizer`、`ConcurrentMap` 加 `Models/`。
2. **`./build_app.sh` 后打开 `.app`**——凡是涉及 `Bundle.main`、网络、进程环境的，**只能这样验**。
3. **`screencapture` + `osascript` 点击**——验证 UI 行为（分组、折叠、全选）。窗口坐标用 `System Events` 取 `position of window 1`。注意先 `activate` 再点，否则点击会落到别的窗口。

两个反复踩到的陷阱：

- `swift run` 跑出来的是裸可执行文件，没有 app bundle，拿不到 `Bundle.main.resourceURL` 里的 wx-cli（会退回 native backend），版本号也读成 `0.0.0`。
- **裸命令行程序不受 ATS 管辖**。同一段下载代码，命令行全过、`.app` 里全挂（`URLError -1022`）。凡是验网络请求，必须在真 `.app` 里做——这个坑让一个「已验证通过」的结论错了一整轮。

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

`vendor/macos/ffmpeg`（2.7 MB）与 `vendor/macos/ffprobe`（2.5 MB）是最小化 LGPL 静态构建，由 `scripts/build_ffmpeg_minimal.sh` 一并产出，`build_app.sh` 拷进 `Contents/Resources/`。

**它们不是给 Swift 用的，主要是喂给 wx-cli。** `WxCliService.childEnvironment()` 在现有环境上注入 `FFMPEG_PATH` 与 `FFPROBE_PATH` 指向包内二进制——这就是语音功能的全部接线：wx-cli 的 `export` 通路本身就会转码语音，拿到 ffmpeg 后自动把 SILK 转成 MP3 写进 `media/`，并挂进该条消息的 `media_files`（两条均已实测确认）。找不到时 wx-cli 降级导出原始 `.silk` 并打 hint，不会报错中断。

改动这块时注意三条红线：

- **两个二进制缺一不可。** wx-cli 用 ffprobe 的 `-count_frames` 数 WXGF 里 HEVC 流的帧数，据此决定输出静态 PNG 还是动图 GIF。只给 ffmpeg 不给 ffprobe，动态表情会始终出不来——这个坑踩过一次
- **构建脚本不可加 `--enable-gpl` / `--enable-version3`**。`libmp3lame` 是 LGPL，不需要 GPL；一旦加了，MIT 的分发前提就不成立。详见 `vendor/README.md`
- 组件清单是从 wx-cli 二进制里还原出的实际调用倒推的，`--disable-everything` 之下漏一个组件就是运行期才炸。踩过两次：PCM demuxer 的组件名是 `pcm_s16le` 而非格式名 `s16le`；png 编解码器依赖 zlib，而 `--disable-autodetect` 会连 zlib 一起关掉，configure 于是**静默丢弃** png，直到用户导出时才报 `Unknown encoder 'png'`。**所以自检必须逐项核对每个组件并端到端跑通每条通路**，构建脚本和 CI 里都有

`WXGFTranscoder.locateFFmpeg()` 也会优先用包内这份，把 WXGF 动态表情转成动图 GIF；拿不到 ffmpeg 时退回 AVFoundation 只能取单帧静图。

### macOS 的第二后端（native fallback）

`AppViewModel.Backend` 是 `.wxCli` 或 `.native` 二选一，构造时若找不到任何 wx-cli 才落到 `.native`。native 路径是自研的完整实现，Windows 侧没有对应物：

`AppPaths.detect()` 定位 `~/Library/Containers/com.tencent.xinWeChat/…/xwechat_files/<账号>/db_storage`（按 `message_0.db` 修改时间挑最新账号）→ `KeyCaptureService` 用内嵌 LLDB Python 脚本在 `CCKeyDerivationPBKDF` 下断点抓密钥（会 `killall WeChat`）→ `CryptoService` 做 SQLCipher 页解密（PBKDF2 256000 轮、4096 页、HMAC 校验）→ `ContactStore` / `ChatExporter` 直接读解密后的 SQLite。

`AppPaths` 还负责：`PRAGMA quick_check` 健康检查（`isDecryptedHealthy`）、从 `~/Library/Caches/wx-cli/<账号>/db_storage` 同步解密结果（`syncFromWxCliCache`）、清理 `-wal`/`-shm`、迁移旧版 `~/wechat-export`。

### 导出管线

`AppViewModel.exportSelected()` 对每个会话：建临时目录 → `wx-cli export` 写 json（必要时再写 txt）→ 后处理 → 按 `ExportMode` 决定落盘形态 → 删临时目录。后处理链：`normalizeExportArtifacts`（把 `联系人_日期.json` 统一复制成 `chat.json`/`chat.txt`，并从 JSON 生成带 BOM 的 `chat.csv`）、含媒体时再跑 `EmojiExporter` → `ImageExporter`（内部调 `DatImageDecoder` 解 `.dat`、`WXGFTranscoder` 转 WXGF）。

**别再把 txt 和 json 都跑成含媒体。** wx-cli 每一趟 `export` 都会完整重做图片解密与语音转码，跑两趟等于媒体活干两遍（实测 4413 个媒体文件的群聊：72s + 74s）。所以 `export(needsPlainText:)` 在网页导出下为 `false`，直接省掉 txt 那趟。注意**不能改用 `--no-media` 来省**：txt 里的 `[图片1] media/xxx.png` 附件索引会整段消失（实测少 4416 行），分类导出与全部导出要把 chat.txt 交给用户，必须跑真的那一趟。含媒体时两趟都会带 `--parallel`（`WxCliService.mediaParallelism`，默认 `min(CPU,4)` 太保守，实测 74s → 41s）。

进度条靠 `WxCliService.parseMediaProgress` 解析 stderr 的 `media: image 610/762`，经 `AppViewModel.exportProgressHandler` 映射到「会话区间的 10%–90%」，两头留给读消息与整理文本。不接这个的话，含媒体的大会话导出期间界面就只有一个不动的「处理中…」。

**`EmojiExporter` / `ImageExporter` 里下载前一定要先按内容去重。** 群聊里同一张表情会被反复发送——实测一个群有 3095 处表情引用，唯一 URL 只有 1190 个，最热的一张出现 139 次。早先的写法给每次出现都用 `uniqueFilename` 起新名字（`md5_2.gif`、`md5_3.gif`…），`fileExists` 因此永远命不中，同一张图被重复下载上百遍，导出直接卡死在「正在下载表情」。现在先收集引用、按 URL（图片按 md5/aeskey）建唯一任务表，下载完再把同一个文件挂回所有引用它的消息。

这两个服务都用 `ConcurrentMap.run` 跑批（表情 8 路、图片 6 路并发），并各自设了时间预算（120s / 180s）。预算是必须的：微信 CDN 链接过期是常态，没有上限的话几千个失效链接足以让导出永远跑不完。单请求超时也要短——表情只有几十 KB，默认 30 秒纯属浪费。

**ATS 例外不能删。** 微信 CDN 的媒体几乎全是明文 `http://`（实测 44570 : 560），App Transport Security 默认拦截，报 `URLError -1022`。`build_app.sh` 生成的 Info.plist 里为腾讯 / 微信的 CDN 根域（qq.com、qpic.cn、qlogo.cn、wechat.com、tenpay.com、gtimg.com）配了 `NSExceptionDomains`，没有用 `NSAllowsArbitraryLoads` 全局关闭。换了新的 CDN 域名要往这里加。

### 媒体缺失是常态，要如实呈现

微信本地并不保存所有媒体：实测一个群里 308 个视频、9 条语音在本机根本没有文件（wx-cli 报 `video(s) skipped — not found after hardlink + directory scan`），2927 张图只有缩略图。此时 wx-cli 的 snippet 会退化成 `[video <md5>]` 这种「类型 + 内容哈希」。`SingleFileExporter.cleanContent` 负责把它规整成 `[视频]`，`missingMediaNote` 再把它换成说明为什么没有、以及怎么补救的文案——不要让用户对着一串十六进制猜。

**落盘形态由 `ExportNaming` 统一**：四种模式一律把单个会话写进 `<导出目录>/<联系人>_<时间戳>/`，时间戳由 `exportSelected` 开头算一次（`runStamp`）后全程复用，所以同一批导出的文件夹在 Finder 里挨在一起，重复导出也不会覆盖上一次。早先网页导出是把多卷 HTML 和 `<名称>_<时间戳>_media/` 直接摊在导出根目录里，导几个会话后根目录就分不清谁是谁——不要改回去。文件夹名已带时间戳，所以里面的网页文件名不再重复带（`张三_1.html`、`张三_2.html`，单卷时就是 `张三.html`）。

`ExportMode`（持久化在 UserDefaults `export.mode`）：
- `categorized`（默认）→ `MediaOrganizer.organize` 归档到 `<联系人>_<时间戳>/{文字,图片,视频,语音,其他}/`
- `textOnly` → 只拷 txt/json/csv，且 `includesMedia == false`（wx-cli 加 `--no-media`）
- `all` → 原样递归拷贝全部文件
- `singleFileHTML` → `SingleFileExporter.writeHTML`，表情包另出一张 `writeStickerGallery` 画廊（单个文件，放在导出根目录）

新增 case 时注意 `includesMedia` 必须返回 `true`，否则 wx-cli 被加 `--no-media`，拿不到任何媒体。

`SingleFileExporter.embedMedia` **纯按文件扩展名分派**，与 msg_type 无关——语音只要是 `.mp3` 就渲染成 `<audio>`。视频与 >8 MB 的文件不做 base64，改由 `ExternalMediaSink` 拷进会话文件夹的 `media/<类型>/` 后相对路径外链（base64 会让含视频的 HTML 涨到 GB 级）。**分类表只有 `MediaOrganizer.category(forExtension:)` 这一份**，分类导出与网页导出共用，别再各写一份扩展名列表。`renderOrphanMedia` 兜底渲染没被任何消息引用的媒体，但它们会堆在最后一卷末尾而非按时间内联。

`writeHTML` 超过 `defaultMessagesPerPage`（1000 条）会自动分卷，返回 `[URL]` 而非单个 URL。分卷时各卷**共用同一个媒体目录**（避免视频被拷多份），但**每卷各自做媒体去重**——同一张图被两卷的消息引用时两卷都要显示，否则读者在第 3 卷会看到无图的消息。单卷时文件名保持不带编号，与旧行为一致。

**两端分叉**：Windows 的 `SingleFileExporter.cs` 一直是主路径且只出 HTML；macOS 这边 HTML 只是四选一里的一种。两边的 HTML 结构和样式并不一致，改一侧不会自动同步到另一侧。

### 会话分类

`ContactKind.classify(username:isGroupType:officialAccounts:)`（`Models/ContactItem.swift`）是**唯一**的分类入口，wx-cli 与 native 两个后端都走它——早先两边各写了一份 if-else，很容易分叉。

**光看 username 分不出公众号。** 微信里不少公众号的 username 就是 `wxid_` 开头，和真人好友完全同构（多家媒体号、银行服务号都是这种形态），只按前缀判断会把它们全判成好友。真正的判据是 `contact` 表的 `verify_flag`：非 0 即为认证过的公众号 / 服务号（订阅号 24、服务号 28/29、媒体号 1048；实测一份真实数据里 25336 个 0、730 个非 0）。wx-cli 的 `sessions` 输出不带这个字段，所以 `OfficialAccountIndex` 直接读它解密缓存里的 `contact.db`（定位手法与 `StickerPackExporter.locateEmoticonDB` 一致），读一次缓存住。读不到时退回按前缀判断，不会崩。

实测 875 个会话：公众号 370、好友 306、群聊 136、其他 63。

侧栏按 `AppViewModel.sidebarRows(collapsed:expandAll:)` 渲染，组内保持按时间排序。这里有两个踩过的坑：

- **不要用 `Section`。** macOS 会把带 Section 的 `List` 渲染成 `NSOutlineView`，它自带一套折叠状态，和自己维护的 `collapsedKinds` 会打架——表现为实际折叠情况与代码里写的默认值完全不符。
- **标题与会话要摊平成单一数组再交给 `ForEach`。** 在 `ForEach` 里混着发标题和条件行，List 差分算不清每行身份，折叠后会留下一片空白行。`SidebarRow` 枚举给每行一个稳定 id 就好了。

搜索时 `expandAll` 强制展开所有分组，否则命中的会话会被折叠的分组藏起来，看着像搜不到。

### 进度与日志

`LoadProgressTracker`（`Models/LoadProgress.swift`）合并「时间预估」与「真实分页进度」，保证进度条单调不回退：无总量时按耗时爬到 ≤30%，解密阶段 ≤35%，拿到 `paging.total` 后映射 35%–99%。

**日志绝不能逐行派发到主线程。** `AppViewModel.logHandler()` 返回的闭包只往 `LogBuffer`（`Models/LogBuffer.swift`）里塞，由 `startLogPump()` 每 200ms 批量刷进 `@Published logs`（上限 300 行），空闲 3 秒后自动停下。`WxCliService.run()` 也直接在读管道的线程上调用 `log`，不再 `DispatchQueue.main.async`。原因：wx-cli 处理上千张图且每张都报错时，几秒内上万次主线程派发会把主队列彻底堵死，应用在活动监视器里显示「未响应」——这个坑踩过。`LogBuffer` 还会把连续重复的行折叠成「（上一行重复了 N 次）」。

### 自动更新（仅 macOS）

`UpdateService` 查 GitHub `releases/latest`，**优先选 ZIP 资产**（静默更新用，无需挂载），DMG 仅供手动下载。自动模式流程：后台下载 ZIP → `ditto` 解压到 `~/Library/Application Support/WeChatExporter/pending-update-<版本>/` → 写 `UpdatePreferences.pendingInstallPath` → 发系统通知（`NotificationService`，未授权则降级为应用内弹窗）。安装动作由 `replaceApp` 写一个临时 bash 脚本完成——脚本 quit 旧应用、`cp -R` 覆盖、`xattr -cr` + adhoc `codesign`、`open` 新版本，因为运行中的 app 不能覆盖自身。`AppDelegate.applicationDidFinishLaunching` 启动 1 秒后自动应用待安装更新。

版本号来源是 `Info.plist` 的 `CFBundleShortVersionString`，而该 plist 由 `build_app.sh` 内联生成——所以改版本号只能改 `build_app.sh`，源码里没有版本常量。

## 约定

- 用户可见文案、日志、代码注释统一用简体中文；错误通过 `AppError` / `UpdateError` 的 `errorDescription` 给出可操作的中文提示（例：提示关 SIP、以管理员身份运行）
- macOS 需要关闭 SIP；`WxCliService.tryAutoFixDevToolsSecurity` 会在 SIP 已关但 DevToolsSecurity 未启用时，用 `NSAppleScript` 弹系统授权框自动执行 `DevToolsSecurity -enable`（必须在主线程调用）
- 导出查询一律用 `contact.id`（wxid/username）而非 `displayName`，后者不唯一会导致导出错位
- `.gitignore` 已封掉 `raw_key.bin`、`all_keys.json`、`**/decrypted/`、`*.db`——不要放行这些
- 仓库为 `Sheldon1001/WeChatExporter`（`origin`），是 `93857536-pixel/WeChatExporter`（`upstream`）的 fork——**发布只推 origin**；仓库 About 信息由 `scripts/update_github_about.sh` 维护
- 应用内「检查更新」「Release 下载」「GitHub 仓库」「问题反馈」四处都由 `UpdateService.repoOwner` / `repoName` 派生，换仓库只改这一处
