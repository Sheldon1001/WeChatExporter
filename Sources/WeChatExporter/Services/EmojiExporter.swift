import Foundation

/// 从 wx-cli 导出的 JSON 中解析表情 XML，下载 GIF/PNG 到 media/emojis/
enum EmojiExporter {
    private static let emojiTagPattern = #"<emoji\b[^>]*(?:/>|>[^<]*</emoji>)"#
    private static let attrPattern = #"(\w+)="([^"]*)""#

    /// 同时下载多少个。表情都是几十 KB 的小文件，瓶颈全在往返延迟上。
    private static let concurrency = 8
    /// 整个表情阶段的时间预算。过期的 CDN 链接是常态，不能让它们无限拖住导出。
    private static let timeBudget: TimeInterval = 120

    static func exportEmojis(
        in outputDir: URL,
        log: @escaping (String) -> Void,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async -> Int {
        let jsonURL = outputDir.appendingPathComponent("chat.json")
        guard FileManager.default.fileExists(atPath: jsonURL.path),
              let data = try? Data(contentsOf: jsonURL),
              var root = try? JSONSerialization.jsonObject(with: data) else {
            return 0
        }

        guard var items = extractMutableItems(from: &root), !items.isEmpty else { return 0 }

        let emojiDir = outputDir.appendingPathComponent("media/emojis", isDirectory: true)
        try? FileManager.default.createDirectory(at: emojiDir, withIntermediateDirectories: true)

        // ── 第一步：把所有表情引用收集起来，**按 URL 去重**。
        //
        // 群聊里同一张表情会被反复发送——实测一个 74479 条消息的群有 13780 处表情引用，
        // 但唯一 URL 只有 1190 个，最热门的一张出现了 278 次。早先的写法给每次出现都用
        // `uniqueFilename` 起一个新名字（md5_2.gif、md5_3.gif…），于是 `fileExists` 永远
        // 命不中，同一张表情被重复下载几百遍，导出就卡死在这一步。
        var seenNames = Set<String>()
        var jobForURL: [String: (url: URL, filename: String)] = [:]
        var refs: [(itemIndex: Int, urlKey: String)] = []
        var noURLCount = 0

        for index in items.indices {
            for xml in emojiXMLSources(from: items[index]) {
                let attrs = parseAttributes(from: xml)
                guard let raw = pickURL(from: attrs) else {
                    noURLCount += 1
                    continue
                }
                let urlString = unescapeXML(raw)
                guard let url = URL(string: urlString) else {
                    noURLCount += 1
                    continue
                }
                if jobForURL[urlString] == nil {
                    let name = uniqueFilename(base: makeFilename(attrs: attrs, fallbackIndex: index), seen: &seenNames)
                    jobForURL[urlString] = (url, name)
                }
                refs.append((index, urlString))
            }
        }

        guard !jobForURL.isEmpty || noURLCount > 0 else { return 0 }

        // ── 第二步：只下载还不在盘上的那些，并发跑
        let fm = FileManager.default
        var readyNames = Set<String>()
        var pending: [(url: URL, filename: String)] = []
        for (_, job) in jobForURL {
            if fm.fileExists(atPath: emojiDir.appendingPathComponent(job.filename).path) {
                readyNames.insert(job.filename)
            } else {
                pending.append(job)
            }
        }

        if !pending.isEmpty {
            log("表情：\(refs.count) 处引用，去重后需下载 \(pending.count) 个")
        }

        let dir = emojiDir
        let outcomes = await ConcurrentMap.run(
            pending,
            concurrency: concurrency,
            budget: timeBudget,
            onProgress: { done, total in onProgress?("正在下载表情 \(done)/\(total)") }
        ) { job in
            await download(url: job.url, to: dir.appendingPathComponent(job.filename))
        }

        // 表情下载失败是常态：微信 CDN 链接会过期，老消息的表情多半已经取不回来了。
        // 逐条刷屏没有意义，这里只统计原因，最后汇总一行。
        var failures: [String: Int] = [:]
        var skipped = 0
        for (job, outcome) in zip(pending, outcomes) {
            switch outcome {
            case .success:
                readyNames.insert(job.filename)
            case .failure(let reason):
                failures[reason, default: 0] += 1
            case nil:
                skipped += 1
            }
        }

        // ── 第三步：把下载成功的表情挂回引用它的每一条消息
        var downloaded = 0
        for ref in refs {
            guard let job = jobForURL[ref.urlKey], readyNames.contains(job.filename) else { continue }
            appendMediaFile(to: &items[ref.itemIndex], path: "media/emojis/\(job.filename)")
            downloaded += 1
        }

        if !failures.isEmpty {
            let detail = failures
                .sorted { $0.value > $1.value }
                .map { "\($0.key) \($0.value) 个" }
                .joined(separator: "、")
            let total = failures.values.reduce(0, +)
            log("表情未能下载 \(total) 个（\(detail)）。微信 CDN 链接会过期，老消息的表情通常已无法取回，不影响其他内容导出。")
        }
        if skipped > 0 {
            log("表情下载已达 \(Int(timeBudget)) 秒上限，跳过剩余 \(skipped) 个，不再继续等待。")
        }
        if noURLCount > 0 {
            log("另有 \(noURLCount) 个表情在聊天记录里没有可用下载地址，已跳过。")
        }

        guard downloaded > 0 else { return 0 }

        writeItems(items, to: &root)
        if let newData = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? newData.write(to: jsonURL)
        }
        log("共导出 \(downloaded) 个表情文件 → media/emojis/")
        return downloaded
    }

    // MARK: - JSON helpers

    private static func extractMutableItems(from root: inout Any) -> [[String: Any]]? {
        if let dict = root as? [String: Any] {
            if let items = dict["items"] as? [[String: Any]] { return items }
            if let messages = dict["messages"] as? [[String: Any]] { return messages }
            if let results = dict["results"] as? [[String: Any]] { return results }
        }
        if let array = root as? [[String: Any]] { return array }
        return nil
    }

    private static func writeItems(_ items: [[String: Any]], to root: inout Any) {
        guard var dict = root as? [String: Any] else {
            if root is [[String: Any]] { root = items; return }
            return
        }
        if dict["items"] != nil { dict["items"] = items }
        else if dict["messages"] != nil { dict["messages"] = items }
        else if dict["results"] != nil { dict["results"] = items }
        root = dict
    }

    private static func appendMediaFile(to item: inout [String: Any], path: String) {
        var files = item["media_files"] as? [String] ?? []
        if !files.contains(path) { files.append(path) }
        item["media_files"] = files
    }

    // MARK: - XML / URL extraction

    private static func emojiXMLSources(from item: [String: Any]) -> [String] {
        var texts: [String] = []
        collectStrings(from: item, into: &texts)
        var xmls: [String] = []
        for text in texts {
            for match in matches(for: emojiTagPattern, in: text) {
                if !xmls.contains(match) { xmls.append(match) }
            }
        }
        return xmls
    }

    private static func collectStrings(from value: Any, into out: inout [String]) {
        switch value {
        case let s as String where s.contains("<emoji"):
            out.append(s)
        case let dict as [String: Any]:
            for v in dict.values { collectStrings(from: v, into: &out) }
        case let array as [Any]:
            for v in array { collectStrings(from: v, into: &out) }
        default:
            break
        }
    }

    private static func parseAttributes(from xml: String) -> [String: String] {
        var attrs: [String: String] = [:]
        guard let regex = try? NSRegularExpression(pattern: attrPattern) else { return attrs }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        for match in regex.matches(in: xml, range: range) {
            guard match.numberOfRanges == 3,
                  let keyRange = Range(match.range(at: 1), in: xml),
                  let valRange = Range(match.range(at: 2), in: xml) else { continue }
            attrs[String(xml[keyRange]).lowercased()] = String(xml[valRange])
        }
        return attrs
    }

    private static func pickURL(from attrs: [String: String]) -> String? {
        for key in ["cdnurl", "tpurl", "encrypturl", "externurl", "thumburl", "cdnthumburl"] {
            if let value = attrs[key], !value.isEmpty, value != "null" { return value }
        }
        return nil
    }

    private static func makeFilename(attrs: [String: String], fallbackIndex: Int) -> String {
        let md5 = attrs["md5"] ?? attrs["androidmd5"] ?? attrs["externmd5"] ?? "emoji_\(fallbackIndex)"
        let ext = guessExtension(attrs: attrs)
        return sanitizeFilename("\(md5).\(ext)")
    }

    private static func guessExtension(attrs: [String: String]) -> String {
        if attrs["type"] == "2" { return "gif" }
        for key in ["cdnurl", "tpurl", "externurl", "thumburl"] {
            if let url = attrs[key]?.lowercased() {
                if url.contains(".gif") { return "gif" }
                if url.contains(".png") { return "png" }
                if url.contains(".jpg") || url.contains(".jpeg") { return "jpg" }
                if url.contains(".webp") { return "webp" }
            }
        }
        return "gif"
    }

    private static func uniqueFilename(base: String, seen: inout Set<String>) -> String {
        if seen.insert(base).inserted { return base }
        let stem = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem)_\(n)" : "\(stem)_\(n).\(ext)"
            if seen.insert(candidate).inserted { return candidate }
            n += 1
        }
    }

    private static func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?*\"<>|")
        return name.components(separatedBy: invalid).joined(separator: "_")
    }

    private static func unescapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private static func matches(for pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range, in: text) else { return nil }
            return String(text[r])
        }
    }

    // MARK: - Download

    enum DownloadOutcome {
        case success
        /// 归类后的失败原因，用于汇总统计而不是逐条刷屏
        case failure(String)
    }

    private static func download(url: URL, to dest: URL, attempts: Int = 2) async -> DownloadOutcome {
        var lastReason = "未知错误"

        for attempt in 1...max(1, attempts) {
            var request = URLRequest(url: url)
            // 表情就是几十 KB 的小文件，30 秒的默认超时只会让失效链接白白拖住导出
            request.timeoutInterval = 12
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    // 4xx 是链接已失效，重试没有意义
                    let reason = "服务器返回 \(http.statusCode)"
                    if (400..<500).contains(http.statusCode) { return .failure(reason) }
                    lastReason = reason
                } else if data.isEmpty {
                    lastReason = "返回内容为空"
                } else if sniffImageExtension(data) == nil {
                    // 微信部分表情的 URL 拿回来的是 AES 加密数据而非图片，
                    // 写成 .gif 只会得到一个打不开的坏文件，不如不写
                    return .failure("返回的不是图片（可能是加密内容）")
                } else {
                    try data.write(to: dest, options: .atomic)
                    return .success
                }
            } catch let error as URLError where error.code == .timedOut {
                lastReason = "连接超时"
            } catch {
                lastReason = "网络错误"
            }

            if attempt < attempts {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        return .failure(lastReason)
    }

    /// 按文件头判断是不是浏览器认得的图片格式。
    private static func sniffImageExtension(_ data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "gif" }
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "png" }
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "jpg" }
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "webp" }
        return nil
    }
}
