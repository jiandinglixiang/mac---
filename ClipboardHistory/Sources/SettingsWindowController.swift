import Cocoa

/// 简单设置面板：历史窗口背景透明度、卡片背景透明度
final class SettingsWindowController: NSWindowController {
    private let historyAlphaSlider = NSSlider(value: 0.9, minValue: 0.2, maxValue: 1.0, target: nil, action: nil)
    private let cardAlphaSlider = NSSlider(value: 0.85, minValue: 0.2, maxValue: 1.0, target: nil, action: nil)
    
    private let historyValueLabel = NSTextField(labelWithString: "")
    private let cardValueLabel = NSTextField(labelWithString: "")
    
    private let optionVSystemClipboardCheckbox = NSButton(checkboxWithTitle: "启用 ⌥V 打开系统剪贴板", target: nil, action: nil)
    private let optionVSystemClipboardHintLabel = NSTextField(labelWithString: "触发顺序：⌘Space →（延迟）→ ⌘4")
    
    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
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
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
    
    private func setupUI(in panel: NSPanel) {
        let root = NSView(frame: panel.contentView?.bounds ?? .zero)
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = root
        
        let title = NSTextField(labelWithString: "外观")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        
        let featureTitle = NSTextField(labelWithString: "功能")
        featureTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        
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
        
        optionVSystemClipboardCheckbox.target = self
        optionVSystemClipboardCheckbox.action = #selector(onOptionVSystemClipboardChanged(_:))
        
        optionVSystemClipboardHintLabel.font = .systemFont(ofSize: 11, weight: .regular)
        optionVSystemClipboardHintLabel.textColor = .secondaryLabelColor
        
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
        
        let resetButton = NSButton(title: "恢复默认", target: self, action: #selector(onReset))
        resetButton.bezelStyle = .rounded
        
        let closeButton = NSButton(title: "关闭", target: self, action: #selector(onClose))
        closeButton.bezelStyle = .rounded
        
        let buttons = NSStackView(views: [resetButton, closeButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.distribution = .gravityAreas
        buttons.spacing = 10
        
        let featureStack = NSStackView(views: [optionVSystemClipboardCheckbox, optionVSystemClipboardHintLabel])
        featureStack.orientation = .vertical
        featureStack.alignment = .leading
        featureStack.spacing = 6
        
        let stack = NSStackView(views: [title, historyRow, cardRow, featureTitle, featureStack, buttons])
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
    
    private func syncFromDefaults() {
        historyAlphaSlider.doubleValue = Double(AppearanceSettings.historyBackgroundAlpha)
        cardAlphaSlider.doubleValue = Double(AppearanceSettings.cardBackgroundAlpha)
        optionVSystemClipboardCheckbox.state = FeatureSettings.enableOptionVSystemClipboard ? .on : .off
        refreshValueLabels()
    }
    
    private func refreshValueLabels() {
        historyValueLabel.stringValue = "\(Int(historyAlphaSlider.doubleValue * 100))%"
        cardValueLabel.stringValue = "\(Int(cardAlphaSlider.doubleValue * 100))%"
    }
    
    @objc private func onSliderChanged(_ sender: NSSlider) {
        if sender == historyAlphaSlider {
            AppearanceSettings.setHistoryBackgroundAlpha(sender.doubleValue)
        } else if sender == cardAlphaSlider {
            AppearanceSettings.setCardBackgroundAlpha(sender.doubleValue)
        }
        refreshValueLabels()
    }
    
    @objc private func onReset() {
        AppearanceSettings.resetToDefaults()
        FeatureSettings.resetToDefaults()
        syncFromDefaults()
    }
    
    @objc private func onClose() {
        window?.close()
    }
    
    @objc private func onOptionVSystemClipboardChanged(_ sender: NSButton) {
        FeatureSettings.setEnableOptionVSystemClipboard(sender.state == .on)
    }
}

