import Foundation
import CoreGraphics
import IOKit.pwr_mgt

/// Save before changing; keep the snapshot if restoration fails, including across app restarts.
final class LowPowerSession {
    private let defaults: UserDefaults
    private let key = "travelBatteryPowerMode"
    private let appliedKey = "travelBatteryAppliedPowerMode"
    var readMode: () -> Int? = batteryPowerMode
    var writeMode: (Int) -> String? = setBatteryPowerMode

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func setEnabled(_ enabled: Bool, lidClosed: Bool = false) -> String? {
        if enabled {
            guard let current = readMode() else { return "배터리 전원 설정을 읽을 수 없음" }
            if defaults.object(forKey: key) == nil {
                defaults.set(current, forKey: key)
                defaults.synchronize()
            }
            let original = defaults.integer(forKey: key)
            let target = lidClosed ? 1 : (original == 1 ? 0 : original)
            if current == target { return nil }
            if let error = writeMode(target) { return error }
            defaults.set(target, forKey: appliedKey)
            defaults.synchronize()
            return nil
        }
        guard let original = defaults.object(forKey: key) as? Int else { return nil }
        guard let current = readMode() else { return "배터리 전원 설정 복원 대기" }
        // v0.6 snapshots had no applied mode and always requested low power (1).
        let applied = defaults.object(forKey: appliedKey) as? Int ?? 1
        // A newer manual choice wins over our saved setting.
        if current == applied, current != original, let error = writeMode(original) { return error }
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: appliedKey)
        return nil
    }
}

// shortcut: Apple Silicon brightness uses a private API; report failure if a macOS update removes it.
private let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
private let getBrightness: (@convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32)? = {
    guard let h = displayServices, let s = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
    return unsafeBitCast(s, to: (@convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32).self)
}()
private let setBrightness: (@convention(c) (UInt32, Float) -> Int32)? = {
    guard let h = displayServices, let s = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
    return unsafeBitCast(s, to: (@convention(c) (UInt32, Float) -> Int32).self)
}()

func builtinBrightness() -> Float? {
    guard let display = onlineDisplays().first(where: { CGDisplayIsBuiltin($0) != 0 }), let get = getBrightness else { return nil }
    var value: Float = 0
    guard get(display, &value) == 0, value.isFinite, (0...1).contains(value) else { return nil }
    return value
}

private func setBuiltinBrightness(_ value: Float) -> Bool {
    guard value.isFinite, (0...1).contains(value), let display = onlineDisplays().first(where: { CGDisplayIsBuiltin($0) != 0 }), let set = setBrightness else { return false }
    return set(display, value) == 0
}

final class TravelDisplay {
    private let defaults: UserDefaults
    private let key = "travelDisplayBrightness"
    private var assertion: IOPMAssertionID = 0
    var readBrightness: () -> Float? = builtinBrightness
    var writeBrightness: (Float) -> Bool = setBuiltinBrightness

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func holdAwake(_ enabled: Bool) -> String? {
        if enabled, assertion == 0 {
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Jungwook's Mac Utility 이동 모드" as CFString, &assertion)
            if result != kIOReturnSuccess { assertion = 0; return "이동 모드 화면 절전 방지 실패" }
        } else if !enabled, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        return nil
    }

    /// Brightness zero keeps the session usable; display sleep would trigger macOS password-on-wake.
    func dim(_ enabled: Bool) -> String? {
        if enabled {
            guard let current = readBrightness() else { return "내장 화면 밝기를 읽을 수 없음" }
            if defaults.object(forKey: key) == nil {
                defaults.set(current, forKey: key)
                defaults.synchronize()
            }
            if current == 0 { return nil }
            guard writeBrightness(0) else { return "내장 화면 밝기 0 설정 실패" }
            trace("travel display: brightness=0")
        } else {
            guard let original = defaults.object(forKey: key) as? Float else { return nil }
            guard writeBrightness(original) else { return "내장 화면 밝기 복원 대기" }
            defaults.removeObject(forKey: key)
            trace("travel display: brightness restored=\(original)")
        }
        return nil
    }
}
