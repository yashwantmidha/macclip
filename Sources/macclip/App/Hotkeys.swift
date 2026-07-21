import AppKit
import Carbon

enum HotkeyID {
    static let history: UInt32 = 1
    static let captureRegion: UInt32 = 2
    static let captureWindow: UInt32 = 3
    static let captureFullscreen: UInt32 = 4
    static let library: UInt32 = 5
}

struct HotkeyBinding {
    let id: UInt32
    let keyCode: UInt32
    let modifiers: UInt32
}

final class HotkeyManager {
    private static let signature: OSType = 0x4D434C50 // 'MCLP'

    var onHotkey: ((UInt32) -> Void)?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandlerRef: EventHandlerRef?

    func register(_ bindings: [HotkeyBinding]) {
        installHandlerIfNeeded()
        unregisterKeys()

        for binding in bindings {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: binding.id)
            RegisterEventHotKey(
                binding.keyCode,
                binding.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if let ref {
                hotKeyRefs.append(ref)
            }
        }
    }

    func unregisterAll() {
        unregisterKeys()
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
    }

    private func unregisterKeys() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else {
            return
        }

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let userData, let eventRef else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

                var hk = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hk
                )
                if status == noErr && hk.signature == HotkeyManager.signature {
                    manager.onHotkey?(hk.id)
                }
                return noErr
            },
            1,
            &eventSpec,
            selfPtr,
            &eventHandlerRef
        )
    }
}
