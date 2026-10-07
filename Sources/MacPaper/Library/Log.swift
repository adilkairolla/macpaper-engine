import Foundation

final class Log: @unchecked Sendable {
    static let shared = Log()
    private let queue = DispatchQueue(label: "macpaper.log")
    private let url = Paths.appSupport.appendingPathComponent("macpaper.log")

    func write(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        queue.async { [url] in
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
