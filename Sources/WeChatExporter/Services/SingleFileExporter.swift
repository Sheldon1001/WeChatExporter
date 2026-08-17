import Foundation

/// 将导出目录中的聊天记录与媒体渲染成 HTML：图片、表情、语音以 base64 内嵌，
/// 视频与大附件拷进同一个会话文件夹的 `media/<类型>/` 后用相对路径外链。
///
/// 视频不内嵌是刻意的：微信视频动辄几百 MB，base64 还要再膨胀约 33%，
/// 内嵌会生成 GB 级 HTML 把浏览器拖死。
enum SingleFileExporter {
    struct MessageRow {
        let time: String
        let sender: String
        let type: String
        let content: String
        let mediaPaths: [String]
    }

    /// 单个媒体文件超过此大小就不再 base64 内嵌，改走外链，避免单个大文件撑爆 HTML。
    private static let embedSizeLimit = 8 * 1024 * 1024

    /// 外链媒体的落盘目录与其在 HTML 中的相对前缀。
    ///
    /// 文件按扩展名落进 `media/视频`、`media/图片`、`media/语音`、`media/其他` 子目录，
    /// 分类表与「分类导出」共用 `MediaOrganizer.category`。子目录按需创建——没有外链媒体
    /// 时不会留下一堆空文件夹。
    final class ExternalMediaSink {
        let directory: URL
        let relativePrefix: String
        private var createdSubdirs = Set<String>()
        private var assignedNames = Set<String>()

        init(directory: URL, relativePrefix: String) {
            self.directory = directory
            self.relativePrefix = relativePrefix
        }

        /// 把文件拷进外链目录，返回可直接写进 HTML `src` 的相对路径；失败返回 nil。
        func store(_ fileURL: URL) -> String? {
            let fm = FileManager.default
            // 文字类不会走到外链（HTML 只外链媒体与大附件），归到「其他」
            let category = MediaOrganizer.category(forExtension: fileURL.pathExtension)
            let subdirName = category == .text ? MediaOrganizer.Category.other.rawValue : category.rawValue
            let subdir = directory.appendingPathComponent(subdirName, isDirectory: true)
            if !createdSubdirs.contains(subdirName) {
                guard (try? fm.createDirectory(at: subdir, withIntermediateDirectories: true)) != nil else {
                    return nil
                }
                createdSubdirs.insert(subdirName)
            }

            // media/ 下可能有同名文件位于不同子目录，这里做一次去重命名。
            // 去重跨分类进行：同名文件即便分到不同子目录，重名也容易看花眼。
            var name = sanitizeFilename(fileURL.lastPathComponent)
            if assignedNames.contains(name) {
                let stem = (name as NSString).deletingPathExtension
                let ext = (name as NSString).pathExtension
                var n = 2
                while true {
                    let candidate = ext.isEmpty ? "\(stem)_\(n)" : "\(stem)_\(n).\(ext)"
                    if !assignedNames.contains(candidate) { name = candidate; break }
                    n += 1
                }
            }

            let dest = subdir.appendingPathComponent(name)
            if fm.fileExists(atPath: dest.path) {
                try? fm.removeItem(at: dest)
            }
            guard (try? fm.copyItem(at: fileURL, to: dest)) != nil else { return nil }
            assignedNames.insert(name)
            return "\(urlEncodePathComponent(relativePrefix))/\(urlEncodePathComponent(subdirName))/\(urlEncodePathComponent(name))"
        }
    }

    /// 单个 HTML 最多容纳的消息条数。超出后自动分卷，否则几万条消息的会话会生成
    /// 几百 MB 的 HTML，浏览器打开就卡死。
    static let defaultMessagesPerPage = 1000

    /// 从已导出的临时目录生成 HTML，返回全部页面的 URL（按顺序，首页在前）。
    ///
    /// 产物落在 `destinationDir/<联系人>_<时间戳>/` 这一个专属文件夹里：网页与 `media/`
    /// 都在其中，导多个会话时互不混淆。消息数超过 `messagesPerPage` 时自动分卷，各卷共用
    /// 同一个媒体目录，页眉带上下页导航。
    /// - Parameter embedMedia: 为 true 时将媒体以 base64 内嵌到 HTML；为 false 时仅生成纯文字版本。
    /// - Parameter stamp: 时间戳，传 nil 则取当前时间。同一批导出应传同一个值。
    @discardableResult
    static func writeHTML(
        from sourceDir: URL,
        contactName: String,
        into destinationDir: URL,
        embedMedia: Bool = false,
        messagesPerPage: Int = defaultMessagesPerPage,
        stamp: String? = nil
    ) throws -> [URL] {
        let jsonURL = sourceDir.appendingPathComponent("chat.json")
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            throw AppError.exportFailed("未找到 chat.json，无法生成网页导出")
        }

        let rows = try parseMessages(from: jsonURL)
        guard !rows.isEmpty else {
            throw AppError.exportFailed("聊天记录为空，无法生成网页导出")
        }

        let safeName = ExportNaming.sanitize(contactName)
        let stamp = stamp ?? ExportNaming.stamp()
        let perPage = max(1, messagesPerPage)
        let chunks = stride(from: 0, to: rows.count, by: perPage).map {
            Array(rows[$0..<min($0 + perPage, rows.count)])
        }

        // 本次导出该会话的专属文件夹，网页与媒体都落在里面
        let exportDir = destinationDir.appendingPathComponent(
            ExportNaming.folderName(contact: contactName, stamp: stamp), isDirectory: true
        )
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        // 各卷共用一个媒体目录，避免同一个视频被拷贝多份
        let external = embedMedia
            ? ExternalMediaSink(
                directory: exportDir.appendingPathComponent(ExportNaming.mediaDirName, isDirectory: true),
                relativePrefix: ExportNaming.mediaDirName
              )
            : nil

        let fileNames = (0..<chunks.count).map { pageFileName(safeName: safeName, index: $0, total: chunks.count) }
        let title = escapeHTML(contactName.isEmpty ? "微信聊天记录" : contactName)
        let mediaBadge = embedMedia
            ? "<span class=\"pill pill-purple\">图片 · 语音已内嵌</span>"
            : "<span class=\"pill pill-purple\">纯文字版</span>"

        // 判断哪些媒体没有被任何消息引用，需要全量扫过一遍再算
        var referencedAnywhere = Set<String>()
        for row in rows {
            for rel in row.mediaPaths {
                referencedAnywhere.insert(rel.hasPrefix("media/") ? rel : "media/\(rel)")
            }
        }

        var written: [URL] = []
        for (pageIndex, chunk) in chunks.enumerated() {
            // 每卷各自去重：同一张图被两卷的消息引用时，两卷都该显示出来
            var embedded = Set<String>()
            var body = ""
            for row in chunk {
                body += renderMessage(
                    row, sourceDir: sourceDir, embedded: &embedded,
                    embedMediaFlag: embedMedia, external: external
                )
            }
            // 没被任何消息引用的媒体统一挂在最后一卷末尾
            if embedMedia, pageIndex == chunks.count - 1 {
                var orphanSeen = referencedAnywhere
                body += renderOrphanMedia(sourceDir: sourceDir, embedded: &orphanSeen, external: external)
            }

            let firstIndex = pageIndex * perPage + 1
            let lastIndex = firstIndex + chunk.count - 1
            let nav = chunks.count > 1
                ? renderPageNav(fileNames: fileNames, current: pageIndex)
                : ""
            let rangeBadge = chunks.count > 1
                ? "<span class=\"pill pill-cyan\">第 \(pageIndex + 1) / \(chunks.count) 页 · 第 \(firstIndex)–\(lastIndex) 条</span>"
                : "<span class=\"pill pill-cyan\">\(rows.count) 条消息</span>"

            let html = """
            <!DOCTYPE html>
            <html lang="zh-CN">
            <head>
              <meta charset="utf-8"/>
              <meta name="viewport" content="width=device-width, initial-scale=1"/>
              <title>\(title)\(chunks.count > 1 ? "（\(pageIndex + 1)/\(chunks.count)）" : "")</title>
              <style>
                \(exportStyles)
              </style>
            </head>
            <body>
              <div class="bg-scene" aria-hidden="true">
                <div class="aurora aurora-a"></div>
                <div class="aurora aurora-b"></div>
                <div class="aurora aurora-c"></div>
                <div class="grid-floor"></div>
              </div>
              <header>
                <div class="header-glow"></div>
                <p class="eyebrow">WeChatExporter · 网页导出</p>
                <h1>\(title)</h1>
                <div class="stats">
                  \(rangeBadge)
                  \(chunks.count > 1 ? "<span class=\"pill pill-muted\">共 \(rows.count) 条</span>" : "")
                  \(mediaBadge)
                  <span class="pill pill-muted">\(stamp)</span>
                </div>
            \(nav)
              </header>
              <main>
            \(body)
              </main>
            \(nav.isEmpty ? "" : "  <div class=\"nav-bottom\">\n\(nav)\n  </div>")
              <footer>
                <span class="footer-brand">WeChatExporter</span>
                <span class="footer-dot">·</span>
                <span>深空霓虹主题 · 浏览器离线可阅</span>
              </footer>
            </body>
            </html>
            """

            let outURL = exportDir.appendingPathComponent(fileNames[pageIndex])
            try html.write(to: outURL, atomically: true, encoding: .utf8)
            written.append(outURL)
        }

        return written
    }

    /// 文件夹名里已经带了时间戳，网页文件名就不再重复带；多卷时统一补零编号，
    /// 保证文件管理器里按名称排序即是阅读顺序。
    private static func pageFileName(safeName: String, index: Int, total: Int) -> String {
        guard total > 1 else { return "\(safeName).html" }
        let width = String(total).count
        let number = String(format: "%0\(width)d", index + 1)
        return "\(safeName)_\(number).html"
    }

    private static func renderPageNav(fileNames: [String], current: Int) -> String {
        var links = ""
        if current > 0 {
            links += "<a class=\"page-link\" href=\"\(urlEncodePathComponent(fileNames[current - 1]))\">← 上一页</a>"
        }
        for (i, name) in fileNames.enumerated() {
            if i == current {
                links += "<span class=\"page-link page-current\">\(i + 1)</span>"
            } else {
                links += "<a class=\"page-link\" href=\"\(urlEncodePathComponent(name))\">\(i + 1)</a>"
            }
        }
        if current < fileNames.count - 1 {
            links += "<a class=\"page-link\" href=\"\(urlEncodePathComponent(fileNames[current + 1]))\">下一页 →</a>"
        }
        return "    <nav class=\"pager\">\(links)</nav>"
    }

    /// 单个画廊页面最多容纳的表情数。表情动辄上千张，全塞一页浏览器要滚很久。
    static let defaultStickersPerPage = 500

    /// 从 `stickers-manifest.json` 生成全部表情包画廊，返回全部页面的 URL（按顺序，首页在前）。
    ///
    /// 产物落在 `destinationDir/全部表情包_<时间戳>/` 里，表情**外链**到同目录的 `media/图片/`。
    /// 早先是把每张表情 base64 内嵌进同一个 HTML，实测一份真实数据生成了 427 MB 的单文件，
    /// 浏览器打开就卡死——不要改回内嵌。
    /// - Parameter stamp: 时间戳，传 nil 则取当前时间。同一批导出应传同一个值。
    @discardableResult
    static func writeStickerGallery(
        from sourceDir: URL,
        into destinationDir: URL,
        stamp: String? = nil,
        stickersPerPage: Int = defaultStickersPerPage
    ) throws -> [URL] {
        let manifestURL = sourceDir.appendingPathComponent("stickers-manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(StickerPackExporter.Manifest.self, from: data),
              !manifest.packs.isEmpty else {
            return []
        }

        let stamp = stamp ?? ExportNaming.stamp()
        let galleryName = "全部表情包"
        let exportDir = destinationDir.appendingPathComponent("\(galleryName)_\(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        let external = ExternalMediaSink(
            directory: exportDir.appendingPathComponent(ExportNaming.mediaDirName, isDirectory: true),
            relativePrefix: ExportNaming.mediaDirName
        )

        // 摊平成 (分组名, 表情) 再按数量切页：分组大小差异很大，按分组切会切出一页 3 张、
        // 下一页 900 张的结果。切完再把同一分组的连续条目合回一个 section。
        let flat = manifest.packs.flatMap { pack in pack.stickers.map { (pack.name, $0) } }
        let perPage = max(1, stickersPerPage)
        let chunks = stride(from: 0, to: flat.count, by: perPage).map {
            Array(flat[$0..<min($0 + perPage, flat.count)])
        }
        let fileNames = (0..<chunks.count).map { pageFileName(safeName: galleryName, index: $0, total: chunks.count) }

        var written: [URL] = []
        for (pageIndex, chunk) in chunks.enumerated() {
            var body = ""
            var currentPack: String?
            var tiles = ""
            var tileCount = 0

            func flushSection() {
                guard let name = currentPack, !tiles.isEmpty else { tiles = ""; tileCount = 0; return }
                body += """
                    <section class="sticker-pack">
                      <h2>\(escapeHTML(name)) <span class="pack-count">\(tileCount)</span></h2>
                      <div class="sticker-grid">\(tiles)</div>
                    </section>

                """
                tiles = ""
                tileCount = 0
            }

            for (packName, sticker) in chunk {
                if packName != currentPack {
                    flushSection()
                    currentPack = packName
                }
                guard let block = embedMedia(
                    relativePath: sticker.path, sourceDir: sourceDir,
                    external: external, preferExternal: true
                ) else { continue }
                let caption = escapeHTML(sticker.caption)
                tiles += """
                    <figure class="sticker-tile">
                      \(block)
                      \(caption.isEmpty ? "" : "<figcaption>\(caption)</figcaption>")
                    </figure>

                """
                tileCount += 1
            }
            flushSection()

            let nav = chunks.count > 1 ? renderPageNav(fileNames: fileNames, current: pageIndex) : ""
            let firstIndex = pageIndex * perPage + 1
            let lastIndex = firstIndex + chunk.count - 1
            let rangeBadge = chunks.count > 1
                ? "<span class=\"pill pill-cyan\">第 \(pageIndex + 1) / \(chunks.count) 页 · 第 \(firstIndex)–\(lastIndex) 张</span>"
                : "<span class=\"pill pill-cyan\">\(manifest.totalCount) 张表情</span>"

            let html = """
            <!DOCTYPE html>
            <html lang="zh-CN">
            <head>
              <meta charset="utf-8"/>
              <meta name="viewport" content="width=device-width, initial-scale=1"/>
              <title>全部表情包\(chunks.count > 1 ? "（\(pageIndex + 1)/\(chunks.count)）" : "")</title>
              <style>
                \(exportStyles)
                \(galleryStyles)
              </style>
            </head>
            <body>
              <div class="bg-scene" aria-hidden="true">
                <div class="aurora aurora-a"></div>
                <div class="aurora aurora-b"></div>
                <div class="aurora aurora-c"></div>
                <div class="grid-floor"></div>
              </div>
              <header>
                <div class="header-glow"></div>
                <p class="eyebrow">WeChatExporter · 表情包库</p>
                <h1>全部表情包</h1>
                <div class="stats">
                  \(rangeBadge)
                  \(chunks.count > 1 ? "<span class=\"pill pill-muted\">共 \(manifest.totalCount) 张</span>" : "")
                  <span class="pill pill-purple">\(manifest.packs.count) 个分组</span>
                  <span class="pill pill-muted">\(stamp)</span>
                </div>
            \(nav)
              </header>
              <main>
            \(body)
              </main>
            \(nav.isEmpty ? "" : "  <div class=\"nav-bottom\">\n\(nav)\n  </div>")
              <footer>
                <span class="footer-brand">WeChatExporter</span>
                <span class="footer-dot">·</span>
                <span>收藏与商店表情包 · 浏览器离线可阅</span>
              </footer>
            </body>
            </html>
            """

            let outURL = exportDir.appendingPathComponent(fileNames[pageIndex])
            try html.write(to: outURL, atomically: true, encoding: .utf8)
            written.append(outURL)
        }

        return written
    }

    private static let galleryStyles = """
    .sticker-pack { margin-bottom: 36px; }
    .sticker-pack h2 {
      margin: 0 0 14px;
      font-size: 18px;
      color: var(--cyan);
      text-shadow: 0 0 12px rgba(0,245,255,0.35);
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .pack-count {
      font-size: 12px;
      color: var(--subtext);
      padding: 2px 8px;
      border-radius: 999px;
      border: 1px solid rgba(123,97,255,0.35);
      background: rgba(123,97,255,0.12);
    }
    .sticker-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(92px, 1fr));
      gap: 12px;
    }
    .sticker-tile {
      margin: 0;
      background: rgba(12,20,48,0.55);
      border: 1px solid rgba(0,245,255,0.18);
      border-radius: 12px;
      padding: 8px;
      box-shadow: 0 0 16px rgba(123,97,255,0.08);
      transition: border-color 0.2s ease, transform 0.2s ease;
    }
    .sticker-tile:hover {
      border-color: rgba(0,245,255,0.42);
      transform: translateY(-2px);
    }
    .sticker-tile img {
      width: 100%;
      height: auto;
      display: block;
      border-radius: 8px;
      border: none;
      box-shadow: none;
    }
    .sticker-tile figcaption {
      margin-top: 6px;
      font-size: 11px;
      color: var(--subtext);
      text-align: center;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    """

    /// 与 DMG 安装界面一致的深空霓虹 HUD 样式（青 #00f5ff · 紫 #7b61ff · 品红 #ff4dd2）
    private static let exportStyles = """
    :root {
      --cyan: #00f5ff;
      --purple: #7b61ff;
      --magenta: #ff4dd2;
      --green: #07ffa0;
      --text: #f0f8ff;
      --subtext: #8caad2;
      --glass: rgba(12, 20, 48, 0.78);
      --glass-strong: rgba(8, 14, 36, 0.92);
      --line: rgba(0, 245, 255, 0.22);
    }
    * { box-sizing: border-box; }
    html { scroll-behavior: smooth; }
    body {
      margin: 0;
      min-height: 100vh;
      font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Segoe UI", sans-serif;
      color: var(--text);
      background: linear-gradient(145deg, #080a20 0%, #120830 38%, #06122a 72%, #1c0626 100%);
      background-attachment: fixed;
      position: relative;
      overflow-x: hidden;
    }
    body::before {
      content: "";
      position: fixed;
      inset: 0;
      pointer-events: none;
      z-index: 0;
      opacity: 0.55;
      background-image:
        radial-gradient(1px 1px at 8% 14%, rgba(240,248,255,0.95) 50%, transparent 51%),
        radial-gradient(1px 1px at 22% 38%, rgba(0,245,255,0.85) 50%, transparent 51%),
        radial-gradient(1.5px 1.5px at 35% 8%, rgba(123,97,255,0.9) 50%, transparent 51%),
        radial-gradient(1px 1px at 48% 62%, rgba(240,248,255,0.75) 50%, transparent 51%),
        radial-gradient(1px 1px at 61% 24%, rgba(0,245,255,0.7) 50%, transparent 51%),
        radial-gradient(1.5px 1.5px at 74% 72%, rgba(255,77,210,0.8) 50%, transparent 51%),
        radial-gradient(1px 1px at 86% 18%, rgba(240,248,255,0.8) 50%, transparent 51%),
        radial-gradient(1px 1px at 92% 48%, rgba(123,97,255,0.75) 50%, transparent 51%),
        radial-gradient(2px 2px at 16% 82%, rgba(0,245,255,0.65) 50%, transparent 51%),
        radial-gradient(1px 1px at 54% 88%, rgba(240,248,255,0.7) 50%, transparent 51%);
    }
    .bg-scene { position: fixed; inset: 0; pointer-events: none; z-index: 0; overflow: hidden; }
    .aurora {
      position: absolute;
      border-radius: 50%;
      filter: blur(72px);
      opacity: 0.42;
      animation: drift 18s ease-in-out infinite alternate;
    }
    .aurora-a {
      width: 420px; height: 180px;
      top: -40px; left: 12%;
      background: radial-gradient(circle, rgba(0,180,255,0.55), transparent 70%);
    }
    .aurora-b {
      width: 380px; height: 160px;
      top: 60px; right: 8%;
      background: radial-gradient(circle, rgba(140,60,255,0.5), transparent 70%);
      animation-delay: -6s;
    }
    .aurora-c {
      width: 500px; height: 200px;
      bottom: 18%; left: 28%;
      background: radial-gradient(circle, rgba(255,60,200,0.35), transparent 70%);
      animation-delay: -12s;
    }
    .grid-floor {
      position: absolute;
      left: 0; right: 0; bottom: 0;
      height: 42vh;
      background:
        linear-gradient(to bottom, transparent 0%, rgba(0,245,255,0.04) 100%),
        repeating-linear-gradient(90deg, transparent, transparent 39px, rgba(0,245,255,0.06) 39px, rgba(0,245,255,0.06) 40px),
        repeating-linear-gradient(0deg, transparent, transparent 13px, rgba(123,97,255,0.05) 13px, rgba(123,97,255,0.05) 14px);
      transform: perspective(480px) rotateX(62deg);
      transform-origin: center bottom;
      mask-image: linear-gradient(to top, rgba(0,0,0,0.55), transparent);
      opacity: 0.35;
    }
    @keyframes drift {
      from { transform: translate3d(-12px, 0, 0) scale(1); }
      to { transform: translate3d(18px, 14px, 0) scale(1.06); }
    }
    header, main, footer { position: relative; z-index: 1; }
    header {
      padding: 32px 24px 28px;
      background: linear-gradient(180deg, rgba(12,20,48,0.88), rgba(8,14,36,0.72));
      backdrop-filter: blur(18px) saturate(140%);
      -webkit-backdrop-filter: blur(18px) saturate(140%);
      border-bottom: 1px solid var(--line);
      box-shadow: 0 12px 40px rgba(0,0,0,0.35), inset 0 1px 0 rgba(255,255,255,0.06);
    }
    .header-glow {
      position: absolute;
      top: 0; left: 50%;
      width: min(680px, 90vw);
      height: 2px;
      transform: translateX(-50%);
      background: linear-gradient(90deg, transparent, var(--cyan), var(--purple), var(--magenta), transparent);
      box-shadow: 0 0 24px rgba(0,245,255,0.55);
    }
    .eyebrow {
      margin: 0 0 10px;
      font-size: 11px;
      letter-spacing: 0.22em;
      text-transform: uppercase;
      color: var(--subtext);
    }
    header h1 {
      margin: 0 0 16px;
      font-size: clamp(24px, 4vw, 34px);
      font-weight: 700;
      line-height: 1.2;
      background: linear-gradient(92deg, var(--cyan) 0%, #9ae8ff 35%, var(--purple) 68%, var(--magenta) 100%);
      -webkit-background-clip: text;
      background-clip: text;
      color: transparent;
      filter: drop-shadow(0 0 18px rgba(0,245,255,0.35));
    }
    .stats { display: flex; flex-wrap: wrap; gap: 8px; }
    .pill {
      display: inline-flex;
      align-items: center;
      padding: 5px 12px;
      border-radius: 999px;
      font-size: 12px;
      letter-spacing: 0.02em;
      border: 1px solid transparent;
    }
    .pill-cyan {
      color: var(--cyan);
      background: rgba(0,245,255,0.1);
      border-color: rgba(0,245,255,0.35);
      box-shadow: 0 0 16px rgba(0,245,255,0.18);
    }
    .pill-purple {
      color: #c4b5ff;
      background: rgba(123,97,255,0.14);
      border-color: rgba(123,97,255,0.38);
      box-shadow: 0 0 16px rgba(123,97,255,0.18);
    }
    .pill-muted {
      color: var(--subtext);
      background: rgba(140,170,210,0.08);
      border-color: rgba(140,170,210,0.22);
    }
    main {
      max-width: 880px;
      margin: 0 auto;
      padding: 28px 16px 56px;
    }
    .msg {
      position: relative;
      background: var(--glass);
      backdrop-filter: blur(14px) saturate(130%);
      -webkit-backdrop-filter: blur(14px) saturate(130%);
      border: 1px solid rgba(123,97,255,0.28);
      border-radius: 16px;
      padding: 16px 18px 18px;
      margin-bottom: 14px;
      box-shadow:
        0 8px 32px rgba(0,0,0,0.32),
        inset 0 1px 0 rgba(255,255,255,0.05),
        0 0 24px rgba(123,97,255,0.08);
      transition: border-color 0.25s ease, box-shadow 0.25s ease, transform 0.25s ease;
    }
    .msg::before {
      content: "";
      position: absolute;
      top: 12px; left: 12px;
      width: 18px; height: 18px;
      border-top: 2px solid rgba(0,245,255,0.55);
      border-left: 2px solid rgba(0,245,255,0.55);
      border-radius: 4px 0 0 0;
      pointer-events: none;
    }
    .msg::after {
      content: "";
      position: absolute;
      bottom: 12px; right: 12px;
      width: 18px; height: 18px;
      border-bottom: 2px solid rgba(123,97,255,0.45);
      border-right: 2px solid rgba(123,97,255,0.45);
      border-radius: 0 0 4px 0;
      pointer-events: none;
    }
    .msg:hover {
      border-color: rgba(0,245,255,0.42);
      box-shadow:
        0 10px 36px rgba(0,0,0,0.38),
        0 0 28px rgba(0,245,255,0.12),
        inset 0 1px 0 rgba(255,255,255,0.07);
      transform: translateY(-1px);
    }
    .meta {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: 8px;
      margin-bottom: 10px;
      font-size: 12px;
    }
    .sender {
      font-weight: 600;
      color: var(--cyan);
      text-shadow: 0 0 10px rgba(0,245,255,0.45);
    }
    .type {
      display: inline-flex;
      align-items: center;
      padding: 2px 9px;
      border-radius: 999px;
      font-size: 11px;
      color: #d5c8ff;
      background: rgba(123,97,255,0.18);
      border: 1px solid rgba(123,97,255,0.42);
      box-shadow: 0 0 12px rgba(123,97,255,0.2);
    }
    .time {
      color: var(--subtext);
      margin-left: auto;
      font-variant-numeric: tabular-nums;
    }
    .text {
      white-space: pre-wrap;
      word-break: break-word;
      line-height: 1.65;
      color: rgba(240,248,255,0.94);
    }
    .missing {
      margin: 0;
      padding: 10px 14px;
      border-radius: 10px;
      font-size: 13px;
      line-height: 1.6;
      color: var(--subtext);
      background: rgba(140,170,210,0.06);
      border: 1px dashed rgba(140,170,210,0.28);
    }
    .pager {
      display: flex;
      flex-wrap: wrap;
      gap: 6px;
      margin-top: 14px;
      align-items: center;
    }
    .page-link {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-width: 32px;
      padding: 5px 10px;
      border-radius: 8px;
      font-size: 12px;
      text-decoration: none;
      color: var(--subtext);
      background: rgba(12,20,48,0.55);
      border: 1px solid rgba(123,97,255,0.28);
      transition: color 0.2s ease, border-color 0.2s ease, transform 0.2s ease;
      font-variant-numeric: tabular-nums;
    }
    .page-link:hover {
      color: var(--cyan);
      border-color: rgba(0,245,255,0.45);
      transform: translateY(-1px);
    }
    .page-current {
      color: #06121f;
      background: linear-gradient(92deg, var(--cyan), var(--purple));
      border-color: transparent;
      font-weight: 600;
    }
    .nav-bottom {
      position: relative;
      z-index: 1;
      max-width: 880px;
      margin: 0 auto;
      padding: 0 16px 32px;
    }
    .nav-bottom .pager { justify-content: center; margin-top: 0; }
    .text a.link {
      color: var(--cyan);
      text-decoration: none;
      border-bottom: 1px solid rgba(0,245,255,0.35);
      word-break: break-all;
      transition: color 0.2s ease, border-color 0.2s ease;
    }
    .text a.link:hover {
      color: var(--magenta);
      border-bottom-color: rgba(255,77,210,0.6);
      text-shadow: 0 0 10px rgba(255,77,210,0.35);
    }
    .attach {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      margin-top: 8px;
      padding: 8px 14px;
      border-radius: 10px;
      font-size: 13px;
      color: var(--text);
      text-decoration: none;
      background: rgba(12,20,48,0.6);
      border: 1px solid rgba(123,97,255,0.35);
      transition: border-color 0.2s ease, transform 0.2s ease;
      word-break: break-all;
    }
    .attach:hover {
      border-color: rgba(0,245,255,0.5);
      transform: translateY(-1px);
    }
    .attach-size {
      color: var(--subtext);
      font-size: 11px;
      font-variant-numeric: tabular-nums;
    }
    .media { margin-top: 12px; }
    .media img, .media .chat-img {
      max-width: min(100%, 440px);
      border-radius: 12px;
      display: block;
      border: 1px solid rgba(0,245,255,0.32);
      box-shadow: 0 0 24px rgba(0,245,255,0.18), 0 8px 24px rgba(0,0,0,0.35);
      cursor: zoom-in;
    }
    .media img:active, .media .chat-img:active { transform: scale(1.01); }
    .media video, .media audio {
      max-width: 100%;
      margin-top: 8px;
      display: block;
      border-radius: 12px;
      border: 1px solid rgba(123,97,255,0.28);
      box-shadow: 0 0 20px rgba(123,97,255,0.15);
      background: var(--glass-strong);
    }
    footer {
      text-align: center;
      color: var(--subtext);
      font-size: 12px;
      padding: 28px 16px 36px;
      border-top: 1px solid rgba(123,97,255,0.15);
      background: linear-gradient(180deg, transparent, rgba(8,14,36,0.55));
    }
    .footer-brand {
      color: var(--cyan);
      font-weight: 600;
      text-shadow: 0 0 10px rgba(0,245,255,0.35);
    }
    .footer-dot { margin: 0 8px; opacity: 0.5; }
    @media (max-width: 640px) {
      header { padding: 24px 16px 22px; }
      .time { margin-left: 0; width: 100%; }
      .msg { padding: 14px 14px 16px; }
    }
    """

    private static func renderMessage(
        _ row: MessageRow,
        sourceDir: URL,
        embedded: inout Set<String>,
        embedMediaFlag: Bool,
        external: ExternalMediaSink?
    ) -> String {
        var mediaHTML = ""
        if embedMediaFlag {
            for rel in row.mediaPaths {
                guard embedded.insert(rel).inserted else { continue }
                if let block = embedMedia(relativePath: rel, sourceDir: sourceDir, external: external) {
                    mediaHTML += block
                }
            }
        }

        let plain = cleanContent(row.content)
        let isBarePlaceholder = redundantPlaceholders.contains(plain)

        // 媒体已经渲染出来时，正文再重复一个占位标签只会碍眼。
        // 媒体没渲染出来时也不要只留一个 `[视频]`——换成说明为什么没有、怎么办。
        let bodyHTML: String
        if isBarePlaceholder, !mediaHTML.isEmpty {
            bodyHTML = ""
        } else if isBarePlaceholder, let note = missingMediaNote(for: plain) {
            bodyHTML = note
        } else if plain.isEmpty {
            bodyHTML = ""
        } else {
            bodyHTML = "<div class=\"text\">\(escapeAndLinkify(plain))</div>"
        }

        return """
            <article class="msg">
              <div class="meta">
                <span class="sender">\(escapeHTML(row.sender))</span>
                <span class="type">\(escapeHTML(row.type))</span>
                <span class="time">\(escapeHTML(row.time))</span>
              </div>
              \(bodyHTML)
              \(mediaHTML.isEmpty ? "" : "<div class=\"media\">\(mediaHTML)</div>")
            </article>

        """
    }

    private static func renderOrphanMedia(
        sourceDir: URL,
        embedded: inout Set<String>,
        external: ExternalMediaSink?
    ) -> String {
        let mediaRoot = sourceDir.appendingPathComponent("media", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: mediaRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return "" }

        var html = ""
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let rel = "media/" + fileURL.path.replacingOccurrences(of: mediaRoot.path + "/", with: "")
            guard embedded.insert(rel).inserted else { continue }
            guard let block = embedMedia(relativePath: rel, sourceDir: sourceDir, external: external) else { continue }
            html += """
                <article class="msg">
                  <div class="meta">
                    <span class="sender">媒体附件</span>
                    <span class="type">文件</span>
                    <span class="time">\(escapeHTML(fileURL.lastPathComponent))</span>
                  </div>
                  <div class="media">\(block)</div>
                </article>

            """
        }
        return html
    }

    /// 按扩展名分派渲染。注意这里**只看文件扩展名**，与消息类型无关——
    /// 所以语音只要被 wx-cli 转成了 .mp3 就会渲染成可播放的 `<audio>`。
    /// - Parameter external: 视频与大附件的外链落点；为 nil 时这类文件退化成文字占位。
    /// - Parameter preferExternal: 图片也一律外链。表情包画廊用它——几千张表情 base64 内嵌
    ///   会生成几百 MB 的 HTML（实测一份真实数据是 427 MB），浏览器根本打不开。
    private static func embedMedia(
        relativePath: String,
        sourceDir: URL,
        external: ExternalMediaSink?,
        preferExternal: Bool = false
    ) -> String? {
        let rel = relativePath.hasPrefix("media/") ? relativePath : "media/\(relativePath)"
        let fileURL = sourceDir.appendingPathComponent(rel)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let ext = fileURL.pathExtension.lowercased()
        if ext == "wxgf", let transcoded = WXGFTranscoder.transcodeIfNeeded(at: fileURL) {
            let decodedRel = (rel as NSString).deletingPathExtension + "." + transcoded.pathExtension
            return embedMedia(relativePath: decodedRel, sourceDir: sourceDir, external: external, preferExternal: preferExternal)
        }

        if ext == "dat" || ext == "wxgf" {
            let base = fileURL.deletingPathExtension()
            for alt in ["jpg", "jpeg", "png", "gif", "webp"] {
                let decoded = base.appendingPathExtension(alt)
                if FileManager.default.fileExists(atPath: decoded.path) {
                    let decodedRel = (rel as NSString).deletingPathExtension + ".\(alt)"
                    return embedMedia(relativePath: decodedRel, sourceDir: sourceDir, external: external, preferExternal: preferExternal)
                }
            }
        }

        // 视频一律外链：base64 会让 HTML 膨胀到浏览器打不开
        if videoExts.contains(ext) {
            if let href = external?.store(fileURL) {
                return "<video controls preload=\"metadata\" src=\"\(href)\"></video>"
            }
            return "<p class=\"text\">[视频 \(escapeHTML(fileURL.lastPathComponent))]</p>"
        }

        // 要求外链的场景里，图片也拷成文件走相对路径
        if preferExternal,
           MediaOrganizer.category(forExtension: ext) == .image,
           let href = external?.store(fileURL) {
            return "<img alt=\"表情\" class=\"chat-img\" loading=\"lazy\" src=\"\(href)\"/>"
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0

        // 单个文件过大时同样外链，避免撑爆 HTML
        if fileSize > embedSizeLimit, let href = external?.store(fileURL) {
            return attachmentLink(href: href, name: fileURL.lastPathComponent, size: fileSize)
        }

        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return nil }

        if let imageData = ImageExporter.normalizeImageData(data),
           let mime = ImageExporter.sniffImageMIME(imageData) {
            let b64 = imageData.base64EncodedString()
            return "<img alt=\"图片\" class=\"chat-img\" loading=\"lazy\" src=\"data:\(mime);base64,\(b64)\"/>"
        }

        let b64 = data.base64EncodedString()
        switch ext {
        case "jpg", "jpeg":
            return "<img alt=\"图片\" class=\"chat-img\" loading=\"lazy\" src=\"data:image/jpeg;base64,\(b64)\"/>"
        case "png":
            return "<img alt=\"图片\" class=\"chat-img\" loading=\"lazy\" src=\"data:image/png;base64,\(b64)\"/>"
        case "gif":
            return "<img alt=\"表情\" class=\"chat-img\" loading=\"lazy\" src=\"data:image/gif;base64,\(b64)\"/>"
        case "webp":
            return "<img alt=\"图片\" class=\"chat-img\" loading=\"lazy\" src=\"data:image/webp;base64,\(b64)\"/>"
        case "dat":
            return "<p class=\"text\">[加密图片未能解密：\(escapeHTML(fileURL.lastPathComponent))]</p>"
        case "wxgf":
            return "<p class=\"text\">[WXGF 动态表情转码失败：\(escapeHTML(fileURL.lastPathComponent))]</p>"
        case "mp3":
            return "<audio controls preload=\"none\" src=\"data:audio/mpeg;base64,\(b64)\"></audio>"
        case "m4a", "aac":
            return "<audio controls preload=\"none\" src=\"data:audio/mp4;base64,\(b64)\"></audio>"
        case "wav":
            return "<audio controls preload=\"none\" src=\"data:audio/wav;base64,\(b64)\"></audio>"
        case "ogg", "opus":
            return "<audio controls preload=\"none\" src=\"data:audio/ogg;base64,\(b64)\"></audio>"
        case "silk":
            // wx-cli 找不到 ffmpeg 时会降级导出微信原始语音格式，浏览器无法播放
            return "<p class=\"text\">[语音 \(escapeHTML(fileURL.lastPathComponent))：微信原始 SILK 格式，浏览器无法直接播放。"
                + "本应由应用内置的 ffmpeg 自动转成 MP3，若持续出现请检查应用包是否完整]</p>"
        default:
            if let href = external?.store(fileURL) {
                return attachmentLink(href: href, name: fileURL.lastPathComponent, size: fileSize)
            }
            return "<p class=\"text\">[附件 \(escapeHTML(fileURL.lastPathComponent))，大小 \(formatBytes(fileSize))]</p>"
        }
    }

    private static let videoExts: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "3gp"]

    private static func attachmentLink(href: String, name: String, size: Int) -> String {
        "<a class=\"attach\" href=\"\(href)\" target=\"_blank\" rel=\"noopener noreferrer\">"
            + "📎 \(escapeHTML(name))<span class=\"attach-size\">\(formatBytes(size))</span></a>"
    }

    private static func formatBytes(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var idx = 0
        while value >= 1024, idx < units.count - 1 {
            value /= 1024
            idx += 1
        }
        return idx == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[idx])
    }

    // MARK: - JSON parsing

    private static func parseMessages(from jsonURL: URL) throws -> [MessageRow] {
        let data = try Data(contentsOf: jsonURL)
        let root = try JSONSerialization.jsonObject(with: data)

        let rawRows: [[String: Any]]
        if let array = root as? [[String: Any]] {
            rawRows = array
        } else if let dict = root as? [String: Any] {
            if let items = dict["items"] as? [[String: Any]] { rawRows = items }
            else if let messages = dict["messages"] as? [[String: Any]] { rawRows = messages }
            else if let results = dict["results"] as? [[String: Any]] { rawRows = results }
            else { throw AppError.exportFailed("chat.json 中未找到消息列表") }
        } else {
            throw AppError.exportFailed("chat.json 格式不支持")
        }

        return rawRows.map { parseRow($0) }.filter { !$0.sender.isEmpty || !$0.content.isEmpty || !$0.mediaPaths.isEmpty }
    }

    private static func parseRow(_ row: [String: Any]) -> MessageRow {
        let nested = row["message"] as? [String: Any]
        let source = nested ?? row

        let ts = intField(source, keys: ["create_time", "timestamp"]) ?? intField(row, keys: ["create_time", "timestamp"])
        let time = stringField(row, keys: ["time", "timestamp_str"])
            ?? stringField(source, keys: ["time", "timestamp_str"])
            ?? formatTimestamp(ts)

        let sender = stringField(row, keys: ["sender_display_name", "sender", "from", "display_name"])
            ?? stringField(source, keys: ["sender_display_name", "sender"])
            ?? "未知"

        let msgType = intField(source, keys: ["msg_type", "type"]) ?? intField(row, keys: ["msg_type", "type"])
        let typeName = stringField(row, keys: ["type_name", "type"])
            ?? stringField(source, keys: ["type_name"])
            ?? typeLabel(for: msgType)

        let content = stringField(row, keys: ["snippet", "content", "text", "message", "summary"])
            ?? stringField(source, keys: ["snippet", "content", "text"])
            ?? ""

        var media = (row["media_files"] as? [String]) ?? (source["media_files"] as? [String]) ?? []
        if media.isEmpty, let array = row["media_files"] as? [Any] {
            media = array.compactMap { $0 as? String }
        }

        return MessageRow(time: time, sender: sender, type: typeName, content: content, mediaPaths: media)
    }

    private static func typeLabel(for type: Int?) -> String {
        guard let type else { return "消息" }
        switch type {
        case 1: return "文本"
        case 3: return "图片"
        case 34: return "语音"
        case 43: return "视频"
        case 47: return "表情"
        case 49: return "链接/文件"
        default: return "类型\(type)"
        }
    }

    private static func stringField(_ row: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = row[key] as? String, !value.isEmpty { return value }
            if let value = row[key] as? Int { return String(value) }
            if let nested = row[key] as? [String: Any] {
                if let text = nested["Text"] as? String { return text }
                if let text = nested["text"] as? String { return text }
                if nested["Emoji"] is String { return "[动画表情]" }
            }
        }
        return nil
    }

    private static func intField(_ row: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = row[key] as? Int { return value }
            if let value = row[key] as? Int64 { return Int(value) }
            if let value = row[key] as? Double { return Int(value) }
        }
        return nil
    }

    private static func formatTimestamp(_ ts: Int?) -> String {
        guard let ts, ts > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: date)
    }

    private static func sanitizeFilename(_ name: String) -> String {
        ExportNaming.sanitize(name)
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let redundantPlaceholders: Set<String> = [
        "[图片]", "[语音]", "[视频]", "[表情]", "[动画表情]", "[文件]",
    ]

    /// wx-cli 的 snippet 有两个毛病，直接渲染会让页面很难看：
    /// 一是表情类消息会把整段原始 XML 带出来（`[emoji <msg><emoji …`），
    /// 二是部分占位标签是英文的（`[voice]` / `[image]`）。这里一并收拾干净。
    ///
    /// 注意 `[旺柴]`、`[微笑]` 这类是微信内联表情的正常文本，必须原样保留。
    private static func cleanContent(_ s: String) -> String {
        var text = s
        if let xmlStart = text.range(of: "<msg") ?? text.range(of: "<?xml") {
            text = String(text[text.startIndex..<xmlStart.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // 截断后括号可能不配对，如 `[emoji`
            if text.hasPrefix("["), !text.hasSuffix("]") { text += "]" }
        }

        // wx-cli 拿不到媒体文件时，snippet 会退化成 `[video 9e5873e9d5…]` 这种
        // 「类型 + 内容 md5」的形式。直接渲染就是一串没人看得懂的十六进制。
        if let match = text.range(of: #"^\[(video|image|voice|emoji|file) [0-9a-fA-F]{16,}\]$"#,
                                  options: .regularExpression) {
            let kind = text[match].dropFirst().split(separator: " ")[0]
            text = "[\(kind)]"
        }

        switch text {
        case "[emoji]": return "[动画表情]"
        case "[voice]": return "[语音]"
        case "[image]": return "[图片]"
        case "[video]": return "[视频]"
        case "[file]": return "[文件]"
        case "[system]": return "[系统消息]"
        default: return text
        }
    }

    /// 一条消息只剩占位标签、却没有任何媒体渲染出来时，给出可操作的说明，
    /// 而不是甩一个孤零零的 `[视频]` 让人以为是导出坏了。
    private static func missingMediaNote(for placeholder: String) -> String? {
        let reason: String
        switch placeholder {
        case "[视频]":
            reason = "该视频没有保存在这台电脑上，微信只留了记录。在微信里打开这条消息让它下载完成后，重新导出即可包含。"
        case "[图片]":
            reason = "原图没有保存在这台电脑上。在微信里打开这条消息让它下载完成后，重新导出即可包含。"
        case "[动画表情]":
            reason = "这张表情已无法从微信服务器取回（CDN 链接会随时间过期）。"
        case "[语音]":
            reason = "这条语音没有保存在这台电脑上，无法导出。"
        case "[文件]":
            reason = "该文件没有保存在这台电脑上，无法导出。"
        default:
            return nil
        }
        return "<p class=\"missing\">\(escapeHTML(placeholder.dropFirst().dropLast() + "：" + reason))</p>"
    }

    /// 用 RFC 3986 的字符允许表而不是排除表：中文聊天里 URL 后面常常紧跟汉字没有空格，
    /// 用排除表很容易把「…/b)结束」整段吞进链接。允许表天然把汉字和全角标点挡在外面。
    private static let urlRegex = try? NSRegularExpression(
        pattern: "https?://[A-Za-z0-9\\-._~:/?#\\[\\]@!$&'()*+,;=%]+",
        options: []
    )

    /// 转义正文，并把其中的 http(s) 链接变成可点击的 `<a>`。
    ///
    /// 先切分再分段转义，而不是先转义再匹配——后者会让 URL 里的 `&` 变成 `&amp;` 干扰匹配边界。
    private static func escapeAndLinkify(_ s: String) -> String {
        guard let regex = urlRegex, !s.isEmpty else { return escapeHTML(s) }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return escapeHTML(s) }

        var result = ""
        var cursor = 0
        for match in matches {
            var range = match.range
            // 句末标点常被贪婪吞进 URL，这里退回去
            while range.length > 0 {
                let lastChar = ns.substring(with: NSRange(location: range.location + range.length - 1, length: 1))
                if ".,;:!?'\"".contains(lastChar) {
                    range.length -= 1
                    continue
                }
                // 右括号只有在配不上左括号时才算多出来的（形如「(详见 https://…)」）；
                // 维基百科那种 URL 自带括号的情况要保留
                if [")", "]", "}"].contains(lastChar) {
                    let candidate = ns.substring(with: range)
                    let opens = candidate.filter { "([{".contains($0) }.count
                    let closes = candidate.filter { ")]}".contains($0) }.count
                    if closes > opens {
                        range.length -= 1
                        continue
                    }
                }
                break
            }
            guard range.length > 0, range.location >= cursor else { continue }

            result += escapeHTML(ns.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            let link = escapeHTML(ns.substring(with: range))
            result += "<a class=\"link\" href=\"\(link)\" target=\"_blank\" rel=\"noopener noreferrer\">\(link)</a>"
            cursor = range.location + range.length
        }
        result += escapeHTML(ns.substring(from: cursor))
        return result
    }

    /// 把文件名编成可安全放进 HTML `src`/`href` 的形式（空格、中文、`#`、`?` 等都要处理）。
    private static func urlEncodePathComponent(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
        return escapeHTML(encoded)
    }
}
