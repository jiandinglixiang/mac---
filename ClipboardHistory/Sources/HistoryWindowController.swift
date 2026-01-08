import Cocoa
import ApplicationServices

// MARK: - 自定义窗口类（允许无边框窗口接收键盘事件）
class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool {
        return true
    }
    
    override var canBecomeMain: Bool {
        return true
    }
}

class HistoryWindowController: NSWindowController, NSWindowDelegate {
    private var window_: NSWindow?
    private var scrollView: NSScrollView!
    private var containerView: NSView!
    private var items: [ClipboardItem] = []
    private var itemViews: [ClipboardItemView] = []
    private var selectedIndex: Int = 0
    private var previousActiveApp: NSRunningApplication?  // 记住之前的活动应用
    private let singleClickPasteKey = "singleClickPasteEnabled"
    private let preserveClipboardAfterPasteKey = "preserveClipboardAfterPasteEnabled"
    private let keyboardNavigatePasteKey = "keyboardNavigatePasteEnabled"
    
    override var window: NSWindow? {
        get { return window_ }
        set { window_ = newValue }
    }
    
    init() {
        super.init(window: nil)
        setupWindow()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupWindow() {
        // 获取主屏幕尺寸
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        
        // 计算窗口大小和位置（屏幕底部，宽度100%，高度20%）
        let windowHeight = screenFrame.height * 0.2
        let windowFrame = NSRect(
            x: screenFrame.minX,
            y: screenFrame.minY,
            width: screenFrame.width,
            height: windowHeight
        )
        
        // 创建窗口（使用自定义窗口类以支持键盘事件）
        let window = KeyableWindow(
            contentRect: windowFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        window.isOpaque = false
        window.backgroundColor = NSColor.black.withAlphaComponent(0.95)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.delegate = self
        
        // 创建主容器
        let contentView = ClickThroughView(frame: window.contentView!.bounds)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.95).cgColor
        contentView.windowController = self
        window.contentView = contentView
        
        // 创建自定义横向滚动视图（占据整个窗口）
        scrollView = HorizontalScrollView(frame: NSRect(
            x: 0,
            y: 0,
            width: screenFrame.width,
            height: windowHeight
        ))
        
        // 替换默认的 clipView 为自定义的
        let customClipView = HorizontalClipView(frame: scrollView.contentView.frame)
        customClipView.drawsBackground = false
        scrollView.contentView = customClipView
        
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.usesPredominantAxisScrolling = true  // 只使用主轴滚动
        
        // 内容高度（完全填充窗口高度）
        let contentHeight = windowHeight
        
        // 创建容器视图（高度精确匹配窗口高度）
        containerView = FlippedView(frame: NSRect(x: 0, y: 0, width: 0, height: contentHeight))
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        
        scrollView.documentView = containerView
        contentView.addSubview(scrollView)
        
        self.window_ = window
    }
    
    func showWindow(_ items: [ClipboardItem], previousActiveApp: NSRunningApplication?) {
        self.items = items
        self.selectedIndex = 0

        // 优先使用 AppDelegate 传入的“最后一个非本应用前台App”，更可靠
        self.previousActiveApp = previousActiveApp
        
        updateItemViews()
        
        // 显示窗口
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        
        // 确保内容视图获得键盘焦点（这样才能接收键盘事件）
        if let contentView = window?.contentView {
            window?.makeFirstResponder(contentView)
        }
        
        // 选中第一个项目
        if !itemViews.isEmpty {
            selectItem(at: 0)
        }
    }
    
    private func updateItemViews() {
        // 清除旧的视图
        itemViews.forEach { $0.removeFromSuperview() }
        itemViews.removeAll()
        
        guard !items.isEmpty else {
            containerView.frame.size.width = 0
            return
        }
        
        // 可用内容高度（与滚动视图高度一致）
        let availableHeight = scrollView.frame.height
        
        // 项目尺寸 - 上下边距
        let verticalPadding: CGFloat = 16
        let itemWidth: CGFloat = 180
        let itemHeight = availableHeight - (verticalPadding * 2) // 卡片高度
        let itemSpacing: CGFloat = 10
        let leftPadding: CGFloat = 16
        
        // 容器视图高度与滚动视图高度一致（防止垂直滚动）
        containerView.frame.size.height = availableHeight
        
        // 创建横向排列的项目视图
        for (index, item) in items.enumerated() {
            let x = leftPadding + CGFloat(index) * (itemWidth + itemSpacing)
            let y = verticalPadding
            
            let itemView = ClipboardItemView(
                frame: NSRect(x: x, y: y, width: itemWidth, height: itemHeight)
            )
            itemView.configure(with: item, index: index)
            itemView.onClick = { [weak self] in
                self?.handleItemClick(at: index)
            }
            itemView.onDoubleClick = { [weak self] in
                self?.selectAndPaste(item)
            }
            
            containerView.addSubview(itemView)
            itemViews.append(itemView)
        }
        
        // 更新容器视图宽度
        let totalWidth = leftPadding + CGFloat(items.count) * (itemWidth + itemSpacing) + leftPadding
        containerView.frame.size.width = max(totalWidth, scrollView.frame.width)
    }
    
    private func handleItemClick(at index: Int) {
        selectItem(at: index)
        
        // 可选：单击即粘贴（写入剪贴板 + 切回原应用 + ⌘V）
        if UserDefaults.standard.bool(forKey: singleClickPasteKey),
           index >= 0, index < items.count {
            selectAndPaste(items[index])
        }
    }
    
    private func selectItem(at index: Int) {
        guard index >= 0 && index < itemViews.count else { return }
        
        // 取消选中所有项目
        itemViews.forEach { $0.setSelected(false) }
        
        // 选中当前项目
        selectedIndex = index
        itemViews[index].setSelected(true)
        
        // 滚动到可见区域
        scrollToItem(at: index)
    }
    
    private func scrollToItem(at index: Int) {
        guard index >= 0 && index < itemViews.count else { return }
        
        let itemView = itemViews[index]
        let visibleRect = scrollView.documentVisibleRect
        let itemFrame = itemView.frame
        
        // 如果项目不在可见区域，滚动到该位置
        if itemFrame.maxX > visibleRect.maxX {
            let newX = itemFrame.maxX - scrollView.frame.width + 50
            scrollView.contentView.scroll(to: NSPoint(x: max(0, newX), y: 0))
        } else if itemFrame.minX < visibleRect.minX {
            scrollView.contentView.scroll(to: NSPoint(x: max(0, itemFrame.minX - 20), y: 0))
        }
    }
    
    private func selectAndPaste(_ item: ClipboardItem) {
        let preserveClipboard = UserDefaults.standard.bool(forKey: preserveClipboardAfterPasteKey)
        let snapshot = preserveClipboard ? (NSApp.delegate as? AppDelegate)?.clipboardManager?.snapshotPasteboard() : nil

        // 复制到剪贴板
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.clipboardManager?.copyToClipboard(item)
        }
        
        // 保存之前的应用引用
        let targetApp = previousActiveApp
        
        // 关闭窗口
        hideWindow()
        
        // 先激活之前的应用，再执行粘贴
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // 激活之前的应用
            if let app = targetApp {
                app.activate(options: [.activateIgnoringOtherApps])
            }
            
            // 等待应用激活后再粘贴
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let pasted = self.simulatePaste()

                // 若粘贴成功且启用了“恢复剪贴板”，则在粘贴后恢复原剪贴板内容，避免污染用户剪贴板
                if pasted, let snapshot {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        (NSApp.delegate as? AppDelegate)?.clipboardManager?.restorePasteboard(from: snapshot)
                    }
                }
            }
        }
    }
    
    @discardableResult
    private func simulatePaste() -> Bool {
        // 模拟键盘事件需要“辅助功能”权限（系统设置 -> 隐私与安全性 -> 辅助功能）
        // 注意：开发/重编译后若 App 路径或签名变化，系统可能把它当成“另一个 App”，需要重新在辅助功能里勾选一次。
        if !AXIsProcessTrusted() {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
            let options: [CFString: Any] = [promptKey: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)

            let appPath = Bundle.main.bundleURL.path
            let alert = NSAlert()
            alert.messageText = "辅助功能权限未生效"
            alert.informativeText = """
为了把选中的内容直接粘贴到当前输入框，需要在「系统设置 → 隐私与安全性 → 辅助功能」中允许本应用。

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
        
        // 使用 CGEvent 模拟 Cmd+V
        let source = CGEventSource(stateID: .combinedSessionState)
        
        // V 键的虚拟键码
        let vKeyCode: CGKeyCode = 0x09
        
        // 创建按下 V 键事件（带 Command 修饰键）
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true) else {
            print("无法创建按键事件")
            return false
        }
        keyDown.flags = .maskCommand
        
        // 创建释放 V 键事件
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            print("无法创建释放按键事件")
            return false
        }
        keyUp.flags = .maskCommand
        
        // 发送事件到系统
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        return true
    }
    
    func hideWindow() {
        window?.orderOut(nil)
    }
    
    func handleKeyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // ESC
            hideWindow()
        case 36, 76: // Enter (主键盘36, 小键盘76)
            if selectedIndex >= 0 && selectedIndex < items.count {
                selectAndPaste(items[selectedIndex])
            }
        case 124, 125: // 右箭头(124) 或 下箭头(125) - 选择下一个
            if selectedIndex < itemViews.count - 1 {
                selectItem(at: selectedIndex + 1)
                if UserDefaults.standard.bool(forKey: keyboardNavigatePasteKey),
                   selectedIndex >= 0, selectedIndex < items.count {
                    selectAndPaste(items[selectedIndex])
                }
            }
        case 123, 126: // 左箭头(123) 或 上箭头(126) - 选择上一个
            if selectedIndex > 0 {
                selectItem(at: selectedIndex - 1)
                if UserDefaults.standard.bool(forKey: keyboardNavigatePasteKey),
                   selectedIndex >= 0, selectedIndex < items.count {
                    selectAndPaste(items[selectedIndex])
                }
            }
        case 51: // Delete/Backspace
            if selectedIndex >= 0 && selectedIndex < items.count {
                deleteItem(at: selectedIndex)
            }
        case 49: // 空格键 - 也可以确认粘贴
            if selectedIndex >= 0 && selectedIndex < items.count {
                selectAndPaste(items[selectedIndex])
            }
        default:
            break
        }
    }
    
    private func deleteItem(at index: Int) {
        guard index >= 0 && index < items.count else { return }
        let item = items[index]
        
        // 从管理器中删除
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.clipboardManager?.deleteItem(item)
            
            // 更新本地列表
            if let updatedItems = appDelegate.clipboardManager?.history {
                self.items = updatedItems
                updateItemViews()
                
                // 重新选择项目
                if !itemViews.isEmpty {
                    let newIndex = min(index, itemViews.count - 1)
                    selectItem(at: newIndex)
                }
            }
        }
    }
    
    // NSWindowDelegate 方法
    func windowDidResignKey(_ notification: Notification) {
        // 当窗口失去焦点时，隐藏窗口
        hideWindow()
    }
}

// MARK: - 翻转视图（使坐标系从上往下）
class FlippedView: NSView {
    override var isFlipped: Bool { return true }
}

// MARK: - 自定义横向滚动视图（将纵向滚动转为横向）
class HorizontalScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        // 将垂直滚动转换为水平滚动
        if abs(event.deltaY) > abs(event.deltaX) {
            // 获取原始的滚动值
            let deltaY = event.deltaY
            let scrollingDeltaY = event.scrollingDeltaY
            
            // 直接操作滚动位置
            var newOrigin = self.contentView.bounds.origin
            
            // 使用 scrollingDeltaY 进行更平滑的滚动
            if event.hasPreciseScrollingDeltas {
                newOrigin.x -= scrollingDeltaY
            } else {
                newOrigin.x -= deltaY * 10 // 乘以系数增加滚动速度
            }
            
            // 限制滚动范围
            let maxX = max(0, (self.documentView?.frame.width ?? 0) - self.contentView.bounds.width)
            newOrigin.x = max(0, min(newOrigin.x, maxX))
            newOrigin.y = 0 // 锁定 Y 轴
            
            self.contentView.scroll(to: newOrigin)
            self.reflectScrolledClipView(self.contentView)
            return
        }
        
        // 如果是水平滚动，使用默认行为但锁定 Y
        var newOrigin = self.contentView.bounds.origin
        newOrigin.x -= event.scrollingDeltaX
        
        let maxX = max(0, (self.documentView?.frame.width ?? 0) - self.contentView.bounds.width)
        newOrigin.x = max(0, min(newOrigin.x, maxX))
        newOrigin.y = 0
        
        self.contentView.scroll(to: newOrigin)
        self.reflectScrolledClipView(self.contentView)
    }
}

// MARK: - 自定义 ClipView（锁定垂直滚动）
class HorizontalClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        constrained.origin.y = 0 // 锁定 Y 轴位置
        return constrained
    }
    
    override func scroll(to newOrigin: NSPoint) {
        var lockedOrigin = newOrigin
        lockedOrigin.y = 0 // 锁定 Y 轴
        super.scroll(to: lockedOrigin)
    }
}

// MARK: - 自定义点击穿透视图
class ClickThroughView: NSView {
    weak var windowController: HistoryWindowController?
    
    // 允许视图成为 first responder，以便接收键盘事件
    override var acceptsFirstResponder: Bool {
        return true
    }
    
    override func becomeFirstResponder() -> Bool {
        return true
    }
    
    override func mouseDown(with event: NSEvent) {
        let location = event.locationInWindow
        let hitView = self.hitTest(location)
        
        // 如果点击的不是卡片视图，则隐藏窗口
        if !(hitView is ClipboardItemView) && hitView != nil {
            windowController?.hideWindow()
        } else {
            super.mouseDown(with: event)
        }
    }
    
    override func keyDown(with event: NSEvent) {
        // 将键盘事件传递给 windowController 处理
        windowController?.handleKeyDown(with: event)
    }
}

// MARK: - 自定义横向项目视图
class ClipboardItemView: NSView {
    private let iconImageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let indexBadge = NSView()
    private let indexLabel = NSTextField(labelWithString: "")
    private var isSelected = false
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var clickCount = 0
    private var clickTimer: Timer?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.9).cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor(white: 0.3, alpha: 0.5).cgColor
        
        // 添加微妙的阴影效果
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.shadowRadius = 4
        
        let padding: CGFloat = 10
        let headerHeight: CGFloat = 36
        let footerHeight: CGFloat = 22
        
        // 序号徽章（左上角圆形背景）
        indexBadge.frame = NSRect(x: padding, y: frame.height - headerHeight, width: 24, height: 24)
        indexBadge.wantsLayer = true
        indexBadge.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.8).cgColor
        indexBadge.layer?.cornerRadius = 12
        addSubview(indexBadge)
        
        // 序号文字
        indexLabel.frame = NSRect(x: 0, y: 4, width: 24, height: 16)
        indexLabel.font = .systemFont(ofSize: 10, weight: .bold)
        indexLabel.textColor = .white
        indexLabel.alignment = .center
        indexLabel.isBezeled = false
        indexLabel.drawsBackground = false
        indexBadge.addSubview(indexLabel)
        
        // 图标
        let iconSize: CGFloat = 28
        iconImageView.frame = NSRect(x: padding + 30, y: frame.height - headerHeight + 2, width: iconSize, height: iconSize)
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconImageView)
        
        // 标题（单行，在图标右侧）
        titleLabel.frame = NSRect(x: padding + 64, y: frame.height - headerHeight + 4, width: frame.width - padding - 70, height: 20)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        addSubview(titleLabel)
        
        // 预览文本区域（占据中间区域）
        let previewY = footerHeight + 4
        let previewHeight = frame.height - headerHeight - footerHeight - 8
        previewLabel.frame = NSRect(x: padding, y: previewY, width: frame.width - (padding * 2), height: previewHeight)
        previewLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        previewLabel.textColor = NSColor(white: 0.7, alpha: 1.0)
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.maximumNumberOfLines = 0 // 允许多行
        previewLabel.isBezeled = false
        previewLabel.drawsBackground = false
        previewLabel.cell?.wraps = true
        previewLabel.cell?.truncatesLastVisibleLine = true
        addSubview(previewLabel)
        
        // 时间标签（底部右侧）
        timeLabel.frame = NSRect(x: padding, y: 4, width: frame.width - (padding * 2), height: 16)
        timeLabel.font = .systemFont(ofSize: 9, weight: .medium)
        timeLabel.textColor = NSColor(white: 0.5, alpha: 1.0)
        timeLabel.alignment = .right
        timeLabel.isBezeled = false
        timeLabel.drawsBackground = false
        addSubview(timeLabel)
    }
    
    func configure(with item: ClipboardItem, index: Int) {
        iconImageView.image = item.icon
        titleLabel.stringValue = item.displayText
        // 保留换行符以便多行显示
        let previewText = item.previewText
        previewLabel.stringValue = previewText
        timeLabel.stringValue = item.formattedTime
        indexLabel.stringValue = "\(index + 1)"
        
        // 如果是图片，调整预览显示
        if item.type == .image {
            // 图片类型使用更大的图标显示缩略图
            let padding: CGFloat = 10
            let headerHeight: CGFloat = 36
            let footerHeight: CGFloat = 22
            let previewY = footerHeight + 4
            let previewHeight = frame.height - headerHeight - footerHeight - 8
            
            // 将预览区域用于显示图片缩略图
            iconImageView.frame = NSRect(x: padding, y: previewY, width: frame.width - (padding * 2), height: previewHeight)
            iconImageView.imageScaling = .scaleProportionallyDown
            previewLabel.isHidden = true
        } else {
            previewLabel.isHidden = false
        }
    }
    
    func setSelected(_ selected: Bool) {
        isSelected = selected
        
        if selected {
            layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.4).cgColor
            layer?.borderColor = NSColor.systemBlue.cgColor
            layer?.borderWidth = 2
            indexBadge.layer?.backgroundColor = NSColor.white.cgColor
            indexLabel.textColor = NSColor.systemBlue
            titleLabel.textColor = .white
            previewLabel.textColor = NSColor(white: 0.9, alpha: 1.0)
        } else {
            layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.9).cgColor
            layer?.borderColor = NSColor(white: 0.3, alpha: 0.5).cgColor
            layer?.borderWidth = 1.5
            indexBadge.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.8).cgColor
            indexLabel.textColor = .white
            titleLabel.textColor = .white
            previewLabel.textColor = NSColor(white: 0.7, alpha: 1.0)
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        clickCount += 1
        
        if clickCount == 1 {
            // 单击 - 延迟执行，等待可能的双击
            clickTimer?.invalidate()
            clickTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                if self?.clickCount == 1 {
                    self?.onClick?()
                }
                self?.clickCount = 0
            }
        } else if clickCount == 2 {
            // 双击
            clickTimer?.invalidate()
            clickCount = 0
            onDoubleClick?()
        }
    }
}
