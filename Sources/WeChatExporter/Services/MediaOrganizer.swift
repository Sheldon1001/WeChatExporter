import Foundation

/// 将导出目录中的文件按类型归档到 文字 / 图片 / 视频 / 语音 / 其他 文件夹。
enum MediaOrganizer {

    struct Result {
        let textCount: Int
        let imageCount: Int
        let videoCount: Int
        let audioCount: Int
        let otherCount: Int
    }

    /// 媒体分类。分类名同时是分类导出的文件夹名，也是网页导出 `media/` 下的子目录名——
    /// 两条通路共用这一张表，免得两边各写一份扩展名列表再慢慢分叉。
    enum Category: String, CaseIterable {
        case text = "文字"
        case image = "图片"
        case video = "视频"
        case audio = "语音"
        case other = "其他"
    }

    /// 文字类扩展名
    private static let textExts: Set<String> = ["txt", "json", "csv", "md"]
    /// 图片类扩展名
    private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "tiff"]
    /// 视频类扩展名
    private static let videoExts: Set<String> = ["mp4", "mov", "avi", "mkv", "webm", "3gp", "flv", "wmv", "m4v"]
    /// 语音类扩展名。`silk` 是微信原始语音格式，ffmpeg 缺失时 wx-cli 会降级导出它
    private static let audioExts: Set<String> = ["mp3", "m4a", "aac", "wav", "ogg", "opus", "amr", "silk"]

    /// 按扩展名判断文件属于哪一类
    static func category(forExtension ext: String) -> Category {
        let e = ext.lowercased()
        if textExts.contains(e) { return .text }
        if imageExts.contains(e) { return .image }
        if videoExts.contains(e) { return .video }
        if audioExts.contains(e) { return .audio }
        return .other
    }

    /// 把 sourceDir 下的文件按类型移动到 contactDir 下的分类文件夹。
    /// contactDir 是本次导出该会话的专属文件夹，由调用方按 `ExportNaming.folderName` 拼好。
    /// 返回各分类文件数。
    static func organize(
        sourceDir: URL,
        into contactDir: URL,
        log: @escaping (String) -> Void
    ) throws -> Result {
        let fm = FileManager.default
        let textDir = contactDir.appendingPathComponent(Category.text.rawValue, isDirectory: true)
        let imageDir = contactDir.appendingPathComponent(Category.image.rawValue, isDirectory: true)
        let videoDir = contactDir.appendingPathComponent(Category.video.rawValue, isDirectory: true)
        let audioDir = contactDir.appendingPathComponent(Category.audio.rawValue, isDirectory: true)
        let otherDir = contactDir.appendingPathComponent(Category.other.rawValue, isDirectory: true)

        for dir in [textDir, imageDir, videoDir, audioDir, otherDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        var textCount = 0
        var imageCount = 0
        var videoCount = 0
        var audioCount = 0
        var otherCount = 0

        // 递归收集所有文件
        let files = collectFiles(in: sourceDir)
        for file in files {
            let dest: URL
            switch category(forExtension: file.pathExtension) {
            case .text:
                dest = textDir.appendingPathComponent(file.lastPathComponent)
                textCount += 1
            case .image:
                dest = imageDir.appendingPathComponent(file.lastPathComponent)
                imageCount += 1
            case .video:
                dest = videoDir.appendingPathComponent(file.lastPathComponent)
                videoCount += 1
            case .audio:
                dest = audioDir.appendingPathComponent(file.lastPathComponent)
                audioCount += 1
            case .other:
                dest = otherDir.appendingPathComponent(file.lastPathComponent)
                otherCount += 1
            }

            // 目标已存在同名文件时加序号
            let uniqueDest = uniqueDestination(for: dest)
            do {
                try fm.moveItem(at: file, to: uniqueDest)
            } catch {
                log("归档失败：\(file.lastPathComponent)（\(error.localizedDescription)）")
            }
        }

        // 清理空目录
        removeEmptyDirs(in: sourceDir)
        for dir in [videoDir, audioDir, otherDir] {
            removeIfEmpty(dir)
        }

        let result = Result(
            textCount: textCount,
            imageCount: imageCount,
            videoCount: videoCount,
            audioCount: audioCount,
            otherCount: otherCount
        )
        log("归档完成：文字 \(textCount) 个、图片 \(imageCount) 个、视频 \(videoCount) 个、语音 \(audioCount) 个、其他 \(otherCount) 个 → \(contactDir.path)")
        return result
    }

    // MARK: - Helpers

    private static func collectFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDir { files.append(url) }
        }
        return files
    }

    private static func removeEmptyDirs(in dir: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        // 自底向上删除空目录
        var dirs: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false {
                dirs.append(url)
            }
        }
        for d in dirs.reversed() {
            if let contents = try? fm.contentsOfDirectory(atPath: d.path), contents.isEmpty {
                try? fm.removeItem(at: d)
            }
        }
        if let contents = try? fm.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
            try? fm.removeItem(at: dir)
        }
    }

    private static func removeIfEmpty(_ dir: URL) {
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
            try? fm.removeItem(at: dir)
        }
    }

    private static func uniqueDestination(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let stem = (url.lastPathComponent as NSString).deletingPathExtension
        let ext = (url.lastPathComponent as NSString).pathExtension
        let parent = url.deletingLastPathComponent()
        var n = 2
        while true {
            let candidate = ext.isEmpty
                ? parent.appendingPathComponent("\(stem)_\(n)")
                : parent.appendingPathComponent("\(stem)_\(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
