import Foundation

/// Lightweight file-based diagnostics for the recording pipeline.
/// Written to the app’s private tmp directory so failures can be diagnosed
/// without console access.
enum Diag {
    static let url = PathGuard.appTempDirectory.appendingPathComponent("plume-diagnostics.log")
    private static let queue = DispatchQueue(label: "com.plume.diag")

    static func log(_ msg: String) {
        queue.async {
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "\(stamp) \(msg)\n"
            if let h = FileHandle(forWritingAtPath: url.path) {
                h.seekToEndOfFile()
                try? h.write(contentsOf: line.data(using: .utf8) ?? Data())
                try? h.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}