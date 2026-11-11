import Foundation

/// 监听 Codex 的会话日志，检测 `task_complete` 事件。
///
/// Codex 会把每一轮对话写成
/// ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
/// 每行一个 JSON，其中
///   {"type":"event_msg","payload":{"type":"task_started",...}}
///   {"type":"event_msg","payload":{"type":"task_complete",...}}
/// 就是我们需要的信号。
final class CodexTaskWatcher {

    /// 检测到一次任务完成
    var onTaskComplete: ((_ duration: TimeInterval?) -> Void)?

    private var timer: Timer?
    private var offsets: [String: UInt64] = [:]   // 文件路径 → 已读字节
    private let baseDir: String
    private let pollInterval: TimeInterval = 4

    init() {
        baseDir = NSHomeDirectory() + "/.codex/sessions"
    }

    func start() {
        // 首次把现有文件都标记为已读，避免启动时把历史任务当新的
        primeOffsets()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 内部

    private func primeOffsets() {
        for path in recentFiles(limit: 8) {
            if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64 {
                offsets[path] = size
            }
        }
    }

    /// 最近修改的 session 文件（按修改时间倒序）
    private func recentFiles(limit: Int) -> [String] {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: baseDir) else { return [] }
        var files: [(String, Date)] = []
        for case let rel as String in en where rel.hasSuffix(".jsonl") {
            let full = baseDir + "/" + rel
            let mtime = (try? fm.attributesOfItem(atPath: full)[.modificationDate] as? Date) ?? .distantPast
            files.append((full, mtime))
        }
        return files.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }

    private func poll() {
        for path in recentFiles(limit: 6) {
            let fm = FileManager.default
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? UInt64 else { continue }
            let prev = offsets[path] ?? size   // 新文件从末尾开始，不读历史
            guard size > prev else { continue }

            guard let fh = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? fh.close() }
            do {
                try fh.seek(toOffset: prev)
                let data = fh.readDataToEndOfFile()
                offsets[path] = size
                scan(data)
            } catch {
                continue
            }
        }
    }

    private func scan(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }
        var startedAt: TimeInterval?
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            guard let payload = obj["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }
            if type == "task_started" {
                startedAt = Date().timeIntervalSince1970
            } else if type == "task_complete" {
                let duration = startedAt.map { Date().timeIntervalSince1970 - $0 }
                onTaskComplete?(duration)
                startedAt = nil
            }
        }
    }
}
