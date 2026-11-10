import Foundation
import Vision
import CoreImage
import AppKit

// 用 Vision 的前景主体分割，把角色从背景里抠出来，输出带 alpha 的 PNG
// 用法: cutout <输入图> <输出png>

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("用法: cutout <输入> <输出>\n".utf8))
    exit(1)
}
let inPath = args[1]
let outPath = args[2]

guard let nsImage = NSImage(contentsOfFile: inPath),
      let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("无法读取图片\n".utf8))
    exit(1)
}

let request = VNGenerateForegroundInstanceMaskRequest()
let handler = VNImageRequestHandler(cgImage: cg, options: [:])
do {
    try handler.perform([request])
} catch {
    FileHandle.standardError.write(Data("分割失败: \(error)\n".utf8))
    exit(1)
}

guard let result = request.results?.first else {
    FileHandle.standardError.write(Data("没有检测到前景主体\n".utf8))
    exit(1)
}

do {
    let maskPixelBuffer = try result.generateScaledMaskForImage(
        forInstances: result.allInstances, from: handler)

    let ciInput = CIImage(cgImage: cg)
    let ciMask = CIImage(cvPixelBuffer: maskPixelBuffer)
    let extent = ciInput.extent

    // 用 mask 把主体外的区域变透明
    let clear = CIImage(color: CIColor.clear).cropped(to: extent)
    guard let blend = CIFilter(name: "CIBlendWithMask") else {
        FileHandle.standardError.write(Data("CIBlendWithMask 不可用\n".utf8))
        exit(1)
    }
    blend.setValue(ciInput, forKey: "inputImage")
    blend.setValue(clear, forKey: "inputBackgroundImage")
    blend.setValue(ciMask, forKey: "inputMaskImage")

    guard let output = blend.outputImage else {
        FileHandle.standardError.write(Data("合成失败\n".utf8))
        exit(1)
    }

    let context = CIContext()
    guard let outCG = context.createCGImage(output, from: extent) else {
        FileHandle.standardError.write(Data("渲染失败\n".utf8))
        exit(1)
    }

    let rep = NSBitmapImageRep(cgImage: outCG)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("编码失败\n".utf8))
        exit(1)
    }
    try png.write(to: URL(fileURLWithPath: outPath))

    print("已输出: \(outPath)")
} catch {
    FileHandle.standardError.write(Data("处理失败: \(error)\n".utf8))
    exit(1)
}
