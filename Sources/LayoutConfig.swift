import Foundation

/// 布局参数。
///
/// 默认值对应 GitHub 上的横版卡片（278 × 139）。
/// 用户可以在 `~/.config/ai-quota-hud/layout.json` 里覆盖，
/// 这样个人化的尺寸（比如竖版真人立绘）不会进 git 仓库。
///
/// 示例：
/// ```json
/// { "cardWidth": 240, "charHeight": 370 }
/// ```
enum LayoutConfig {

    private struct Stored: Codable {
        var cardWidth: Double?
        var charHeight: Double?
    }

    /// 默认（开源版）尺寸：横版卡片
    private static let defaultWidth: CGFloat = 278
    private static let defaultHeight: CGFloat = 139

    private static var stored: Stored? {
        let path = ("~/.config/ai-quota-hud/layout.json" as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    /// 窗口宽度（也是角色绘制区宽度）
    static var cardWidth: CGFloat {
        guard let v = stored?.cardWidth, v >= 80 else { return defaultWidth }
        return CGFloat(v)
    }

    /// 角色区高度
    static var charHeight: CGFloat {
        guard let v = stored?.charHeight, v >= 60 else { return defaultHeight }
        return CGFloat(v)
    }

    /// 当前是否在用自定义布局（用于日志/调试）
    static var isCustomized: Bool {
        stored != nil
    }
}
