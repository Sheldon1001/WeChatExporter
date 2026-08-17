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
}
