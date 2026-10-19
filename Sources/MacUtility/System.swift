import Foundation
import IOKit
import IOKit.ps
import CoreGraphics
import ServiceManagement

@discardableResult
func shell(_ path: String, _ args: [String]) -> (status: Int32, out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let o = Pipe(), e = Pipe()
    p.standardOutput = o
    p.standardError = e
    do { try p.run() } catch { return (-1, "", "\(error)") }
    let od = o.fileHandleForReading.readDataToEndOfFile()
    let ed = e.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: od, as: UTF8.self), String(decoding: ed, as: UTF8.self))
}

func sleepDisabled() -> Bool { parseSleepDisabled(shell("/usr/bin/pmset", ["-g"]).out) }

/// nil = ok, otherwise a short message for the panel.
func setSleepDisabled(_ on: Bool) -> String? {
    let r = shell("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"])
    if r.status == 0 { return nil }
    return r.err.contains("password") ? "처음 한 번: setup-sudoers.sh 실행 필요" : "실패: " + r.err.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// True once setup-sudoers.sh ran (lists the allowed command without running it).
func setupDone() -> Bool {
    shell("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"]).status == 0
}

/// Bool property of IOPMrootDomain, nil if the key is absent.
func rootDomainBool(_ key: String) -> Bool? {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard svc != 0 else { return nil }
    defer { IOObjectRelease(svc) }
    return IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
}

func lidClosed() -> Bool { rootDomainBool("AppleClamshellState") ?? false }

func battery() -> (onBattery: Bool, percent: Int) {
    guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [AnyObject] else { return (false, 100) }
    for ps in list {
        guard let d = IOPSGetPowerSourceDescription(snap, ps)?.takeUnretainedValue() as? [String: Any],
              d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
        let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 100
        let mx = d[kIOPSMaxCapacityKey] as? Int ?? 100
        return (d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue, mx > 0 ? cur * 100 / mx : cur)
    }
    return (false, 100)
}

func screenLocked() -> Bool {
    (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
}

// MARK: displays

func onlineDisplays() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var n: UInt32 = 0
    guard CGGetOnlineDisplayList(16, &ids, &n) == .success else { return [] }
    return Array(ids.prefix(Int(n)))
}

/// An external display (or an AirPlay/Sidecar screen) means desk use: leave the screen alone when the lid closes.
func hasExternalDisplay() -> Bool { onlineDisplays().contains { CGDisplayIsBuiltin($0) == 0 } }

/// nil when the built-in display is not listed (for example switched off with the lid closed).
func builtinAsleep() -> Bool? {
    onlineDisplays().first { CGDisplayIsBuiltin($0) != 0 }.map { CGDisplayIsAsleep($0) != 0 }
}

func batteryPowerMode() -> Int? { parseBatteryPowerMode(shell("/usr/bin/pmset", ["-g", "custom"]).out) }

func setBatteryPowerMode(_ mode: Int) -> String? {
    guard (0...2).contains(mode) else { return "지원하지 않는 전원 모드" }
    let r = shell("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-b", "powermode", String(mode)])
    if r.status != 0 {
        let error = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
        return error.contains("password") || error.contains("not allowed") ? "저전력 권한: 절전 권한 설정.command 실행 필요" : "저전력 전환 실패: " + error
    }
    return batteryPowerMode() == mode ? nil : "저전력 설정 변경을 확인할 수 없음"
}

// MARK: fans (root helper installed by setup-sudoers.sh)

let fanHelper = "/Library/PrivilegedHelperTools/macutility-fan"

func fanStatus() -> [FanInfo] {
    FileManager.default.isExecutableFile(atPath: fanHelper) ? parseFanStatus(shell(fanHelper, ["status"]).out) : []
}

/// nil = ok, otherwise a short message for the panel.
func applyFan(_ m: FanMode) -> String? {
    guard FileManager.default.isExecutableFile(atPath: fanHelper) else { return "팬: setup-sudoers.sh 다시 실행 필요" }
    let r = shell("/usr/bin/sudo", ["-n", fanHelper, m.rawValue])
    if r.status == 0 { return nil }
    if r.err.contains("password") { return "처음 한 번: setup-sudoers.sh 실행 필요" }
    return "팬 실패: " + (r.err + r.out).trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: login item

func loginEnabled() -> Bool { SMAppService.mainApp.status == .enabled }

/// Registers the app as a login item. nil = enabled; otherwise a short message (the user may have switched it off in System Settings).
func enableLogin() -> String? {
    do { try SMAppService.mainApp.register() } catch { return "로그인 항목 실패: \(error.localizedDescription)" }
    return loginEnabled() ? nil : "시스템 설정 > 로그인 항목에서 Jungwook's Mac Utility 켜기"
}

// MARK: log

private let stamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

var traceTag = ""

func trace(_ s: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MacUtility.log")
    let line = Data("\(stamp.string(from: Date())) \(traceTag)\(s)\n".utf8)
    if let h = try? FileHandle(forWritingTo: url) {
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: line)
        try? h.close()
    } else {
        try? line.write(to: url)
    }
}

