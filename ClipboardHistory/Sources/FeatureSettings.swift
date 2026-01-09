import Foundation

/// 功能开关相关设置（独立于外观设置）
enum FeatureSettings {
    /// 是否启用：⌥V 触发 ⌘Space，然后延迟触发 ⌘4
    static let enableOptionVSystemClipboardKey = "enableOptionVSystemClipboard"
    
    static var enableOptionVSystemClipboard: Bool {
        UserDefaults.standard.bool(forKey: enableOptionVSystemClipboardKey)
    }
    
    static func setEnableOptionVSystemClipboard(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enableOptionVSystemClipboardKey)
        NotificationCenter.default.post(name: .featureSettingsDidChange, object: nil)
    }
    
    static func resetToDefaults() {
        setEnableOptionVSystemClipboard(false)
    }
}

extension Notification.Name {
    static let featureSettingsDidChange = Notification.Name("featureSettingsDidChange")
}

