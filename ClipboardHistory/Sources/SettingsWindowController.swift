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
    private var fanStateObserver: NSObjectProtocol?
    private let fanStatusLabel = NSTextField(labelWithString: "")
    private let fanReleaseCheckbox = NSButton(checkboxWithTitle: "合盖 / 锁屏 / 睡眠时恢复系统控制", target: nil, action: nil)
    private let fanReleaseHintLabel = NSTextField(labelWithString: "合盖、锁屏（黑屏）或系统睡眠前把风扇交还系统——风扇被强制时系统无法休眠；亮屏/解锁/唤醒后自动恢复提速")
    private let fanHintLabel = NSTextField(labelWithString: "勾选后目标转速为最高转速的 80%（非满速，兼顾散热与噪音）；首次勾选需管理员授权（Touch ID/密码），被系统回收时会自动补发")

    // MARK: - 初始化

    init() {
        let height: CGFloat = fanCount > 0 ? 560 : 400
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
        
        // 后台巡检器补发/放弃后同步界面
        fanStateObserver = NotificationCenter.default.addObserver(
            forName: .fanStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.syncFanSection() }
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        if let fanStateObserver { NotificationCenter.default.removeObserver(fanStateObserver) }
    }
    
    func show() {
        // isForced() 已正确区分 Mode 1/2（用户强制）vs Mode 3（系统接管），
        // 因此可以从 SMC 同步；同时交叉验证 RPM 防止误报。
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
        fanReleaseCheckbox.target = self
        fanReleaseCheckbox.action = #selector(onFanReleaseChanged(_:))
        fanReleaseHintLabel.font = .systemFont(ofSize: 11, weight: .regular)
        fanReleaseHintLabel.textColor = .secondaryLabelColor
        fanReleaseHintLabel.maximumNumberOfLines = 2
        fanReleaseHintLabel.preferredMaxLayoutWidth = 360
        fanReleaseHintLabel.lineBreakMode = .byWordWrapping
        fanHintLabel.maximumNumberOfLines = 3
        fanHintLabel.preferredMaxLayoutWidth = 360
        fanHintLabel.lineBreakMode = .byWordWrapping

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

            let names = fanCount >= 2 ? ["左风扇高速（80%）", "右风扇高速（80%）"] : ["风扇高速（80%）"]
            for i in 0..<min(fanCount, names.count) {
                let cb = NSButton(checkboxWithTitle: names[i], target: self, action: #selector(onFanCheckboxChanged(_:)))
                cb.tag = i
                fanCheckboxes.append(cb)
            }

            let fanStack = NSStackView(views: fanCheckboxes + [fanStatusLabel, fanHintLabel,
                                                               fanReleaseCheckbox, fanReleaseHintLabel])
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

    /// 以硬件真实状态刷新风扇区块：复选框 = SMC 模式位（Mode 1/2 才算手动，Mode 3=系统接管不算）。
    /// 实际转速只用于「是否还在爬升」的提示，不再反过来推翻复选框——风扇从怠速爬到目标
    /// 需要数秒，用瞬时 RPM 判定会把刚勾选上的状态误清掉。SMC 不可用时回退 UserDefaults。
    private func syncFanSection() {
        guard fanCount > 0 else { return }
        guard !fanOperationInProgress else { return }

        let names = fanCount >= 2 ? ["左", "右"] : [""]
        var parts: [String] = []
        var ramping: [String] = []

        for cb in fanCheckboxes {
            let fanIdx = cb.tag
            let rpmStr = FanControl.actualRPM(fanIdx).map { "\($0)" } ?? "?"
            let target = FanControl.targetRPM(fanIdx)

            if let forced = FanControl.isForced(fanIdx) {
                cb.state = forced ? .on : .off
                // 已手动但转速还没爬到目标的 60%：只是「加速中」，不是失效
                if forced,
                   let actual = FanControl.actualRPM(fanIdx),
                   let target, actual < Int(Double(target) * 0.6) {
                    let name = names.indices.contains(fanIdx) ? names[fanIdx] : ""
                    ramping.append(name.isEmpty ? "风扇" : "\(name)风扇")
                }
            } else {
                // SMC 不可用，回退到上次用户操作结果
                cb.state = UserDefaults.standard.bool(forKey: FanControl.enabledKey(fanIdx)) ? .on : .off
            }

            let name = names.indices.contains(fanIdx) && !names[fanIdx].isEmpty ? "\(names[fanIdx]) " : ""
            let targetStr = target.map { " / 目标 \($0)" } ?? ""
            parts.append("\(name)\(rpmStr)\(targetStr) RPM")
        }

        var status = "当前转速：" + parts.joined(separator: " · ")
        if !ramping.isEmpty {
            status += "（\(ramping.joined(separator: "、"))加速中）"
        }
        // 挂起期间硬件确实已回到自动，复选框会显示为未勾选，这里说明原因避免误解
        if FanSupervisor.shared.isSuspended {
            let reason: String
            switch FanSupervisor.shared.suspendReason {
            case .lid:          reason = "合盖中"
            case .displayOff:   reason = "屏幕已关闭"
            case .screenLocked: reason = "已锁屏"
            case .systemSleep:  reason = "睡眠中"
            case .none:         reason = "已暂停"
            }
            status += "（\(reason)，已交还系统控制）"
        }
        fanStatusLabel.stringValue = status
        fanReleaseCheckbox.state = FeatureSettings.fanReleaseWhenClosed ? .on : .off
    }

    @objc private func onFanReleaseChanged(_ sender: NSButton) {
        FeatureSettings.setFanReleaseWhenClosed(sender.state == .on)
        syncFanSection()
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

        FanControl.apply(fan, boost: enabled) { [weak self, weak sender] result in
            guard let self else { return }
            self.fanOperationInProgress = false
            sender?.isEnabled = true
            switch result {
            case .success:
                // 持久化用户意图（SMC 不可用时的回退 + 巡检器据此补发）
                FanSupervisor.shared.setBoosted(fan, enabled)
                self.syncFanSection()  // 重新从 SMC 读取模式位
                // 转速爬到目标需要几秒，延后刷新一次数值显示
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                    self?.syncFanSection()
                }
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
        // 恢复默认 = 系统自动（取消提速）
        for cb in fanCheckboxes {
            cb.state = .off
            FanSupervisor.shared.setBoosted(cb.tag, false)
        }
        restoreNextFan()
    }

    /// 不读 SMC 状态，直接对所有风扇串行发送 auto 命令（已自动的重复发送无副作用）
    private func restoreNextFan(_ index: Int = 0) {
        guard !fanOperationInProgress, index < fanCheckboxes.count else {
            if index >= fanCheckboxes.count { refreshFanRPM() }
            return
        }
        let cb = fanCheckboxes[index]
        let fanIdx = cb.tag
        guard cb.isEnabled else {
            restoreNextFan(index + 1)
            return
        }
        fanOperationInProgress = true
        cb.isEnabled = false
        FanControl.apply(fanIdx, boost: false) { [weak self, weak cb] result in
            DispatchQueue.main.async {
                cb?.isEnabled = true
                if case .success = result {
                    cb?.state = .off
                    FanSupervisor.shared.setBoosted(fanIdx, false)
                }
                self?.fanOperationInProgress = false
                self?.restoreNextFan(index + 1)
            }
        }
    }
    
    @objc private func onClose() {
        window?.close()
    }
}
