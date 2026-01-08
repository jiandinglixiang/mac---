import Cocoa

/// 外观/显示相关设置（透明度等）
enum AppearanceSettings {
    // UserDefaults keys
    static let historyBackgroundAlphaKey = "historyBackgroundAlpha"
    static let cardBackgroundAlphaKey = "cardBackgroundAlpha"
    
    /// 透明度取值范围：0.2 ~ 1.0（过低会影响可读性/可点击性）
    private static let minAlpha: Double = 0.2
    private static let maxAlpha: Double = 1.0
    
    static var historyBackgroundAlpha: CGFloat {
        CGFloat(clamp(UserDefaults.standard.double(forKey: historyBackgroundAlphaKey)))
    }
    
    static var cardBackgroundAlpha: CGFloat {
        CGFloat(clamp(UserDefaults.standard.double(forKey: cardBackgroundAlphaKey)))
    }
    
    static func setHistoryBackgroundAlpha(_ value: Double) {
        UserDefaults.standard.set(clamp(value), forKey: historyBackgroundAlphaKey)
        NotificationCenter.default.post(name: .appearanceSettingsDidChange, object: nil)
    }
    
    static func setCardBackgroundAlpha(_ value: Double) {
        UserDefaults.standard.set(clamp(value), forKey: cardBackgroundAlphaKey)
        NotificationCenter.default.post(name: .appearanceSettingsDidChange, object: nil)
    }
    
    static func resetToDefaults() {
        // 这里不直接 removeObject，以避免 register(defaults:) 不生效时出现 0 值
        setHistoryBackgroundAlpha(0.9)
        setCardBackgroundAlpha(0.85)
    }
    
    private static func clamp(_ value: Double) -> Double {
        min(max(value, minAlpha), maxAlpha)
    }
}

extension Notification.Name {
    static let appearanceSettingsDidChange = Notification.Name("appearanceSettingsDidChange")
}

