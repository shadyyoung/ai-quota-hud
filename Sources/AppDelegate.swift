import AppKit
import Carbon.HIToolbox

final class HUDWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 平时透明度：可在右键菜单里调，默认 18%
    static let idleAlphaKey = "hud.idleAlpha"
    static let idleAlphaOptions: [Double] = [0.08, 0.12, 0.18, 0.25, 0.32, 0.45]

    static var idleAlpha: CGFloat {
        let v = UserDefaults.standard.double(forKey: idleAlphaKey)
        return v > 0 ? CGFloat(v) : 0.18
    }
    static let hoverAlpha: CGFloat = 1.0

    /// 收起时只剩一条 10pt 高的细条
    static var collapsedHeight: CGFloat { HUDContentView.charHeight }

    private var window: HUDWindow!
    private var hud: HUDContentView!
    private var effectView: NSVisualEffectView!
    private var timer: Timer?
    private var hoverTimer: Timer?
    private var pointerInside = true      // 启动时先展开
    private var expanded = true
    private var trackingEnabled = false
    private var isMenuOpen = false
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var flashTimer: Timer?
    private let queue = DispatchQueue(label: "com.kai.aiquota.refresh", qos: .utility)
    private var refreshing = false
    private let frameKey = "hud.frame"
    private var lastItems: [QuotaItem] = []
    private var aiDetectTimer: Timer?
    private var wanderTimer: Timer?
    private var wanderTween: Timer?   // 逐帧移动用的定时器
    private var animTimer: Timer?     // 呼吸动画
    private var animPhase: CGFloat = 0
    private var reminderTimer: Timer?
    private var taskWatcher: CodexTaskWatcher?
    private var lastFixedReminder = Date()
    private var firedThresholds = Set<String>()
    private var currentAvatarImage: NSImage?
    private var currentAvatarPath: String?

    // MARK: 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadAvatar()          // 必须在建窗口之前，否则形象还是 nil
        buildWindow()
        scheduleTimer()
        detectProxyIfNeeded()
        registerHotKey()
        JsonProviderLoader.writeExampleIfNeeded()
        Notifier.requestAuthorization()
        checkForUpdates(silent: true)
        refresh(force: true)
        startAIWatcher()
        startWandering()
        startReminders()
        startCodexWatcher()
        startBreathing()

        // 调试：把窗口实际内容渲染成图片（用于验证布局，不依赖屏幕录制权限）
        if let idx = CommandLine.arguments.firstIndex(of: "--dump-window"),
           idx + 1 < CommandLine.arguments.count {
            let outPath = CommandLine.arguments[idx + 1]
            let wantCompact = CommandLine.arguments.contains("--compact-dump")
            self.trackingEnabled = false     // dump 时别让鼠标追踪改状态
            DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) { [weak self] in
                guard let self, let win = self.window else { return }
                if wantCompact {
                    self.hud.compact = true
                    self.effectView?.isHidden = true
                    self.resize(to: Self.collapsedHeight)
                } else {
                    self.hud.compact = false
                    self.effectView?.isHidden = false
                    self.resize(to: max(60, HUDContentView.preferredHeight(for: self.lastItems)))
                }
                win.displayIfNeeded()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 9.5) { [weak self] in
                guard let win = self?.window, let view = win.contentView else {
                    print("没有窗口"); exit(1)
                }
                win.displayIfNeeded()
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    print("无法创建位图"); exit(1)
                }
                view.cacheDisplay(in: view.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: outPath))
                    print("窗口已渲染: \(outPath) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
                }
                exit(0)
            }
        }
    }

    /// 首次启动没有代理配置时，自动探一个本机可用端口（只改本 app 的配置）
    private func detectProxyIfNeeded() {
        guard UserDefaults.standard.string(forKey: ProxyConfig.defaultsKey) == nil else { return }
        queue.async { [weak self] in
            guard let p = ProxyConfig.detect() else { return }
            UserDefaults.standard.set(p.display, forKey: ProxyConfig.defaultsKey)
            DispatchQueue.main.async { self?.refresh(force: true) }
        }
    }

    private func buildWindow() {
        let h = HUDContentView.preferredHeight(for: [])
        let origin: NSPoint
        if let pos = savedPosition() {
            origin = NSPoint(x: pos.x, y: pos.bottomY)   // 底部（细条）位置稳定
        } else {
            origin = defaultOrigin(height: h)
        }
        let frame = NSRect(x: origin.x, y: origin.y,
                           width: HUDContentView.cardWidth, height: h)

        window = HUDWindow(contentRect: frame,
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        // 透明无边框窗口 + 阴影会在角色上方画出一条硬边，关掉
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.appearance = NSAppearance(named: .vibrantDark)
        window.ignoresMouseEvents = false

        // 毛玻璃只铺在卡片上；上方角色区保持完全透明
        let cardHeight = frame.height - HUDContentView.charHeight
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0,
                                                      width: frame.width,
                                                      height: cardHeight))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .minYMargin]
        effect.wantsLayer = true
        effect.layer?.cornerRadius = HUDContentView.corner
        effect.layer?.masksToBounds = true
        if let layer = effect.layer {
            layer.borderWidth = 0.5
            layer.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        }
        effect.isHidden = true
        effectView = effect

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.addSubview(effect)
        window.contentView = container

        hud = HUDContentView(frame: NSRect(origin: .zero, size: frame.size))
        hud.autoresizingMask = [.width, .height]
        hud.onRightClick = { [weak self] in self?.showMenu() }
        hud.onDoubleClick = { [weak self] in self?.refresh(force: true) }
        hud.avatarImage = currentAvatarImage
        container.addSubview(hud)

        window.alphaValue = Self.hoverAlpha   // 启动先完整展开 3 秒，让人看到位置
        window.ignoresMouseEvents = false
        window.orderFrontRegardless()
        startPointerTracking()
    }

    // MARK: 全局热键 ⌥⌘A

    /// 全局快捷键：一按就把卡片展开并保持 5 秒（鼠标不在上面就自动收回）
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { delegate.flashCard() }
            return noErr
        }, 1, &spec, selfPtr, &eventHandlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x41495148), id: 1)   // 'AIQH'
        let hs = RegisterEventHotKey(UInt32(kVK_ANSI_A),
                                     UInt32(cmdKey | optionKey),
                                     hotKeyID,
                                     GetApplicationEventTarget(), 0, &hotKeyRef)
        if hs != noErr { NSLog("AIQuotaHUD: 全局热键注册失败 status=\(hs)") }
    }

    /// 热键唤起：展开并保持 5 秒
    @objc func flashCard() {
        if !expanded { setExpanded(true) }
        flashTimer?.invalidate()
        let t = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
            guard let self else { return }
            if !self.pointerInside && !self.isMenuOpen {
                self.setExpanded(false)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        flashTimer = t
    }

    // MARK: 鼠标穿透 + 悬停显形

    /// 每 80ms 看一次鼠标在不在卡片范围内：
    /// 不在 → 穿透 + 很淡；在 → 接收事件 + 淡入清晰（此时可以右键/拖动）
    private func startPointerTracking() {
        hoverTimer?.invalidate()
        let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self, self.trackingEnabled else { return }
            self.updatePointerState()
        }
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
        // 启动后先完整展示 3 秒，让人看到位置，之后才允许收起
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.trackingEnabled = true
        }
    }

    private func updatePointerState() {
        // 正在拖动或弹菜单时不要切换，否则拖到一半会掉
        if NSEvent.pressedMouseButtons != 0 { return }
        if isMenuOpen { return }

        let mouse = NSEvent.mouseLocation
        // 热区统一外扩：收起时方便指到细线，展开时也不会因为贴边抖动而误收起
        let hit = window.frame.insetBy(dx: -12, dy: -12)

        let inside = hit.contains(mouse)
        guard inside != pointerInside else { return }
        pointerInside = inside

        window.ignoresMouseEvents = !inside
        setExpanded(inside)
    }

    /// 展开成完整卡片 / 收起成一条细线（顶部固定，向下伸缩）
    private func setExpanded(_ on: Bool) {
        guard on != expanded else { return }
        expanded = on

        if on {
            hud.isHidden = false
            hud.compact = false
            resize(to: max(60, HUDContentView.preferredHeight(for: lastItems)))
        } else {
            resize(to: Self.collapsedHeight)
            hud.compact = true          // 收起时只显示角色
            effectView.isHidden = true
        }
        hud.needsDisplay = true

        let target = on ? Self.hoverAlpha : Self.idleAlpha
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = target
        }
    }

    private func resize(to height: CGFloat) {
        let old = window.frame
        guard abs(old.height - height) > 0.5 else { return }
        var f = old
        // 底部固定：细条留在原地，角色向上伸展 / 收回
        f.size.height = height
        window.setFrame(f, display: true, animate: false)
        window.contentView?.frame = NSRect(origin: .zero, size: f.size)
        // 气泡自己画底色，毛玻璃层彻底不用了
        effectView.isHidden = true
        hud.frame = NSRect(origin: .zero, size: f.size)
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: AppSettings.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh(force: false)
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    // MARK: 刷新

    func refresh(force: Bool) {
        if refreshing { return }
        refreshing = true
        queue.async { [weak self] in
            let items = Collector.all()
            DispatchQueue.main.async {
                guard let self else { return }
                self.apply(items)
                self.refreshing = false
            }
        }
    }

    private func apply(_ items: [QuotaItem]) {
        lastItems = items
        if expanded {
            resize(to: max(60, HUDContentView.preferredHeight(for: items)))
        }
        hud.update(items: items, updatedAt: Date())
        Notifier.checkLowQuota(items)
    }

    // MARK: 位置记忆

    /// 存的是「x 坐标 + 顶部 y」——因为高度会在展开/收起之间变化，
    /// 只有顶部位置是稳定的，这样重启后卡片不会上下漂。
    private func savedPosition() -> (x: CGFloat, bottomY: CGFloat)? {
        guard let s = UserDefaults.standard.string(forKey: frameKey) else { return nil }
        let parts = s.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return (CGFloat(parts[0]), CGFloat(parts[1]))
    }

    private func savePosition() {
        let f = window.frame
        UserDefaults.standard.set("\(f.origin.x),\(f.origin.y)", forKey: frameKey)
    }

    private func defaultOrigin(height: CGFloat) -> NSPoint {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: screen.maxX - HUDContentView.cardWidth - 24,
                       y: screen.maxY - height - 24)
    }

    /// 通过 Spotlight / 启动台 / 再次 open 激活时，也展开卡片
    func applicationDidBecomeActive(_ notification: Notification) {
        flashCard()
    }

    func applicationWillTerminate(_ notification: Notification) {
        savePosition()
    }

    // MARK: 右键菜单

    func showMenu() {
        savePosition()
        isMenuOpen = true
        defer { isMenuOpen = false }
        let menu = NSMenu()

        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(doRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        // 手动校准子菜单
        let calib = NSMenuItem(title: "手动校准额度", action: nil, keyEquivalent: "")
        let calibMenu = NSMenu()
        for p in Collector.providerList() {
            let it = NSMenuItem(title: p.name, action: #selector(doCalibrate(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = p.id
            calibMenu.addItem(it)
        }
        calibMenu.addItem(.separator())
        let clearItem = NSMenuItem(title: "清除全部校准", action: #selector(doClearAllCalibration), keyEquivalent: "")
        clearItem.target = self
        calibMenu.addItem(clearItem)
        calib.submenu = calibMenu
        menu.addItem(calib)

        // 代理：只对本 app 生效
        let proxyStatus: String
        if let p = ProxyConfig.configured {
            proxyStatus = "代理：\(p.display)"
        } else {
            proxyStatus = "代理：自动检测"
        }
        let proxyInfo = NSMenuItem(title: proxyStatus, action: nil, keyEquivalent: "")
        proxyInfo.isEnabled = false
        menu.addItem(proxyInfo)

        let proxyItem = NSMenuItem(title: "设置代理…", action: #selector(doSetProxy), keyEquivalent: "")
        proxyItem.target = self
        menu.addItem(proxyItem)

        // 形象
        let avatarMenu = NSMenu()
        for path in avatarPaths() {
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let it = NSMenuItem(title: name, action: #selector(doSetAvatar(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = path
            it.state = (path == currentAvatarPath) ? .on : .off
            avatarMenu.addItem(it)
        }
        avatarMenu.addItem(.separator())
        let importPhoto = NSMenuItem(title: "更换形象照片…",
                                     action: #selector(doImportPhoto), keyEquivalent: "")
        importPhoto.target = self
        avatarMenu.insertItem(importPhoto, at: 0)
        avatarMenu.insertItem(.separator(), at: 1)

        let openAvatarDir = NSMenuItem(title: "把新图片放进形象文件夹…",
                                       action: #selector(doOpenAvatarDir), keyEquivalent: "")
        openAvatarDir.target = self
        avatarMenu.addItem(openAvatarDir)
        let avatarItem = NSMenuItem(title: "形象", action: nil, keyEquivalent: "")
        avatarItem.submenu = avatarMenu
        menu.addItem(avatarItem)

        let wbItem = NSMenuItem(title: "设置 WorkBuddy 剩余积分…",
                                action: #selector(doSetWorkBuddyCredits), keyEquivalent: "")
        wbItem.target = self
        menu.addItem(wbItem)

        // 平时透明度
        let alphaMenu = NSMenu()
        for v in Self.idleAlphaOptions {
            let pct = Int((v * 100).rounded())
            let it = NSMenuItem(title: "\(pct)%", action: #selector(doSetIdleAlpha(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = v
            it.state = abs(Double(Self.idleAlpha) - v) < 0.005 ? .on : .off
            alphaMenu.addItem(it)
        }
        let alphaItem = NSMenuItem(title: "平时透明度", action: nil, keyEquivalent: "")
        alphaItem.submenu = alphaMenu
        menu.addItem(alphaItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(doOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(title: updateMenuTitle(), action: #selector(doCheckUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        let login = NSMenuItem(title: "开机自动启动", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        login.target = self
        login.state = FileManager.default.fileExists(atPath: loginPlist().path) ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(doQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.popUp(positioning: nil,
                   at: NSPoint(x: hud.bounds.width - 12, y: 8),
                   in: hud)
    }

    @objc private func doRefresh() { refresh(force: true) }

    @objc private func doQuit() {
        savePosition()
        NSApp.terminate(nil)
    }

    // MARK: 手动校准

    @objc private func doCalibrate(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let name = Collector.providerList().first { $0.id == id }?.name ?? id
        let existing = ManualCalibration.load(id)

        let alert = NSAlert()
        alert.messageText = "手动校准 · \(name)"
        alert.informativeText = "填当前剩余百分比和周期结束时间。\n适用于没有公开额度接口的服务。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))

        let pctLabel = NSTextField(labelWithString: "剩余 %")
        pctLabel.frame = NSRect(x: 0, y: 32, width: 60, height: 18)
        pctLabel.font = .systemFont(ofSize: 11)
        let pctField = NSTextField(frame: NSRect(x: 64, y: 30, width: 80, height: 22))
        pctField.stringValue = existing.map { String(format: "%.0f", $0.remaining * 100) } ?? "50"
        pctField.placeholderString = "0-100"

        let dayLabel = NSTextField(labelWithString: "周期(天)")
        dayLabel.frame = NSRect(x: 0, y: 4, width: 60, height: 18)
        dayLabel.font = .systemFont(ofSize: 11)
        let dayField = NSTextField(frame: NSRect(x: 64, y: 2, width: 80, height: 22))
        let defaultDays = existing.map { max(1, Int($0.expiresAt.timeIntervalSinceNow / 86400)) } ?? 30
        dayField.stringValue = "\(defaultDays)"

        box.addSubview(pctLabel); box.addSubview(pctField)
        box.addSubview(dayLabel); box.addSubview(dayField)
        alert.accessoryView = box

        NSApp.activate(ignoringOtherApps: true)
        let resp = alert.runModal()
        guard resp == .alertFirstButtonReturn else { return }

        let pct = Double(pctField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 50
        let days = max(1, Double(dayField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 30)
        ManualCalibration.save(id,
                              remaining: max(0, min(1, pct / 100)),
                              expiresAt: Date().addingTimeInterval(days * 86400),
                              label: "手动校准")
        refresh(force: true)
    }

    @objc private func doClearAllCalibration() {
        for p in Collector.providerList() { ManualCalibration.clear(p.id) }
        refresh(force: true)
    }

    // MARK: DeepSeek Key

    @objc private func doSetDeepSeekKey() {
        let alert = NSAlert()
        alert.messageText = "DeepSeek API Key"
        alert.informativeText = "用于查询账户余额（https://api.deepseek.com/user/balance）。\n只保存在本机 UserDefaults 中。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "清除")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = UserDefaults.standard.string(forKey: DeepSeekProvider.defaultsKey) ?? ""
        field.placeholderString = "sk-..."
        alert.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(v, forKey: DeepSeekProvider.defaultsKey)
        } else if resp == .alertSecondButtonReturn {
            UserDefaults.standard.removeObject(forKey: DeepSeekProvider.defaultsKey)
        }
        refresh(force: true)
    }

    // MARK: 代理配置

    @objc private func doSetProxy() {
        let alert = NSAlert()
        alert.messageText = "设置代理"
        alert.informativeText = """
        只作用于「AI 额度」这一个 app 的网络请求。
        不会修改系统代理设置，也不影响其他应用。

        格式：http://127.0.0.1:7890 或 socks5://127.0.0.1:7891
        留空 = 关闭代理
        """
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "清除")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = UserDefaults.standard.string(forKey: ProxyConfig.defaultsKey)
            ?? "http://127.0.0.1:7890"
        field.placeholderString = "http://127.0.0.1:7890"
        alert.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty {
                UserDefaults.standard.removeObject(forKey: ProxyConfig.defaultsKey)
            } else if ProxyConfig.parse(v) != nil {
                UserDefaults.standard.set(v, forKey: ProxyConfig.defaultsKey)
            } else {
                let bad = NSAlert()
                bad.messageText = "代理格式无效"
                bad.informativeText = "请写成 http://127.0.0.1:7890 或 socks5://127.0.0.1:7891"
                bad.runModal()
            }
        } else if resp == .alertSecondButtonReturn {
            UserDefaults.standard.removeObject(forKey: ProxyConfig.defaultsKey)
        }
        refresh(force: true)
    }

    // MARK: WorkBuddy 积分锚点

    @objc private func doSetWorkBuddyCredits() {
        let alert = NSAlert()
        alert.messageText = "WorkBuddy 当前剩余积分"
        alert.informativeText = """
        在 WorkBuddy 里看一眼当前剩余积分，填到这里。
        之后卡片会按本地消耗流水自动扣减，跟着实际使用走。

        一次性设置：直到 WorkBuddy 赠送或重置积分，重新填一次即可。
        """
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "清除")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        if let a = WBAnchor.load() { field.stringValue = String(format: "%.1f", a.credits) }
        field.placeholderString = "例如 2000"
        alert.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let v = Double(raw) {
                // 同时抓一份当前每个会话的累计积分作为基线，之后只算增量
                WBAnchor.save(credits: v, baseline: WorkBuddyProvider().creditBySession())
            } else {
                let bad = NSAlert()
                bad.messageText = "请填数字"
                bad.informativeText = "例如 2000 或 1850.5"
                bad.runModal()
            }
        } else if resp == .alertSecondButtonReturn {
            WBAnchor.clear()
        }
        refresh(force: true)
    }

    // MARK: 平时透明度

    @objc private func doSetIdleAlpha(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        UserDefaults.standard.set(v, forKey: Self.idleAlphaKey)
        if !pointerInside {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                window.animator().alphaValue = Self.idleAlpha
            }
        }
    }

    // MARK: 呼吸动画

    /// 30fps 更新相位，角色轻微上下浮动 + 缩放，像在呼吸
    private func startBreathing() {
        animTimer?.invalidate()
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            // 悬停时呼吸快一点（周期 2.8s），平时慢一点（4.2s）
            self.animPhase += self.expanded ? 0.075 : 0.05
            if self.animPhase > .pi * 2 { self.animPhase -= .pi * 2 }
            self.hud.animPhase = self.animPhase
            self.hud.hovering = self.expanded
            self.hud.needsDisplay = true
        }
        if let t = animTimer { RunLoop.main.add(t, forMode: .common) }
    }

    // MARK: 桌宠自动化

    /// 每 3 秒看一眼前台是哪个 AI，气泡跟着切换
    private func startAIWatcher() {
        aiDetectTimer?.invalidate()
        aiDetectTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshHighlight()
        }
        if let t = aiDetectTimer { RunLoop.main.add(t, forMode: .common) }
        refreshHighlight()
    }

    private func refreshHighlight() {
        let providerId = AIDetector.currentProviderId()
        let appName = AIDetector.currentAppName()

        // 前台是 AI → 显示它；否则显示额度最低的那个
        let target: QuotaItem?
        if let pid = providerId, let hit = lastItems.first(where: { $0.id == pid }) {
            target = hit
        } else {
            target = lastItems
                .filter { $0.remaining != nil }
                .min { ($0.remaining ?? 1) < ($1.remaining ?? 1) } ?? lastItems.first
        }
        hud.highlighted = target
        hud.contextText = appName.map { "\($0) 在前台" }
        hud.needsDisplay = true
    }

    /// 角色自己在桌面上溜达（只在没悬停时走）
    private func startWandering() {
        wanderTimer?.invalidate()
        scheduleNextWander()
    }

    private func scheduleNextWander() {
        wanderTimer?.invalidate()
        var delay = Double.random(in: 50...140)
        if let override = ProcessInfo.processInfo.environment["HUD_WANDER_DELAY"],
           let v = Double(override), v > 0 {
            delay = v
        }
        NSLog("[wander] 下次移动 %.1f 秒后", delay)
        wanderTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.wanderOnce()
            self?.scheduleNextWander()
        }
        if let t = wanderTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func wanderOnce() {
        guard let win = window else { NSLog("[wander] 没有窗口"); return }
        if expanded { NSLog("[wander] 跳过：窗口处于展开态"); return }
        if wanderTween != nil { NSLog("[wander] 跳过：上一个移动还没走完"); return }

        let screen = NSScreen.main?.visibleFrame ?? .zero
        let w = win.frame.width, h = win.frame.height
        guard screen.width > w, screen.height > h else {
            NSLog("[wander] 跳过：屏幕 %.0fx%.0f 放不下窗口 %.0fx%.0f", screen.width, screen.height, w, h)
            return
        }
        let from = win.frame.origin
        let to = NSPoint(x: CGFloat.random(in: screen.minX...(screen.maxX - w)),
                         y: CGFloat.random(in: screen.minY...(screen.maxY - h)))
        NSLog("[wander] 从 (%.0f,%.0f) 移到 (%.0f,%.0f)", from.x, from.y, to.x, to.y)

        // 自己插值：animator() 在 borderless NSPanel 上不可靠
        let duration: TimeInterval = 2.2
        let steps = Int(duration * 60)
        var step = 0
        let timer = Timer(timeInterval: duration / Double(steps), repeats: true) { [weak self] t in
            guard let self, let win = self.window else { t.invalidate(); self?.wanderTween = nil; return }
            step += 1
            let p = min(1.0, Double(step) / Double(steps))
            // easeInOut
            let e = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
            let x = from.x + (to.x - from.x) * CGFloat(e)
            let y = from.y + (to.y - from.y) * CGFloat(e)
            win.setFrameOrigin(NSPoint(x: x, y: y))
            if step >= steps {
                t.invalidate()
                self.wanderTween = nil
                self.savePosition()
            }
        }
        wanderTween = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 周期提醒：固定间隔 + 额度阈值
    private func startReminders() {
        reminderTimer?.invalidate()
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.checkReminders()
        }
        if let t = reminderTimer { RunLoop.main.add(t, forMode: .common) }
    }

    private func checkReminders() {
        guard AppSettings.notifyEnabled else { return }

        // 阈值提醒（50 / 20 / 10，各只报一次）
        for item in lastItems {
            guard let r = item.remaining else { continue }
            let pct = Int((r * 100).rounded())
            for threshold in [50, 20, 10] where pct <= threshold {
                let key = "\(item.id)_\(threshold)"
                if firedThresholds.contains(key) { continue }
                firedThresholds.insert(key)
                Notifier.post(title: "\(item.name) 额度偏低",
                              body: "剩余 \(pct)%\(item.secondary.isEmpty ? "" : "· \(item.secondary)")")
                flashCard()
            }
            // 额度回升（重置）后允许再次提醒
            if pct > 60 {
                firedThresholds = firedThresholds.filter { !$0.hasPrefix("\(item.id)_") }
            }
        }

        // 固定间隔提醒
        let interval = TimeInterval(max(15, AppSettings.reminderMinutes)) * 60
        guard Date().timeIntervalSince(lastFixedReminder) >= interval else { return }
        lastFixedReminder = Date()
        if let worst = lastItems.filter({ $0.remaining != nil }).min(by: { ($0.remaining ?? 1) < ($1.remaining ?? 1) }) {
            let pct = Int(((worst.remaining ?? 0) * 100).rounded())
            Notifier.post(title: "额度快照",
                          body: "\(worst.name) 剩余 \(pct)%\(worst.secondary.isEmpty ? "" : "· \(worst.secondary)")")
            flashCard()
        }
    }

    /// 监听 Codex 的 task_complete
    private func startCodexWatcher() {
        let w = CodexTaskWatcher()
        w.onTaskComplete = { [weak self] duration in
            guard let self else { return }
            var body = "任务跑完了"
            if let d = duration, d > 1 { body = String(format: "任务跑完了，用时 %.0f 秒", d) }
            Notifier.post(title: "Codex 完成", body: body)
            self.flashCard()
        }
        w.start()
        taskWatcher = w
    }

    // MARK: 形象（头像）

    private var userAvatarDir: URL {
        QuotaUtil.home.appendingPathComponent(".config/ai-quota-hud/avatars")
    }

    /// 所有可用形象：内置 + 用户目录
    private func avatarPaths() -> [String] {
        var out: [String] = []
        if let url = Bundle.main.url(forResource: "default", withExtension: "png",
                                     subdirectory: "avatars") {
            out.append(url.path)
        } else if let res = Bundle.main.resourceURL?
                    .appendingPathComponent("avatars/default.png"),
                  FileManager.default.fileExists(atPath: res.path) {
            out.append(res.path)
        }

        let dir = userAvatarDir
        if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for f in files.sorted() {
                let lower = f.lowercased()
                if lower.hasSuffix(".png") || lower.hasSuffix(".jpg")
                    || lower.hasSuffix(".jpeg") || lower.hasSuffix(".gif") {
                    out.append(dir.appendingPathComponent(f).path)
                }
            }
        }
        return out
    }

    private func loadAvatar() {
        let all = avatarPaths()

        let saved = UserDefaults.standard.string(forKey: "avatarPath")

        // 先试用户上次选的
        if let saved, let img = NSImage(contentsOfFile: saved) {
            currentAvatarPath = saved
            currentAvatarImage = img
            return
        }

        // 再试用户目录里的第一张
        let dir = userAvatarDir
        if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for f in files.sorted() {
                let lower = f.lowercased()
                if lower.hasSuffix(".png") || lower.hasSuffix(".jpg")
                    || lower.hasSuffix(".jpeg") || lower.hasSuffix(".gif") {
                    let p = dir.appendingPathComponent(f).path
                    if let img = NSImage(contentsOfFile: p) {
                        currentAvatarPath = p
                        currentAvatarImage = img
                        return
                    }
                }
            }
        }

        // 最后用内置
        let builtin = all.first(where: { $0.hasSuffix("default.png") })
        currentAvatarPath = builtin
        currentAvatarImage = builtin.flatMap { NSImage(contentsOfFile: $0) }
    }

    @objc private func doSetAvatar(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let img = NSImage(contentsOfFile: path) else { return }
        currentAvatarPath = path
        currentAvatarImage = img
        UserDefaults.standard.set(path, forKey: "avatarPath")
        hud.avatarImage = img
        hud.needsDisplay = true
    }

    // MARK: 设置与更新

    private var settingsWC: SettingsWindowController?

    @objc private func doOpenSettings() {
        if settingsWC == nil {
            settingsWC = SettingsWindowController(onChange: { [weak self] in
                self?.scheduleTimer()
                self?.refresh(force: true)
            })
        }
        settingsWC?.show()
    }

    @objc private func doCheckUpdates() { checkForUpdates(silent: false) }

    private func updateMenuTitle() -> String {
        guard let tag = Updater.latestTag else { return "检查更新" }
        let clean = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Updater.compareVersion(clean, Updater.currentVersion) > 0
            ? "有新版本 \(tag)" : "检查更新"
    }

    private func checkForUpdates(silent: Bool) {
        Updater.check { [weak self] newer, tag in
            guard let self else { return }
            if newer, let tag {
                self.showUpdateAlert(tag: tag)
            } else if !silent {
                self.showInfo("已是最新版本", "当前版本 \(Updater.currentVersion)")
            }
        }
    }

    private func showUpdateAlert(tag: String) {
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(tag)"
        alert.informativeText = "当前版本 \(Updater.currentVersion)。"
        alert.addButton(withTitle: "打开下载页")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: Updater.updateURL) {
            NSWorkspace.shared.open(url)
        }
    }

    private func showInfo(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    /// 选一张照片，自动抠背景后作为形象
    @objc private func doImportPhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP, .gif, .bmp]
        panel.allowsMultipleSelection = false
        panel.message = "选一张照片，自动抠掉背景后放到卡片上"
        panel.prompt = "用这张"
        guard panel.runModal() == .OK, let url = panel.url,
              let img = NSImage(contentsOf: url) else { return }

        guard let processed = CharacterProcessor.process(img) else {
            let alert = NSAlert()
            alert.messageText = "没法处理这张图"
            alert.informativeText = "背景太杂或图片太小都可能失败。建议用主体清晰、浅色背景的照片。"
            alert.runModal()
            return
        }

        let dir = userAvatarDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "photo-\(Int(Date().timeIntervalSince1970)).png"
        let dest = dir.appendingPathComponent(name)

        guard let tiff = processed.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: dest)
        } catch {
            return
        }

        currentAvatarPath = dest.path
        currentAvatarImage = processed
        UserDefaults.standard.set(dest.path, forKey: "avatarPath")
        hud.avatarImage = processed
        hud.needsDisplay = true
    }

    @objc private func doOpenAvatarDir() {
        let dir = userAvatarDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
    }

    // MARK: 开机自启

    private func loginPlist() -> URL {
        QuotaUtil.home.appendingPathComponent("Library/LaunchAgents/com.kai.aiquota.plist")
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        let plist = loginPlist()
        if FileManager.default.fileExists(atPath: plist.path) {
            try? FileManager.default.removeItem(at: plist)
            sender.state = .off
            return
        }
        let exe = Bundle.main.executablePath ?? ""
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
        do {
            try content.write(to: plist, atomically: true, encoding: .utf8)
            sender.state = .on
        } catch {
            sender.state = .off
        }
    }
}
