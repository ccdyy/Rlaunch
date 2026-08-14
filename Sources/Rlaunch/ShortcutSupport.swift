import Cocoa
import Carbon.HIToolbox
import RlaunchCore

// MARK: - 全局快捷键（Carbon RegisterEventHotKey，无需辅助功能权限）

final class HotKeyMonitor {
    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private static let signature = OSType(0x524C_6E63) // 'RLnc'
    private static let hotKeyID = UInt32(1)

    /// 按配置注册/注销；组合键不可用（如被系统占用）时返回 false
    @discardableResult
    func apply(config: AppConfig) -> Bool {
        stop()
        guard config.hotKeyEnabled, let keyCode = config.hotKeyKeyCode else { return true }
        return start(keyCode: UInt32(keyCode), modifiers: UInt32(config.hotKeyModifiers))
    }

    @discardableResult
    private func start(keyCode: UInt32, modifiers: UInt32) -> Bool {
        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("Rlaunch: 注册全局快捷键失败（status=%d，可能已被占用）", status)
            return false
        }
        hotKeyRef = ref

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let handler: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let s = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &id)
            guard s == noErr, id.signature == HotKeyMonitor.signature, id.id == HotKeyMonitor.hotKeyID else {
                return OSStatus(eventNotHandledErr)
            }
            let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { monitor.onTrigger?() }
            return noErr
        }
        InstallEventHandler(
            GetEventDispatcherTarget(), handler, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        return true
    }

    func stop() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}

// MARK: - 快捷键显示与修饰键转换

enum ShortcutFormatter {
    /// Carbon 修饰键位 → 显示串（macOS 惯例顺序：⌃ ⌥ ⇧ ⌘）
    static func modifierSymbols(carbonModifiers: Int) -> String {
        var s = ""
        if carbonModifiers & Int(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & Int(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & Int(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & Int(cmdKey) != 0 { s += "⌘" }
        return s
    }

    /// 完整快捷键显示串（如「⌘⇧Space」）；未录制时返回「未设置」
    static func displayString(keyCode: Int?, carbonModifiers: Int) -> String {
        guard let keyCode else { return "未设置" }
        return modifierSymbols(carbonModifiers: carbonModifiers) + keyDisplayString(forKeyCode: UInt16(keyCode))
    }

    /// NSEvent 修饰键 → Carbon 修饰键位
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    /// 按键名（按当前键盘布局翻译；无字符的键回退到固定名称）
    static func keyDisplayString(forKeyCode keyCode: UInt16) -> String {
        if let ch = translatedCharacter(forKeyCode: keyCode) { return ch }
        switch Int(keyCode) {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "Esc"
        case 71: return "Clear"
        case 76: return "⌤"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 105: return "F13"
        case 107: return "F14"
        case 109: return "F10"
        case 111: return "F12"
        case 113: return "F15"
        case 114: return "Help"
        case 115: return "Home"
        case 116: return "PageUp"
        case 117: return "⌦"
        case 118: return "F4"
        case 119: return "End"
        case 120: return "F2"
        case 121: return "PageDown"
        case 122: return "F1"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return "Key\(keyCode)"
        }
    }

    /// 用 UCKeyTranslate 按当前输入源把 keyCode 翻译为可显示字符（大写）
    private static func translatedCharacter(forKeyCode keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let dataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(dataPointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            layout,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysMask),
            &deadKeyState,
            chars.count,
            &length,
            &chars)
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}
