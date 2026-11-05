import AppKit

/// 离屏渲染：不依赖屏幕权限，把悬浮窗用真实数据画成 PNG，用于自检视觉效果
enum Snapshot {
    static func render(to path: String, compact: Bool = false) {
        let items = Collector.all()
        let w = HUDContentView.cardWidth
        let h = compact ? AppDelegate.collapsedHeight : HUDContentView.preferredHeight(for: items)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        container.appearance = NSAppearance(named: .vibrantDark)   // 系统语义色按深色解析
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor
        container.layer?.cornerRadius = HUDContentView.corner
        container.layer?.masksToBounds = true

        let hud = HUDContentView(frame: container.bounds)
        hud.compact = compact
        hud.update(items: items, updatedAt: Date())
        container.layer?.cornerRadius = compact ? 5 : HUDContentView.corner
        container.addSubview(hud)
        container.layoutSubtreeIfNeeded()

        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else {
            FileHandle.standardError.write(Data("snapshot: 无法创建位图\n".utf8))
            return
        }
        container.cacheDisplay(in: container.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot: PNG 编码失败\n".utf8))
            return
        }
        let url = URL(fileURLWithPath: path)
        do {
            try png.write(to: url)
            print("snapshot written: \(url.path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
        } catch {
            FileHandle.standardError.write(Data("snapshot: 写入失败 \(error)\n".utf8))
        }
    }
}
