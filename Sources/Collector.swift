import Foundation

/// 汇总所有数据源，并把手动校准值叠加到真实结果上
struct Collector {
    static func providers() -> [QuotaProvider] {
        // DeepSeek 客户端免费不限量，没有"剩余额度"可监控，所以不列出一栏。
        // 如果以后要用 API 余额，把 DeepSeekProvider() 加回来即可（代码仍在 Providers.swift）。
        var list: [QuotaProvider] = [CodexProvider(), CursorProvider(), WorkBuddyProvider()]
        // 用户在 ~/.config/ai-quota-hud/providers.json 里自定义的数据源
        list.append(contentsOf: JsonProviderLoader.loadAll())
        return list
    }

    static func all() -> [QuotaItem] {
        providers().map { provider in
            var item = provider.fetch()
            // WorkBuddy 的额度单位是积分，不是百分比：
            // 一旦设了积分锚点，就完全以锚点推算为准，不再叠加百分比校准
            if provider.id == "workbuddy", WBAnchor.load() != nil {
                return item
            }
            // 手动校准优先：只有当用户明确设置过且周期未结束时才覆盖
            if let m = ManualCalibration.load(provider.id), !m.isExpired {
                item.remaining = m.remaining
                item.primary = "剩余 " + QuotaUtil.percentText(m.remaining)
                item.secondary = m.label + " · " + QuotaUtil.resetDescription(m.expiresAt)
                item.status = .manual
                item.badge = "手动"
            }
            return item
        }
    }

    /// 供菜单使用：所有数据源（用于手动校准选择）
    static func providerList() -> [(id: String, name: String)] {
        providers().map { ($0.id, $0.name) }
    }
}
