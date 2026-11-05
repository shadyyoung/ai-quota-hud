import Foundation

// MARK: - JSON 点路径取值

enum JSONPath {
    /// 按 "a.b[0].c" 或 "a.b.0.c" 取嵌套值
    static func value(at path: String, in root: Any) -> Any? {
        guard !path.isEmpty else { return nil }
        var current: Any = root
        for part in path.split(separator: ".") {
            let key = String(part)
            if let dict = current as? [String: Any], let next = dict[key] {
                current = next
            } else if let arr = current as? [Any], let idx = Int(key), idx >= 0, idx < arr.count {
                current = arr[idx]
            } else {
                return nil
            }
        }
        return current
    }

    static func double(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func date(_ v: Any?) -> Date? {
        guard let v else { return nil }
        if let n = v as? NSNumber {
            let d = n.doubleValue
            // 毫秒或秒
            return d > 1e11 ? Date(timeIntervalSince1970: d / 1000) : Date(timeIntervalSince1970: d)
        }
        if let s = v as? String {
            let iso = ISO8601DateFormatter()
            if let d = iso.date(from: s) { return d }
            // 纯数字字符串
            if let d = Double(s) { return Date(timeIntervalSince1970: d) }
        }
        return nil
    }

    static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
}

// MARK: - 用户自定义数据源配置

/// providers.json 里的单个条目
struct JsonProviderConfig: Codable {
    var id: String
    var name: String
    var accent: String?
    var icon: String?

    /// http = 请求接口；manual = 纯手动；command = 执行命令（stdout 为 JSON）
    var type: String?

    // http
    var url: String?
    var headers: [String: String]?
    /// 存 API key 的 UserDefaults 键；请求时用 ${key} 占位
    var apiKeySetting: String?
    var viaProxy: Bool?

    // 提取
    var remainingPath: String?
    var totalPath: String?
    var percentPath: String?
    var resetPath: String?

    // 展示
    /// percent = 显示百分比 + 进度条；value = 显示数值
    var display: String?
    var unit: String?

    // command
    var command: String?

    var enabled: Bool?
}

struct JsonProvidersFile: Codable {
    var version: Int?
    var providers: [JsonProviderConfig]
}

// MARK: - 由配置驱动的 Provider

final class JsonProvider: QuotaProvider {
    let config: JsonProviderConfig
    private static let defaults = UserDefaults.standard

    var id: String { config.id }
    var name: String { config.name }
    var accent: String { config.accent ?? "blue" }

    init(config: JsonProviderConfig) {
        self.config = config
    }

    // MARK: 取 API key

    private func apiKey() -> String? {
        guard let key = config.apiKeySetting else { return nil }
        let v = Self.defaults.string(forKey: key) ?? ""
        return v.isEmpty ? nil : v
    }

    // MARK: fetch

    func fetch() -> QuotaItem {
        switch (config.type ?? "http").lowercased() {
        case "manual":
            return manualItem()
        case "command":
            return commandItem()
        default:
            return httpItem()
        }
    }

    private func manualItem() -> QuotaItem {
        // 纯手动：走已有的 ManualCalibration 或 WBAnchor 体系
        if let m = ManualCalibration.load(id), !m.isExpired {
            return QuotaItem(id: id, name: name,
                             primary: "剩余 " + QuotaUtil.percentText(m.remaining),
                             secondary: m.label + " · " + QuotaUtil.resetDescription(m.expiresAt),
                             remaining: m.remaining, status: .manual, badge: nil, accent: accent)
        }
        return .unavailable(id: id, name: name, reason: "右键 → 手动校准额度")
    }

    private func httpItem() -> QuotaItem {
        guard let urlStr = config.url, !urlStr.isEmpty else {
            return .unavailable(id: id, name: name, reason: "配置缺少 url")
        }

        // 需要 key 但没配
        if config.apiKeySetting != nil, apiKey() == nil {
            return .unavailable(id: id, name: name, reason: "右键 → 设置 \(name) Key")
        }

        // 替换 ${key}
        var headers: [String: String] = config.headers ?? [:]
        if let key = apiKey() {
            for (k, v) in headers where v.contains("${key}") {
                headers[k] = v.replacingOccurrences(of: "${key}", with: key)
            }
        }

        guard let (code, data) = HTTP.getJSON(urlStr, headers: headers,
                                             timeout: 12, viaProxy: config.viaProxy ?? true),
              (200..<300).contains(code),
              let obj = (try? JSONSerialization.jsonObject(with: data)) else {
            return .unavailable(id: id, name: name, reason: "请求失败（检查 Key 或网络）")
        }

        // 百分比模式
        if let pp = config.percentPath, let raw = JSONPath.double(JSONPath.value(at: pp, in: obj)) {
            let ratio = raw > 1 ? raw / 100 : raw      // 兼容 0-100 与 0-1
            return QuotaItem(id: id, name: name,
                             primary: "剩余 " + QuotaUtil.percentText(ratio),
                             secondary: secondaryText(resetValue: JSONPath.value(at: config.resetPath ?? "", in: obj)),
                             remaining: ratio, status: .live, badge: nil, accent: accent)
        }

        // 绝对值模式
        guard let rp = config.remainingPath,
              let remainRaw = JSONPath.double(JSONPath.value(at: rp, in: obj)) else {
            return .unavailable(id: id, name: name, reason: "返回里找不到额度字段")
        }

        let unit = config.unit ?? ""
        let display = (config.display ?? "value").lowercased()
        let reset = JSONPath.value(at: config.resetPath ?? "", in: obj)

        if display == "percent" {
            let total = config.totalPath.flatMap { JSONPath.double(JSONPath.value(at: $0, in: obj)) }
                ?? remainRaw
            let ratio = total > 0 ? max(0, min(1, remainRaw / total)) : 0
            return QuotaItem(id: id, name: name,
                             primary: "剩余 " + QuotaUtil.percentText(ratio),
                             secondary: secondaryText(resetValue: reset),
                             remaining: ratio, status: .live, badge: nil, accent: accent)
        }

        // 显示数值
        let valueText: String
        if unit == "¥" || unit == "$" {
            valueText = String(format: "%@ %.2f", unit, remainRaw)
        } else if unit.isEmpty {
            valueText = String(format: "%.1f", remainRaw)
        } else {
            valueText = String(format: "%.1f %@", remainRaw, unit)
        }

        // 有 total 时给进度条
        var ratio: Double?
        if let tp = config.totalPath,
           let total = JSONPath.double(JSONPath.value(at: tp, in: obj)), total > 0 {
            ratio = max(0, min(1, remainRaw / total))
        }

        return QuotaItem(id: id, name: name,
                         primary: valueText,
                         secondary: secondaryText(resetValue: reset),
                         remaining: ratio, status: .live, badge: nil, accent: accent)
    }

    private func commandItem() -> QuotaItem {
        guard let cmd = config.command, !cmd.isEmpty else {
            return .unavailable(id: id, name: name, reason: "配置缺少 command")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch {
            return .unavailable(id: id, name: name, reason: "命令执行失败")
        }
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else {
            return .unavailable(id: id, name: name, reason: "命令无输出")
        }
        // 支持纯数字 或 JSON
        if let direct = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return QuotaItem(id: id, name: name,
                             primary: String(format: "%.1f", direct),
                             secondary: "来自命令", remaining: nil,
                             status: .live, badge: nil, accent: accent)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
            return .unavailable(id: id, name: name, reason: "命令输出不是 JSON")
        }
        if let pp = config.percentPath, let raw = JSONPath.double(JSONPath.value(at: pp, in: obj)) {
            let ratio = raw > 1 ? raw / 100 : raw
            return QuotaItem(id: id, name: name,
                             primary: "剩余 " + QuotaUtil.percentText(ratio),
                             secondary: secondaryText(resetValue: nil),
                             remaining: ratio, status: .live, badge: nil, accent: accent)
        }
        if let rp = config.remainingPath,
           let val = JSONPath.double(JSONPath.value(at: rp, in: obj)) {
            return QuotaItem(id: id, name: name,
                             primary: String(format: "%.1f %@", val, config.unit ?? ""),
                             secondary: "来自命令", remaining: nil,
                             status: .live, badge: nil, accent: accent)
        }
        return .unavailable(id: id, name: name, reason: "命令输出里没有额度字段")
    }

    private func secondaryText(resetValue: Any?) -> String {
        if let d = JSONPath.date(resetValue) {
            let desc = QuotaUtil.resetDescription(d)
            return desc.isEmpty ? "实时" : desc
        }
        return "实时"
    }
}

// MARK: - 加载用户配置

enum JsonProviderLoader {
    static func loadAll() -> [QuotaProvider] {
        let path = AppSettings.providersConfigPath
        guard let data = try? Data(contentsOf: path) else { return [] }
        guard let file = try? JSONDecoder().decode(JsonProvidersFile.self, from: data) else {
            NSLog("AIQuotaHUD: providers.json 解析失败")
            return []
        }
        return file.providers
            .filter { $0.enabled ?? true }
            .map { JsonProvider(config: $0) }
    }

    /// 生成一份示例配置（首次运行时）
    static func writeExampleIfNeeded() {
        AppSettings.ensureConfigDir()
        let path = AppSettings.providersConfigPath
        guard !FileManager.default.fileExists(atPath: path.path) else { return }

        let example = """
        {
          "version": 1,
          "providers": [
            {
              "id": "kimi",
              "name": "Kimi",
              "accent": "orange",
              "type": "http",
              "url": "https://api.moonshot.cn/v1/users/me/balance",
              "headers": { "Authorization": "Bearer ${key}" },
              "apiKeySetting": "kimi.apiKey",
              "remainingPath": "data.available_balance",
              "totalPath": "data.cash_balance",
              "display": "value",
              "unit": "¥",
              "enabled": false
            }
          ]
        }
        """
        try? example.write(to: path, atomically: true, encoding: .utf8)
    }
}
