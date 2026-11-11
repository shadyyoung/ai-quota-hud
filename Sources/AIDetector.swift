import AppKit

/// 识别当前前台是哪个 AI 应用，把它映射到我们的 provider id。
/// 用 bundle id 精确匹配优先，名字关键词兜底。
enum AIDetector {

    /// bundle id → provider id
    private static let bundleMap: [String: String] = [
        "com.openai.codex": "codex",
        "com.openai.chat": "codex",
        "com.todesktop.230313mzl4w4u92": "cursor",      // Cursor
        "com.anthropic.claudefordesktop": "claude",
        "com.openai.chatgpt": "chatgpt",
        "com.google.gemini": "gemini",
        "ai.perplexity.mac": "perplexity",
    ]

    /// 名字关键词 → provider id（兜底，bundle id 未知时用）
    private static let nameKeywords: [(String, String)] = [
        ("codex", "codex"),
        ("chatgpt", "codex"),
        ("cursor", "cursor"),
        ("claude", "claude"),
        ("gemini", "gemini"),
        ("perplexity", "perplexity"),
    ]

    /// 当前前台应用对应的 provider id，没有就 nil
    static func currentProviderId() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        if let bid = app.bundleIdentifier, let pid = bundleMap[bid] { return pid }
        let name = (app.localizedName ?? "").lowercased()
        for (kw, pid) in nameKeywords where name.contains(kw) {
            return pid
        }
        return nil
    }

    /// 当前前台应用名（用于气泡里显示"你在用 X"）
    static func currentAppName() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let name = app.localizedName ?? ""
        guard !name.isEmpty else { return nil }
        let lower = name.lowercased()
        for (kw, _) in nameKeywords where lower.contains(kw) {
            return name
        }
        return nil
    }
}
