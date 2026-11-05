import Foundation

// 数据层自检入口：swiftc 编译后直接运行，打印每个 provider 的真实读取结果
let items = Collector.all()
for item in items {
    print("""
    [\(item.id)] \(item.name)  status=\(item.status.rawValue)  accent=\(item.accent)
      primary   : \(item.primary)
      secondary : \(item.secondary)
      remaining : \(item.remaining.map { String(format: "%.3f", $0) } ?? "nil")
      badge     : \(item.badge ?? "-")
    """)
}
