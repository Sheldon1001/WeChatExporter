# macOS 新增「单文件 HTML」导出方式（含语音）— 需求与实施计划

> 状态：**已完成**（2026-08-17，v2.14.0，分支 `fix/stale-html-copy`）。
> 创建日期：2026-08-16 · 保留本文档是因为第二节的调查证据仍有参考价值。
>
> **第四节的两条契约已实测确认成立，附录 A 未启用。**实测记录：
> - `wx-cli export` 在 ffmpeg 可用时自动把 5/5 条语音转成 MP3（ID3v2.4 / 64 kbps / 24 kHz / 单声道）
> - 转码结果确实写进了该条消息的 `media_files`（`["media/<svr_id>.mp3"]`），因此语音按时间内联在对话流中，不走 orphan 兜底
> - `FFMPEG_PATH` 单独设置即生效，PATH 上无需有 ffmpeg
>
> 与计划有出入的三处，以实际为准：
> - 计划 2.2 称无 ffmpeg 时「直接报错，不自动降级」——那是 `media extract-voice` 子命令的行为；`export` 通路会自动降级导出 `.silk` 并打 hint，不中断
> - 计划 2.5 预估 ffmpeg 增重 6~10 MB，实际 **2.7 MB**
> - 实施中额外修掉了两个渲染缺陷：表情消息的原始 XML 被当正文渲染、媒体缺失时占位文案被压掉导致空卡片

---

## 一、需求理解

### 1.1 用户要什么

macOS 端新增一种导出方式：生成可用浏览器直接打开的 HTML 文件，**内嵌图片、视频、语音、链接等内容**。

### 1.2 背景：为什么现在没有

macOS 在 **v2.12.0** 主动移除了媒体 base64 内嵌的单文件 HTML 导出，改为直接输出文件夹结构（见 `CHANGELOG.md` 的 2.12.0 条目）。这导致：

- `Sources/WeChatExporter/Services/SingleFileExporter.swift`（735 行）成为**无人调用的死代码**，但仍在编译
- Windows 侧的 `SingleFileExporter.cs` **至今仍是主路径**，两端行为已分叉
- 界面与文档留下多处过期文案，仍在告诉用户「会生成 HTML 文件」

### 1.3 已确认的四项决策

均由用户在了解代价后拍板，**执行时不要擅自更改**：

| 议题 | 决定 | 理由 |
|---|---|---|
| HTML 形态 | `ExportMode` 增加第四个 case，四选一 | 改动最小，与现有 UI 一致 |
| 视频 | **一律外链**（相对路径），不做 base64 内嵌 | 微信视频动辄几百 MB，base64 再膨胀 33%，会生成 GB 级 HTML 导致浏览器卡死 |
| 语音 | 转 MP3，**可播放** | 用户在了解需捆绑依赖后仍选择此项 |
| ffmpeg | **随包捆绑** | 用户在知晓体积与授权代价后选定；目的是让所有用户开箱即用，不要求自行安装 |
| ffmpeg 构建范围 | 语音通路 + WXGF 动图 | 多花几 MB 换取动态表情真的会动 |

---

## 二、调查发现（含证据，勿重复推导）

以下结论均已实测或有二进制字符串证据支撑，是本方案成立的基础。

### 2.1 渲染器是现成的，不用重写

`SingleFileExporter.swift` 功能完整：图片内嵌、`.dat` 解密、WXGF 转码、完整 CSS、消息类型标签（`typeLabel` 已含 `34: 语音`）、表情包画廊。只需改 3 处即可复用。

### 2.2 语音转码能力已在 wx-cli 内，缺的只是 ffmpeg

**实测验证通过**：

```bash
./vendor/macos/wx-cli media extract-voice \
  --media-dir ~/Library/Caches/wx-cli/<账号>/db_storage/message \
  -o /tmp/probe.mp3 <svr_id>
# → 5270 字节 SILK 转出 25580 字节 MP3（ID3v2.4 / 64kbps / 24kHz / 单声道）
```

**ffmpeg 是硬依赖**：把 ffmpeg 移出 PATH 后同一命令直接报错，且不会自动降级为原始 SILK（需显式传 `--raw`）。错误信息明示支持 `FFMPEG_PATH` 环境变量指定。

**导出流程本身就会转码语音**：二进制内 `crates/wx-cli/src/cmd/export_task.rs` 紧邻字符串 `warning: voice transcode failed for svr_id=`，说明 `export` 命令内部即尝试语音转码并在失败时告警。

> 补充：另有一处 `... is unavailable because wx-cli was built without the 'audio' feature`，经上下文判断属于 `server` 子命令的某个输出格式分支，**不影响导出通路**。

### 2.3 ffmpeg 顺带修好 WXGF 动态表情

wx-cli 的 WXGF 通路同样需要 ffmpeg（字符串 `requires ffmpeg for HEVC decode`），且使用 `palettegen` 生成**动图 GIF**。而当前无 ffmpeg 时，仓库的 `WXGFTranscoder` 退回 AVFoundation，只能取**单帧静图**（`WXGFTranscoder.swift:100-127`）。

### 2.4 从二进制还原出的 ffmpeg 实际调用

```
语音： -hide_banner -loglevel error -f s16le -ar 24000 -ac 1 -i pipe:0 -b:a 64k -f mp3 pipe:1
WXGF： -i pipe:0 -frames:v 1 -f image2pipe -vcodec png pipe:1
       -filter_complex [0:v]split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse
```

这决定了最小构建需保留哪些组件（见 3.1）。

### 2.5 体积基线

| 项 | 大小 |
|---|---|
| 当前 macOS DMG | 10 MB |
| 当前 macOS ZIP | 7 MB |
| `vendor/macos/wx-cli` | 12 MB |
| 预计新增 ffmpeg | +6~10 MB |

> Homebrew 的 ffmpeg **不可直接搬运**：12 个非系统 dylib 依赖，必须静态构建。

### 2.6 渲染兜底机制

`renderOrphanMedia`（`SingleFileExporter.swift:536-563`）会递归遍历 `media/`，把未被任何消息引用的文件渲染成独立卡片。因此语音即使没挂进 `media_files` 也不会丢失，**但会堆在文档末尾而非按时间内联**。

`embedMedia` **纯按文件扩展名分派**，与 msg_type 无关——只要文件是 `.mp3` 就会渲染成 `<audio controls>`（`SingleFileExporter.swift:609-611`）。

---

## 三、实施方案

### 3.1 捆绑最小静态 ffmpeg

新增 `scripts/build_ffmpeg_minimal.sh`，构建 **LGPL-only 静态** ffmpeg，产物提交到 `vendor/macos/ffmpeg`（与 `wx-cli` 同样以预编译二进制入库，符合仓库既有做法）。

configure 骨架（所需组件已在本机 ffmpeg 8.0.1 上逐项确认存在，且无一需要 GPL）：

```
--disable-everything --enable-static --disable-shared --disable-programs --enable-ffmpeg
--enable-demuxer=s16le,hevc,image2
--enable-decoder=pcm_s16le,hevc
--enable-encoder=libmp3lame,png,gif
--enable-muxer=mp3,image2,image2pipe,gif
--enable-filter=split,palettegen,paletteuse,scale
--enable-protocol=pipe,file
--enable-libmp3lame --enable-videotoolbox
```

> ⚠️ **授权红线**：`libmp3lame` 是 LGPL，**不触发 GPL**。务必不要加 `--enable-gpl`（Homebrew 那份加了是因为捆了 x264），也不要加 `--enable-version3`，以保持在 LGPL v2.1 下。

**打包接入**：`build_app.sh` 在拷贝 wx-cli 之后（参照 `build_app.sh:22-24`），同样把 `vendor/macos/ffmpeg` 拷进 `Contents/Resources/` 并 `chmod +x`。

### 3.2 让 wx-cli 找到捆绑的 ffmpeg

`WxCliService.run()` 当前是 `process.environment = ProcessInfo.processInfo.environment`。改为在此基础上注入 `FFMPEG_PATH` 指向 bundle 内的 ffmpeg；找不到则不注入，保持现有降级行为。

定位函数参照 `WxCliService.bundledExecutable()`（`WxCliService.swift:21-30`）。

**这就是语音功能的全部接线**——无需新增 VoiceExporter。

### 3.3 复活 SingleFileExporter

整体保留，只改 `embedMedia`（`SingleFileExporter.swift:565-620`）三处：

- **视频**：`mp4`/`mov` 分支从 base64 内嵌改为拷贝到外部 media 目录 + 相对路径 `<video controls src="...">`
- **语音**：`silk` 分支保留作为降级占位（仅 ffmpeg 缺失时才会走到），文案从「大小 N 字节」改为提示性说明
- **链接**：新增 linkify，把正文中的 `http(s)://` 转成 `<a target="_blank" rel="noopener">`。当前链接只是被 `escapeHTML` 转成纯文本

### 3.4 ExportMode 增加第四个 case

`Models/ExportMode.swift` 加 `case singleFileHTML`。

⚠️ `includesMedia` **必须返回 `true`**，否则 wx-cli 会被加 `--no-media`，拿不到任何媒体。

设置页 picker 是 `ForEach(ExportMode.allCases)`，第四项自动出现，UI 代码不用动（但需目视确认四项布局不挤）。

### 3.5 AppViewModel 接线

`exportSelected()` 的 switch（`AppViewModel.swift:321-343`）增加 `.singleFileHTML` 分支，调用 `SingleFileExporter.writeHTML`。表情包在该模式下改用现成的 `writeStickerGallery` 输出画廊 HTML，而非当前的文件夹。

产物布局：

```
微信聊天记录导出/
├── 张三_20260816-1930.html          ← 图片/表情/语音内嵌
├── 张三_20260816-1930_media/        ← 仅视频与大附件
└── 全部表情包_20260816-1930.html
```

HTML 与其 media 目录同名配对，多个会话导到同一目录不会互相覆盖。

### 3.6 补上 MediaOrganizer 的音频分类

`MediaOrganizer` 的分类扩展名表（`MediaOrganizer.swift:14-18`）只有 文字/图片/视频三类，**没有音频**。捆绑 ffmpeg 后语音开始产出 `.mp3`，「分类导出」模式会把它们全丢进「其他」。

需增加音频桶（`mp3`/`m4a`/`aac`/`wav`/`silk`）归档到 `<联系人>/语音/`，`Result` 结构体与导出摘要文案同步加一项。

> 这是本次改动对既有导出方式的**连带必需修正**，不是主动改动。

### 3.7 授权合规（随捆绑 ffmpeg 强制，不可省略）

- 将 ffmpeg 的 `COPYING.LGPLv2.1` 全文放入 `Contents/Resources/`，并在「关于」页或 README 注明
- `vendor/README.md` 增加 ffmpeg 行：来源版本、精确 configure flags、源码获取地址
- `scripts/build_ffmpeg_minimal.sh` 本身即构成「可重新构建 / 重新链接」的凭据，满足 LGPL 静态链接下的 §6 义务
- README 增加第三方组件与授权说明段落

> 法律定性：我们以**独立子进程**方式调用 ffmpeg，不是链接进程序，因此不构成衍生作品，项目的 MIT 许可不受传染。但随包分发本身仍触发上述义务。

### 3.8 订正过期文案

这些原本就错，且本次改动后含义再次变化：

| 位置 | 现文案 | 问题 |
|---|---|---|
| `Views/ContentView.swift:338` | 「点击『导出选中』生成 HTML 文件」 | 改为中性表述（四选一里只有一种出 HTML） |
| `Views/SettingsView.swift:415` | 同上 | 同上 |
| `Models/ExportMode.swift:9` | 注释「全部导出（文字 + 媒体内嵌到 HTML）」 | 与实现相反 |
| `Models/ExportMode.swift:25` | `textOnly` 描述含 HTML | 实际只拷 txt/json/csv |
| `README.md:33` | 「单文件导出……全部内嵌」 | v2.12.0 之前的描述 |

### 3.9 CI

`.github/workflows/ci.yml` 现有对 wx-cli 的校验（`doctor` 通过 + strings 含 `4.1.11`）需增补：

- 断言 `WeChatExporter.app/Contents/Resources/ffmpeg` 存在且可执行
- 跑一次 `ffmpeg -encoders | grep libmp3lame` 确认最小构建没漏组件

---

## 四、两条待验证契约 ⚠️

**这是本方案最大的风险点。** 以下两条只有字符串证据，制定计划时无法实跑验证。**执行时必须作为第一步验证**：

1. **`wx-cli export` 在 ffmpeg 可用时自动转码语音**
   → 不成立则整个 3.2 的「零代码接线」失效，须改走附录 A

2. **转码后的 mp3 被写进该条消息的 `media_files`**
   → 不成立则语音只能靠 `renderOrphanMedia` 兜底堆在文档末尾，须补一段按 svr_id 回填 `media_files` 的逻辑（回填手法可抄 `ImageExporter.appendMediaFile`，`ImageExporter.swift:87-91`）

---

## 五、验证方法

仓库**没有任何测试设施**（`Package.swift` 只有一个 `executableTarget`，CI 也不跑测试），因此验证以实跑为主。

1. **先验证第四节的两条契约**。手工把 `vendor/macos/ffmpeg` 放上 PATH 或设 `FFMPEG_PATH`，跑一次含媒体导出，检查：
   - `media/` 下出现 `.mp3` 而非 `.silk`
   - `chat.json` 里语音消息的 `media_files` 含该 mp3
2. `swift build --disable-sandbox -c release` 通过
3. `./build_app.sh` 后确认 `Contents/Resources/` 内 wx-cli 与 ffmpeg 均存在且可执行
4. 打开 `.app`，选「单文件 HTML」导出一个含语音 / 图片 / 视频 / 链接的会话
5. 浏览器打开产物，逐项确认：图片显示、**语音可播且位置在对话流正确时点**、WXGF 表情会动、链接可点、视频能播
6. 切到「分类导出」再导一次，确认语音落进 `<联系人>/语音/` 而非「其他」
7. 临时移走 `Contents/Resources/ffmpeg`，重导一次，确认降级为占位文字而非崩溃

---

## 六、附录 A：备选路径（仅当第四节契约 1 验证失败时启用）

新增 `Services/VoiceExporter.swift`。**这条路径比主方案贵得多**，涉及四处改动：

**a. 服务本体** — 对齐既有约定：`enum` + `static func exportVoices(in outputDir: URL, log: @escaping (String) -> Void) async -> Int`，不 throws，返回处理条数，失败靠 `try?` 吞掉不中断（参照 `ImageExporter.swift:9`）。插入点在 `WxCliService.export` 末尾的 `includeMedia` 块内（`WxCliService.swift:260-265`），与 `EmojiExporter` / `ImageExporter` 并列。产物写 `media/voices/<svr_id>.mp3`，并回填 `media_files`。

**b. 解析层要加字段** — `MessageRow`（`SingleFileExporter.swift:5-11`）没有任何 id 字段，`parseRow`（`:642-670`）也没读 `server_id`（全仓库 grep `server_id` 零命中）。但 wx-cli 的 `EnrichedMessage` 确实序列化了该字段，chat.json 里有，只是被 Swift 解析层丢弃。两处都要加。

**c. 定位解密缓存目录** — `.wxCli` 后端拿不到 `accountID`（`AppViewModel.init` 一旦构造出 `WxCliService` 就 `return`，`AppPaths.detect()` 根本不执行，见 `AppViewModel.swift:52-56`）。**直接复用 `StickerPackExporter.locateEmoticonDB()` 的手法**（`StickerPackExporter.swift:91-121`）：glob `~/Library/Caches/wx-cli/*/db_storage/`、`PRAGMA quick_check` 过滤、取 mtime 最新。把目标从 `emoticon` 换成 `message/media_0.db` 即可。

**d. 并发** — 仓库内**不存在任何可抄的并发模式**（全仓库 `TaskGroup|OperationQueue|DispatchSemaphore|concurrentPerform` 只命中 `NotificationService.swift:37` 一处），现有媒体服务全是串行 `for` + `await`。而语音量级很大（实测本机 `media_0.db` 有 6745 条），逐条起子进程不可接受，需自建 `TaskGroup` 并限流。

> 优化线索（与本需求正交）：wx-cli 的 `export` 自带 `--parallel`（help：`Max parallel threads for media resolve, default min(CPU,4)`），Swift 侧从未传过。含媒体导出慢时可从这里入手。

---

## 七、不做的事

- 不改 Windows 侧（它本来就在出 HTML）
- 不新增测试 target（如需回归保护应另行决定）
- 除 3.6 的音频分类外，不改现有三种导出方式的行为

---

## 八、发版提醒

`AGENTS.md` 规定**任何一次代码修改完成后都必须走完整发布流程**。本改动属功能变化，按规则：

- 次版本号 +1（`2.13.0` → `2.14.0`），Build 号递增
- 三处同步：`build_app.sh` 的 `APP_VERSION`/`APP_BUILD`、`windows/.../WeChatExporter.Windows.csproj` 的 `<Version>`、`CHANGELOG.md` 新条目
- 打 `v2.14.0` 标签推送，用 `gh run watch` 确认三个 job 全绿

> 若本次仍在本地分支开发、暂不发版，则跳过此节，待合并时再执行。
