import Foundation

/// Spike only: can the sandboxed extension run the bundled helper and
/// lyrebird? Sends hello to the helper and logs the reply; runs lyrebird
/// with -version and logs its exit status.
enum SpikeHelperCheck {
    static func run() {
        DispatchQueue.global().async {
            helper()
            lyrebird()
        }
    }

    private static func helper() {
        guard let url = Bundle.main.url(forAuxiliaryExecutable: "tortuga-helper") else {
            spikeLog.error("spike: no tortuga-helper in the bundle")
            return
        }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = url
        process.standardInput = input
        process.standardOutput = output
        process.environment = ["TORTUGA_DATA_DIR": NSTemporaryDirectory() + "tortuga-spike",
                               "TORTUGA_PT_DIR": Bundle.main.resourceURL?.appending(path: "pt").path ?? ""]
        do {
            try process.run()
        } catch {
            spikeLog.error("spike: helper didn't start: \(error.localizedDescription, privacy: .public)")
            return
        }
        let hello = Data(#"{"id":1,"type":"hello","payload":{"protocol":1}}"#.utf8)
        var length = UInt32(hello.count).littleEndian
        input.fileHandleForWriting.write(Data(bytes: &length, count: 4) + hello)
        let head = output.fileHandleForReading.readData(ofLength: 4)
        guard head.count == 4 else {
            spikeLog.error("spike: helper closed without answering")
            return
        }
        let size = head.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        let body = output.fileHandleForReading.readData(ofLength: size)
        spikeLog.notice("spike: helper said \(String(decoding: body, as: UTF8.self), privacy: .public)")
        process.terminate()
    }

    private static func lyrebird() {
        guard let resources = Bundle.main.resourceURL else { return }
        let process = Process()
        process.executableURL = resources.appending(path: "pt/lyrebird")
        process.arguments = ["-version"]
        process.standardOutput = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            spikeLog.notice("spike: lyrebird -version exited \(process.terminationStatus)")
        } catch {
            spikeLog.error("spike: lyrebird didn't start: \(error.localizedDescription, privacy: .public)")
        }
    }
}
