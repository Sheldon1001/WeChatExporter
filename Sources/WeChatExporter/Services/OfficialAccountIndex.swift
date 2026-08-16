import Foundation
import SQLite3

/// 公众号 / 服务号名单，用来给会话分类。
///
/// 光看 username 是分不出来的：微信里不少公众号的 username 就是 `wxid_` 开头，
/// 与真人好友完全同构（实测多家媒体号、银行服务号都是 `wxid_` 形态，
/// 只按前缀判断会把它们全部误判成好友）。真正的判据是 `contact` 表的
/// `verify_flag`：非 0 即为微信认证过的公众号 / 服务号 / 企业号
/// （实测一份真实数据里 25336 个 0、730 个非 0，订阅号是 24、服务号 28/29、媒体号 1048）。
///
/// wx-cli 的 `sessions` 输出不带这个字段，所以这里直接读它解密缓存里的 `contact.db`。
enum OfficialAccountIndex {

    /// 读一次就缓存住：会话列表每次刷新都要用，而这张表几千行、不会频繁变。
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cached: Set<String>?

    /// 已认证的公众号 username 集合。读不到数据库时返回空集，
    /// 分类会退回到「按 username 前缀判断」，不会因此崩掉。
    static func usernames() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let loaded = load()
        cached = loaded
        return loaded
    }

    /// 解密数据变化后（重新「准备数据」）需要重新读。
    static func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    private static func load() -> Set<String> {
        guard let dbURL = locateContactDB(),
              let db = try? SQLiteDatabase.openReadOnly(at: dbURL) else { return [] }
        defer { sqlite3_close(db) }

        guard SQLiteDatabase.tableExists(db, name: "contact"),
              SQLiteDatabase.columnNames(db, table: "contact").contains("verify_flag") else { return [] }

        var result = Set<String>()
        let sql = "SELECT username FROM contact WHERE verify_flag != 0"
        guard let stmt = try? SQLiteDatabase.prepare(db, sql: sql, context: "official accounts") else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(stmt, 0) else { continue }
            let name = String(cString: cString)
            if !name.isEmpty { result.insert(name) }
        }
        return result
    }

    /// 与 `StickerPackExporter.locateEmoticonDB` 同一套手法：
    /// glob wx-cli 的解密缓存，挑修改时间最新的那份。
    private static func locateContactDB() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let cacheRoots = [
            home.appendingPathComponent("Library/Caches/wx-cli", isDirectory: true),
            home.appendingPathComponent(".wx-cli/cache", isDirectory: true),
        ]

        var candidates: [URL] = []
        for root in cacheRoots where fm.fileExists(atPath: root.path) {
            guard let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries where entry.hasDirectoryPath {
                let db = entry.appendingPathComponent("db_storage/contact/contact.db", isDirectory: false)
                if fm.fileExists(atPath: db.path) { candidates.append(db) }
            }
        }

        return candidates.max(by: {
            let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return d0 < d1
        })
    }
}
