import Foundation

/// 一个 AI 服务的额度快照
struct QuotaItem {
    enum Status: String {
        case live          // 实时读取成功
        case local         // 从本地缓存/日志读到的快照
        case manual        // 用户手动校准的值
        case unavailable   // 读不到
    }

    var id: String
    var name: String
    /// 主数值，例如 "68%" / "¥ 12.40" / "0 次"
    var primary: String
    /// 副标题，例如 "月额度 · 26 天后重置"
    var secondary: String
    /// 剩余比例 0...1，用于进度条；nil 表示无进度概念
    var remaining: Double?
    var status: Status
    /// 状态角标文字，例如 "本地快照"
    var badge: String?
    /// 强调色名称，由 UI 层映射成 NSColor
    var accent: String

    static func unavailable(id: String, name: String, reason: String) -> QuotaItem {
        QuotaItem(id: id, name: name, primary: "--", secondary: reason,
                  remaining: nil, status: .unavailable, badge: nil, accent: "gray")
    }
}

/// 数据源协议：每个 AI 服务一个实现
protocol QuotaProvider {
    var id: String { get }
    var name: String { get }
    var accent: String { get }
    func fetch() -> QuotaItem
}

// MARK: - 公共工具

enum QuotaUtil {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// 相对时间，例如 "3 小时 12 分后重置" / "已重置"
    static func resetDescription(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let interval = date.timeIntervalSince(now)
        if interval <= 0 { return "已重置" }
        let mins = Int(interval / 60)
        let days = mins / (60 * 24)
        let hours = (mins % (60 * 24)) / 60
        let minutes = mins % 60
        if days > 0 { return "\(days) 天 \(hours) 小时后重置" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分后重置" }
        return "\(minutes) 分钟后重置"
    }

    /// 人类可读的窗口长度
    static func windowLabel(minutes: Int) -> String {
        switch minutes {
        case 300: return "5 小时额度"
        case 60 * 24 * 7: return "周额度"
        case 60 * 24 * 30: return "月额度"
        case ..<60: return "\(minutes) 分钟额度"
        case 60..<(60 * 24): return "\(minutes / 60) 小时额度"
        case 60 * 24..<(60 * 24 * 7 + 1): return "\(minutes / (60 * 24)) 天额度"
        case 60 * 24 * 7..<(60 * 24 * 30 + 1): return "周额度"
        default: return "月额度"
        }
    }

    static func percentText(_ ratio: Double) -> String {
        let pct = ratio * 100
        if pct >= 99.5 { return "100%" }
        if pct < 10 { return String(format: "%.1f%%", pct) }
        return String(format: "%.0f%%", pct)
    }
}
