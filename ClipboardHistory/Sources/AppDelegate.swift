import Cocoa
import Carbon

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var clipboardManager: ClipboardManager?
    var historyWindow: HistoryWindowController?
    var shortcutManager: KeyboardShortcutManager?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 设置应用为后台应用（不显示在 Dock）
        NSApp.setActivationPolicy(.accessory)
        
        // 创建状态栏图标
        setupStatusBar()
        
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
    
    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
    
    func toggleHistoryWindow() {
        if let window = historyWindow?.window, window.isVisible {
            window.orderOut(nil)
        } else {
            historyWindow?.showWindow(clipboardManager?.history ?? [])
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        clipboardManager?.stopMonitoring()
        shortcutManager?.unregisterHotKey()
    }
}
