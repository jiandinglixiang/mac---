import Cocoa
import ApplicationServices

// MARK: - NSView 工具：向上查找某种类型的父视图
extension NSView {
    func enclosingView<T: NSView>(ofType type: T.Type) -> T? {
        var view: NSView? = self
        while let current = view {
            if let typed = current as? T { return typed }
            view = current.superview
        }
        return nil
    }
}

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
    private var scrollView: HorizontalScrollView!
    private var containerView: NSView!
    private var backgroundEffectView: NSVisualEffectView?
    private var items: [ClipboardItem] = []
    /// 卡片视图池：只保留「可见区 + 两侧缓冲」这么多张卡片视图，滚动时复用并只更新内容。
    /// 注意：池视图的数组下标与 `items` 不再一一对应，每张视图用自己的 `index` 记录它当前代表的条目。
    private var cardPool: [ClipboardItemView] = []
    private var selectedIndex: Int = 0
    private var previousActiveApp: NSRunningApplication?  // 记住之前的活动应用
    private var appearanceObserver: NSObjectProtocol?
    private var clipViewBoundsObserver: NSObjectProtocol?
    private var isRestoringFocus: Bool = false

    // 卡片布局常量（建池、点击命中、滚动定位共用同一套算法）
    private let cardWidth: CGFloat = 180
    private let cardSpacing: CGFloat = 10
    private let cardVerticalPadding: CGFloat = 16
    private let cardLeftPadding: CGFloat = 16
    /// 可见区两侧各多留几张卡片，让它们提前就位，滚动时不会露白
    private let cardOverscan = 2
    
    override var window: NSWindow? {
        get { return window_ }
        set { window_ = newValue }
    }
    
    init() {
        super.init(window: nil)
        setupWindow()
        startObservingAppearanceSettings()
        applyAppearanceSettings()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
        }
        if let clipViewBoundsObserver {
            NotificationCenter.default.removeObserver(clipViewBoundsObserver)
        }
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
        // 使用透明背景，真正的背景由 NSVisualEffectView（毛玻璃）提供
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        // 关掉系统窗口阴影：这是全宽 + 非不透明(isOpaque=false) + 内容每帧变化的窗口，
        // 窗口阴影会由内容 alpha 反复重算，是 WindowServer 占用居高不下的主要来源之一。
        window.hasShadow = false
        window.delegate = self
        
        // 创建主容器
        let contentView = ClickThroughView(frame: window.contentView!.bounds)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.windowController = self
        window.contentView = contentView

        // 背景毛玻璃（铺满整个窗口，放在最底层）
        let effectView = NSVisualEffectView(frame: contentView.bounds)
        effectView.autoresizingMask = [.width, .height]
        effectView.blendingMode = .behindWindow
        effectView.material = .hudWindow
        effectView.state = .active
        contentView.addSubview(effectView, positioned: .below, relativeTo: nil)
        self.backgroundEffectView = effectView
        
        // 创建自定义横向滚动视图（占据整个窗口）
        scrollView = HorizontalScrollView(frame: NSRect(
            x: 0,
            y: 0,
            width: screenFrame.width,
            height: windowHeight
        ))
        scrollView.autoresizingMask = [.width, .height]
        
        // 替换默认的 clipView 为自定义的
        let customClipView = HorizontalClipView(frame: scrollView.contentView.frame)
        customClipView.drawsBackground = false
        customClipView.postsBoundsChangedNotifications = true
        scrollView.contentView = customClipView

        // 滚动时按可见区间刷新卡片池（覆盖滚轮、弹性回弹、程序化滚动等所有路径）。
        // queue 传 nil：同步回调，保证新卡片在本次滚动绘制前就位，不会露出空白。
        clipViewBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: customClipView,
            queue: nil
        ) { [weak self] _ in
            self?.refreshVisibleCards()
        }
        scrollView.historyWindowController = self
        
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

    private func startObservingAppearanceSettings() {
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .appearanceSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppearanceSettings()
        }
    }

    private func applyAppearanceSettings() {
        // 只调背景毛玻璃的透明度，避免整体窗口（包括文字）一起变透明
        backgroundEffectView?.alphaValue = AppearanceSettings.historyBackgroundAlpha
        cardPool.forEach { $0.applyCardAppearanceSettings() }
    }

    /// 根据窗口坐标定位被点击的卡片（不依赖 AppKit hitTest），用于解决“点A贴B”的错位问题。
    /// - Parameter pointInWindow: `event.locationInWindow`
    func itemAtWindowPoint(_ pointInWindow: NSPoint) -> ClipboardItem? {
        // 把窗口坐标转换到 containerView 坐标系（会自动包含 scrollView 的偏移）
        let pointInContainer = containerView.convert(pointInWindow, from: nil)

        // 从后往前找（更贴近 Z-order：后添加的视图在更上层）。
        // 池化后卡片视图索引与 items 不再一一对应，所以一律通过视图自己绑定的 boundItem 取内容。
        for view in cardPool.reversed() where !view.isHidden {
            if view.frame.contains(pointInContainer), let item = view.boundItem {
                return item
            }
        }
        return nil
    }
    
    private func updateWindowPosition() {
        let mouseLocation = NSEvent.mouseLocation
        // 找到包含鼠标的屏幕，如果找不到则默认使用主屏幕
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main
        
        guard let targetScreen = screen else { return }
        
        let screenFrame = targetScreen.visibleFrame
        // 保持高度比例为屏幕高度的 20%
        let windowHeight = screenFrame.height * 0.2
        
        let newFrame = NSRect(
            x: screenFrame.minX,
            y: screenFrame.minY,
            width: screenFrame.width,
            height: windowHeight
        )
        
        window?.setFrame(newFrame, display: true)
    }
    
    func showWindow(_ items: [ClipboardItem], previousActiveApp: NSRunningApplication?) {
        updateWindowPosition()
        self.items = items
        self.selectedIndex = 0

        // 优先使用 AppDelegate 传入的“最后一个非本应用前台App”，更可靠
        self.previousActiveApp = previousActiveApp

        rebuildCardPool()

        // 显示窗口
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        
        // 确保内容视图获得键盘焦点（这样才能接收键盘事件）
        if let contentView = window?.contentView {
            window?.makeFirstResponder(contentView)
        }
        
        // 选中第一个项目
        if !items.isEmpty {
            selectItem(at: 0)
        }
    }

    /// 历史记录异步加载完成后刷新窗口内容（数据源发生变化，整体重建卡片池）
    func updateItems(_ items: [ClipboardItem]) {
        guard window?.isVisible == true else { return }
        self.items = items
        selectedIndex = min(selectedIndex, max(0, items.count - 1))
        rebuildCardPool()
        if !items.isEmpty {
            selectItem(at: selectedIndex)
        }
    }
    
    // MARK: - 卡片视图池

    /// 卡片高度（随窗口高度变化）
    private var cardHeight: CGFloat {
        max(40, scrollView.frame.height - (cardVerticalPadding * 2))
    }

    /// 第 index 张卡片的 x 坐标：卡片位置只由 index 决定，
    /// 因此点击命中（frame.contains）与滚动定位都不依赖池视图的数组下标
    private func cardX(for index: Int) -> CGFloat {
        cardLeftPadding + CGFloat(index) * (cardWidth + cardSpacing)
    }

    /// 重建卡片池：只在打开窗口 / 条目集合变化（删除、加载完成）时调用。
    /// 改前这里会一次性创建 200 张卡片（实测 227 ms、共 1200 个子视图），
    /// 现在只创建一屏可见的十几张，滚动时复用。
    private func rebuildCardPool() {
        cardPool.forEach { $0.removeFromSuperview() }
        cardPool.removeAll()

        containerView.frame = NSRect(x: 0, y: 0, width: scrollView.frame.width, height: scrollView.frame.height)
        updateContainerWidth()

        guard !items.isEmpty else { return }

        // 池容量 = 一屏可见张数 + 两侧缓冲
        let visibleCount = Int(ceil(scrollView.frame.width / (cardWidth + cardSpacing))) + 1
        let poolSize = min(items.count, visibleCount + cardOverscan * 2 + 1)
        let height = cardHeight

        for _ in 0..<poolSize {
            let card = ClipboardItemView(
                frame: NSRect(x: 0, y: cardVerticalPadding, width: cardWidth, height: height)
            )
            card.isHidden = true
            // 关键修复：点击绑定到“item本体/ID”，而不是 index。
            // 否则一旦 items 在窗口显示期间发生插入/重排（例如剪贴板监控更新 history），就会出现“点A卡片却按 index 取到B内容”的错位。
            card.onClick = { [weak self] clickedItem in
                self?.handleItemClick(clickedItem)
            }
            containerView.addSubview(card)
            cardPool.append(card)
        }

        refreshVisibleCards()
    }

    /// 只刷新「可见区 + 缓冲」区间内的卡片：区间内已由某张池视图代表的 index 完全不碰，
    /// 只有新进入区间的 index 才占用一张空闲视图并重新配置（滚动时通常只有 1 张在变）。
    fileprivate func refreshVisibleCards() {
        guard !items.isEmpty, !cardPool.isEmpty else { return }

        let visibleRect = scrollView.documentVisibleRect
        let step = cardWidth + cardSpacing
        let first = max(0, Int(floor((visibleRect.minX - cardLeftPadding) / step)) - cardOverscan)
        let last = min(items.count - 1, Int(ceil((visibleRect.maxX - cardLeftPadding) / step)) + cardOverscan)
        guard first <= last else { return }

        // 当前区间外的池视图都是可复用的空闲视图
        var freeCards = cardPool.filter { $0.index < first || $0.index > last }
        let height = cardHeight

        for index in first...last where !cardPool.contains(where: { $0.index == index }) {
            guard !freeCards.isEmpty else { break }
            let card = freeCards.removeFirst()
            card.index = index
            card.frame = NSRect(x: cardX(for: index), y: cardVerticalPadding, width: cardWidth, height: height)
            card.isHidden = false
            card.configure(with: items[index], index: index)
            card.setSelected(index == selectedIndex)
        }

        // 离开区间的卡片移出视口后隐藏（下次滚动到附近时复用）
        for card in cardPool where card.index < first || card.index > last {
            card.isHidden = true
        }
    }

    /// 容器宽度按条目总数计算（池化后仍保留完整滚动范围与弹性滚动）
    private func updateContainerWidth() {
        let totalWidth = cardLeftPadding + CGFloat(items.count) * (cardWidth + cardSpacing) + cardLeftPadding
        containerView.frame.size.width = max(totalWidth, scrollView.frame.width)
    }
    
    fileprivate func handleItemClick(_ item: ClipboardItem) {
        // 按你的需求：鼠标点击不依赖/不切换“选中状态”，只粘贴被点中的卡片内容
        selectAndPaste(item)
    }
    
    private func selectItem(at index: Int) {
        guard index >= 0 && index < items.count else { return }

        selectedIndex = index
        // 池视图只负责显示「自己当前代表的 index」是否被选中，不依赖数组下标
        for card in cardPool where !card.isHidden {
            card.setSelected(card.index == index)
        }

        // 滚动到可见区域（目标卡片可能还在可视区外，滚动后由 bounds 变化通知把它配置出来）
        scrollToItem(at: index)
    }

    private func scrollToItem(at index: Int) {
        guard index >= 0 && index < items.count else { return }

        let visibleRect = scrollView.documentVisibleRect
        let minX = cardX(for: index)
        let maxX = minX + cardWidth

        // 如果项目不在可见区域，滚动到该位置
        if maxX > visibleRect.maxX {
            let newX = maxX - scrollView.frame.width + 50
            scrollView.contentView.scroll(to: NSPoint(x: max(0, newX), y: 0))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else if minX < visibleRect.minX {
            scrollView.contentView.scroll(to: NSPoint(x: max(0, minX - 20), y: 0))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
    
    private func selectAndPaste(_ item: ClipboardItem) {
        // 复制到剪贴板
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.clipboardManager?.copyToClipboard(item)
        }

        // 保存之前的应用引用
        let targetApp = previousActiveApp

        // 关闭窗口
        hideWindow(restoreFocus: false)

        // 先激活之前的应用，再执行粘贴
        // 优化：缩短等待时间以提高响应速度
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            // 激活之前的应用
            if let app = targetApp {
                app.activate(options: [.activateIgnoringOtherApps])
            }
            
            // 等待应用激活后再粘贴
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                _ = self.simulatePaste()
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
    
    /// 隐藏窗口。可选：把焦点恢复回唤起前的应用（避免 Esc/点空白关闭后“输入焦点丢失”）。
    func hideWindow(restoreFocus: Bool = false) {
        window?.orderOut(nil)
        if restoreFocus {
            restorePreviousFocusIfPossible()
        }
    }

    /// 显式恢复到唤起前的输入焦点（尽量激活之前的前台应用）。
    private func restorePreviousFocusIfPossible() {
        // 多条关闭路径可能会触发多次（例如鼠标点空白 + resignKey），做一次轻量去重。
        if isRestoringFocus { return }
        isRestoringFocus = true

        // 如果本地没有记到，回退取 AppDelegate 里记录的“最后一个非本应用前台App”
        if previousActiveApp == nil, let appDelegate = NSApp.delegate as? AppDelegate {
            previousActiveApp = appDelegate.lastNonSelfActiveApp
        }

        guard let app = previousActiveApp else {
            isRestoringFocus = false
            return
        }

        // 稍微延迟，让 orderOut 完成，避免本应用仍处于 active 但无 key window 的中间态。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            app.activate(options: [.activateIgnoringOtherApps])
            self?.isRestoringFocus = false
        }
    }
    
    func handleKeyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // ESC
            hideWindow(restoreFocus: true)
        case 36, 76: // Enter (主键盘36, 小键盘76)
            if selectedIndex >= 0 && selectedIndex < items.count {
                selectAndPaste(items[selectedIndex])
            }
        case 124, 125: // 右箭头(124) 或 下箭头(125) - 选择下一个
            if selectedIndex < items.count - 1 {
                selectItem(at: selectedIndex + 1)
            }
        case 123, 126: // 左箭头(123) 或 上箭头(126) - 选择上一个
            if selectedIndex > 0 {
                selectItem(at: selectedIndex - 1)
            }
        case 51, 117:
            // 51: Backspace/⌫（键帽通常写 Delete）
            // 117: Forward Delete/⌦（外接键盘的 Del，或 Mac 上 fn+Delete）
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

            // 更新本地列表：条目集合变了，整体重建卡片池
            if let updatedItems = appDelegate.clipboardManager?.history {
                self.items = updatedItems
                selectedIndex = min(index, max(0, updatedItems.count - 1))
                rebuildCardPool()

                // 重新选择项目
                if !updatedItems.isEmpty {
                    selectItem(at: selectedIndex)
                }
            }
        }
    }
    
    // NSWindowDelegate 方法
    func windowDidResignKey(_ notification: Notification) {
        // 当窗口失去焦点时，隐藏窗口
        // 这里不主动“恢复焦点”，因为用户可能是点击到别的应用/窗口想切走焦点，
        // 我们不应把焦点强行拉回唤起前的应用。
        hideWindow(restoreFocus: false)
    }
}

// MARK: - 翻转视图（使坐标系从上往下）
class FlippedView: NSView {
    override var isFlipped: Bool { return true }
}

// MARK: - 自定义横向滚动视图（将纵向滚动转为横向）
class HorizontalScrollView: NSScrollView {
    /// 滚动后需要按新的可见区间刷新卡片池
    weak var historyWindowController: HistoryWindowController?

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
            historyWindowController?.refreshVisibleCards()
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
        historyWindowController?.refreshVisibleCards()
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
        
        // 关键修复：不用 hitTest 来判断点中了哪张卡片，直接在容器坐标里用 frame.contains 精确定位。
        // 这样可规避某些情况下 hitTest/子视图拦截导致命中错乱，从而出现“点A贴B”。
        if let item = windowController?.itemAtWindowPoint(location) {
            windowController?.handleItemClick(item)
            return
        }
        
        // 未点击到任何卡片：隐藏窗口
        windowController?.hideWindow(restoreFocus: true)
    }
    
    override func keyDown(with event: NSEvent) {
        // 将键盘事件传递给 windowController 处理
        windowController?.handleKeyDown(with: event)
    }
}

// MARK: - 自定义横向项目视图
class ClipboardItemView: NSView {
    /// 背景改成普通 layer 半透明纯色：改前是 NSVisualEffectView 实时毛玻璃，
    /// 200 张卡片就是 200 个实时 backdrop 层，是 WindowServer/GPU 合成的最大开销来源。
    private let backgroundView = NSView()
    private let iconImageView = NSImageView()
    private let thumbnailImageView = NSView() // 修改：使用普通 NSView 配合 Layer 显示图片
    private let titleLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    // 序号组件已移除
    // private let indexBadge = NSView()
    // private let indexLabel = NSTextField(labelWithString: "")
    private var isSelected = false
    /// 点击回调：直接回传当前卡片绑定的 ClipboardItem，避免任何 index/选中状态错位
    var onClick: ((ClipboardItem) -> Void)?
    // var onDoubleClick: (() -> Void)? // 移除双击
    
    /// 当前卡片代表的条目下标（池化复用后，一张卡片视图会依次代表不同条目）
    var index: Int = -1

    /// 当前卡片绑定的剪贴板项 ID，用于在外部根据 ID 精确定位/高亮。
    private(set) var itemID: UUID?
    /// 当前卡片绑定的剪贴板项（用于外部根据坐标定位后直接取到正确内容）
    private(set) var boundItem: ClipboardItem?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupViews() {
        wantsLayer = true
        // 外层只负责阴影（不做裁剪），内层 backgroundView 负责圆角+描边+半透明底色
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.shadowRadius = 4
        updateShadowPath()

        backgroundView.frame = bounds
        backgroundView.autoresizingMask = [.width, .height]
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 10
        backgroundView.layer?.masksToBounds = true
        backgroundView.layer?.borderWidth = 1.0
        backgroundView.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        addSubview(backgroundView)

        applyCardAppearanceSettings()
        
        let padding: CGFloat = 10
        let headerHeight: CGFloat = 36
        let footerHeight: CGFloat = 22
        
        // 序号组件已移除
        /*
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
        */
        
        // 图标 - 居左排列 (padding)
        let iconSize: CGFloat = 28
        iconImageView.frame = NSRect(x: padding, y: frame.height - headerHeight + 2, width: iconSize, height: iconSize)
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconImageView)
        
        // 标题（单行，在图标右侧）
        // padding + iconSize + spacing (8)
        let titleX = padding + iconSize + 8
        titleLabel.frame = NSRect(x: titleX, y: frame.height - headerHeight + 4, width: frame.width - titleX - padding, height: 20)
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
        // 限制行数：改前是 0（不限）＋整段文本，TextKit 要为每条历史布局完整内容
        previewLabel.maximumNumberOfLines = 6
        previewLabel.isBezeled = false
        previewLabel.drawsBackground = false
        previewLabel.cell?.wraps = true
        previewLabel.cell?.truncatesLastVisibleLine = true
        addSubview(previewLabel)
        
        // 预览图片视图（用于显示图片类型的缩略图，位置同 previewLabel）
        thumbnailImageView.frame = previewLabel.frame
        // 使用 Layer 的 resizeAspectFill 来实现“只保证图片的短边能完全显示出来”（即 Aspect Fill）
        thumbnailImageView.wantsLayer = true
        thumbnailImageView.layer?.contentsGravity = .resizeAspectFill
        thumbnailImageView.layer?.masksToBounds = true
        thumbnailImageView.layer?.cornerRadius = 4
        // 缩略图是降采样后的小图，按屏幕缩放显示，避免 Retina 下发虚
        thumbnailImageView.layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        thumbnailImageView.isHidden = true
        addSubview(thumbnailImageView)
        
        // 时间标签（底部右侧）
        timeLabel.frame = NSRect(x: padding, y: 4, width: frame.width - (padding * 2), height: 16)
        timeLabel.font = .systemFont(ofSize: 9, weight: .medium)
        timeLabel.textColor = NSColor(white: 0.5, alpha: 1.0)
        timeLabel.alignment = .right
        timeLabel.isBezeled = false
        timeLabel.drawsBackground = false
        addSubview(timeLabel)
    }

    /// 显式指定阴影路径：否则 Core Animation 要按层内容的 alpha 现算阴影，
    /// 滚动时每帧都要重算（卡片尺寸只在窗口高度变化时改变，随 bounds 更新即可）
    private func updateShadowPath() {
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateShadowPath()
    }

    func applyCardAppearanceSettings() {
        // 仅影响卡片背景本身，不影响文字/图标；「卡片背景透明度」滑块照旧生效
        let alpha = AppearanceSettings.cardBackgroundAlpha
        let background: NSColor = isSelected
            ? NSColor.systemBlue.withAlphaComponent(0.22 * alpha + 0.08)
            : NSColor.white.withAlphaComponent(0.12 * alpha)
        backgroundView.layer?.backgroundColor = background.cgColor
        backgroundView.layer?.borderColor = (isSelected
            ? NSColor.systemBlue.withAlphaComponent(0.9)
            : NSColor.white.withAlphaComponent(0.18)).cgColor
        backgroundView.layer?.borderWidth = isSelected ? 1.5 : 1.0
    }
    
    func configure(with item: ClipboardItem, index: Int) {
        self.index = index
        self.itemID = item.id
        self.boundItem = item
        iconImageView.image = item.icon
        titleLabel.stringValue = item.displayText
        // 显示用预览文本：超长内容已截断（改前实测最长 7005 字整段塞进多行标签）
        previewLabel.stringValue = item.previewTextForDisplay
        timeLabel.stringValue = item.formattedTime
        // 卡片被复用给别的条目时，背景/描边要跟随当前选中态
        applyCardAppearanceSettings()

        // 确保图标位置正确（因为之前可能被修改过）
        let padding: CGFloat = 10
        let headerHeight: CGFloat = 36
        let iconSize: CGFloat = 28
        iconImageView.frame = NSRect(x: padding, y: frame.height - headerHeight + 2, width: iconSize, height: iconSize)

        // 如果是图片，调整预览显示
        if item.type == .image {
            previewLabel.isHidden = true
            thumbnailImageView.isHidden = false
            thumbnailImageView.layer?.contents = nil
            loadThumbnail(for: item)
        } else {
            previewLabel.isHidden = false
            thumbnailImageView.isHidden = true
            thumbnailImageView.layer?.contents = nil
        }
    }

    /// 缩略图后台生成（ImageIO 降采样），避免在主线程序解码原图；
    /// 回调时校验卡片是否仍绑定同一条目，防止池化复用后串图。
    private func loadThumbnail(for item: ClipboardItem) {
        let itemID = item.id
        ThumbnailCache.shared.thumbnail(for: item) { [weak self] cgImage in
            guard let self, self.itemID == itemID else { return }
            self.thumbnailImageView.layer?.contents = cgImage
        }
    }
    
    func setSelected(_ selected: Bool) {
        isSelected = selected
        // 选中态不再切换毛玻璃 material（那会触发 backdrop 重算），改用背景色 + 蓝色描边表达
        titleLabel.textColor = .white
        previewLabel.textColor = selected ? NSColor(white: 0.9, alpha: 1.0) : NSColor(white: 0.7, alpha: 1.0)
        applyCardAppearanceSettings()
    }

    // 说明：点击事件已在 ClickThroughView 中统一处理（坐标命中卡片 → 取 boundItem → 粘贴），
    // 这里不再依赖 hitTest/mouseDown 以避免命中错位导致“点A贴B”。
}
