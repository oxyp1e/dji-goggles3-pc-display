// sckcap: capture the main display with ScreenCaptureKit, scaled on the GPU to WxH (letterboxed),
// and write raw NV12 frames to stdout as fast as they arrive (up to FPS).
// If the screen is idle, the last frame is repeated every 1/FPS so the encoder keeps a steady rate.
// Usage: sckcap [width] [height] [fps] [displayIndex]
import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

let args = CommandLine.arguments
let W = args.count > 1 ? Int(args[1])! : 1920
let H = args.count > 2 ? Int(args[2])! : 1080
let FPS = args.count > 3 ? Int(args[3])! : 60
let displayIndex = args.count > 4 ? Int(args[4])! : 0

setvbuf(stdout, nil, _IONBF, 0)
signal(SIGPIPE, SIG_IGN)
let out = FileHandle.standardOutput
let frameBytes = W * H * 3 / 2
var lastFrame = Data(count: frameBytes)
var lastWrite = DispatchTime.now()
let lock = NSLock()
var newFrames = 0, repeats = 0

func write(_ d: Data) {
    do { try out.write(contentsOf: d) } catch { exit(0) }  // reader gone
    lastWrite = DispatchTime.now()
}

final class Output: NSObject, SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        // skip idle/blank status frames
        if let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = att.first?[.status] as? Int, let st = SCFrameStatus(rawValue: raw), st != .complete { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        var d = Data(count: frameBytes)
        d.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            var off = 0
            for plane in 0..<2 {
                let base = CVPixelBufferGetBaseAddressOfPlane(pb, plane)!
                let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
                let rows = plane == 0 ? H : H / 2
                for r in 0..<rows {
                    memcpy(dst.baseAddress! + off, base + r * bpr, W)
                    off += W
                }
            }
        }
        lock.lock(); lastFrame = d; newFrames += 1; write(d); lock.unlock()
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write("sckcap: stream stopped: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

let output = Output()
var stream: SCStream?

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard displayIndex < content.displays.count else { fatalError("no display \(displayIndex)") }
        let display = content.displays[displayIndex]
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = W
        cfg.height = H
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(FPS))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.showsCursor = true
        cfg.queueDepth = 3
        cfg.scalesToFit = true
        cfg.preservesAspectRatio = true
        cfg.backgroundColor = .black
        let s = SCStream(filter: filter, configuration: cfg, delegate: output)
        try s.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cap", qos: .userInteractive))
        try await s.startCapture()
        stream = s
        FileHandle.standardError.write("sckcap: capturing display \(display.displayID) \(display.width)x\(display.height) -> \(W)x\(H)@\(FPS)\n".data(using: .utf8)!)
    } catch {
        FileHandle.standardError.write("sckcap: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

// idle filler: repeat the last frame when nothing new arrived for one frame interval
let interval = 1.0 / Double(FPS)
Thread {
    // precise filler loop (GCD timers coalesce and fired too rarely at 100 fps)
    while true {
        usleep(1000)
        lock.lock()
        let since = Double(DispatchTime.now().uptimeNanoseconds - lastWrite.uptimeNanoseconds) / 1e9
        if stream != nil && since >= interval { repeats += 1; write(lastFrame) }
        lock.unlock()
    }
}.start()
if ProcessInfo.processInfo.environment["SCKCAP_STATS"] != nil {
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
        lock.lock(); FileHandle.standardError.write("sckcap: new \(newFrames/2)/s repeat \(repeats/2)/s\n".data(using: .utf8)!)
        newFrames = 0; repeats = 0; lock.unlock()
    }
}
RunLoop.main.run()
