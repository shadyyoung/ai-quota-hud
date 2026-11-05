import Foundation

/// 从 GitHub Releases 检查新版本
enum Updater {
    /// 发布时替换成实际的 GitHub 仓库
    static let repo = "shadyyoung/ai-quota-hud"

    static var latestTag: String? {
        get { UserDefaults.standard.string(forKey: "update.latestTag") }
        set { UserDefaults.standard.set(newValue, forKey: "update.latestTag") }
    }

    static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    /// 后台检查；有新版返回 true
    static func check(completion: @escaping (Bool, String?) -> Void) {
        guard AppSettings.checkUpdates, !repo.hasPrefix("OWNER") else {
            completion(false, nil); return
        }
        let url = "https://api.github.com/repos/\(repo)/releases/latest"
        guard let obj = HTTP.getJSONObject(url, headers: ["Accept": "application/vnd.github+json"],
                                           timeout: 10, viaProxy: true),
              let tag = obj["tag_name"] as? String else {
            completion(false, nil); return
        }
        let clean = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        latestTag = tag
        let newer = compareVersion(clean, currentVersion) > 0
        completion(newer, tag)
    }

    /// 语义化版本比较
    static func compareVersion(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }

    static var updateURL: String { "https://github.com/\(repo)/releases/latest" }
}
