import AppKit

// MARK: - 配色（全部用系统语义色，自动跟随深浅色）

enum Palette {
    static func accent(_ name: String) -> NSColor {
        switch name {
        case "blue":   return .systemBlue
        case "purple": return .systemPurple
        case "teal":   return .systemTeal
        case "indigo": return .systemIndigo
        case "orange": return .systemOrange
        default:       return .systemGray
        }
    }

    static var textPrimary: NSColor { .labelColor }
    static var textSecondary: NSColor { .secondaryLabelColor }
    static var textTertiary: NSColor { .tertiaryLabelColor }
    static var track: NSColor { .quaternaryLabelColor }
    static var separator: NSColor { .separatorColor }
    static var warn: NSColor { .systemRed }
}

// MARK: - 主视图（纯自绘）

final class HUDContentView: NSView {
    var items: [QuotaItem] = []
    var updatedAt: Date = Date()
    var staleSeconds: TimeInterval = 0
    /// 收起态：只画几个小圆点
    var compact = false
    /// 形象图片（可为空，空则不占位）
    var avatarImage: NSImage?
    var onRightClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    static let cardWidth: CGFloat = 278
    /// 角色立绘区域高度（宽度按图片比例 675:330 推算）
    static let charHeight: CGFloat = 139
    static let pad: CGFloat = 16
    static let headerHeight: CGFloat = 44
    static let rowBar: CGFloat = 60
    static let rowPlain: CGFloat = 48
    /// Liquid Glass 的圆角比传统卡片更大
    static let avatarSize: CGFloat = 38
    static let corner: CGFloat = 20

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    static func rowHeight(for item: QuotaItem) -> CGFloat {
        item.remaining != nil ? rowBar : rowPlain
    }

    static func preferredHeight(for items: [QuotaItem]) -> CGFloat {
        let rows = items.reduce(0) { $0 + rowHeight(for: $1) }
        return charHeight + pad + headerHeight + rows + pad - 6
    }

    func update(items: [QuotaItem], updatedAt: Date) {
        self.items = items
        self.updatedAt = updatedAt
        self.staleSeconds = Date().timeIntervalSince(updatedAt)
        needsDisplay = true
    }

    // MARK: 交互

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
        else { super.mouseDown(with: event) }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if compact {
            // 收起态：角色仍然趴在上面，下面只是变成一条细线
            let cardRect = NSRect(x: 0, y: Self.charHeight,
                                  width: bounds.width,
                                  height: max(1, bounds.height - Self.charHeight))
            drawCharacter(in: NSRect(x: 0, y: 0, width: bounds.width, height: Self.charHeight))
            drawGlass(in: cardRect, corner: 5)
            drawCompactDots(baseY: Self.charHeight)
            return
        }

        // 上方：角色立绘（从卡片背后探出来）
        let charRect = NSRect(x: 0, y: 0, width: bounds.width, height: Self.charHeight)
        drawCharacter(in: charRect)

        // 下方：额度卡片
        let cardRect = NSRect(x: 0, y: Self.charHeight,
                              width: bounds.width,
                              height: bounds.height - Self.charHeight)
        drawGlass(in: cardRect, corner: Self.corner)

        drawHeader(baseY: Self.charHeight)
        var y = Self.charHeight + Self.pad + Self.headerHeight
        for item in items {
            let h = Self.rowHeight(for: item)
            drawRow(item, y: y, height: h)
            y += h
        }
        if items.isEmpty {
            drawText("正在读取…", font: NSFont.systemFont(ofSize: 11),
                     color: Palette.textTertiary,
                     at: NSPoint(x: Self.pad,
                                 y: Self.charHeight + Self.pad + Self.headerHeight + 6))
        }
    }

    /// 角色立绘：底部贴着卡片上沿，像是趴在卡片后面
    private func drawCharacter(in rect: NSRect) {
        guard let img = avatarImage else { return }
        let imgAspect = img.size.width / max(img.size.height, 1)
        var w = rect.width
        var h = w / imgAspect
        if h > rect.height {
            h = rect.height
            w = h * imgAspect
        }
        let x = rect.minX + (rect.width - w) / 2
        let y = rect.maxY - h
        let drawRect = NSRect(x: x, y: y, width: w, height: h)

        img.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0,
                 respectFlipped: true,
                 hints: [.interpolation: NSImageInterpolation.high])
    }

    /// Liquid Glass：玻璃本体底色 + 顶部冷光 → 中部透明 → 底部暗角，
    /// 一层渐变覆盖全高避免硬边；再叠内外描边与顶部折射亮边。
    private func drawGlass(in rect: NSRect, corner: CGFloat) {
        let r = rect
        guard r.width > 1, r.height > 1 else { return }
        let shape = NSBezierPath(roundedRect: r, xRadius: corner, yRadius: corner)

        // 玻璃本体：极淡的白，让毛玻璃看起来有"实体感"
        NSColor(white: 1, alpha: 0.022).setFill()
        shape.fill()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()

        if let g = NSGradient(colorsAndLocations:
            (NSColor(white: 1, alpha: 0.13), 0.00),
            (NSColor(white: 1, alpha: 0.05), 0.18),
            (NSColor(white: 1, alpha: 0.00), 0.42),
            (NSColor(white: 0, alpha: 0.00), 0.60),
            (NSColor(white: 0, alpha: 0.10), 1.00)
        ) {
            g.draw(in: r, angle: -90)
        }

        NSGraphicsContext.restoreGraphicsState()

        // 内描边（玻璃内壁的高光）
        NSColor(white: 1, alpha: 0.10).setStroke()
        let inner = NSBezierPath(roundedRect: r.insetBy(dx: 1.5, dy: 1.5),
                                 xRadius: max(1, corner - 1.5), yRadius: max(1, corner - 1.5))
        inner.lineWidth = 1
        inner.stroke()

        // 外描边
        NSColor(white: 1, alpha: 0.20).setStroke()
        let outer = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: corner, yRadius: corner)
        outer.lineWidth = 1
        outer.stroke()

        // 顶部折射亮边
        if r.height > 14 {
            let inset = corner * 0.65
            let line = NSRect(x: inset, y: 1, width: r.width - inset * 2, height: 0.9)
            NSColor(white: 1, alpha: 0.46).setFill()
            NSBezierPath(roundedRect: line, xRadius: 0.45, yRadius: 0.45).fill()
        }
    }

    /// 收起态：一排彩色小圆点，一眼看到各服务状态
    private func drawCompactDots(baseY: CGFloat = 0) {
        let barH = max(1, bounds.height - baseY)
        guard !items.isEmpty else {
            Palette.textTertiary.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - 2, y: baseY + (barH - 4) / 2,
                                        width: 4, height: 4)).fill()
            return
        }
        let dot: CGFloat = 4
        let gap: CGFloat = 7
        let total = CGFloat(items.count) * dot + CGFloat(items.count - 1) * gap
        var x = (bounds.width - total) / 2
        let y = baseY + (barH - dot) / 2
        for item in items {
            let color = item.status == .unavailable ? Palette.textTertiary : Palette.accent(item.accent)
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: dot, height: dot)).fill()
            x += dot + gap
        }
    }

    private func drawHeader(baseY: CGFloat) {
        drawText("AI 额度", font: .systemFont(ofSize: 11, weight: .semibold),
                 color: Palette.textSecondary,
                 at: NSPoint(x: Self.pad, y: baseY + Self.pad + 3))

        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
        var right = fmt.string(from: updatedAt)
        if staleSeconds > 180 { right = "\(Int(staleSeconds / 60)) 分钟前" }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let size = (right as NSString).size(withAttributes: [.font: font])
        drawText(right, font: font, color: Palette.textSecondary.withAlphaComponent(0.7),
                 at: NSPoint(x: bounds.width - Self.pad - size.width, y: baseY + Self.pad + 4))
    }

    private func drawRow(_ item: QuotaItem, y: CGFloat, height: CGFloat) {
        let left = Self.pad
        let right = bounds.width - Self.pad
        var cursorY = y + 4

        // 图标
        let symbolName: String
        switch item.id {
        case "codex":     symbolName = "chevron.left.forwardslash.chevron.right"
        case "cursor":    symbolName = "cursorarrow.rays"
        case "workbuddy": symbolName = "sparkles"
        default:          symbolName = "circle.fill"
        }
        let iconColor = item.status == .unavailable ? Palette.textTertiary : Palette.accent(item.accent)
        drawSymbol(symbolName, color: iconColor,
                   at: NSRect(x: left, y: cursorY + 1, width: 15, height: 15), size: 12)

        // 服务名
        drawText(item.name,
                 font: .systemFont(ofSize: 12.5, weight: .medium),
                 color: item.status == .unavailable ? Palette.textSecondary : Palette.textPrimary,
                 at: NSPoint(x: left + 21, y: cursorY))

        // 主数值（右对齐；「剩余」小灰字 + 数字大号等宽）
        let valueColor: NSColor = {
            if item.status == .unavailable { return Palette.textTertiary }
            if let r = item.remaining {
                if r <= 0.12 { return Palette.warn }
                if r <= 0.30 { return .systemOrange }
            }
            return Palette.textPrimary
        }()
        let value = NSMutableAttributedString()
        let numFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        if item.primary.hasPrefix("剩余 ") {
            value.append(NSAttributedString(string: "剩余 ", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: Palette.textSecondary
            ]))
            value.append(NSAttributedString(string: String(item.primary.dropFirst(3)), attributes: [
                .font: numFont,
                .foregroundColor: valueColor
            ]))
        } else {
            value.append(NSAttributedString(string: item.primary, attributes: [
                .font: numFont,
                .foregroundColor: valueColor
            ]))
        }
        let vsize = value.size()
        value.draw(at: NSPoint(x: right - vsize.width, y: cursorY - 1))

        cursorY += 21

        // 进度条：3pt 圆角，与文字左对齐
        if let remaining = item.remaining, item.status != .unavailable {
            let barX = left + 21
            let barRect = NSRect(x: barX, y: cursorY + 1, width: right - barX, height: 3)
            Palette.track.setFill()
            NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5).fill()

            let filled = max(0.01, min(1, remaining))
            let w = max(3, barRect.width * CGFloat(filled))
            let color: NSColor = {
                if remaining <= 0.12 { return Palette.warn }
                if remaining <= 0.30 { return .systemOrange }
                return Palette.accent(item.accent)
            }()
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: barX, y: cursorY + 1, width: w, height: 3),
                         xRadius: 1.5, yRadius: 1.5).fill()
            cursorY += 11
        }

        // 副标题
        var sub = item.secondary
        if let badge = item.badge { sub = "\(badge) · \(sub)" }
        drawText(sub, font: .systemFont(ofSize: 10, weight: .regular),
                 color: Palette.textSecondary.withAlphaComponent(0.78),
                 at: NSPoint(x: left + 21, y: cursorY))
    }

    /// 圆形裁剪绘制头像
    private func drawAvatar(_ img: NSImage, in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: rect).addClip()
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0,
                 respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()

        NSColor(white: 1, alpha: 0.24).setStroke()
        let border = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
        border.lineWidth = 1.5
        border.stroke()
    }

    // MARK: 绘制工具

    private func drawSymbol(_ name: String, color: NSColor, at rect: NSRect, size: CGFloat) {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return }
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0,
                 respectFlipped: true, hints: nil)
    }

    private func drawText(_ s: String, font: NSFont, color: NSColor, at point: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .kern: -0.1
        ]
        (s as NSString).draw(at: point, withAttributes: attrs)
    }
}
