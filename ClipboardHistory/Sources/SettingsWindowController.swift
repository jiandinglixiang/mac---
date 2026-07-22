import Cocoa

/// 设置面板：通用（开机启动）、外观（透明度）、功能（快捷键开关）
final class SettingsWindowController: NSWindowController {
    // MARK: - 外观设置控件
    
    private let historyAlphaSlider = NSSlider(value: 0.9, minValue: 0.2, maxValue: 1.0, target: nil, action: nil)
    private let cardAlphaSlider = NSSlider(value: 0.85, minValue: 0.2, maxValue: 1.0, target: nil, action: nil)
    
    private let historyValueLabel = NSTextField(labelWithString: "")
    private let cardValueLabel = NSTextField(labelWithString: "")
    
    // MARK: - 通用设置控件
    
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "开机启动", target: nil, action: nil)
    private let launchAtLoginHintLabel = NSTextField(labelWithString: "需要 macOS 13.0 或更高版本")
    
    // MARK: - 功能设置控件
    
    private let optionVAppClipboardCheckbox = NSButton(checkboxWithTitle: "启用 ⌥V 打开应用剪贴板", target: nil, action: nil)
    private let optionVAppClipboardHintLabel = NSTextField(labelWithString: "按下 ⌥V 唤起本应用剪贴板历史窗口")
    
    private let controlVSystemClipboardCheckbox = NSButton(checkboxWithTitle: "启用 ⌃V 打开系统剪贴板", target: nil, action: nil)
    private let controlVSystemClipboardHintLabel = NSTextField(labelWithString: "触发顺序：⌘Space →（延迟）→ ⌘4")

    // MARK: - 风扇设置控件（按机型自适应：双风扇=左/右，单风扇=单项，无风扇=隐藏）

    private let fanCount = FanControl.fanCount()
    private var fanCheckboxes: [NSButton] = []   // tag = 风扇序号（0=左，1=右）
    private let fanStatusLabel = NSTextField(labelWithString: "")
    private let fanHintLabel = NSTextField(labelWithString: "勾选需管理员授权（Touch ID/密码）；睡眠或重启后系统可能恢复自动")

    // MARK: - 初始化

    init() {
        let height: CGFloat = fanCount > 0 ? 500 : 400
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "设置"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        
        super.init(window: panel)
        
        setupUI(in: panel)
        syncFromDefaults()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func show() {
        syncFanSection()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
    
    // MARK: - UI 设置
    
    private func setupUI(in panel: NSPanel) {
        let root = NSView(frame: panel.contentView?.bounds ?? .zero)
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = root
        
        // 区块标题样式
        let generalTitle = NSTextField(labelWithString: "通用")
        generalTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        
        let appearanceTitle = NSTextField(labelWithString: "外观")
        appearanceTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        
        let featureTitle = NSTextField(labelWithString: "功能")
        featureTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        
        // 外观滑块设置
        historyAlphaSlider.target = self
        historyAlphaSlider.action = #selector(onSliderChanged(_:))
        historyAlphaSlider.isContinuous = true
        
        cardAlphaSlider.target = self
        cardAlphaSlider.action = #selector(onSliderChanged(_:))
        cardAlphaSlider.isContinuous = true
        
        historyValueLabel.font = .systemFont(ofSize: 11, weight: .medium)
        historyValueLabel.textColor = .secondaryLabelColor
        
        cardValueLabel.font = .systemFont(ofSize: 11, weight: .medium)
        cardValueLabel.textColor = .secondaryLabelColor
        
        // 通用设置控件设置
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(onLaunchAtLoginChanged(_:))
        
        launchAtLoginHintLabel.font = .systemFont(ofSize: 11, weight: .regular)
        launchAtLoginHintLabel.textColor = .secondaryLabelColor
        
        // 功能设置控件设置
        optionVAppClipboardCheckbox.target = self
        optionVAppClipboardCheckbox.action = #selector(onOptionVAppClipboardChanged(_:))
        
        optionVAppClipboardHintLabel.font = .systemFont(ofSize: 11, weight: .regular)
        optionVAppClipboardHintLabel.textColor = .secondaryLabelColor
        
        controlVSystemClipboardCheckbox.target = self
        controlVSystemClipboardCheckbox.action = #selector(onControlVSystemClipboardChanged(_:))
        
        controlVSystemClipboardHintLabel.font = .systemFont(ofSize: 11, weight: .regular)
        controlVSystemClipboardHintLabel.textColor = .secondaryLabelColor

        // 风扇控件设置
        fanStatusLabel.font = .systemFont(ofSize: 11, weight: .regular)
        fanStatusLabel.textColor = .secondaryLabelColor
        fanHintLabel.font = .systemFont(ofSize: 11, weight: .regular)
        fanHintLabel.textColor = .secondaryLabelColor

        // 外观滑块行
        let historyRow = labeledSliderRow(
            label: "历史窗口背景透明度",
            slider: historyAlphaSlider,
            valueLabel: historyValueLabel
        )
        let cardRow = labeledSliderRow(
            label: "卡片背景透明度",
            slider: cardAlphaSlider,
            valueLabel: cardValueLabel
        )
        
        // 按钮
        let resetButton = NSButton(title: "恢复默认", target: self, action: #selector(onReset))
        resetButton.bezelStyle = .rounded
        
        let closeButton = NSButton(title: "关闭", target: self, action: #selector(onClose))
        closeButton.bezelStyle = .rounded
        
        let buttons = NSStackView(views: [resetButton, closeButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.distribution = .gravityAreas
        buttons.spacing = 10
        
        // 通用设置堆叠
        let generalStack = NSStackView(views: [launchAtLoginCheckbox, launchAtLoginHintLabel])
        generalStack.orientation = .vertical
        generalStack.alignment = .leading
        generalStack.spacing = 4
        
        // 功能设置堆叠
        let featureStack = NSStackView(views: [
            optionVAppClipboardCheckbox,
            optionVAppClipboardHintLabel,
            controlVSystemClipboardCheckbox,
            controlVSystemClipboardHintLabel
        ])
        featureStack.orientation = .vertical
        featureStack.alignment = .leading
        featureStack.spacing = 4
        
        // 风扇设置堆叠（风扇 0=左，风扇 1=右；无风扇机型不显示该区块）
        var fanSectionViews: [NSView] = []
        if fanCount > 0 {
            let fanTitle = NSTextField(labelWithString: "风扇")
            fanTitle.font = .systemFont(ofSize: 14, weight: .semibold)

            let names = fanCount >= 2 ? ["左风扇满速", "右风扇满速"] : ["风扇满速"]
            for i in 0..<min(fanCount, names.count) {
                let cb = NSButton(checkboxWithTitle: names[i], target: self, action: #selector(onFanCheckboxChanged(_:)))
                cb.tag = i
                fanCheckboxes.append(cb)
            }

            let fanStack = NSStackView(views: fanCheckboxes + [fanStatusLabel, fanHintLabel])
            fanStack.orientation = .vertical
            fanStack.alignment = .leading
            fanStack.spacing = 4
            fanSectionViews = [fanTitle, fanStack]
        }

        // 主布局堆叠
        var mainViews: [NSView] = [
            generalTitle, generalStack,
            appearanceTitle, historyRow, cardRow,
            featureTitle, featureStack
        ]
        mainViews.append(contentsOf: fanSectionViews)
        mainViews.append(buttons)
        let stack = NSStackView(views: mainViews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        
        root.addSubview(stack)
        
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -16),
            
            historyRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            cardRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
        ])
    }
    
    private func labeledSliderRow(label: String, slider: NSSlider, valueLabel: NSTextField) -> NSView {
        let name = NSTextField(labelWithString: label)
        name.font = .systemFont(ofSize: 12, weight: .regular)
        
        slider.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        
        let row = NSStackView(views: [name, slider, valueLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            name.widthAnchor.constraint(equalToConstant: 140),
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            valueLabel.widthAnchor.constraint(equalToConstant: 54)
        ])
        
        return row
    }
    
    // MARK: - 数据同步
    
    private func syncFromDefaults() {
        historyAlphaSlider.doubleValue = Double(AppearanceSettings.historyBackgroundAlpha)
        cardAlphaSlider.doubleValue = Double(AppearanceSettings.cardBackgroundAlpha)
        optionVAppClipboardCheckbox.state = FeatureSettings.enableOptionVAppClipboard ? .on : .off
        controlVSystemClipboardCheckbox.state = FeatureSettings.enableControlVSystemClipboard ? .on : .off
        launchAtLoginCheckbox.state = FeatureSettings.launchAtLogin ? .on : .off
        syncFanSection()
        refreshValueLabels()
    }

    // MARK: - 风扇控制

    private var fanOperationInProgress = false

    /// 只刷新转速标签（不触碰复选框，避免 SMC 读取瞬时失败导致复选框回退）
    private func refreshFanRPM() {
        guard fanCount > 0 else { return }
        let names = fanCount >= 2 ? ["左", "右"] : [""]
        let parts = fanCheckboxes.map { cb -> String in
            let rpm = FanControl.actualRPM(cb.tag).map { "\($0)" } ?? "?"
            return names[cb.tag].isEmpty ? "\(rpm) RPM" : "\(names[cb.tag]) \(rpm) RPM"
        }
        fanStatusLabel.stringValue = "当前转速：" + parts.joined(separator: " · ")
    }

    /// 以硬件真实状态刷新风扇区块：复选框 = SMC 强制模式位，状态行 = 实时转速
    private func syncFanSection() {
        guard fanCount > 0 else { return }
        guard !fanOperationInProgress else { return }  // 操作中不刷新，避免覆盖中间状态
        for cb in fanCheckboxes {
            cb.state = (FanControl.isForced(cb.tag) ?? false) ? .on : .off
        }
        let names = fanCount >= 2 ? ["左", "右"] : [""]
        let parts = fanCheckboxes.map { cb -> String in
            let rpm = FanControl.actualRPM(cb.tag).map { "\($0)" } ?? "?"
            return names[cb.tag].isEmpty ? "\(rpm) RPM" : "\(names[cb.tag]) \(rpm) RPM"
        }
        fanStatusLabel.stringValue = "当前转速：" + parts.joined(separator: " · ")
    }

    @objc private func onFanCheckboxChanged(_ sender: NSButton) {
        guard !fanOperationInProgress else {
            sender.state = sender.state == .on ? .off : .on
            return
        }
        fanOperationInProgress = true
        let fan = sender.tag
        let enabled = sender.state == .on
        sender.isEnabled = false

        FanControl.applyFullSpeed(fan, enabled: enabled) { [weak self, weak sender] result in
            guard let self else { return }
            self.fanOperationInProgress = false
            sender?.isEnabled = true
            switch result {
            case .success:
                refreshFanRPM()  // 只刷新转速，不动复选框（系统已正确切换）
            case .failure(let error):
                sender?.state = enabled ? .off : .on  // 失败则回退
                if case .cancelled = error { return }
                let alert = NSAlert()
                alert.messageText = "无法控制风扇"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "确定")
                alert.runModal()
            }
        }
    }
    
    private func refreshValueLabels() {
        historyValueLabel.stringValue = "\(Int(historyAlphaSlider.doubleValue * 100))%"
        cardValueLabel.stringValue = "\(Int(cardAlphaSlider.doubleValue * 100))%"
    }
    
    // MARK: - 事件处理
    
    @objc private func onSliderChanged(_ sender: NSSlider) {
        if sender == historyAlphaSlider {
            AppearanceSettings.setHistoryBackgroundAlpha(sender.doubleValue)
        } else if sender == cardAlphaSlider {
            AppearanceSettings.setCardBackgroundAlpha(sender.doubleValue)
        }
        refreshValueLabels()
    }
    
    @objc private func onLaunchAtLoginChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        do {
            try FeatureSettings.setLaunchAtLogin(enabled)
        } catch {
            // 失败时恢复复选框状态
            sender.state = enabled ? .off : .on
            let alert = NSAlert()
            alert.messageText = "无法设置开机启动"
            alert.informativeText = "发生错误：\(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "确定")
            alert.runModal()
        }
    }
    
    @objc private func onOptionVAppClipboardChanged(_ sender: NSButton) {
        FeatureSettings.setEnableOptionVAppClipboard(sender.state == .on)
    }
    
    @objc private func onControlVSystemClipboardChanged(_ sender: NSButton) {
        FeatureSettings.setEnableControlVSystemClipboard(sender.state == .on)
    }
    
    @objc private func onReset() {
        AppearanceSettings.resetToDefaults()
        FeatureSettings.resetToDefaults()
        syncFromDefaults()
        // ponytail: 恢复默认=系统自动（取消满速）。先乐观取消勾选，避免末尾回读 SMC（切换滞后）把已发的 auto 指令又显示成勾选，导致要点两次
        for cb in fanCheckboxes { cb.state = .off }
        restoreNextFan()
    }

    /// 不读 SMC 状态，直接对所有风扇串行发送 auto 命令（已自动的重复发送无副作用）
    private func restoreNextFan(_ index: Int = 0) {
        guard !fanOperationInProgress, index < fanCheckboxes.count else {
            // ponytail: 末尾只刷新转速，不再回读 SMC 重置勾选状态（SMC 切换有滞后，回读会重新勾上导致要点两次）
            if index >= fanCheckboxes.count { refreshFanRPM() }
            return
        }
        let cb = fanCheckboxes[index]
        guard cb.isEnabled else {
            restoreNextFan(index + 1)
            return
        }
        fanOperationInProgress = true
        cb.isEnabled = false
        FanControl.applyFullSpeed(cb.tag, enabled: false) { [weak self, weak cb] result in
            DispatchQueue.main.async {
                cb?.isEnabled = true
                if case .success = result { cb?.state = .off }
                self?.fanOperationInProgress = false
                self?.restoreNextFan(index + 1)
            }
        }
    }
    
    @objc private func onClose() {
        window?.close()
    }
}
