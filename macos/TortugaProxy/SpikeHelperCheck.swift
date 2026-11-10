import Foundation

/// Spike only: where can the sandboxed extension run the helper and lyrebird
/// from? sysextd strips the execute bit from everything in its installed copy
/// but the main executable, so three places are tried, each logged:
/// 1. the installed extension bundle (expected to fail);
/// 2. the app's copy of the extension in /Applications;
/// 3. a copy in the extension's own container, made executable.
enum SpikeHelperCheck {
    static func run() {
        DispatchQueue.global().async {
            let installed = Bundle.main.bundleURL
            let inApp = URL(fileURLWithPath: "/Applications/Tortuga.app/Contents/Library/SystemExtensions/org.tortuga.app.proxy.systemextension")
            attempt(label: "installed", bundle: installed)
            attempt(label: "app copy", bundle: inApp)
            tryContainerCopy(from: inApp)
        }
    }

    private static func attempt(label: String, bundle: URL) {
        let helper = bundle.appending(path: "Contents/MacOS/tortuga-helper")
        let pt = bundle.appending(path: "Contents/Resources/pt")
        hello(label: label, helper: helper, pt: pt)
        lyrebird(label: label, at: pt.appending(path: "lyrebird"))
    }

    private static func tryContainerCopy(from bundle: URL) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "tortuga-bin")
        do {
            try? fm.removeItem(at: dir)
            try fm.createDirectory(at: dir.appending(path: "pt"), withIntermediateDirectories: true)
            let helper = dir.appending(path: "tortuga-helper")
            try fm.copyItem(at: bundle.appending(path: "Contents/MacOS/tortuga-helper"), to: helper)
            for name in ["lyrebird", "pt_config.json"] {
                try fm.copyItem(at: bundle.appending(path: "Contents/Resources/pt/\(name)"), to: dir.appending(path: "pt/\(name)"))
            }
            for path in [helper.path, dir.appending(path: "pt/lyrebird").path] {
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            }
            spikeLog.notice("spike: container copy made at \(dir.path, privacy: .public)")
            hello(label: "container copy", helper: helper, pt: dir.appending(path: "pt"))
            lyrebird(label: "container copy", at: dir.appending(path: "pt/lyrebird"))
        } catch {
            spikeLog.error("spike: container copy failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func hello(label: String, helper: URL, pt: URL) {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = helper
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.environment = ["TORTUGA_DATA_DIR": NSTemporaryDirectory() + "tortuga-spike", "TORTUGA_PT_DIR": pt.path,
                               "RUST_BACKTRACE": "1", "HOME": NSHomeDirectory()]
        do {
            try process.run()
        } catch {
            spikeLog.error("spike: [\(label, privacy: .public)] helper didn't start: \(String(describing: error), privacy: .public)")
            return
        }
        let message = Data(#"{"id":1,"type":"hello","payload":{"protocol":1}}"#.utf8)
        var length = UInt32(message.count).littleEndian
        input.fileHandleForWriting.write(Data(bytes: &length, count: 4) + message)
        let head = output.fileHandleForReading.readData(ofLength: 4)
        guard head.count == 4 else {
            process.waitUntilExit()
            let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile().prefix(1500), as: UTF8.self)
            spikeLog.error("spike: [\(label, privacy: .public)] helper exited \(process.terminationStatus) (reason \(process.terminationReason.rawValue)) without answering; stderr: \(stderr, privacy: .public)")
            return
        }
        let size = head.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        let body = output.fileHandleForReading.readData(ofLength: size)
        spikeLog.notice("spike: [\(label, privacy: .public)] helper said \(String(decoding: body, as: UTF8.self), privacy: .public)")
        process.terminate()
    }

    private static func lyrebird(label: String, at url: URL) {
        let process = Process()
        process.executableURL = url
        process.arguments = ["-version"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            spikeLog.notice("spike: [\(label, privacy: .public)] lyrebird -version exited \(process.terminationStatus)")
        } catch {
            spikeLog.error("spike: [\(label, privacy: .public)] lyrebird didn't start: \(String(describing: error), privacy: .public)")
        }
    }
}
