import Foundation
import AppKit

// 从图片四边做洪水填充，把与边缘连通的近白色像素变透明。
// 与背景不连通的白色（围裙、高光）会被保留。
// 用法: cutout-white <输入> <输出> [阈值]

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("用法: cutout-white <输入> <输出> [阈值]\n".utf8))
    exit(1)
}
let inPath = args[1]
let outPath = args[2]
let threshold = args.count >= 4 ? (Int(args[3]) ?? 238) : 238
let softRange = 26   // 边缘羽化宽度

guard let nsImage = NSImage(contentsOfFile: inPath),
      let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("无法读取图片\n".utf8))
    exit(1)
}

let w = cg.width
let h = cg.height
let bytesPerRow = w * 4
var pixels = [UInt8](repeating: 0, count: h * bytesPerRow)

guard let ctx = CGContext(data: &pixels, width: w, height: h,
                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write(Data("创建上下文失败\n".utf8))
    exit(1)
}
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

// 判断是否"接近白色"
func isWhite(_ i: Int) -> Bool {
    let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
    let mn = min(r, min(g, b)), mx = max(r, max(g, b))
    return mn >= threshold && (mx - mn) <= 14
}

var visited = [Bool](repeating: false, count: w * h)
var queue = [Int]()
var head = 0

// 从四边开始
for x in 0..<w {
    for y in [0, h - 1] {
        let p = y * w + x
        if !visited[p] && isWhite(p * 4) {
            visited[p] = true
            queue.append(p)
        }
    }
}
for y in 0..<h {
    for x in [0, w - 1] {
        let p = y * w + x
        if !visited[p] && isWhite(p * 4) {
            visited[p] = true
            queue.append(p)
        }
    }
}

// BFS 扩散
while head < queue.count {
    let p = queue[head]; head += 1
    let x = p % w, y = p / w
    let neighbors = [
        (x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)
    ]
    for (nx, ny) in neighbors {
        if nx < 0 || nx >= w || ny < 0 || ny >= h { continue }
        let np = ny * w + nx
        if visited[np] { continue }
        if isWhite(np * 4) {
            visited[np] = true
            queue.append(np)
        }
    }
}

// 背景像素 → 透明；边界像素 → 按亮度做羽化
var removed = 0
for p in 0..<(w * h) {
    let i = p * 4
    if visited[p] {
        pixels[i + 3] = 0
        removed += 1
    }
}

// 羽化：紧邻透明区的不透明像素，按白色程度降低 alpha
for p in 0..<(w * h) where !visited[p] {
    let i = p * 4
    let x = p % w, y = p / w
    var nearHole = false
    for (nx, ny) in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)] {
        if nx < 0 || nx >= w || ny < 0 || ny >= h { continue }
        if visited[ny * w + nx] { nearHole = true; break }
    }
    if nearHole {
        let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
        let mn = min(r, min(g, b))
        if mn > threshold - softRange {
            let t = Double(mn - (threshold - softRange)) / Double(softRange)
            let a = Double(pixels[i + 3]) * (1.0 - max(0, min(1, t)) * 0.9)
            pixels[i + 3] = UInt8(a)
        }
    }
}

// 去白边：从透明区向外迭代腐蚀，吃掉紧贴边缘的白色描边
var removedMap = visited
for _ in 0..<3 {
    var toRemove = [Int]()
    for p in 0..<(w * h) where !removedMap[p] {
        let i = p * 4
        let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
        let mn = min(r, min(g, b))
        guard mn >= 218 else { continue }          // 只吃浅色
        let x = p % w, y = p / w
        var nearHole = false
        for (nx, ny) in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)] {
            if nx < 0 || nx >= w || ny < 0 || ny >= h { continue }
            if removedMap[ny * w + nx] { nearHole = true; break }
        }
        if nearHole { toRemove.append(p) }
    }
    if toRemove.isEmpty { break }
    for p in toRemove {
        removedMap[p] = true
        pixels[p * 4 + 3] = 0
    }
    print("  腐蚀一轮，去掉 \(toRemove.count) 像素")
}

guard let outCG = ctx.makeImage() else {
    FileHandle.standardError.write(Data("生成图片失败\n".utf8))
    exit(1)
}
let rep = NSBitmapImageRep(cgImage: outCG)
guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("编码失败\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
print("已输出: \(outPath)  去除背景像素 \(removed)/\(w*h) (\(String(format: "%.1f", Double(removed)/Double(w*h)*100))%)")
