import Cocoa
import Carbon
import ApplicationServices

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var clipboardManager: ClipboardManager?
    var historyWindow: HistoryWindowController?
    var shortcutManager: KeyboardShortcutManager?
    var settingsWindow: SettingsWindowController?
    
    /// 最近一次“非本应用”的前台应用，用于把粘贴投递回用户原来的输入焦点处。
    ///（快捷键触发时，本应用可能已成为 active，直接读 frontmostApplication 会拿错）
    private(set) var lastNonSelfActiveApp: NSRunningApplication?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var featureSettingsObserver: NSObjectProtocol?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 设置应用为后台应用（不显示在 Dock）
        NSApp.setActivationPolicy(.accessory)
        
        // 默认配置
        UserDefaults.standard.register(defaults: [
            // 外观默认值
            AppearanceSettings.historyBackgroundAlphaKey: 0.9,
            AppearanceSettings.cardBackgroundAlphaKey: 0.85,
            // 功能开关默认值
            FeatureSettings.enableOptionVSystemClipboardKey: false
        ])

        // 监听前台应用切换，记录“最后一个非本应用”的前台应用
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self.lastNonSelfActiveApp = app
        }
        
        // 创建状态栏图标
        setupStatusBar()
        
        // 提示一次辅助功能权限（用于模拟⌘V粘贴）
        _ = ensureAccessibilityPermission(prompt: false)
        
        // 初始化剪贴板管理器
        clipboardManager = ClipboardManager()
        clipboardManager?.startMonitoring()
        
        // 初始化历史窗口
        historyWindow = HistoryWindowController()
        
        // 设置快捷键
        shortcutManager = KeyboardShortcutManager()
        // 1) ⌘⌥V：唤起本应用历史窗口（固定存在）
        shortcutManager?.registerHotKey(id: 1, keyCode: UInt32(kVK_ANSI_V), modifiers: [.command, .option]) { [weak self] in
            self?.toggleHistoryWindow()
        }
        
        // 2) ⌥V：可选功能（由设置开关控制）
        updateOptionVHotKeyRegistration()
        featureSettingsObserver = NotificationCenter.default.addObserver(
            forName: .featureSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateOptionVHotKeyRegistration()
        }
        
        print("剪贴板历史工具已启动")
    }
    
    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "剪贴板历史")
        }
        
        // 创建菜单
        let menu = NSMenu()
        
        menu.addItem(NSMenuItem(title: "显示历史 (⌘⌥V)", action: #selector(showHistory), keyEquivalent: ""))
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "清空历史", action: #selector(clearHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "关于", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }
    
    @objc func showHistory() {
        toggleHistoryWindow()
    }
    
    @objc func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "确认清空历史"
        alert.informativeText = "此操作将清空所有剪贴板历史记录，是否继续？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        
        if alert.runModal() == .alertFirstButtonReturn {
            clipboardManager?.clearHistory()
        }
    }
    
    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "剪贴板历史工具"
        alert.informativeText = """
        版本: 1.0.0
        
        功能特性:
        • 自动保存剪贴板历史
        • 支持文本、图片、文件、链接
        • 快捷键: ⌘⌥V 唤起历史窗口
        • 横向滚动选择历史记录
        
        仅支持 macOS 系统
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController()
        }
        settingsWindow?.show()
    }
    
    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
    
    private func updateOptionVHotKeyRegistration() {
        guard let shortcutManager else { return }
        
        if FeatureSettings.enableOptionVSystemClipboard {
            shortcutManager.registerHotKey(id: 2, keyCode: UInt32(kVK_ANSI_V), modifiers: [.option]) { [weak self] in
                self?.triggerSystemClipboardViaSpotlight()
            }
        } else {
            shortcutManager.unregisterHotKey(id: 2)
        }
    }
    
    /// ⌥V 触发：模拟 ⌘Space，然后延迟模拟 ⌘4（用户可用于唤起“系统剪贴板/第三方剪贴板”等）
    private func triggerSystemClipboardViaSpotlight() {
        guard ensureAccessibilityPermissionOrAlert() else { return }
        
        // 1) ⌘Space
        _ = postKeyCombo(keyCode: CGKeyCode(kVK_Space), flags: .maskCommand)
        
        // 2) 延迟 ⌘4（给 Spotlight 一个弹出时间）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            _ = self?.postKeyCombo(keyCode: CGKeyCode(kVK_ANSI_4), flags: .maskCommand)
        }
    }
    
    func toggleHistoryWindow() {
        if let window = historyWindow?.window, window.isVisible {
            // 再次按快捷键关闭时，也恢复到唤起前的输入焦点，避免焦点丢失
            historyWindow?.hideWindow(restoreFocus: true)
        } else {
            // 只有在“自动模拟粘贴(⌘V)”路径下才需要辅助功能权限；
            // 现已移除“仅写入系统剪贴板”选项，默认总是模拟粘贴，因此总是检查权限。
            _ = ensureAccessibilityPermission(prompt: false)
            historyWindow?.showWindow(clipboardManager?.history ?? [], previousActiveApp: lastNonSelfActiveApp)
        }
    }
    
    /// 用于模拟键盘事件（⌘V）所需的辅助功能权限。此处只做“是否授权”的检测与可选弹窗引导。
    @discardableResult
    private func ensureAccessibilityPermission(prompt: Bool) -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options: [CFString: Any] = [promptKey: prompt]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    
    /// 需要向系统发送按键事件（如 ⌘Space/⌘4）时的权限检查 + 友好提示
    private func ensureAccessibilityPermissionOrAlert() -> Bool {
        if AXIsProcessTrusted() { return true }
        
        // 触发系统弹窗（如果系统允许弹出）
        _ = ensureAccessibilityPermission(prompt: true)
        
        let appPath = Bundle.main.bundleURL.path
        let alert = NSAlert()
        alert.messageText = "辅助功能权限未生效"
        alert.informativeText = """
为了执行快捷键动作（模拟 ⌘Space / ⌘4），需要在「系统设置 → 隐私与安全性 → 辅助功能」中允许本应用。

当前运行的应用路径：
\(appPath)

如果你已经勾选过但仍提示，请在辅助功能列表里删除旧条目后重新添加上述路径的这个 App，并完全退出后重新打开。
"""
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "知道了")
        let result = alert.runModal()
        if result == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        return false
    }
    
    @discardableResult
    private func postKeyCombo(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            print("无法创建按键事件 (keyCode=\(keyCode))")
            return false
        }
        
        keyDown.flags = flags
        keyUp.flags = flags
        
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        clipboardManager?.stopMonitoring()
        shortcutManager?.unregisterHotKey()
        if let observer = workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = featureSettingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
