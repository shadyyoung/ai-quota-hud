import AppKit

/// 设置窗口：透明度、刷新频率、告警阈值、代理、开机自启
final class SettingsWindowController: NSWindowController {
    private var alphaSlider: NSSlider!
    private var thresholdSlider: NSSlider!
    private var intervalPopup: NSPopUpButton!
    private var proxyField: NSTextField!
    private var notifyCheck: NSButton!
    private var updateCheck: NSButton!
    private var loginCheck: NSButton!
    private var onChange: (() -> Void)?

    private let intervals: [TimeInterval] = [30, 60, 120, 300]

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 430),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "AI 额度 · 设置"
        w.isReleasedWhenClosed = false
        w.center()
        super.init(window: w)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: UI

    private func buildUI() {
        guard let window, let cv = window.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            stack.topAnchor.constraint(equalTo: cv.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: cv.bottomAnchor)
        ])

        // 平时透明度
        alphaSlider = NSSlider(value: AppSettings.idleAlpha, minValue: 0.05, maxValue: 0.5,
                               target: self, action: #selector(settingsChanged))
        alphaSlider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        stack.addArrangedSubview(row("平时透明度", alphaSlider))

        // 刷新间隔
        intervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for v in intervals { intervalPopup.addItem(withTitle: "\(Int(v)) 秒") }
        let idx = intervals.firstIndex(of: AppSettings.refreshInterval) ?? 1
        intervalPopup.selectItem(at: idx)
        intervalPopup.target = self
        intervalPopup.action = #selector(settingsChanged)
        stack.addArrangedSubview(row("刷新间隔", intervalPopup))

        // 低额度阈值
        thresholdSlider = NSSlider(value: AppSettings.lowThreshold, minValue: 0.05, maxValue: 0.5,
                                   target: self, action: #selector(settingsChanged))
        thresholdSlider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        stack.addArrangedSubview(row("低额度告警阈值", thresholdSlider))

        // 代理
        proxyField = NSTextField(string: UserDefaults.standard.string(forKey: ProxyConfig.defaultsKey) ?? "")
        proxyField.placeholderString = "http://127.0.0.1:7890（留空自动检测）"
        proxyField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        proxyField.target = self
        proxyField.action = #selector(settingsChanged)
        stack.addArrangedSubview(row("代理", proxyField))

        // 开关
        notifyCheck = checkbox("低额度时发系统通知", AppSettings.notifyEnabled)
        updateCheck = checkbox("自动检查更新", AppSettings.checkUpdates)
        loginCheck = checkbox("开机自动启动", fileExists(loginPlist()))
        stack.addArrangedSubview(notifyCheck)
        stack.addArrangedSubview(updateCheck)
        stack.addArrangedSubview(loginCheck)

        stack.addArrangedSubview(separator())

        // 按钮
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.addArrangedSubview(button("编辑数据源配置", #selector(openConfig)))
        buttons.addArrangedSubview(button("打开配置目录", #selector(openConfigDir)))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
        buttons.addArrangedSubview(spacer)
        buttons.addArrangedSubview(button("完成", #selector(closeWindow)))
        stack.addArrangedSubview(buttons)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
    }

    private func row(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let s = NSStackView(views: [label, control])
        s.orientation = .horizontal
        s.spacing = 10
        s.alignment = .centerY
        return s
    }

    private func checkbox(_ title: String, _ on: Bool) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(settingsChanged))
        b.state = on ? .on : .off
        b.font = .systemFont(ofSize: 12)
        return b
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.font = .systemFont(ofSize: 12)
        return b
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 420).isActive = true
        return box
    }

    // MARK: 动作

    @objc private func settingsChanged() {
        AppSettings.idleAlpha = alphaSlider.doubleValue
        AppSettings.lowThreshold = thresholdSlider.doubleValue
        AppSettings.refreshInterval = intervals[max(0, intervalPopup.indexOfSelectedItem)]
        AppSettings.notifyEnabled = notifyCheck.state == .on
        AppSettings.checkUpdates = updateCheck.state == .on

        let proxy = proxyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if proxy.isEmpty {
            UserDefaults.standard.removeObject(forKey: ProxyConfig.defaultsKey)
        } else {
            UserDefaults.standard.set(proxy, forKey: ProxyConfig.defaultsKey)
        }

        setLoginItem(loginCheck.state == .on)
        onChange?()
    }

    @objc private func openConfig() {
        JsonProviderLoader.writeExampleIfNeeded()
        NSWorkspace.shared.open(AppSettings.providersConfigPath)
    }

    @objc private func openConfigDir() {
        AppSettings.ensureConfigDir()
        NSWorkspace.shared.selectFile(nil,
            inFileViewerRootedAtPath: AppSettings.providersConfigPath.deletingLastPathComponent().path)
    }

    @objc private func closeWindow() {
        window?.close()
    }

    // MARK: 开机自启

    private func loginPlist() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.kai.aiquota.plist")
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func setLoginItem(_ on: Bool) {
        let plist = loginPlist()
        if on == fileExists(plist) { return }
        if on {
            let exe = Bundle.main.executablePath ?? ""
            if exe.isEmpty || exe.contains("/build/") {
                // 从 build 目录跑时不写自启，避免重启后路径失效
                return
            }
            let content = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key><string>com.kai.aiquota</string>
                <key>ProgramArguments</key>
                <array><string>\(exe)</string></array>
                <key>RunAtLoad</key><true/>
                <key>ProcessType</key><string>Interactive</string>
            </dict>
            </plist>
            """
            try? FileManager.default.createDirectory(at: plist.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? content.write(to: plist, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: plist)
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
