import Foundation
import Network

/// 代理配置：只作用于本 app 的 URLSession，绝不修改系统代理设置，不影响其他应用。
enum ProxyConfig {
    struct Proxy: Equatable {
        var host: String
        var port: Int
        var isSOCKS: Bool

        var display: String { "\(isSOCKS ? "socks5" : "http")://\(host):\(port)" }

        var dict: [AnyHashable: Any] {
            if isSOCKS {
                return [
                    kCFNetworkProxiesSOCKSEnable as String: 1,
                    kCFNetworkProxiesSOCKSProxy as String: host,
                    kCFNetworkProxiesSOCKSPort as String: port
                ]
            }
            return [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: host,
                kCFNetworkProxiesHTTPSPort as String: port
            ]
        }
    }

    static let defaultsKey = "proxy.url"

    /// 探测结果的进程内缓存
    private static var detectedCache: Proxy?
    private static var didDetect = false

    /// 用户手动配置的代理（按字符串解析）
    static var configured: Proxy? {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return parse(raw)
    }

    /// 实际生效的代理：优先用户配置，其次自动探测（只探测一次）
    static var active: Proxy? {
        if let c = configured { return c }
        if didDetect { return detectedCache }
        didDetect = true
        detectedCache = detect()
        return detectedCache
    }

    static func parse(_ raw: String) -> Proxy? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var socks = false
        if s.hasPrefix("socks5://") { socks = true; s = String(s.dropFirst(9)) }
        else if s.hasPrefix("socks5h://") { socks = true; s = String(s.dropFirst(10)) }
        else if s.hasPrefix("http://") { s = String(s.dropFirst(7)) }
        else if s.hasPrefix("https://") { s = String(s.dropFirst(8)) }
        if s.hasSuffix("/") { s = String(s.dropLast()) }
        let parts = s.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]), port > 0, port < 65536 else { return nil }
        return Proxy(host: String(parts[0]), port: port, isSOCKS: socks)
    }

    /// 常见本地代理端口，按可能性排序
    private static let candidates: [(port: Int, socks: Bool)] = [
        (7890, false), (7891, true), (1087, false), (1080, true),
        (6152, false), (8080, false), (8888, false), (10808, true)
    ]

    /// 探测本机可用的代理端口（只做本机 TCP 连接测试，不发外网请求）
    static func detect() -> Proxy? {
        guard let p = scanPorts() else { return nil }
        return p
    }

    private static func scanPorts() -> Proxy? {
        let lock = NSLock()
        var found: Proxy?
        let group = DispatchGroup()

        for c in candidates {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                let open = portOpen(host: "127.0.0.1", port: UInt16(c.port), timeout: 0.35)
                guard open else { return }
                lock.lock()
                if found == nil { found = Proxy(host: "127.0.0.1", port: c.port, isSOCKS: c.socks) }
                lock.unlock()
            }
        }
        _ = group.wait(timeout: .now() + 1.5)
        return found
    }

    private static func portOpen(host: String, port: UInt16, timeout: TimeInterval) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        let once = NSLock()
        var signalled = false

        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port) ?? 0,
                                using: .tcp)
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                once.lock(); if !signalled { signalled = true; ok = true; sem.signal() }; once.unlock()
            case .failed, .cancelled:
                once.lock(); if !signalled { signalled = true; sem.signal() }; once.unlock()
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .utility))
        _ = sem.wait(timeout: .now() + timeout)
        conn.cancel()
        return ok
    }
}
