import Foundation

/// 导出产物的统一命名与目录约定。
///
/// 每导出一次，每个会话各自落到 `<联系人>_<时间戳>/` 下。早先网页导出是把多卷 HTML
/// 与 `<名称>_media` 目录直接摊在导出根目录里，连着导几个会话之后根目录就是一堆同名
/// 前缀的文件，分不清谁属于谁；带上时间戳还能让同一个会话的多次导出各自成卷，不会互相
/// 覆盖或混在一起。
enum ExportNaming {
    /// 外链媒体目录名（会话文件夹内）
    static let mediaDirName = "media"

    /// 一次导出全程共用同一个时间戳，这样同批导出的多个会话文件夹在文件管理器里挨在一起。
    static func stamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f.string(from: date)
    }

    /// 去掉文件名里不能用的字符
    static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?*\"<>|")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "聊天记录" : cleaned
    }

    /// 单个会话本次导出的文件夹名
    static func folderName(contact: String, stamp: String) -> String {
        "\(sanitize(contact))_\(stamp)"
    }

    /// 为一批会话算出互不冲突的文件夹名，顺序与入参一致。
    ///
    /// 同批导出共用一个时间戳，所以光靠 `<联系人>_<时间戳>` 不足以区分重名会话——微信里
    /// 重名昵称与同名群都很常见，两个「老王」会写进同一个文件夹，后一个把前一个的
    /// chat.json 覆盖掉。这里只在真的撞名时才追加 wxid 尾段，常见情况下夹名保持干净。
    static func uniqueFolderNames(for contacts: [(id: String, displayName: String)], stamp: String) -> [String] {
        var nameCounts: [String: Int] = [:]
        for c in contacts { nameCounts[sanitize(c.displayName), default: 0] += 1 }

        var used = Set<String>()
        var names: [String] = []
        names.reserveCapacity(contacts.count)
        for c in contacts {
            let safe = sanitize(c.displayName)
            var candidate = nameCounts[safe, default: 0] > 1
                ? "\(safe)_\(shortID(c.id))_\(stamp)"
                : "\(safe)_\(stamp)"
            // wxid 尾段也可能撞（同一个会话被选中两次之类），再兜一层序号
            if used.contains(candidate) {
                var n = 2
                while used.contains("\(candidate)_\(n)") { n += 1 }
                candidate = "\(candidate)_\(n)"
            }
            used.insert(candidate)
            names.append(candidate)
        }
        return names
    }

    /// 用来区分同名会话的 wxid 尾段。`12345678@chatroom` 这类先去掉 `@` 后缀再取尾部。
    private static func shortID(_ id: String) -> String {
        let base = id.components(separatedBy: "@").first ?? id
        let invalid = CharacterSet(charactersIn: "/\\:?*\"<>|")
        let cleaned = base.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "id" : String(cleaned.suffix(6))
    }
}
