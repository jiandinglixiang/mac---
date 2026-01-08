import Cocoa
import Carbon

class KeyboardShortcutManager {
    private var eventHotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var callback: (() -> Void)?
    
    func registerHotKey(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, callback: @escaping () -> Void) {
        self.callback = callback
        
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = UTGetOSTypeFromString("CLIP" as CFString)
        hotKeyID.id = 1
        
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
        let status = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &eventHotKeyRef
        )
        
        if status != noErr {
            print("注册快捷键失败: \(status)")
            return
        }
        
        // 安装事件处理器
        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)
        
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { (nextHandler, theEvent, userData) -> OSStatus in
                if let userData = userData {
                    let manager = Unmanaged<KeyboardShortcutManager>.fromOpaque(userData).takeUnretainedValue()
                    manager.callback?()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        
        print("快捷键已注册")
    }
    
    func unregisterHotKey() {
        if let hotKeyRef = eventHotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        
        if let handler = eventHandler {
            RemoveEventHandler(handler)
        }
        
        print("快捷键已注销")
    }
    
    deinit {
        unregisterHotKey()
    }
}
