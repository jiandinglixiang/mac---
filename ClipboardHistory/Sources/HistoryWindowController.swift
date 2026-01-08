import Cocoa

class HistoryWindowController: NSWindowController, NSWindowDelegate {
    private var window_: NSWindow?
    private var scrollView: NSScrollView!
    private var containerView: NSView!
    private var items: [ClipboardItem] = []
    private var itemViews: [ClipboardItemView] = []
    private var selectedIndex: Int = 0
    
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
        
        // 创建窗口
        let window = NSWindow(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
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
        
        // 创建横向滚动视图（占据整个窗口）
        scrollView = NSScrollView(frame: NSRect(
            x: 0,
            y: 0,
            width: screenFrame.width,
            height: windowHeight
        ))
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none // 禁止垂直滚动
        
        // 创建容器视图（用于横向排列项目）
        containerView = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: windowHeight))
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        
        scrollView.documentView = containerView
        contentView.addSubview(scrollView)
        
        self.window_ = window
    }
    
    func showWindow(_ items: [ClipboardItem]) {
        self.items = items
        self.selectedIndex = 0
        
        updateItemViews()
        
        // 显示窗口
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        
        // 确保窗口获得键盘焦点
        window?.makeFirstResponder(window_)
        
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
        
        // 项目尺寸
        let itemWidth: CGFloat = 250
        let itemHeight = scrollView.frame.height - 40 // 留出上下边距
        let itemSpacing: CGFloat = 15
        let leftPadding: CGFloat = 20
        let topPadding: CGFloat = 20
        
        // 创建横向排列的项目视图
        for (index, item) in items.enumerated() {
            let x = leftPadding + CGFloat(index) * (itemWidth + itemSpacing)
            let y = topPadding
            
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
        
        // 更新容器视图大小
        let totalWidth = leftPadding + CGFloat(items.count) * (itemWidth + itemSpacing) + leftPadding
        containerView.frame.size.width = max(totalWidth, scrollView.frame.width)
    }
    
    private func handleItemClick(at index: Int) {
        selectItem(at: index)
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
        // 复制到剪贴板
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.clipboardManager?.copyToClipboard(item)
        }
        
        // 关闭窗口
        hideWindow()
        
        // 模拟粘贴 (Cmd+V)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.simulatePaste()
        }
    }
    
    private func simulatePaste() {
        // 使用 CGEvent 模拟 Cmd+V
        let source = CGEventSource(stateID: .hidSystemState)
        
        // 按下 Command 键
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)
        cmdDown?.flags = .maskCommand
        
        // 按下 V 键
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        vDown?.flags = .maskCommand
        
        // 释放 V 键
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        vUp?.flags = .maskCommand
        
        // 释放 Command 键
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
        
        // 发送事件
        let location = CGEventTapLocation.cghidEventTap
        cmdDown?.post(tap: location)
        vDown?.post(tap: location)
        vUp?.post(tap: location)
        cmdUp?.post(tap: location)
    }
    
    func hideWindow() {
        window?.orderOut(nil)
    }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            hideWindow()
        } else if event.keyCode == 36 { // Enter
            if selectedIndex >= 0 && selectedIndex < items.count {
                selectAndPaste(items[selectedIndex])
            }
        } else if event.keyCode == 124 { // 右箭头
            if selectedIndex < itemViews.count - 1 {
                selectItem(at: selectedIndex + 1)
            }
        } else if event.keyCode == 123 { // 左箭头
            if selectedIndex > 0 {
                selectItem(at: selectedIndex - 1)
            }
        } else if event.keyCode == 51 { // Delete/Backspace
            if selectedIndex >= 0 && selectedIndex < items.count {
                deleteItem(at: selectedIndex)
            }
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

// MARK: - 自定义点击穿透视图
class ClickThroughView: NSView {
    weak var windowController: HistoryWindowController?
    
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
}

// MARK: - 自定义横向项目视图
class ClipboardItemView: NSView {
    private let iconImageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
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
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.3).cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.clear.cgColor
        
        // 序号标签（左上角）
        indexLabel.frame = NSRect(x: 10, y: frame.height - 30, width: 40, height: 20)
        indexLabel.font = .systemFont(ofSize: 12, weight: .bold)
        indexLabel.textColor = .secondaryLabelColor
        indexLabel.alignment = .left
        addSubview(indexLabel)
        
        // 图标
        iconImageView.frame = NSRect(x: 10, y: frame.height - 90, width: 50, height: 50)
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconImageView)
        
        // 标题
        titleLabel.frame = NSRect(x: 70, y: frame.height - 60, width: frame.width - 80, height: 40)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 2
        addSubview(titleLabel)
        
        // 预览文本
        previewLabel.frame = NSRect(x: 10, y: 35, width: frame.width - 20, height: frame.height - 130)
        previewLabel.font = .systemFont(ofSize: 11)
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.maximumNumberOfLines = 5
        addSubview(previewLabel)
        
        // 时间
        timeLabel.frame = NSRect(x: 10, y: 10, width: frame.width - 20, height: 18)
        timeLabel.font = .systemFont(ofSize: 9)
        timeLabel.textColor = .tertiaryLabelColor
        timeLabel.alignment = .right
        addSubview(timeLabel)
    }
    
    func configure(with item: ClipboardItem, index: Int) {
        iconImageView.image = item.icon
        titleLabel.stringValue = item.displayText
        previewLabel.stringValue = item.previewText.replacingOccurrences(of: "\n", with: " ")
        timeLabel.stringValue = item.formattedTime
        indexLabel.stringValue = "#\(index + 1)"
        
        // 如果是图片，调整图标大小
        if item.type == .image {
            iconImageView.frame = NSRect(x: 10, y: frame.height - 120, width: 80, height: 80)
            iconImageView.imageScaling = .scaleProportionallyDown
            titleLabel.frame = NSRect(x: 100, y: frame.height - 80, width: frame.width - 110, height: 60)
        }
    }
    
    func setSelected(_ selected: Bool) {
        isSelected = selected
        
        if selected {
            layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.8).cgColor
            layer?.borderColor = NSColor.systemBlue.cgColor
            titleLabel.textColor = .white
            previewLabel.textColor = NSColor.white.withAlphaComponent(0.8)
        } else {
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.3).cgColor
            layer?.borderColor = NSColor.clear.cgColor
            titleLabel.textColor = .labelColor
            previewLabel.textColor = .secondaryLabelColor
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
