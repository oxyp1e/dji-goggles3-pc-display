// sckenc: capture a display with ScreenCaptureKit and encode it in hardware (VideoToolbox, low-latency
// rate control) to H.264. Always encodes the NEWEST frame: if the encoder is busy, older frames are dropped,
// never queued. When the screen is idle, the last frame is encoded again every 1/FPS so the goggles get a steady rate.
//
// Output on stdout, one record per access unit:
//   "SKE1" | u32 len | u64 capture_ns | u64 encoded_ns | u8 key | Annex-B AU (AUD, SPS/PPS on key frames, slices)
// Times are mach uptime ns (same clock as Python time.monotonic_ns() on macOS).
//
// Usage: sckenc [width] [height] [fps] [displayIndex] [kbit] [gopFrames] [appName]
// Env: SCKENC_STATS=1 prints per-2s stats to stderr, SCKENC_INFLIGHT=n frames in the encoder (default 2),
// SCKENC_LL=1 low-latency rate control, SCKENC_RT=1 RealTime (both slower on M1 Pro, see makeSession).
import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import VideoToolbox

let a = CommandLine.arguments
func arg(_ i: Int, _ d: Int) -> Int { a.count > i ? Int(a[i]) ?? d : d }
let W = arg(1, 1920), H = arg(2, 1080), FPS = arg(3, 100), displayIndex = arg(4, 0)
let KBIT = arg(5, 40000), GOP = arg(6, 0)
let APP = a.count > 7 ? a[7].lowercased() : ""  // capture only this app's biggest window (name substring)

setvbuf(stdout, nil, _IONBF, 0)
signal(SIGPIPE, SIG_IGN)
func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

let lock = NSLock()
var latest: CVPixelBuffer?
var latestCapNs: UInt64 = 0
var latestIsNew = false
var inFlight = 0
let MAXFLIGHT = Int(ProcessInfo.processInfo.environment["SCKENC_INFLIGHT"] ?? "") ?? 2
var lastSubmit: UInt64 = 0
var frameIndex: Int64 = 0
var capOf: [UInt64: UInt64] = [:]  // submit ns -> capture ns
var st = (new: 0, repeats: 0, skipped: 0, enc: 0, encUs: 0, bytes: 0, maxEncUs: 0, dropped: 0)

// ---- encoder
var session: VTCompressionSession?
let outLock = NSLock()

func writeAll(_ d: Data) {
    d.withUnsafeBytes { p in
        var off = 0
        while off < d.count {
            let n = Darwin.write(1, p.baseAddress! + off, d.count - off)
            if n <= 0 { exit(0) }  // reader gone
            off += n
        }
    }
}

func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

// VT may return frames from different threads out of order when 2+ are in flight. The goggles decoder then sees
// "gaps in frame num". So records are written strictly in submit order.
var seqOf: [UInt64: Int64] = [:]  // submit ns -> sequence
var nextOut: Int64 = 1
var ready: [Int64: Data] = [:]  // empty Data = encoder dropped this frame

let outputCallback: VTCompressionOutputCallback = { _, srcRef, status, _, sb in
    let submitNs = UInt64(UInt(bitPattern: srcRef))
    let rec = makeRecord(submitNs, status, sb)
    outLock.lock()
    lock.lock(); let seq = seqOf.removeValue(forKey: submitNs) ?? nextOut; lock.unlock()
    ready[seq] = rec ?? Data()
    while let r = ready.removeValue(forKey: nextOut) {
        if !r.isEmpty { writeAll(r) }
        nextOut += 1
    }
    outLock.unlock()
    lock.lock(); inFlight -= 1; lock.unlock(); kick()
}

func makeRecord(_ submitNs: UInt64, _ status: OSStatus, _ sb: CMSampleBuffer?) -> Data? {
    guard status == noErr, let sb = sb, let block = CMSampleBufferGetDataBuffer(sb) else {
        lock.lock(); st.dropped += 1; _ = capOf.removeValue(forKey: submitNs); lock.unlock(); return nil
    }
    var key = true
    if let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
       let ns = att.first?[kCMSampleAttachmentKey_NotSync] as? Bool, ns { key = false }
    let sc = Data([0, 0, 0, 1])
    var au = Data([0, 0, 0, 1, 0x09, 0xF0])  // AUD
    if key, let fd = CMSampleBufferGetFormatDescription(sb) {
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil,
            parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?; var size = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if let ptr = ptr { au += sc; au += Data(bytes: ptr, count: size) }
        }
    }
    var len = 0; var dp: UnsafeMutablePointer<Int8>?
    CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &dp)
    guard let base = dp else { return nil }
    let raw = UnsafeRawPointer(base)
    var off = 0
    while off + 4 <= len {
        let n = Int(UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt32.self)))
        off += 4
        if n <= 0 || off + n > len { break }
        au += sc; au += Data(bytes: raw + off, count: n)
        off += n
    }
    lock.lock(); let capNs = capOf.removeValue(forKey: submitNs) ?? submitNs; lock.unlock()
    let encNs = nowNs()
    var rec = Data("SKE1".utf8)
    rec += le(UInt32(au.count)); rec += le(capNs); rec += le(encNs); rec += Data([key ? 1 : 0])
    rec += au
    lock.lock()
    let us = Int((encNs - submitNs) / 1000)
    st.enc += 1; st.encUs += us; st.maxEncUs = max(st.maxEncUs, us); st.bytes += au.count
    lock.unlock()
    return rec
}

func makeSession() {
    let spec: [CFString: Any] = [
        kVTVideoEncoderSpecification_EnableLowLatencyRateControl: ProcessInfo.processInfo.environment["SCKENC_LL"] != nil,
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
    ]
    var s: VTCompressionSession?
    let err = VTCompressionSessionCreate(allocator: nil, width: Int32(W), height: Int32(H), codecType: kCMVideoCodecType_H264,
        encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
        outputCallback: outputCallback, refcon: nil, compressionSessionOut: &s)
    guard err == noErr, let s = s else { log("sckenc: VTCompressionSessionCreate failed \(err)"); exit(1) }
    func set(_ k: CFString, _ v: Any) {
        let e = VTSessionSetProperty(s, key: k, value: v as CFTypeRef)
        if e != noErr { log("sckenc: property \(k) failed \(e)") }
    }
    // RealTime=true and low-latency RC both cap the M1 Pro encoder at ~70 fps (1080p). Without them: ~146 fps.
    if ProcessInfo.processInfo.environment["SCKENC_RT"] != nil { set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!) }
    set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!)
    set(kVTCompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanFalse!)
    set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue!)
    set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
    // The goggles decoder (VC8000D) waits for max_dec_frame_buffering frames before output. In low-latency mode VT uses
    // 15 refs and the decoder stalls. One reference frame = output right away.
    if ProcessInfo.processInfo.environment["SCKENC_LL"] != nil { set(kVTCompressionPropertyKey_ReferenceBufferCount, 1) }  // normal mode already uses 1
    set(kVTCompressionPropertyKey_AverageBitRate, KBIT * 1000)
    set(kVTCompressionPropertyKey_ExpectedFrameRate, FPS)
    set(kVTCompressionPropertyKey_MaxKeyFrameInterval, GOP > 0 ? GOP : FPS * 2)
    set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, Double(GOP > 0 ? GOP : FPS * 2) / Double(FPS))
    VTCompressionSessionPrepareToEncodeFrames(s)
    session = s
}

// Encode the newest frame if the encoder is free. Called on new capture and from the idle filler.
func kick(repeatOnly: Bool = false) {
    lock.lock()
    guard let s = session, let pb = latest, inFlight < MAXFLIGHT else {  // busy: picked up when an encode finishes
        lock.unlock(); return
    }
    let t = nowNs()
    let interval = UInt64(1e9 / Double(FPS))
    if repeatOnly {
        if latestIsNew || t - lastSubmit < interval { lock.unlock(); return }
        st.repeats += 1
    } else if !latestIsNew {
        lock.unlock(); return
    }
    latestIsNew = false
    inFlight += 1
    lastSubmit = t
    frameIndex += 1
    seqOf[t] = frameIndex
    capOf[t] = repeatOnly ? t : latestCapNs  // a repeat counts as captured now
    let pts = CMTime(value: CMTimeValue(t), timescale: 1_000_000_000)  // must increase: repeats get a fresh pts
    lock.unlock()
    let err = VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
        frameProperties: nil, sourceFrameRefcon: UnsafeMutableRawPointer(bitPattern: UInt(t)), infoFlagsOut: nil)
    if err != noErr {  // no callback will come for this frame: mark it as dropped
        log("sckenc: encode error \(err)")
        outLock.lock(); lock.lock(); let seq = seqOf.removeValue(forKey: t) ?? 0; inFlight -= 1; lock.unlock()
        ready[seq] = Data(); while let r = ready.removeValue(forKey: nextOut) { if !r.isEmpty { writeAll(r) }; nextOut += 1 }
        outLock.unlock()
    }
}

final class Output: NSObject, SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        if let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = att.first?[.status] as? Int, let s = SCFrameStatus(rawValue: raw), s != .complete { return }
        lock.lock()
        if latestIsNew { st.skipped += 1 }  // previous new frame never got encoded: dropped, not queued
        latest = pb
        latestCapNs = UInt64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)) * 1e9)
        latestIsNew = true
        st.new += 1
        lock.unlock()
        kick()
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { log("sckenc: stream stopped: \(error)"); exit(1) }
}

let output = Output()
var stream: SCStream?
makeSession()

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard displayIndex < content.displays.count else { log("sckenc: no display \(displayIndex)"); exit(1) }
        let display = content.displays[displayIndex]
        let cfg = SCStreamConfiguration()
        cfg.width = W
        cfg.height = H
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(FPS))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.showsCursor = true
        cfg.queueDepth = 5
        cfg.scalesToFit = true
        cfg.preservesAspectRatio = true
        cfg.backgroundColor = .black
        var filter = SCContentFilter(display: display, excludingWindows: [])
        var what = "display \(display.displayID) \(display.width)x\(display.height)"
        if !APP.isEmpty {
            let wins = content.windows.filter { ($0.owningApplication?.applicationName.lowercased() ?? "").contains(APP) && $0.frame.width > 100 }
            guard let w = wins.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                let apps = Set(content.windows.compactMap { $0.owningApplication?.applicationName }).sorted()
                log("sckenc: no window for app '\(APP)'. Apps: \(apps.joined(separator: ", "))"); exit(1)
            }
            filter = SCContentFilter(desktopIndependentWindow: w)
            what = "window '\(w.title ?? "")' of \(w.owningApplication?.applicationName ?? "") \(Int(w.frame.width))x\(Int(w.frame.height))"
        }
        let s = SCStream(filter: filter, configuration: cfg, delegate: output)
        try s.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cap", qos: .userInteractive))
        try await s.startCapture()
        stream = s
        log("sckenc: \(what) -> \(W)x\(H)@\(FPS), \(KBIT) kbit, VideoToolbox")
    } catch { log("sckenc: \(error)"); exit(1) }
}

Thread {
    while true { usleep(1000); kick(repeatOnly: true) }
}.start()

if ProcessInfo.processInfo.environment["SCKENC_STATS"] != nil {
    Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
        lock.lock()
        let e = max(st.enc, 1)
        log("sckenc: capture \(st.new / 3)/s repeat \(st.repeats / 3)/s skipped \(st.skipped / 3)/s | encoded \(st.enc / 3)/s "
            + "enc \(st.encUs / e / 1000).\(st.encUs / e / 100 % 10) ms avg \(st.maxEncUs / 1000) max | \(st.bytes * 8 / 3 / 1000) kbit/s | vt dropped \(st.dropped)")
        st = (0, 0, 0, 0, 0, 0, 0, 0)
        lock.unlock()
    }
}
RunLoop.main.run()
