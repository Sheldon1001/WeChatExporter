import Foundation

/// 后台任务日志的缓冲区。
///
/// wx-cli 处理大量媒体时可能在几秒内吐出上万行——比如每张图都转码失败，
/// 一张图就是四行报错。若逐行 `DispatchQueue.main.async` 派发到 UI，
/// 主队列会被塞满，界面直接失去响应（活动监视器里显示「未响应」）。
///
/// 所以后台只管往这里塞，UI 定时批量取走。同时把连续重复的行折叠成一条，
/// 避免同一句报错刷满整个面板——那既没信息量，也会让真正有用的行被挤掉。
final class LogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String] = []
    private var lastLine: String?
    private var repeatCount = 0

    /// 缓冲上限。UI 只显示最近若干行，攒再多也没意义，还会白吃内存。
    private let capacity: Int

    init(capacity: Int = 600) {
        self.capacity = capacity
    }

    /// 可从任意线程调用。
    func append(_ message: String) {
        let line = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        if line == lastLine {
            repeatCount += 1
            return
        }
        collapseRepeatsLocked()
        lastLine = line
        pending.append(line)
        trimLocked()
    }

    /// 取走全部已缓冲的行，交给调用方在主线程消费。
    func drain() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        collapseRepeatsLocked()
        let out = pending
        pending.removeAll(keepingCapacity: true)
        return out
    }

    func reset() {
        lock.lock()
        pending.removeAll(keepingCapacity: true)
        lastLine = nil
        repeatCount = 0
        lock.unlock()
    }

    private func collapseRepeatsLocked() {
        guard repeatCount > 0 else { return }
        pending.append("（上一行重复了 \(repeatCount) 次）")
        repeatCount = 0
        trimLocked()
    }

    private func trimLocked() {
        if pending.count > capacity {
            pending.removeFirst(pending.count - capacity)
        }
    }
}
