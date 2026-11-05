import AppKit

let app = NSApplication.shared

// 离屏渲染模式：./AIQuotaHUD --snapshot /path/to/preview.png
if CommandLine.arguments.contains("--snapshot") {
    app.setActivationPolicy(.prohibited)
    let idx = CommandLine.arguments.firstIndex(of: "--snapshot")!
    let path = CommandLine.arguments.count > idx + 1
        ? CommandLine.arguments[idx + 1]
        : "./preview.png"
    Snapshot.render(to: path, compact: CommandLine.arguments.contains("--compact"))
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 不出现在 Dock，只做悬浮窗
app.run()
