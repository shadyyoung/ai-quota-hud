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

            // 去白边：迭代腐蚀，只吃低饱和度的白，保住浅蓝发丝
            for _ in 0..<30 {
                var batch = [Int]()
                for p in 0..<(w * h) where !removed[p] {
                    let i = p * 4
                    let mn = min(Int(px[i]), min(Int(px[i + 1]), Int(px[i + 2])))
                    let mx = max(Int(px[i]), max(Int(px[i + 1]), Int(px[i + 2])))
                    guard mn >= 222, mx - mn <= 34 else { continue }
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

            // 清理发丝缝隙里的碎白块：小面积 + 不在中心
            do {
                var seen = [Bool](repeating: false, count: w * h)
                let cx = w / 2, cy = h / 2
                let rx = Int(Double(w) * 0.28), ry = Int(Double(h) * 0.30)
                for start in 0..<(w * h) where !seen[start] && !removed[start] {
                    let i = start * 4
                    let r0 = Int(px[i]), g0 = Int(px[i + 1]), b0 = Int(px[i + 2])
                    let mn0 = min(r0, min(g0, b0)), mx0 = max(r0, max(g0, b0))
                    guard mx0 - mn0 <= 30, mn0 >= 200, px[i + 3] > 8 else { continue }

                    var comp = [Int]()
                    var queue = [start]
                    var head = 0
                    seen[start] = true
                    var sumX = 0, sumY = 0
                    while head < queue.count {
                        let q = queue[head]; head += 1
                        comp.append(q)
                        let x = q % w, y = q / w
                        sumX += x; sumY += y
                        for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                            if nx < 0 || nx >= w || ny < 0 || ny >= h { continue }
                            let np = ny * w + nx
                            if seen[np] || removed[np] { continue }
                            let ni = np * 4
                            if px[ni + 3] <= 8 { continue }
                            let nr = Int(px[ni]), ng = Int(px[ni + 1]), nb = Int(px[ni + 2])
                            let nmn = min(nr, min(ng, nb)), nmx = max(nr, max(ng, nb))
                            guard nmx - nmn <= 30, nmn >= 200 else { continue }
                            seen[np] = true
                            queue.append(np)
                        }
                    }
                    let area = comp.count
                    guard area <= 400 else { continue }
                    let mxp = sumX / area, myp = sumY / area
                    if abs(mxp - cx) < rx && abs(myp - cy) < ry { continue }   // 中心不动（眼睛高光）
                    for q in comp { removed[q] = true }
                }
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
