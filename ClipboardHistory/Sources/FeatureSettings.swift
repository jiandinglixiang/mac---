import Foundation
import ServiceManagement

/// 功能开关相关设置（独立于外观设置）
enum FeatureSettings {
    // MARK: - UserDefaults Keys
    
    /// 是否启用：⌥V 唤起本应用剪贴板历史窗口
    static let enableOptionVAppClipboardKey = "enableOptionVAppClipboard"
    
    /// 是否启用：⌃V 触发系统剪贴板（⌘Space → 延迟 → ⌘4）
    static let enableControlVSystemClipboardKey = "enableControlVSystemClipboard"
    
    /// 旧版迁移标记
    private static let migrationKey = "hasMigratedFeatureSettingsV2"
    
    // MARK: - 快捷键开关 Getters
    
    static var enableOptionVAppClipboard: Bool {
        UserDefaults.standard.bool(forKey: enableOptionVAppClipboardKey)
    }
    
    static var enableControlVSystemClipboard: Bool {
        UserDefaults.standard.bool(forKey: enableControlVSystemClipboardKey)
    }
    
    // MARK: - 快捷键开关 Setters
    
    static func setEnableOptionVAppClipboard(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enableOptionVAppClipboardKey)
        NotificationCenter.default.post(name: .featureSettingsDidChange, object: nil)
    }
    
    static func setEnableControlVSystemClipboard(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enableControlVSystemClipboardKey)
        NotificationCenter.default.post(name: .featureSettingsDidChange, object: nil)
    }
    
    // MARK: - 开机启动 (SMAppService)
    
    /// 是否在登录时启动应用（读取 SMAppService 状态）
    static var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }
    
    /// 设置开机启动状态
    /// - Parameter enabled: 是否启用
    /// - Throws: SMAppService 注册/注销错误
    static func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
    
    // MARK: - 旧版设置迁移
    
    /// 将旧版 `enableOptionVSystemClipboard` 迁移到新版 `enableControlVSystemClipboard`
    /// 应在 UserDefaults.register(defaults:) 之前调用
    static func migrateLegacyKeys() {
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        
        let legacyKey = "enableOptionVSystemClipboard"
        
        // 检查旧 key 是否存在
        if UserDefaults.standard.object(forKey: legacyKey) != nil {
            let oldValue = UserDefaults.standard.bool(forKey: legacyKey)
            // 旧 ⌥V 系统剪贴板功能 -> 新 ⌃V 系统剪贴板（相同功能，快捷键变更）
            if oldValue {
                UserDefaults.standard.set(true, forKey: enableControlVSystemClipboardKey)
            }
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
        
        UserDefaults.standard.set(true, forKey: migrationKey)
    }
    
    // MARK: - 重置
    
    static func resetToDefaults() {
        setEnableOptionVAppClipboard(true)
        setEnableControlVSystemClipboard(false)
        // 注意：不重置 launchAtLogin，因为它是系统级设置
    }
}

extension Notification.Name {
    static let featureSettingsDidChange = Notification.Name("featureSettingsDidChange")
}
