import Foundation

// MARK: - 同步 HTTP 工具

enum HTTP {
    /// 无缓存会话：额度必须每次拿新的，且避免沙盒下写缓存目录报错
    private static func makeSession(proxy: ProxyConfig.Proxy?) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.timeoutIntervalForRequest = 20
        // 关键：代理只挂在本次 app 自己的 URLSession 上，不碰系统设置，不影响其他应用
        if let proxy { cfg.connectionProxyDictionary = proxy.dict }
        return URLSession(configuration: cfg)
    }

    private static let directSession = makeSession(proxy: nil)

    private static func session(viaProxy: Bool) -> URLSession {
        guard viaProxy, let proxy = ProxyConfig.active else { return directSession }
        return makeSession(proxy: proxy)
    }

    static func getJSON(_ url: String, headers: [String: String] = [:],
                        timeout: TimeInterval = 20, viaProxy: Bool = false) -> (Int, Data)? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.timeoutInterval = timeout
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let sem = DispatchSemaphore(value: 0)
        var result: (Int, Data)?
        let task = session(viaProxy: viaProxy).dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            guard let http = resp as? HTTPURLResponse, let data else { return }
            result = (http.statusCode, data)
        }
        task.resume()
        _ = sem.wait(timeout: .now() + timeout + 5)
        return result
    }

    static func getJSONObject(_ url: String, headers: [String: String] = [:],
                              timeout: TimeInterval = 20, viaProxy: Bool = false) -> [String: Any]? {
        guard let (code, data) = getJSON(url, headers: headers, timeout: timeout, viaProxy: viaProxy),
              (200..<300).contains(code) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - sqlite 命令行读取（避免链接 libsqlite3 的编译依赖）

enum SQLiteCLI {
    /// 执行一条查询，返回按 tab 分隔的行
    static func query(_ dbPath: String, _ sql: String) -> [[String]] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["-separator", "\u{1F}", "-readonly", dbPath, sql]
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return [] }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { line in
            line.components(separatedBy: "\u{1F}")
        }
    }
}

// MARK: - Codex / ChatGPT

/// 从 ~/.codex/sessions/**/*.jsonl 里读取最新的 rate_limits 快照。
/// 这些文件由 Codex CLI 在每次对话时写入，包含 5h / 周 / 月 窗口的已用百分比与重置时间，
/// 因此无需联网即可读出额度。
final class CodexProvider: QuotaProvider {
    let id = "codex"
    let name = "Codex"
    let accent = "blue"

    private let sessionsDir = QuotaUtil.home.appendingPathComponent(".codex/sessions")

    struct Snapshot {
        var usedPercent: Double
        var windowMinutes: Int
        var resetsAt: Date?
        var capturedAt: Date
        var planType: String?
    }

    func fetch() -> QuotaItem {
        // 优先走代理拿实时额度；拿不到再退回本地快照
        if let live = fetchLive() { return live }
        return fetchCached()
    }

    /// 实时：GET chatgpt.com/backend-api/wham/usage（只在本 app 内走代理）
    private func fetchLive() -> QuotaItem? {
        guard let auth = codexAuth() else { return nil }
        let headers: [String: String] = [
            "Authorization": "Bearer \(auth.token)",
            "chatgpt-account-id": auth.accountID,
            "User-Agent": "codex_cli_rs/0.100.0",
            "Accept": "application/json"
        ]
        guard let (code, data) = HTTP.getJSON(
                "https://chatgpt.com/backend-api/wham/usage",
                headers: headers, timeout: 8, viaProxy: true),
              (200..<300).contains(code),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rl = obj["rate_limit"] as? [String: Any],
              let pw = rl["primary_window"] as? [String: Any] else { return nil }

        let used = (pw["used_percent"] as? NSNumber)?.doubleValue ?? 0
        let windowSec = (pw["limit_window_seconds"] as? NSNumber)?.doubleValue ?? 0
        let resetEpoch = pw["reset_at"] as? NSNumber
        let plan = obj["plan_type"] as? String

        let now = Date()
        let resetsAt = resetEpoch.map { Date(timeIntervalSince1970: $0.doubleValue) }
        var remaining = max(0, min(1, 1 - used / 100))
        var resetDesc = QuotaUtil.resetDescription(resetsAt, now: now)
        if let r = resetsAt, r <= now { remaining = 1; resetDesc = "已重置" }

        var parts: [String] = []
        if let plan { parts.append("\(plan) 计划") }
        if windowSec > 0 { parts.append(QuotaUtil.windowLabel(minutes: Int(windowSec / 60))) }
        if !resetDesc.isEmpty { parts.append(resetDesc) }

        return QuotaItem(
            id: id, name: name,
            primary: "剩余 " + QuotaUtil.percentText(remaining),
            secondary: parts.joined(separator: " · "),
            remaining: remaining,
            status: .live,
            badge: nil,
            accent: accent
        )
    }

    private func codexAuth() -> (token: String, accountID: String)? {
        let url = QuotaUtil.home.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String,
              let acct = tokens["account_id"] as? String else { return nil }
        return (token, acct)
    }

    /// 离线回退：从本地会话文件读最近一次服务端下发的额度快照
    private func fetchCached() -> QuotaItem {
        guard let snap = latestSnapshot() else {
            return .unavailable(id: id, name: name, reason: "没有找到 Codex 会话记录")
        }

        let now = Date()
        var remaining = max(0, min(1, 1 - snap.usedPercent / 100))
        var resetDesc = QuotaUtil.resetDescription(snap.resetsAt, now: now)
        // 重置时间已过 → 窗口已刷新，视为满额
        if let r = snap.resetsAt, r <= now {
            remaining = 1
            resetDesc = "已重置"
        }

        let age = now.timeIntervalSince(snap.capturedAt)
        let stale = age > 60 * 60 * 24
        let ageText: String
        if age < 60 { ageText = "刚刚更新" }
        else if age < 3600 { ageText = "\(Int(age / 60)) 分钟前" }
        else if age < 86400 { ageText = "\(Int(age / 3600)) 小时前" }
        else { ageText = "\(Int(age / 86400)) 天前" }

        var parts = [QuotaUtil.windowLabel(minutes: snap.windowMinutes)]
        if !resetDesc.isEmpty { parts.append(resetDesc) }

        return QuotaItem(
            id: id,
            name: name,
            primary: "剩余 " + QuotaUtil.percentText(remaining),
            secondary: parts.joined(separator: " · "),
            remaining: remaining,
            status: stale ? .local : .live,
            badge: stale ? "快照 \(ageText)" : nil,
            accent: accent
        )
    }

    private func latestSnapshot() -> Snapshot? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: sessionsDir,
                                    includingPropertiesForKeys: [.contentModificationDateKey],
                                    options: [.skipsHiddenFiles]) else { return nil }

        var files: [(URL, Date)] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            files.append((url, mtime))
        }
        files.sort { $0.1 > $1.1 }

        for (url, mtime) in files.prefix(40) {
            if let snap = parseSnapshot(at: url, fallbackDate: mtime) { return snap }
        }
        return nil
    }

    private func parseSnapshot(at url: URL, fallbackDate: Date) -> Snapshot? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let text = String(data: data, encoding: .utf8) else { return nil }

        // 从最后一行往前找，取最近一次带 rate_limits 的记录
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard line.contains("\"rate_limits\"") else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let rl = payload["rate_limits"] as? [String: Any] else { continue }

            let primary = rl["primary"] as? [String: Any]
            let used = primary?["used_percent"] as? Double ?? 0
            let window = primary?["window_minutes"] as? Int ?? 0
            let resets = primary?["resets_at"] as? Double

            let ts = (obj["timestamp"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? fallbackDate
            return Snapshot(usedPercent: used,
                            windowMinutes: window,
                            resetsAt: resets.map { Date(timeIntervalSince1970: $0) },
                            capturedAt: ts,
                            planType: rl["plan_type"] as? String)
        }
        return nil
    }
}

// MARK: - Cursor

/// Cursor 在本地 state.vscdb 里保存登录 JWT，官方 /auth/usage 接口返回本月请求数。
final class CursorProvider: QuotaProvider {
    let id = "cursor"
    let name = "Cursor"
    let accent = "purple"

    private let dbPath = QuotaUtil.home
        .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")

    func fetch() -> QuotaItem {
        guard let token = accessToken(), !token.isEmpty else {
            return .unavailable(id: id, name: name, reason: "未找到 Cursor 登录态")
        }
        let auth: [String: String] = ["Authorization": "Bearer \(token)"]

        guard let usage = HTTP.getJSONObject("https://api2.cursor.sh/auth/usage", headers: auth) else {
            return .unavailable(id: id, name: name, reason: "请求失败（可能需要重新登录 Cursor）")
        }

        let plan = HTTP.getJSONObject("https://api2.cursor.sh/auth/full_stripe_profile", headers: auth)
        let membership = (plan?["membershipType"] as? String) ?? "未知"

        // usage: {"gpt-4": {"numRequests": N, "maxRequestUsage": M}, "startOfMonth": "..."}
        let gpt4 = usage["gpt-4"] as? [String: Any]
        let used = gpt4?["numRequests"] as? Int ?? 0
        let maxReq = gpt4?["maxRequestUsage"] as? Int

        let start = (usage["startOfMonth"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        var resetDesc = ""
        if let start, let next = Calendar.current.date(byAdding: .month, value: 1, to: start) {
            resetDesc = QuotaUtil.resetDescription(next)
        }

        if let maxReq, maxReq > 0 {
            let remaining = max(0, min(1, Double(maxReq - used) / Double(maxReq)))
            var secondary = "\(used)/\(maxReq) 次" + (membership == "free" ? "" : " · \(membership)")
            if !resetDesc.isEmpty { secondary += " · " + resetDesc }
            return QuotaItem(id: id, name: name,
                             primary: "剩余 " + QuotaUtil.percentText(remaining),
                             secondary: secondary,
                             remaining: remaining, status: .live, badge: nil, accent: accent)
        }

        // free 计划没有请求数上限，只显示已用量
        var secondary = "\(membership) 计划 · 本月 \(used) 次请求"
        if !resetDesc.isEmpty { secondary += " · " + resetDesc }
        return QuotaItem(id: id, name: name,
                         primary: "\(used) 次",
                         secondary: secondary,
                         remaining: nil, status: .live, badge: nil, accent: accent)
    }

    private func accessToken() -> String? {
        let rows = SQLiteCLI.query(dbPath.path,
            "select value from ItemTable where key='cursorAuth/accessToken' limit 1;")
        guard let v = rows.first?.first, !v.isEmpty else { return nil }
        return v
    }
}

// MARK: - WorkBuddy（腾讯）

/// WorkBuddy 把每次会话的 credit 消耗记录在本地 sqlite 的 session_usage.credit_json 里，
/// 额度上限在云端（没有公开接口），因此这里展示近 30 天真实消耗量。
final class WorkBuddyProvider: QuotaProvider {
    let id = "workbuddy"
    let name = "WorkBuddy"
    let accent = "teal"

    private let dbPath: URL = {
        let home = QuotaUtil.home
        let candidates = [
            home.appendingPathComponent(".workbuddy/workbuddy.db"),
            home.appendingPathComponent("Library/Application Support/WorkBuddy/workbuddy.db")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
    }()

    func fetch() -> QuotaItem {
        guard FileManager.default.fileExists(atPath: dbPath.path) else {
            return .unavailable(id: id, name: name, reason: "未找到 WorkBuddy 数据")
        }

        // 有锚点：剩余 = 锚点 − 锚点之后的新增消耗（逐会话对比 baseline，只算增量）
        if let anchor = WBAnchor.load() {
            let consumed = incrementalConsumption(since: anchor)
            let remaining = max(0, anchor.credits - consumed)
            let days = max(0, Int(Date().timeIntervalSince(anchor.at) / 86400))
            return QuotaItem(
                id: id,
                name: name,
                primary: fmt(remaining) + " 积分",
                secondary: "当前剩余 · 校准后消耗 \(fmt(consumed))" + (days > 0 ? " · \(days) 天前校准" : ""),
                remaining: nil,
                status: .live,
                badge: "本地扣减",
                accent: accent
            )
        }

        // 没有锚点：先显示近 30 天消耗
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        let consumed = credits(since: cutoff)
        let sessions = sessionCount(since: cutoff)
        if consumed <= 0 && sessions == 0 {
            return .unavailable(id: id, name: name, reason: "右键 → 设置剩余积分")
        }
        return QuotaItem(
            id: id,
            name: name,
            primary: fmt(consumed) + " 积分",
            secondary: "近 30 天消耗 · 右键填当前剩余",
            remaining: nil,
            status: .local,
            badge: nil,
            accent: accent
        )
    }

    private func fmt(_ v: Double) -> String { String(format: "%.1f", v) }

    /// 锚点之后的新增消耗：逐会话用「当前累计 − 锚点基线」取正增量。
    /// 这样锚点前就存在、之后仍在继续的会话（比如一个很长的任务）不会被整段重复计算。
    private func incrementalConsumption(since anchor: WBAnchor) -> Double {
        let current = creditBySession()
        var delta = 0.0
        for (sid, cur) in current {
            let base = anchor.baseline[sid] ?? 0
            delta += max(0, cur - base)
        }
        return delta
    }

    /// 每个会话当前累计消耗的积分（credit_json 里各模型消耗求和）
    func creditBySession() -> [String: Double] {
        let rows = SQLiteCLI.query(dbPath.path,
            "select session_id, credit_json from session_usage;")
        var out: [String: Double] = [:]
        for row in rows where row.count >= 2 {
            guard let d = row[1].data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            var sum = 0.0
            for v in obj.values { if let n = v as? NSNumber { sum += n.doubleValue } }
            out[row[0]] = sum
        }
        return out
    }

    /// 某时刻之后新增的积分消耗（session_usage.credit_json 求和）
    private func credits(since date: Date) -> Double {
        let cutoffMs = Int(date.timeIntervalSince1970 * 1000)
        let rows = SQLiteCLI.query(dbPath.path,
            "select credit_json from session_usage where updated_at > \(cutoffMs);")
        var total = 0.0
        for row in rows where !row.isEmpty {
            guard let d = row[0].data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            for v in obj.values {
                if let n = v as? NSNumber { total += n.doubleValue }
            }
        }
        return total
    }

    private func sessionCount(since date: Date) -> Int {
        let cutoffMs = Int(date.timeIntervalSince1970 * 1000)
        let rows = SQLiteCLI.query(dbPath.path,
            "select count(*) from session_usage where updated_at > \(cutoffMs);")
        return Int(rows.first?.first ?? "0") ?? 0
    }
}

// MARK: - DeepSeek（按量付费余额）

final class DeepSeekProvider: QuotaProvider {
    let id = "deepseek"
    let name = "DeepSeek"
    let accent = "indigo"

    static let defaultsKey = "deepseek_api_key"

    func fetch() -> QuotaItem {
        let key = (UserDefaults.standard.string(forKey: Self.defaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return .unavailable(id: id, name: name, reason: "右键 → 设置 DeepSeek Key")
        }

        guard let obj = HTTP.getJSONObject("https://api.deepseek.com/user/balance",
                                          headers: ["Authorization": "Bearer \(key)"]) else {
            return .unavailable(id: id, name: name, reason: "余额接口请求失败（检查 Key / 网络）")
        }

        let infos = obj["balance_infos"] as? [[String: Any]] ?? []
        guard let first = infos.first,
              let balance = Double((first["total_balance"] as? String) ?? "0") else {
            return .unavailable(id: id, name: name, reason: "返回格式异常")
        }
        let currency = (first["currency"] as? String) ?? "CNY"
        let symbol = currency.uppercased() == "CNY" ? "¥" : "$"

        // 余额是绝对值，没有"周期"。用一条低额度警示线来给进度条一个参考（剩余/50 元封顶）
        let referenceCeiling = 50.0
        let remaining = max(0, min(1, balance / referenceCeiling))
        let available = (obj["is_available"] as? Bool) ?? true

        return QuotaItem(
            id: id,
            name: name,
            primary: String(format: "%@ %.2f", symbol, balance),
            secondary: "账户余额" + (available ? "" : " · 不可用"),
            remaining: remaining,
            status: .live,
            badge: available ? nil : "不可用",
            accent: accent
        )
    }
}
