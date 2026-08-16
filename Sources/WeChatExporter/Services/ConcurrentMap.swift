import Foundation

/// 以固定并发度批量跑异步任务，并可设总时间预算。
///
/// 媒体导出里要下载成百上千个小文件。串行做的话，单个 12 秒超时就足以把整个导出
/// 拖到不可用——群聊里几千个表情、其中不少 CDN 链接早已过期，串行等下来是几十分钟。
/// 这里限制并发数（不能无限开，会被 CDN 限流也会打满连接数），并给整批设一个时间上限：
/// 超预算后不再启动新任务，已在跑的等它结束，剩下的报告为「已跳过」。
enum ConcurrentMap {

    /// - Parameters:
    ///   - concurrency: 同时在跑的任务数上限。
    ///   - budget: 整批的时间预算（秒）。为 nil 表示不限时。
    ///   - onProgress: 每完成一个回调一次，参数为 (已完成, 总数)。
    /// - Returns: 与 `jobs` 一一对应的结果；因超预算未执行的为 `nil`。
    static func run<Job: Sendable, Result: Sendable>(
        _ jobs: [Job],
        concurrency: Int,
        budget: TimeInterval? = nil,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil,
        _ body: @escaping @Sendable (Job) async -> Result
    ) async -> [Result?] {
        guard !jobs.isEmpty else { return [] }
        let limit = max(1, min(concurrency, jobs.count))
        let deadline = budget.map { Date().addingTimeInterval($0) }

        var results = [Result?](repeating: nil, count: jobs.count)
        var completed = 0
        var next = 0

        await withTaskGroup(of: (Int, Result).self) { group in
            func addNext() -> Bool {
                guard next < jobs.count else { return false }
                if let deadline, Date() >= deadline { return false }
                let index = next
                let job = jobs[index]
                next += 1
                group.addTask { (index, await body(job)) }
                return true
            }

            while group.isEmpty || next < limit {
                if !addNext() { break }
            }

            while let (index, value) = await group.next() {
                results[index] = value
                completed += 1
                onProgress?(completed, jobs.count)
                _ = addNext()
            }
        }

        return results
    }
}
