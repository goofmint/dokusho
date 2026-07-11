import Foundation

/// TEMPORARY file-based debug logging for reader tap diagnosis. Appends to
/// Documents/tapdebug.log so the log can be read from the simulator app
/// container after an automated UI-test run. Remove once the tap bug is fixed.
enum TapDebug {
    static func log(_ message: String) {
        #if DEBUG
        let url = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0].appendingPathComponent("tapdebug.log")
        let line = "\(Date()) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
        #endif
    }
}
