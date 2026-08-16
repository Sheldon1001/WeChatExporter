import Foundation

enum ContactKind: String, CaseIterable {
    case friend = "好友"
    case group = "群聊"
    case official = "公众号"
    /// 企业微信联系人、客服会话，以及服务通知 / 文件传输助手这类系统会话
    case other = "其他"

    var icon: String {
        switch self {
        case .friend: return "person.circle.fill"
        case .group: return "person.3.fill"
        case .official: return "megaphone.fill"
        case .other: return "tray.full.fill"
        }
    }

    /// 会话列表里的分组顺序：先人、再群、再公众号，杂项垫底。
    var sortOrder: Int {
        switch self {
        case .friend: return 0
        case .group: return 1
        case .official: return 2
        case .other: return 3
        }
    }

    /// 微信的系统会话，username 是固定的保留字。
    private static let systemUsernames: Set<String> = [
        "notifymessage", "brandsessionholder", "brandservicesessionholder",
        "filehelper", "weixin", "qqmail", "newsapp", "fmessage", "medianote",
        "floatbottle", "qmessage", "tmessage", "qqsync", "blogapp", "masssendapp",
        "feedsapp", "voip", "officialaccounts", "helper_entry", "pc_share",
        "shakeapp", "readerapp", "lbsapp", "voicevoipapp", "voipapp",
        "exmail_tool", "mphelper", "weixinreminder", "service_notification",
        "wxitil", "userexperience_alarm", "qqfriend",
    ]

    /// 依 username 判定会话类型。两个后端（wx-cli 与 native）都走这里，避免各写一份而分叉。
    ///
    /// 判定顺序：
    /// - `*@chatroom` 是群聊
    /// - `gh_*` 是公众号
    /// - 保留字与 `@` 开头的是系统会话（服务通知、折叠的群聊等）
    /// - 含 `@` 的（`*@openim` / `*@kefu.openim`）是企业微信联系人与客服会话
    /// - **`verify_flag != 0` 的也是公众号**：微信里不少公众号的 username 就是 `wxid_` 开头，
    ///   与真人好友完全同构（媒体号、银行服务号多是这种），只看前缀会误判成好友。
    ///   名单由 `OfficialAccountIndex` 从解密后的 `contact.db` 读出。
    /// - 其余都算好友
    ///
    /// - Parameter officialAccounts: 已认证公众号名单。传 nil 时现取（内部有缓存）；
    ///   批量分类时建议由调用方取一次传进来，省得每条都走一次加锁。
    static func classify(
        username: String,
        isGroupType: Bool = false,
        officialAccounts: Set<String>? = nil
    ) -> ContactKind {
        if username.hasSuffix("@chatroom") || isGroupType { return .group }
        if username.hasPrefix("gh_") { return .official }
        if username.hasPrefix("@") || systemUsernames.contains(username) { return .other }
        // 企业微信 / 客服：形如 25984982075192595@openim
        if username.contains("@") { return .other }
        let verified = officialAccounts ?? OfficialAccountIndex.usernames()
        if verified.contains(username) { return .official }
        return .friend
    }
}

struct ContactItem: Identifiable, Hashable {
    let id: String
    let displayName: String
    let nickName: String
    let remark: String
    let kind: ContactKind
    let lastTime: String
    let lastTimestamp: Int
    let summary: String

    var subtitle: String {
        if summary.isEmpty { return lastTime }
        return "\(lastTime) · \(summary)"
    }
}

struct ExportResult: Identifiable {
    let id = UUID()
    let contact: ContactItem
    let messageCount: Int
    let outputURL: URL
}
