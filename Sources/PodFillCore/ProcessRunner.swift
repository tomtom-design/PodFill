import Foundation

/// Runs a child process, streams its combined stdout+stderr line by line, and can kill the whole process tree.
public final class ProcessRunner: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var buffer = Data()

    public init() {}

    public var pid: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    /// Starts the process and returns its exit status once it has finished. `onLine` is called on a background queue.
    public func run(executable: String, arguments: [String], environment: [String: String],
                    onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice   // never let a prompt block on stdin
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.feed(data, onLine: onLine)
        }

        return try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { [weak self] proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                // Drain whatever is left in the pipe, then flush the last partial line.
                if let self {
                    let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                    if !rest.isEmpty { self.feed(rest, onLine: onLine) }
                    self.flush(onLine: onLine)
                }
                cont.resume(returning: proc.terminationStatus)
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }

    private func feed(_ data: Data, onLine: (String) -> Void) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        // Split on \n and \r so progress-style output also streams.
        while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty { onLine(line) }
        }
    }

    private func flush(onLine: (String) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) { onLine(line) }
        buffer.removeAll()
    }

    /// Terminates the process and every descendant (spotdl spawns yt-dlp/ffmpeg workers; killing only the
    /// parent leaves ffmpeg running and writing files). Polite SIGTERM first, SIGKILL for stragglers.
    public func terminateTree() {
        guard process.isRunning else { return }
        let root = process.processIdentifier
        let victims = [root] + Self.descendants(of: root)
        for pid in victims { kill(pid, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            for pid in victims where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    static func descendants(of pid: Int32) -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(pid)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let children = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").compactMap { Int32($0) }
        return children + children.flatMap { descendants(of: $0) }
    }
}
