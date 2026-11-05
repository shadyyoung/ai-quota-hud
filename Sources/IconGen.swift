import AppKit
import CoreGraphics

// 生成 App 图标：深色玻璃底 + 环形额度表盘 + 三个服务节点
// 用法：IconGen <输出目录>

let OUT = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./AppIcon.iconset"

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

let blue   = rgb(0.25, 0.55, 1.00)
let purple = rgb(0.58, 0.45, 1.00)
let teal   = rgb(0.22, 0.85, 0.78)

/// 风格：funnel（漏斗汇聚） / bars（一叠额度条）
let STYLE = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "bars"

func drawBackground(in ctx: CGContext, size S: CGFloat) -> CGRect {
    let margin = S * 0.0975
    let rect = CGRect(x: margin, y: margin, width: S - margin * 2, height: S - margin * 2)
    let radius = rect.width * 0.2237
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        rgb(0.13, 0.15, 0.23), rgb(0.07, 0.08, 0.14), rgb(0.04, 0.04, 0.08)
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg,
        start: CGPoint(x: rect.midX, y: rect.maxY),
        end: CGPoint(x: rect.midX, y: rect.minY), options: [])

    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        rgb(1, 1, 1, 0.15), rgb(1, 1, 1, 0.0)
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(glow,
        start: CGPoint(x: rect.midX, y: rect.maxY),
        end: CGPoint(x: rect.midX, y: rect.midY), options: [])
    ctx.restoreGState()

    ctx.addPath(squircle)
    ctx.setStrokeColor(rgb(1, 1, 1, 0.14))
    ctx.setLineWidth(max(1, S * 0.0022))
    ctx.strokePath()
    return rect
}

/// 风格 A：一叠额度条
func drawBars(in ctx: CGContext, size S: CGFloat, rect: CGRect) {
    let barW = rect.width * 0.60
    let barH = rect.width * 0.088
    let gap  = rect.width * 0.078
    let totalH = barH * 3 + gap * 2
    let x0 = S / 2 - barW / 2
    var y = S / 2 + totalH / 2 - barH

    let rows: [(fill: CGFloat, from: CGColor, to: CGColor)] = [
        (0.94, blue,   purple),
        (0.68, purple, teal),
        (0.42, teal,   rgb(0.40, 0.95, 0.62))
    ]
    let barRadius = barH / 2
    for row in rows {
        ctx.addPath(CGPath(roundedRect: CGRect(x: x0, y: y, width: barW, height: barH),
                           cornerWidth: barRadius, cornerHeight: barRadius, transform: nil))
        ctx.setFillColor(rgb(1, 1, 1, 0.085))
        ctx.fillPath()

        let fw = max(barH, barW * row.fill)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: CGRect(x: x0, y: y, width: fw, height: barH),
                           cornerWidth: barRadius, cornerHeight: barRadius, transform: nil))
        ctx.clip()
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [row.from, row.to] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: x0, y: y),
                               end: CGPoint(x: x0 + fw, y: y), options: [])
        let sh = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            rgb(1, 1, 1, 0.22), rgb(1, 1, 1, 0.0)
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sh,
            start: CGPoint(x: x0, y: y + barH),
            end: CGPoint(x: x0, y: y + barH * 0.35), options: [])
        ctx.restoreGState()
        y -= (barH + gap)
    }
}

/// 风格 B：漏斗，多个源汇入一个聚合点
func drawFunnel(in ctx: CGContext, size S: CGFloat, rect: CGRect) {
    let cx = S / 2

    let funnel = CGMutablePath()
    funnel.move(to: CGPoint(x: S * 0.262, y: S * 0.688))
    funnel.addLine(to: CGPoint(x: S * 0.738, y: S * 0.688))
    funnel.addLine(to: CGPoint(x: S * 0.541, y: S * 0.360))
    funnel.addLine(to: CGPoint(x: S * 0.459, y: S * 0.360))
    funnel.closeSubpath()
    ctx.addPath(funnel)
    ctx.setFillColor(rgb(1, 1, 1, 0.035))
    ctx.fillPath()
    ctx.addPath(funnel)
    ctx.setStrokeColor(rgb(1, 1, 1, 0.17))
    ctx.setLineWidth(S * 0.007)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    let converge = CGPoint(x: cx, y: S * 0.318)
    let streams: [(from: CGPoint, c1: CGPoint, c2: CGPoint, color: CGColor)] = [
        (CGPoint(x: S * 0.302, y: S * 0.664),
         CGPoint(x: S * 0.360, y: S * 0.542),
         CGPoint(x: S * 0.440, y: S * 0.410), blue),
        (CGPoint(x: S * 0.500, y: S * 0.706),
         CGPoint(x: S * 0.500, y: S * 0.570),
         CGPoint(x: S * 0.500, y: S * 0.430), purple),
        (CGPoint(x: S * 0.698, y: S * 0.664),
         CGPoint(x: S * 0.640, y: S * 0.542),
         CGPoint(x: S * 0.560, y: S * 0.410), teal)
    ]
    for st in streams {
        let path = CGMutablePath()
        path.move(to: st.from)
        path.addCurve(to: converge, control1: st.c1, control2: st.c2)
        ctx.addPath(path)
        ctx.setStrokeColor(st.color.copy(alpha: 0.28)!)
        ctx.setLineWidth(S * 0.052)
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setStrokeColor(st.color)
        ctx.setLineWidth(S * 0.026)
        ctx.setLineCap(.round)
        ctx.strokePath()
    }
    for st in streams {
        ctx.setFillColor(st.color)
        ctx.fillEllipse(in: CGRect(x: st.from.x - S * 0.020, y: st.from.y - S * 0.020,
                                   width: S * 0.040, height: S * 0.040))
    }

    let halo = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        rgb(0.75, 0.90, 1.0, 0.45), rgb(0.75, 0.90, 1.0, 0.0)
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(halo, startCenter: converge, startRadius: 0,
                           endCenter: converge, endRadius: S * 0.095, options: [])

    let dotR = S * 0.031
    let dotRect = CGRect(x: converge.x - dotR, y: converge.y - dotR,
                         width: dotR * 2, height: dotR * 2)
    ctx.setFillColor(rgb(0.07, 0.08, 0.13, 0.85))
    ctx.fillEllipse(in: dotRect.insetBy(dx: -S * 0.006, dy: -S * 0.006))
    ctx.setFillColor(rgb(1, 1, 1, 0.96))
    ctx.fillEllipse(in: dotRect)
}

func drawIcon(in ctx: CGContext, size S: CGFloat) {
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    let rect = drawBackground(in: ctx, size: S)
    if STYLE == "bars" { drawBars(in: ctx, size: S, rect: rect) }
    else { drawFunnel(in: ctx, size: S, rect: rect) }
}

func render(size: CGFloat, to path: String) {
    let px = Int(size)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return }
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return }
    drawIcon(in: ctx, size: size)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
    print("  ✓ \(px)px")
}

let fm = FileManager.default
try? fm.createDirectory(atPath: OUT, withIntermediateDirectories: true)

let variants: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]
for (size, name) in variants {
    render(size: CGFloat(size), to: OUT + "/" + name)
}
print("iconset 生成完毕：\(OUT)")
