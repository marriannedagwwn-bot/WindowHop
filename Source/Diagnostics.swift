import Foundation

/// Opt-in developer tracing. Never records text, window titles, or captured images.
enum Diagnostics {
    static let enabled = CommandLine.arguments.contains("--trace")
    static func log(_ message: String) {
        guard enabled else { return }
        let line = "[WindowHop \(Date().timeIntervalSince1970)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
