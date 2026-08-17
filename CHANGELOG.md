# Changelog

All notable changes to this project are documented in this file.

## [2.14.1] - 2026-08-17

### Fixed
- **更新通道指向本仓库**：应用内「检查更新」与「Release 下载」此前查询的是上游仓库 `93857536-pixel/WeChatExporter`，本仓库自行发布的版本永远检查不到。现在两处都由 `UpdateService.repoOwner` / `repoName` 派生，换仓库只改一处
  - 设置页的「GitHub 仓库」按钮、README 徽章与下载链接、`install.sh` 提示、`scripts/update_github_about.sh` 默认仓库同步更新
  - 「问题反馈」按钮仍指向上游仓库——本仓库的 Issues 未开启，且 issue 模板在上游

## [2.14.0] - 2026-08-17

### Added
- **网页导出**（macOS）：新增第四种导出方式，生成可用浏览器直接打开的 HTML
  - 图片、表情、语音以 base64 内嵌，单个文件即可离线阅读
  - **单个网页最多 1000 条消息**，超出自动分卷成多个文件，页眉带上下页与页码导航；各卷共用一个媒体文件夹，视频不会被拷贝多份
  - 视频与大附件（>8 MB）拷进同名 `_media/` 文件夹外链，避免生成 GB 级 HTML 拖死浏览器
  - 正文中的 http(s) 链接自动变为可点击，按 RFC 3986 字符集切分，紧跟汉字或包在括号里都能正确断句
  - 表情包同时输出一张画廊网页
- **语音可播放**（macOS）：随包内置最小化静态 ffmpeg 与 ffprobe（合计 5.3 MB），wx-cli 自动把微信 SILK 语音转成 MP3
  - 未内置时 wx-cli 会降级导出原始 `.silk`，导出不会中断
- **动态表情会动**（macOS）：WXGF 表情改用 `palettegen`/`paletteuse` 转成动图 GIF，此前只能取单帧静图
- **语音归档**：「分类导出」新增 `<联系人>/语音/` 分类，此前语音会被丢进「其他」

### Added
- **会话按类型分列**：侧栏不再是一条长列表，改为「好友 / 群聊 / 公众号 / 其他」四个分组，点标题可折叠展开，公众号与其他默认收起
  - 点分组右侧的数量徽标可一键全选或取消该类的全部会话——公众号动辄三百多个，逐个点不现实
  - 搜索时自动展开全部分组，避免命中的会话被折叠的分组藏起来
  - 分类判定收敛到 `ContactKind.classify` 一处，两个后端（wx-cli 与 native）共用，不再各写一份
  - 新增「其他」类，收纳企业微信联系人、客服会话，以及服务通知、文件传输助手这类系统会话
  - **公众号识别改用 `verify_flag`**：微信里不少公众号的 username 是 `wxid_` 开头，与真人好友完全同构（「第一财经资讯」「三联生活周刊」「时尚芭莎」等），只看前缀会全部误判成好友。现在读解密后 `contact.db` 的 `verify_flag` 判定。实测 875 个会话分为：公众号 370、好友 306、群聊 136、其他 63

### Performance
- **表情下载不再卡住导出**（实测 74479 条消息的群聊：约 10 分钟 → 31 秒）
  - 同一张表情在群里会被反复发送，但每次出现都被当成新文件下载。实测 3095 处引用只对应 1190 个唯一表情，最热门的一张被重复下载了 139 次。现在按 URL 去重，只下一次
  - 下载改为 8 路并发（图片 6 路），此前完全串行
  - 单个请求超时由 30 秒收到 12 秒（表情只有几十 KB），并给整个阶段设 120 秒预算，超时后跳过剩余的而不是无限等下去——微信 CDN 链接过期是常态
  - 表情与图片阶段都会显示 `正在下载表情 320/1190` 这样的实时进度
- **含媒体导出快 2–3.7 倍**（实测 74479 条消息、4413 个媒体文件的群聊）
  - 原先对同一个会话跑两趟 wx-cli（txt 一趟、json 一趟），两趟都完整做了图片解密与语音转码。网页导出只读 `chat.json`，现在直接省掉 txt 那一趟：146s → 39s
  - 分类导出与全部导出仍需要 chat.txt（里面有 `[图片1] media/xxx.png` 附件索引，加 `--no-media` 会整段丢失），保留两趟但都提速：146s → 77s
  - 媒体解析传入 `--parallel`：wx-cli 默认只用 `min(CPU, 4)` 个线程，放开到 CPU 核数后单趟 74s → 41s
- **导出进度条不再空转**。此前含媒体的大会话导出期间界面只有一个不动的「处理中…」，现在解析 wx-cli 的 `media: image 610/762` 输出，显示当前会话、阶段与处理条数

### Fixed
- **表情在 `.app` 里全部下载失败**（日志显示成片的「网络错误」）。微信 CDN 的表情、图片、视频几乎全是明文 `http://`（实测 44570 个 http 对 560 个 https），而 App Transport Security 默认拦截明文请求，报 `-1022`。Info.plist 现在为腾讯 / 微信的 CDN 根域（qq.com、qpic.cn、qlogo.cn、wechat.com、tenpay.com、gtimg.com）开放例外，未使用 `NSAllowsArbitraryLoads` 全局关闭 ATS
- **视频消息显示成 `[video 4521309da…]` 这样的十六进制串**。wx-cli 找不到本地视频文件时会把「类型 + md5」当作正文返回，现在统一规整；并且媒体缺失时不再只留一个孤零零的 `[视频]`，而是说明原因与解决办法（在微信里打开该消息下载后重新导出）
- **导出大量媒体时界面卡死**。后台逐行把日志派发到主线程，媒体密集的导出几秒内上万行会把主队列灌满，应用变成「未响应」。改为后台缓冲 + 定时批量刷新，并把连续重复的行折叠成「（上一行重复了 N 次）」
- **内置 ffmpeg 缺少 png 编码器**，导致每张 WXGF 图片都报 `Unknown encoder 'png'` 并保持 `.wxgf` 无法显示。根因是 `--disable-autodetect` 连带关掉了 zlib，而 png 编解码器依赖 zlib，configure 于是静默丢弃了它；已显式 `--enable-zlib`，并把自检改为逐项核对全部编解码器 / 滤镜 / 封装器 + 端到端跑通 PNG 与 GIF 两条通路
- 补上遗漏的 ffprobe。wx-cli 靠它数 WXGF 的帧数来判断动图还是静图，只给 ffmpeg 不给 ffprobe 会导致动态表情始终出不来
- 表情与图片下载失败不再逐条刷屏日志，改为按原因汇总一行，并说明「微信 CDN 链接会过期，老消息的表情通常已无法取回」；网络类失败会重试一次
- 表情下载会校验返回内容确实是图片，避免把加密数据写成打不开的 `.gif`
- 表情类消息不再把原始 XML 当正文渲染进 HTML
- 媒体缺失时不再因为压掉占位文案而产生空白消息卡片

### Changed
- 订正多处过期文案：主界面与设置页的引导步骤不再声称「生成 HTML 文件」，`ExportMode` 的注释与描述与实现对齐，README 功能列表按四种导出方式重写

### Notes
- 内置 ffmpeg 为 LGPL v2.1 最小化静态构建（未启用 GPL），以独立子进程方式调用，不影响本项目的 MIT 许可
- 可用 `scripts/build_ffmpeg_minimal.sh` 重新构建，详见 `vendor/README.md`

## [2.13.0] - 2026-08-06

### Added
- **自然更新体验**：自动更新改为后台静默下载（ZIP，无需挂载 DMG），完成后弹系统通知横幅
  - 点击通知横幅「重启并安装」一键完成更新，不打断当前操作
  - 未点击时，下次启动应用自动应用更新
  - 通知权限未授权时降级为应用内提示

### Changed
- 更新检查优先使用 ZIP 资产（体积小、更快），DMG 仅用于手动下载
- 更新弹窗「下载并安装」改为「下载更新」，下载后经系统通知完成安装

## [2.12.0] - 2026-08-06

### Added
- **导出方式选择**：设置中可选择三种导出方式
  - 分类导出：文字、图片、视频分别归档到独立文件夹
  - 只导出文字：仅导出 txt / json / csv
  - 全部导出：导出全部文字与媒体文件（不生成内嵌 HTML）
- 表情包在含媒体模式下导出到「全部表情包」文件夹

### Changed
- 不再生成媒体 base64 内嵌的单文件 HTML，改为直接输出文件夹结构

## [2.11.0] - 2026-08-06

### Changed
- **设置面板布局重构**：改为 macOS 系统设置风格的「左侧导航 + 右侧内容」双栏布局，导出/更新/关于三个入口清晰切换
- 右侧内容区支持滚动，内容较多时不再挤压截断

## [2.10.1] - 2026-08-06

### Fixed
- **日志面板 JSON 刷屏**：`sessions --format json` 的原始输出不再刷进 UI 日志，只显示有意义的状态信息
- **窗口标题**：主窗口标题从「详情」修正为「微信聊天记录导出」

## [2.10.0] - 2026-08-06

### Added
- **科技感 UI 重设计**：全新青蓝色主题配色、渐变头部卡片、终端风格日志面板
- **统一设置面板**：整合导出/更新/关于三个标签页，独立设置按钮入口
- **更新方式选择**：支持自动更新 / 仅通知 / 手动检查 / 关闭四种模式
- **DevToolsSecurity 自动检测**：SIP 关闭时自动检测并启用 DevToolsSecurity

### Fixed
- 修复 DMG 挂载点解析失败问题（改用 `-mountpoint` 显式指定挂载路径）
- 修复链接按钮参数缺失导致的编译错误

## [2.6.4] - 2026-07-23

### Changed
- **内置 wx-cli**：改为仓库 `vendor/` 随附，构建不再依赖外部 wx-cli GitHub 仓库下载
- macOS 内置 CLI 支持微信 **4.1.7–4.1.11**
- Windows 内置 `wx.exe` 改为使用仓库 vendored 副本（上游 jackwener/wx-cli 因 DMCA 不可用）

### Fixed
- CI/Release 因外部 CLI 下载 404 / DMCA 导致打包失败

## [2.6.3] - 2026-07-23

### Fixed
- 支持微信 **4.1.11**：密钥提取版本白名单扩展至 4.1.7–4.1.11
- 「环境检查未通过」时输出 wx-cli doctor 失败项详情

## [2.6.2] - 2026-07-08

### Added
- **WXGFTranscoder**：自动将微信 `*.wxgf` 图片提取 HEVC 首帧并转码为 JPEG 后嵌入 HTML
- 表情包导出遇到 WXGF 资源时，同样会尝试自动转码

### Fixed
- HTML 导出里 WXGF 图片只显示占位提示、无法直接浏览的问题（macOS 原生解码优先，双平台支持 ffmpeg 回退）

## [2.6.1] - 2026-07-08

### Added
- **ImageExporter**：从聊天 JSON 解析 `<img>` 标签，按 CDN 链接下载图片并写入消息
- **DatImageDecoder**：自动解密 `.dat` 加密图片（优先 wx-cli `decode-image`，失败时 XOR 探测）
- HTML 导出以 `<img>` 内嵌 base64，聊天图片可直接在浏览器中显示

### Fixed
- 勾选媒体导出后仍只显示 `[图片]` 占位、无法看图的问题

## [2.6.0] - 2026-07-08

### Added
- 勾选「同时导出媒体」时额外导出**全部表情包**（收藏表情 + 已下载商店表情），生成独立的 `全部表情包_<时间>.html` 画廊文件
- 从 wx-cli 解密缓存中的 `emoticon.db` 读取 CDN 链接并下载（支持 AES 加密表情）

### Changed
- 导出选项文案明确包含「全部表情包」

## [2.5.1] - 2026-07-08

### Changed
- 单文件 HTML 导出界面美化：深空霓虹 HUD 风格，与 macOS DMG 安装界面视觉一致（玻璃拟态消息卡片、星点/网格背景、青紫霓虹标题与媒体光晕）

## [2.5.0] - 2026-07-08

### Changed
- 每次导出生成**单个 HTML 文件**（图片、表情、音视频以 base64 内嵌），浏览器打开即可查看全部内容
- 不再在导出目录留下 chat.json / media 等分散文件夹

## [2.4.0] - 2026-07-08

### Added
- 勾选「同时导出媒体」时自动下载聊天中的表情/贴纸（GIF/PNG）到 `media/emojis/`
- macOS 导出时向 wx-cli 传递 `--show-emoji`，保留表情详情

### Changed
- 导出选项文案明确包含「表情」

## [2.3.9] - 2026-07-07

### Fixed
- macOS DMG 背景图无法铺满窗口：修正 1x/2x 背景 DPI（72/144）并合并为 Retina TIFF，Finder 不再只显示左上角

## [2.3.8] - 2026-07-07

### Changed
- macOS DMG 安装包界面美化：自定义背景、图标拖拽布局、卷标图标与固定窗口尺寸

## [2.3.7] - 2026-07-06

### Fixed
- macOS 勾选「同时导出媒体」后显示 0 条：wx-cli 实际输出为「联系人_日期.json」，现已正确统计并复制为 chat.json/txt/csv
- 含媒体导出取消 600 秒超时限制，避免大体积导出被中断
- Windows 同步改进 JSON 消息计数（支持 wrapper 格式）

## [2.3.6] - 2026-07-06

### Added
- **Windows**：会话加载与准备数据进度条（先时间预估，完成后显示实际数量）
- **Windows**：取消会话/初始化超时上限，使用 `-n 999999` 拉取全部会话
- **Windows**：未准备数据时跳过启动自动加载

## [2.3.5] - 2026-07-06

### Added
- 会话加载进度条：先时间预估，拿到总量后按「已加载 / 总数」实时更新
- 分页拉取全部会话（每批 500 条），不再受 120 秒超时限制

### Changed
- 准备数据 / 解密过程同样显示进度条
- wx-cli 长时间任务取消固定超时，改为无上限等待

## [2.3.4] - 2026-07-06

### Fixed
- macOS 加载会话列表超时：移除 `--all`（最多 2 万条），改用 `--limit 10000`，超时延长至 5 分钟
- 未准备数据时不再盲目加载会话，避免首次启动长时间卡住
- wx-cli 执行过程实时输出日志，超时时给出更明确的提示

### Changed
- 解密命令超时延长至 10 分钟；会话查询使用 `--no-server` 直连本地缓存

## [2.3.3] - 2026-07-06

### Fixed
- macOS 启动崩溃：修复 wx-cli 在后台线程回调导致 SwiftUI 菜单栏断言失败（SIGABRT）
- 将自动加载会话列表从 `init` 延迟到界面 `onAppear`，避免启动阶段竞态

### Changed
- 全新科技感应用图标（深青渐变 + 导出箭头）
- 构建脚本不再将 PNG 误当作 icns 使用，确保 Dock/Finder 图标尺寸正确

## [2.3.2] - 2026-07-06

### Added
- App icon bundled in repository (`assets/AppIcon.png`)
- README screenshots, badges, English README, CHANGELOG, CONTRIBUTING
- GitHub Issue templates and CI workflow (Swift + .NET build)
- `scripts/prepare_icon.sh` for macOS icns generation

### Changed
- README reorganized with Release-first install instructions
- `install.sh` documents DMG download and optional `CREATE_DMG=1`

## [2.3.1] - 2026-07-06

### Added
- macOS DMG installer (`WeChatExporter-macOS-arm64.dmg`) with drag-to-Applications layout
- `scripts/create_dmg.sh` for local DMG generation

### Changed
- GitHub Releases now publish DMG as the recommended macOS download

## [2.3.0] - 2026-07-06

### Added
- Windows self-contained Release build (no .NET runtime required)
- Optional media export toggle on macOS and Windows
- Readiness status banner in both UIs
- Windows administrator detection and one-click restart as administrator

### Changed
- First launch no longer shows error dialogs when data is not prepared yet
- Improved bootstrap and session loading UX

## [2.2.0] - 2026-07-06

### Added
- Windows WPF application with bundled jackwener/wx-cli
- GitHub Actions automated Release builds for macOS and Windows
- Bundled wx-cli inside macOS app (pandorafuture/wx-cli)

### Changed
- macOS app prefers bundled CLI over system-installed wx-cli

## [2.1.0] - Initial public release

### Added
- Native macOS SwiftUI chat exporter
- TXT / CSV / JSON export
- LLDB key capture and SQLCipher decryption fallback backend
- wx-cli integration for session list and export
