import Cocoa
import Carbon

class KeyboardShortcutManager {
    private var eventHandler: EventHandlerRef?
    
    /// HotKey ID -> EventHotKeyRef
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    /// HotKey ID -> callback
    private var callbacks: [UInt32: () -> Void] = [:]
    
    private let signature: OSType = UTGetOSTypeFromString("CLIP" as CFString)
    
    /// 兼容旧用法：默认 id = 1
    func registerHotKey(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, callback: @escaping () -> Void) {
        registerHotKey(id: 1, keyCode: keyCode, modifiers: modifiers, callback: callback)
    }
    
    /// 注册全局热键（支持多个 hotkey 并存）
    /// - Parameters:
    ///   - id: 用于区分不同热键回调的 ID（建议从 1 开始）
    ///   - keyCode: Carbon virtual keyCode，例如 `kVK_ANSI_V`
    ///   - modifiers: Cocoa modifier flags，例如 `[.command, .option]`
    func registerHotKey(id: UInt32, keyCode: UInt32, modifiers: NSEvent.ModifierFlags, callback: @escaping () -> Void) {
        // 若已存在同 id，先注销再注册，避免重复
        unregisterHotKey(id: id)
        callbacks[id] = callback
        
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = signature
        hotKeyID.id = id
        
        // 转换修饰键
        var carbonModifiers: UInt32 = 0
        if modifiers.contains(.command) {
            carbonModifiers |= UInt32(cmdKey)
        }
        if modifiers.contains(.shift) {
            carbonModifiers |= UInt32(shiftKey)
        }
        if modifiers.contains(.option) {
            carbonModifiers |= UInt32(optionKey)
        }
        if modifiers.contains(.control) {
            carbonModifiers |= UInt32(controlKey)
        }
        
        // 注册热键
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &newRef
        )
        
        if status != noErr {
            print("注册快捷键失败: \(status)")
            callbacks.removeValue(forKey: id)
            return
        }
        
        if let newRef {
            hotKeyRefs[id] = newRef
        }
        
        installEventHandlerIfNeeded()
        print("快捷键已注册 (id=\(id))")
    }
    
    func unregisterHotKey() {
        unregisterAllHotKeys()
    }
    
    func unregisterHotKey(id: UInt32) {
        if let ref = hotKeyRefs[id] {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeValue(forKey: id)
        callbacks.removeValue(forKey: id)
        
        // 没有任何热键时再卸载 handler
        if hotKeyRefs.isEmpty {
            uninstallEventHandlerIfNeeded()
        }
        
        print("快捷键已注销 (id=\(id))")
    }
    
    func unregisterAllHotKeys() {
        let ids = Array(hotKeyRefs.keys)
        for id in ids {
            unregisterHotKey(id: id)
        }
    }
    
    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        
        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)
        
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, theEvent, userData) -> OSStatus in
                guard let theEvent, let userData else { return noErr }
                
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    theEvent,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                
                guard status == noErr else { return noErr }
                
                let manager = Unmanaged<KeyboardShortcutManager>.fromOpaque(userData).takeUnretainedValue()
                manager.callbacks[hotKeyID.id]?()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }
    
    private func uninstallEventHandlerIfNeeded() {
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }
    
    deinit {
        unregisterAllHotKeys()
    }
}
