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
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 设置应用为后台应用（不显示在 Dock）
        NSApp.setActivationPolicy(.accessory)
        
        // 默认配置
        UserDefaults.standard.register(defaults: [
            // 外观默认值
            AppearanceSettings.historyBackgroundAlphaKey: 0.9,
            AppearanceSettings.cardBackgroundAlphaKey: 0.85
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
        
        // 设置快捷键 (默认: Command + Option + V)
        shortcutManager = KeyboardShortcutManager()
        shortcutManager?.registerHotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: [.command, .option]) { [weak self] in
            self?.toggleHistoryWindow()
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
    
    func applicationWillTerminate(_ notification: Notification) {
        clipboardManager?.stopMonitoring()
        shortcutManager?.unregisterHotKey()
        if let observer = workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
