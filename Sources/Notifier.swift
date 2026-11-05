import AppKit
import UserNotifications

/// 低额度系统通知（同一 provider 每小时最多提醒一次）
enum Notifier {
    private static var lastNotified: [String: Date] = [:]
    private static var authorized = false

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            authorized = ok
        }
    }

    static func checkLowQuota(_ items: [QuotaItem]) {
        guard AppSettings.notifyEnabled else { return }
        let threshold = AppSettings.lowThreshold
        let now = Date()

        for item in items {
            guard let r = item.remaining,
                  r <= threshold,
                  item.status == .live || item.status == .local,
                  r > 0 else { continue }

            if let last = lastNotified[item.id], now.timeIntervalSince(last) < 3600 { continue }
            lastNotified[item.id] = now

            let content = UNMutableNotificationContent()
            content.title = "\(item.name) 额度偏低"
            content.body = "\(item.primary) · \(item.secondary)"
            content.sound = .default

            let req = UNNotificationRequest(identifier: "low-\(item.id)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req) { err in
                if let err { NSLog("AIQuotaHUD 通知失败: \(err.localizedDescription)") }
            }
        }
    }
}
