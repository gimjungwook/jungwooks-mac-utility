import Foundation
import IOKit

// Root helper for fan control, run through a narrow sudoers rule (see setup-sudoers.sh).
// Accepts only: status | auto | 4000 | max. Reads need no root, writes do. Every write is read back.

private func fcc(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

private struct Ver { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
private struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
private struct KInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var attr: UInt8 = 0, p1: UInt8 = 0, p2: UInt8 = 0, p3: UInt8 = 0 }
private typealias Bytes32 = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                             UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

// 80-byte AppleSMC user-client struct; the layout was checked by reading fan keys on this M1 Max.
private struct Param {
    var key: UInt32 = 0
    var vers = Ver()
    var pl = PLimit()
    var ki = KInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes32 = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private final class SMC {
    private var conn: io_connect_t = 0

    init?() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
    }

    deinit { IOServiceClose(conn) }

    private func call(_ i: inout Param) -> Param? {
        var o = Param()
        var outSize = MemoryLayout<Param>.stride
        let r = IOConnectCallStructMethod(conn, 2, &i, MemoryLayout<Param>.stride, &o, &outSize)
        return r == KERN_SUCCESS ? o : nil
    }

    private func keySize(_ key: String) -> UInt32? {
        var i = Param(); i.key = fcc(key); i.data8 = 9
        guard let o = call(&i), o.result == 0 else { return nil }
        return o.ki.dataSize
    }

    func read(_ key: String) -> [UInt8]? {
        guard let n = keySize(key) else { return nil }
        var i = Param(); i.key = fcc(key); i.ki.dataSize = n; i.data8 = 5
        guard let o = call(&i), o.result == 0 else { return nil }
        return withUnsafeBytes(of: o.bytes) { Array($0.prefix(Int(n))) }
    }

    private func writeOnce(_ key: String, _ data: [UInt8]) -> Bool {
        guard let n = keySize(key), Int(n) == data.count else { return false }
        var i = Param(); i.key = fcc(key); i.ki.dataSize = n; i.data8 = 6
        withUnsafeMutableBytes(of: &i.bytes) { p in for (k, b) in data.enumerated() { p[k] = b } }
        guard let o = call(&i) else { return false }
        return o.result == 0
    }

    /// The SMC can reject a write transiently; retry like other open-source fan tools do.
    func write(_ key: String, _ data: [UInt8]) -> Bool {
        for attempt in 0..<10 {
            if writeOnce(key, data) { return true }
            if attempt < 9 { usleep(50_000) }
        }
        return false
    }
}

private func f32(_ b: [UInt8]) -> Float? {
    guard b.count == 4 else { return nil }
    return Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
}

private func enc(_ v: Float) -> [UInt8] {
    let u = v.bitPattern
    return [UInt8(u & 255), UInt8((u >> 8) & 255), UInt8((u >> 16) & 255), UInt8((u >> 24) & 255)]
}

struct Fan { var actual: Float; var mn: Float; var mx: Float; var target: Float; var mode: UInt8 }

/// Some newer Macs name the mode key F0md instead of F0Md.
private func modeKey(_ smc: SMC, _ i: Int) -> String { smc.read("F\(i)Md") != nil ? "F\(i)Md" : "F\(i)md" }

private func readFans(_ smc: SMC, _ n: Int) -> [Fan] {
    (0..<n).map { i in
        func f(_ s: String) -> Float { f32(smc.read("F\(i)\(s)") ?? []) ?? 0 }
        return Fan(actual: f("Ac"), mn: f("Mn"), mx: f("Mx"), target: f("Tg"), mode: smc.read(modeKey(smc, i))?.first ?? 255)
    }
}

private func printFans(_ fans: [Fan]) {
    print("fans=\(fans.count)")
    for (i, f) in fans.enumerated() {
        print(String(format: "fan%d actual=%.1f min=%.0f max=%.0f target=%.0f mode=%d", i, Double(f.actual), Double(f.mn), Double(f.mx), Double(f.target), Int(f.mode)))
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 1, ["status", "auto", "4000", "max", "selftest"].contains(args[0]) else {
    fputs("usage: macutility-fan status|auto|4000|max\n", stderr)
    exit(64)
}
let cmd = args[0]

if cmd == "selftest" {
    var bad = 0
    func check(_ ok: Bool, _ what: String) { print(ok ? "ok    " : "FAIL  ", what); if !ok { bad += 1 } }
    check(enc(4000) == [0x00, 0x00, 0x7A, 0x45], "4000.0 encodes as little-endian float")
    check(f32(enc(5348)) == 5348, "float round trip")
    check(f32([1, 2, 3]) == nil, "wrong size rejected")
    check(fcc("F0Md") == 0x46304D64, "four-char key")
    if let smc = SMC() {
        let n = Int(smc.read("FNum")?.first ?? 0)
        check(n > 0, "SMC readable, fans=\(n)")
        printFans(readFans(smc, n))
    } else {
        check(false, "SMC open")
    }
    exit(bad == 0 ? 0 : 1)
}

guard let smc = SMC() else { fputs("SMC를 열 수 없음\n", stderr); exit(2) }
let n = Int(smc.read("FNum")?.first ?? 0)
guard n > 0 else { fputs("팬을 찾을 수 없음\n", stderr); exit(3) }

if cmd == "status" { printFans(readFans(smc, n)); exit(0) }

guard geteuid() == 0 else { fputs("root 필요: sudo로 실행\n", stderr); exit(77) }

func wanted(_ f: Fan) -> Float { cmd == "max" ? f.mx : min(max(4000, f.mn), f.mx) }

var ok = true
for (i, f) in readFans(smc, n).enumerated() {
    let mk = modeKey(smc, i)
    if cmd == "auto" {
        ok = smc.write(mk, [0]) && smc.write("F\(i)Tg", enc(0)) && ok
    } else {
        guard f.mx > 0 else { fputs("fan\(i): 최대 rpm을 읽을 수 없음\n", stderr); exit(4) }
        ok = smc.write(mk, [1]) && smc.write("F\(i)Tg", enc(wanted(f))) && ok
    }
}
usleep(300_000)
let after = readFans(smc, n)
printFans(after)
let verified = after.allSatisfy { cmd == "auto" ? $0.mode == 0 : ($0.mode == 1 && abs($0.target - wanted($0)) < 1) }
exit(ok && verified ? 0 : 5)

