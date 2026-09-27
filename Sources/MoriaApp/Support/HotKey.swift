import Carbon.HIToolbox
import Foundation

/// Global keyboard shortcut via Carbon `RegisterEventHotKey`, which (unlike an event tap)
/// needs no Accessibility permission.
@MainActor
final class HotKey {
    /// The shortcuts offered in Settings.
    enum Choice: String, CaseIterable, Identifiable {
        case controlOptionSpace, optionSpace, commandShiftSpace, controlSpace, optionCommandM, none

        var id: String { rawValue }

        var label: String {
            switch self {
            case .controlOptionSpace: "⌃⌥Space"
            case .optionSpace: "⌥Space"
            case .commandShiftSpace: "⇧⌘Space"
            case .controlSpace: "⌃Space"
            case .optionCommandM: "⌥⌘M"
            case .none: "None"
            }
        }

        var keyCode: UInt32 {
            self == .optionCommandM ? UInt32(kVK_ANSI_M) : UInt32(kVK_Space)
        }

        var modifiers: UInt32 {
            switch self {
            case .controlOptionSpace: UInt32(controlKey | optionKey)
            case .optionSpace: UInt32(optionKey)
            case .commandShiftSpace: UInt32(cmdKey | shiftKey)
            case .controlSpace: UInt32(controlKey)
            case .optionCommandM: UInt32(optionKey | cmdKey)
            case .none: 0
            }
        }
    }

    enum HotKeyError: Error, CustomStringConvertible {
        case registrationFailed(OSStatus)

        var description: String {
            switch self {
            case let .registrationFailed(status):
                status == eventHotKeyExistsErr
                    ? "That shortcut is already used by another app."
                    : "The shortcut could not be registered (error \(status))."
            }
        }
    }

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func register(_ choice: Choice) throws {
        unregister()
        guard choice != .none else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &eventType, context, &handlerRef)
        guard installStatus == noErr else { throw HotKeyError.registrationFailed(installStatus) }
        let id = EventHotKeyID(signature: OSType(0x4D4F5249), id: 1)  // "MORI"
        let status = RegisterEventHotKey(choice.keyCode, choice.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else {
            unregister()
            throw HotKeyError.registrationFailed(status)
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}
