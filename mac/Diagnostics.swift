import Foundation
import OSLog

final class Diagnostics {
    static let shared = Diagnostics()
    private let queue = DispatchQueue(label: "com.stanislav1342.conector-m-w.diagnostics")
    private let logger = Logger(subsystem: "com.stanislav1342.conector-m-w", category: "diagnostics")
    private let clock = ISO8601DateFormatter()
    let file: URL
    private let limit = 256 * 1024

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Conector-M-W", isDirectory: true)) {
        file = directory.appendingPathComponent("conector-m-w.log")
        clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func record(_ message: String) {
        logger.info("\(message, privacy: .public)")
        queue.async {
            do {
                let manager = FileManager.default
                let directory = self.file.deletingLastPathComponent()
                try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
                let line = Data("\(self.clock.string(from: Date())) \(message)\n".utf8)
                let attributes = try? manager.attributesOfItem(atPath: self.file.path)
                let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
                if size + line.count > self.limit {
                    let previous = directory.appendingPathComponent("conector-m-w.previous.log")
                    if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
                    try manager.moveItem(at: self.file, to: previous)
                }
                if !manager.fileExists(atPath: self.file.path) {
                    guard manager.createFile(atPath: self.file.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else { return }
                }
                let handle = try FileHandle(forWritingTo: self.file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                self.logger.error("Could not write diagnostic file")
            }
        }
    }

    func recent() -> String {
        queue.sync {
            let latest = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let lines = latest.split(separator: "\n")
            if lines.count >= 120 { return lines.suffix(120).joined(separator: "\n") }
            let previous = file.deletingLastPathComponent().appendingPathComponent("conector-m-w.previous.log")
            let earlier = (try? String(contentsOf: previous, encoding: .utf8)) ?? ""
            return (earlier.split(separator: "\n").suffix(120 - lines.count) + lines).joined(separator: "\n")
        }
    }

    func drain() { queue.sync {} }
}
