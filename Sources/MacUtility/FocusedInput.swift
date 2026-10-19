import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Focus notifications replace repeated eligibility reads while an IME is composing.
final class FocusedInputWatcher {
    private var observer: AXObserver?
    private var application: AXUIElement?
    private var pid: pid_t?
    private let changed: (AXUIElement) -> Void

    init(changed: @escaping (AXUIElement) -> Void) { self.changed = changed }

    func watch(_ pid: pid_t) -> Bool {
        if self.pid == pid { return observer != nil }
        stop()
        self.pid = pid
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        var candidate: AXObserver?
        guard AXObserverCreate(pid, { observer, element, _, context in
            guard let context else { return }
            let watcher = Unmanaged<FocusedInputWatcher>.fromOpaque(context).takeUnretainedValue()
            guard let current = watcher.observer, CFEqual(current, observer) else { return }
            watcher.changed(element)
        }, &candidate) == .success, let candidate,
              AXObserverAddNotification(candidate, app, kAXFocusedUIElementChangedNotification as CFString,
                                        Unmanaged.passUnretained(self).toOpaque()) == .success else { return false }
        observer = candidate; application = app
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(candidate), .commonModes)
        return true
    }

    func stop() {
        let old = observer
        observer = nil; pid = nil
        guard let old else { return }
        if let application {
            AXObserverRemoveNotification(old, application, kAXFocusedUIElementChangedNotification as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .commonModes)
        application = nil
    }

    deinit { stop() }
}

struct FocusedInput {
    let element: AXUIElement
    let text: String

    // shortcut: refuse unusually large editors rather than truncate them; revisit for document mirroring.
    static let limit = 65_536
    private static let queue = DispatchQueue(label: "MacUtility.focused-input", qos: .utility)

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func editable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }

    static func read(_ element: AXUIElement,
                     includeText: Bool = true,
                     copy: (AXUIElement, String) -> CFTypeRef? = attribute,
                     canEdit: (AXUIElement) -> Bool = editable) -> FocusedInput? {
        guard let role = copy(element, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              copy(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole,
              (copy(element, kAXEnabledAttribute) as? Bool) != false, canEdit(element) else { return nil }
        guard includeText else { return FocusedInput(element: element, text: "") }
        if let count = copy(element, kAXNumberOfCharactersAttribute) as? Int, count > limit { return nil }
        guard let text = copy(element, kAXValueAttribute) as? String, text.utf16.count <= limit else { return nil }
        return FocusedInput(element: element, text: text)
    }

    static func fetch(includeText: Bool = true, _ completion: @escaping (FocusedInput?) -> Void) -> DispatchWorkItem? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != getpid() else {
            completion(nil); return nil
        }
        let work = DispatchWorkItem {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.08)
            var result: FocusedInput?
            if !IsSecureEventInputEnabled(), let value = attribute(app, kAXFocusedUIElementAttribute),
               CFGetTypeID(value) == AXUIElementGetTypeID() {
                let element = value as! AXUIElement
                AXUIElementSetMessagingTimeout(element, 0.08)
                result = read(element, includeText: includeText)
                // A focus change during the read must not publish the previous field.
                guard let current = attribute(app, kAXFocusedUIElementAttribute), CFEqual(current, element) else {
                    DispatchQueue.main.async { completion(nil) }; return
                }
            }
            DispatchQueue.main.async {
                completion(!IsSecureEventInputEnabled() && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid ? result : nil)
            }
        }
        queue.async(execute: work)
        return work
    }
}
