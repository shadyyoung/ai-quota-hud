import AppKit
import CoreGraphics

/// 把用户选的照片处理成"趴在卡片上"的形象：
/// 1. 从图片边缘做洪水填充，去掉与边缘连通的浅色背景
/// 2. 迭代腐蚀吃掉贴边的白色描边
/// 3. 裁到内容包围盒，保持宽高比
enum CharacterProcessor {

    static func process(_ image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        var w = cg.width
        var h = cg.height

        // 太大先缩小，避免处理过慢
        let maxSide = 1200
        if max(w, h) > maxSide {
            let scale = CGFloat(maxSide) / CGFloat(max(w, h))
            w = Int(CGFloat(w) * scale)
            h = Int(CGFloat(h) * scale)
        }
        guard w > 8, h > 8 else { return nil }

        let bpr = w * 4
        var px = [UInt8](repeating: 0, count: h * bpr)
        guard let ctx = CGContext(data: &px, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // 估计背景色：四角平均
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = y * bpr + x * 4
            return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
        }
        let corners = [pixel(2, 2), pixel(w - 3, 2), pixel(2, h - 3), pixel(w - 3, h - 3)]
        let bgR = corners.map { $0.0 }.reduce(0, +) / 4
        let bgG = corners.map { $0.1 }.reduce(0, +) / 4
        let bgB = corners.map { $0.2 }.reduce(0, +) / 4
        let bgLum = (bgR + bgG + bgB) / 3

        // 只对浅色背景做抠图；背景本来就深的话保留原图
        let shouldCut = bgLum > 200

        func nearBackground(_ x: Int, _ y: Int) -> Bool {
            let (r, g, b) = pixel(x, y)
            let lum = (r + g + b) / 3
            let dr = abs(r - bgR), dg = abs(g - bgG), db = abs(b - bgB)
            return lum >= bgLum - 26 && dr + dg + db <= 78
        }

        var removed = [Bool](repeating: false, count: w * h)

        if shouldCut {
            var queue = [Int]()
            var head = 0
            func seed(_ x: Int, _ y: Int) {
                let p = y * w + x
                if !removed[p] && nearBackground(x, y) {
                    removed[p] = true
                    queue.append(p)
                }
            }
            for x in 0..<w { seed(x, 0); seed(x, h - 1) }
            for y in 0..<h { seed(0, y); seed(w - 1, y) }

            while head < queue.count {
                let p = queue[head]; head += 1
                let x = p % w, y = p / w
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                    if nx < 0 || nx >= w || ny < 0 || ny >= h { continue }
                    let np = ny * w + nx
                    if removed[np] { continue }
                    if nearBackground(nx, ny) {
                        removed[np] = true
                        queue.append(np)
                    }
                }
            }

            // 去白边：迭代腐蚀
            for _ in 0..<3 {
                var batch = [Int]()
                for p in 0..<(w * h) where !removed[p] {
                    let i = p * 4
                    let mn = min(Int(px[i]), min(Int(px[i + 1]), Int(px[i + 2])))
                    guard mn >= 218 else { continue }
                    let x = p % w, y = p / w
                    var nearHole = false
                    for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                        if nx < 0 || nx >= w || ny < 0 || ny >= h { continue }
                        if removed[ny * w + nx] { nearHole = true; break }
                    }
                    if nearHole { batch.append(p) }
                }
                if batch.isEmpty { break }
                for p in batch { removed[p] = true }
            }

            for p in 0..<(w * h) where removed[p] {
                px[p * 4 + 3] = 0
            }
        }

        // 裁到不透明内容的包围盒
        var minX = w, minY = h, maxX = 0, maxY = 0
        for y in 0..<h {
            for x in 0..<w {
                if px[y * bpr + x * 4 + 3] > 8 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard minX <= maxX, minY <= maxY else { return nil }

        let cropW = maxX - minX + 1
        let cropH = maxY - minY + 1
        let cropRect = CGRect(x: minX, y: minY, width: cropW, height: cropH)
        guard let fullImage = ctx.makeImage()?.cropping(to: cropRect) else { return nil }

        return NSImage(cgImage: fullImage, size: NSSize(width: cropW, height: cropH))
    }
}
