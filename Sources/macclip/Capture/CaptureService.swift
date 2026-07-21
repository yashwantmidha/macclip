import AppKit

final class CaptureService {
    enum Mode {
        case region
        case window
        case fullscreen
    }

    /// Runs the interactive system capture UI. Calls back on the main queue with
    /// the captured image file, or nil if the user cancelled.
    func capture(_ mode: Mode, completion: @escaping (URL?) -> Void) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macclip-\(UUID().uuidString).png")

        var args = ["-x", "-t", "png"]
        switch mode {
        case .region:
            args.append("-i")
        case .window:
            args.append(contentsOf: ["-i", "-W"])
        case .fullscreen:
            break
        }
        args.append(url.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = args
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                let exists = FileManager.default.fileExists(atPath: url.path)
                completion(exists ? url : nil)
            }
        }

        do {
            try process.run()
        } catch {
            DispatchQueue.main.async {
                completion(nil)
            }
        }
    }
}
