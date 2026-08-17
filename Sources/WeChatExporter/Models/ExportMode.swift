import Foundation

/// 导出方式
enum ExportMode: String, CaseIterable, Identifiable {
    /// 按分类把文字、图片、视频、语音放在各自文件夹里
    case categorized = "categorized"
    /// 只导出文字
    case textOnly = "textOnly"
    /// 导出全部文字与原始媒体文件，保持文件夹结构
    case all = "all"
    /// 生成可用浏览器打开的 HTML，图片 / 表情 / 语音内嵌，视频与大附件外链到 media/<类型>/
    case singleFileHTML = "singleFileHTML"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .categorized: return "分类导出"
        case .textOnly: return "只导出文字"
        case .all: return "全部导出"
        case .singleFileHTML: return "网页导出"
        }
    }

    var description: String {
        switch self {
        case .categorized: return "文字、图片、视频、语音分别归档到独立文件夹"
        case .textOnly: return "仅导出聊天文字（txt / json / csv）"
        case .all: return "导出全部文字与原始媒体文件，保持文件夹结构"
        case .singleFileHTML: return "生成 HTML 网页，图片、表情、语音内嵌，视频与大附件放进 media/ 外链"
        }
    }

    var icon: String {
        switch self {
        case .categorized: return "folder.fill"
        case .textOnly: return "doc.text.fill"
        case .all: return "photo.on.rectangle.fill"
        case .singleFileHTML: return "safari.fill"
        }
    }

    /// 是否包含媒体内容。注意：网页导出必须为 true，否则 wx-cli 会被加 `--no-media`，拿不到任何媒体。
    var includesMedia: Bool { self != .textOnly }
}

/// 导出方式偏好（持久化到 UserDefaults）
enum ExportModePreferences {
    private enum Keys {
        static let mode = "export.mode"
    }

    static var mode: ExportMode {
        get {
            let raw = UserDefaults.standard.string(forKey: Keys.mode) ?? ExportMode.categorized.rawValue
            return ExportMode(rawValue: raw) ?? .categorized
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.mode)
        }
    }
}
