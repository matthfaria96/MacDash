import Foundation

/// Runs a command-line tool and returns its exit status and output.
enum Shell {
    /// Output is read before waiting for the tool to exit, so a tool that
    /// prints more than a pipe holds (64 KB) can't stall both sides.
    /// Standard error is discarded.
    static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, Data())
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
