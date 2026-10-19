import AppKit

let args = CommandLine.arguments
if args.contains("--selftest") { selfTest() }
if args.contains("--benchmark-memes") { benchmarkMemes(anchorsOnly: args.contains("--anchors-only")) }

let app = NSApplication.shared
if let i = args.firstIndex(of: "--render-island-test"), i + 1 < args.count { renderIslandTest(args[i + 1]) }
let delegate = AppDelegate()
if let i = args.firstIndex(of: "--smoke") {
    delegate.smokePNG = i + 1 < args.count ? args[i + 1] : "/tmp/macutility-panel.png"
}
if args.contains("--layout-test") { delegate.layoutTestMode = true }
app.delegate = delegate
app.run()

