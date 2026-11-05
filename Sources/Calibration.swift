import AppKit

// MARK: - 手动校准（对没有接口的服务，用基准线 + 周期倒计时）

struct ManualCalibration {
    var remaining: Double      // 0...1
    var expiresAt: Date        // 周期结束时间
    var label: String

    var isExpired: Bool { expiresAt <= Date() }

    static func key(_ id: String, _ field: String) -> String { "manual.\(id).\(field)" }

    static func load(_ id: String) -> ManualCalibration? {
        let d = UserDefaults.standard
        guard d.object(forKey: key(id, "remaining")) != nil,
              let exp = d.object(forKey: key(id, "expiresAt")) as? Date else { return nil }
        let remaining = d.double(forKey: key(id, "remaining"))
        let label = d.string(forKey: key(id, "label")) ?? "手动校准"
        return ManualCalibration(remaining: remaining, expiresAt: exp, label: label)
    }

    static func save(_ id: String, remaining: Double, expiresAt: Date, label: String) {
        let d = UserDefaults.standard
        d.set(remaining, forKey: key(id, "remaining"))
        d.set(expiresAt, forKey: key(id, "expiresAt"))
        d.set(label, forKey: key(id, "label"))
    }

    static func clear(_ id: String) {
        let d = UserDefaults.standard
        for f in ["remaining", "expiresAt", "label"] { d.removeObject(forKey: key(id, f)) }
    }
}

// MARK: - WorkBuddy 积分锚点

/// WorkBuddy 的云端额度没有公开接口，但本地记录了每次会话的积分消耗。
/// 用户填一次「当前剩余积分」作为锚点，之后用「锚点 − 新增消耗」实时推算剩余。
///
/// 关键：同时记录锚点时刻**每个会话已累计的积分**（baseline）。
/// 只算「当前累计 − baseline」的增量，这样锚点之前就已存在、之后还在继续的会话
/// 不会被重复计算。
struct WBAnchor {
    var credits: Double      // 锚点时刻的剩余积分
    var at: Date             // 锚点时刻
    var baseline: [String: Double]   // session_id -> 该会话在锚点时刻的累计积分

    private static let creditsKey = "wb.anchor.credits"
    private static let atKey = "wb.anchor.at"
    private static let baselineKey = "wb.anchor.baseline"

    static func load() -> WBAnchor? {
        let d = UserDefaults.standard
        guard d.object(forKey: creditsKey) != nil,
              let at = d.object(forKey: atKey) as? Date else { return nil }
        var baseline: [String: Double] = [:]
        if let json = d.string(forKey: baselineKey),
           let data = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Double] {
            baseline = obj
        }
        return WBAnchor(credits: d.double(forKey: creditsKey), at: at, baseline: baseline)
    }

    static func save(credits: Double, baseline: [String: Double]) {
        let d = UserDefaults.standard
        d.set(credits, forKey: creditsKey)
        d.set(Date(), forKey: atKey)
        if let data = try? JSONSerialization.data(withJSONObject: baseline),
           let json = String(data: data, encoding: .utf8) {
            d.set(json, forKey: baselineKey)
        }
    }

    static func clear() {
        let d = UserDefaults.standard
        d.removeObject(forKey: creditsKey)
        d.removeObject(forKey: atKey)
        d.removeObject(forKey: baselineKey)
    }
}
