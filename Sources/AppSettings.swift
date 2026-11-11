import Foundation

/// 全局设置（UserDefaults 封装）
enum AppSettings {
    private static let d = UserDefaults.standard

    /// 刷新间隔（秒）
    static var refreshInterval: TimeInterval {
        get { let v = d.double(forKey: "refreshInterval"); return v > 0 ? v : 60 }
        set { d.set(newValue, forKey: "refreshInterval") }
    }

    /// 低额度告警阈值（0-1）
    static var lowThreshold: Double {
        get { let v = d.double(forKey: "lowThreshold"); return v > 0 ? v : 0.2 }
        set { d.set(newValue, forKey: "lowThreshold") }
    }

    /// 是否启用系统通知
    /// 固定间隔提醒（分钟）
    static var reminderMinutes: Int {
        get { let v = UserDefaults.standard.integer(forKey: "reminderMinutes"); return v > 0 ? v : 60 }
        set { UserDefaults.standard.set(newValue, forKey: "reminderMinutes") }
    }

    static var notifyEnabled: Bool {
        get { d.object(forKey: "notifyEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "notifyEnabled") }
    }

    /// 是否检查更新
    static var checkUpdates: Bool {
        get { d.object(forKey: "checkUpdates") as? Bool ?? true }
        set { d.set(newValue, forKey: "checkUpdates") }
    }

    /// 平时透明度
    static var idleAlpha: Double {
        get { let v = d.double(forKey: AppDelegate.idleAlphaKey); return v > 0 ? v : 0.18 }
        set { d.set(newValue, forKey: AppDelegate.idleAlphaKey) }
    }

    /// 用户自定义数据源配置文件
    static var providersConfigPath: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ai-quota-hud")
        return base.appendingPathComponent("providers.json")
    }

    /// 确保配置目录存在
    static func ensureConfigDir() {
        let dir = providersConfigPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}
