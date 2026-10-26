import Foundation
import AVFoundation
import CoreImage
import MotionGraphics

/// Sequential forward decoder that delivers every source frame as an SDR CIImage in source pixels (CI coordinates,
/// origin bottom-left).
///
/// HDR (HLG/PQ) is tone mapped by AVFoundation through the output color properties.
///
/// Memory: decoded frames are IOSurfaces owned by the out-of-process decoder (VTDecoderXPCService), invisible in this
/// process' footprint. Every decoder call runs in its own autorelease pool: an async main never drains the default one
/// and each 4K frame stayed alive (~1.5 GB/s at 60 fps, which froze a 16 GB machine). Steady state is ~0.7 GB in the
/// decoder per open source. MEDIT_DECODE=native (experimental) takes 4:2:0 YUV and tone maps in Core Image instead; its
/// levels do not match the default yet.
public final class FootageSource {
    private var reader: AVAssetReader, output: AVAssetReaderTrackOutput
    private let transform: CGAffineTransform, track: AVAssetTrack, asset: AVURLAsset
    private var lastPTS = -Double.infinity, restarts = 0, failedAt = -Double.infinity, skip = 0.0
    private var current: CMSampleBuffer?, next: CMSampleBuffer?
    private var previousTime = -Double.infinity
    /// Presentation time of the frame last returned by frame(at:): per-frame data (deflicker) must be looked up by this,
    /// not by the requested time (30 fps output times sit on 60 fps frame boundaries).
    public private(set) var currentTime = 0.0
    public let url: URL, size: CGSize, fps: Double, duration: Double, hdr: Bool
    /// HLG nominal peak over reference white (1000 / 203 nits); MEDIT_HDR_HEADROOM overrides.
    static let hdrHeadroom = Double(ProcessInfo.processInfo.environment["MEDIT_HDR_HEADROOM"] ?? "") ?? 4.93

    public static func info(url: URL) async throws -> (size: CGSize, fps: Double, duration: Double, hdr: Bool, transform: CGAffineTransform) {
        let asset = AVURLAsset(url:url)
        guard let track = try await asset.loadTracks(withMediaType:.video).first else { throw GraphicsError.invalid("No picture track in \(url.path)") }
        let natural = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        let bounds = CGRect(origin:.zero,size:natural).applying(transform)
        let fps = Double(try await track.load(.nominalFrameRate)), duration = try await asset.load(.duration).seconds
        let hdr = try await track.load(.mediaCharacteristics).contains(.containsHDRVideo)
        return (CGSize(width:abs(bounds.width),height:abs(bounds.height)), fps > 0 ? fps : 30, duration, hdr, transform)
    }

    /// start: seconds to begin at (the reader starts at the keyframe before it).
    public init(url: URL, start: Double = 0) async throws {
        self.url = url
        let i = try await Self.info(url:url)
        size = i.size; fps = i.fps; duration = i.duration; hdr = i.hdr; transform = i.transform
        asset = AVURLAsset(url:url)
        track = try await asset.loadTracks(withMediaType:.video).first!
        native = ProcessInfo.processInfo.environment["MEDIT_DECODE"] == "native"
        (reader, output) = try Self.open(asset:asset,track:track,start:start,native:native,hdr:hdr)
        next = try pull()
    }
    private let native: Bool

    private static func open(asset: AVURLAsset, track: AVAssetTrack, start: Double, native: Bool, hdr: Bool) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader = try AVAssetReader(asset:asset)
        let settings: [String:Any] = native
            ? [kCVPixelBufferPixelFormatTypeKey as String:hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            : [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,
               AVVideoColorPropertiesKey:[AVVideoColorPrimariesKey:AVVideoColorPrimaries_ITU_R_709_2,
                                          AVVideoTransferFunctionKey:AVVideoTransferFunction_ITU_R_709_2,
                                          AVVideoYCbCrMatrixKey:AVVideoYCbCrMatrix_ITU_R_709_2],
               kCVPixelBufferIOSurfacePropertiesKey as String:[:]]
        let output = AVAssetReaderTrackOutput(track:track,outputSettings:settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw GraphicsError.unavailable("Cannot attach decoder") }
        reader.add(output)
        if start > 0 { reader.timeRange = CMTimeRange(start:CMTime(seconds:max(0,start-0.05),preferredTimescale:600_000),duration:.positiveInfinity) }
        guard reader.startReading() else { throw reader.error ?? GraphicsError.io("Cannot start decoder") }
        return (reader, output)
    }

    /// Next sample in order. Long HEVC/HDR reads can fail mid-file ("Cannot Decode", -12137) although every range decodes
    /// on its own: reopen the reader just after the last delivered frame and continue (bounded retries).
    private func pull() throws -> CMSampleBuffer? {
        while true {
            // Drain per call: the decoder's autoreleased wrappers retain the frame's IOSurface (owned by
            // VTDecoderXPCService); never drained in an async main, every 4K frame stayed alive (~1.5 GB/s at 60 fps).
            if let sample = autoreleasepool(invoking:{ output.copyNextSampleBuffer() }) {
                let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if t <= lastPTS + 1e-6 { continue } // frames before the resume point after a reopen
                lastPTS = t
                return sample
            }
            guard reader.status == .failed else { return nil }
            restarts += 1
            guard restarts <= 3 else { throw reader.error ?? GraphicsError.io("Decoding failed repeatedly") }
            FileHandle.standardError.write(Data("medit: decoder failed after \(String(format:"%.3f",lastPTS)) s in \(url.lastPathComponent) (\(reader.error?.localizedDescription ?? "?")); reopening\n".utf8))
            reader.cancelReading()
            // Failing again at the same spot means a damaged frame: step past it (the previous frame is held).
            skip = abs(lastPTS-failedAt) < 1e-6 ? skip+0.05 : 0; failedAt = lastPTS
            lastPTS += skip
            (reader, output) = try Self.open(asset:asset,track:track,start:max(0,lastPTS),native:native,hdr:hdr)
        }
    }

    private func image(_ sample: CMSampleBuffer) throws -> CIImage { try autoreleasepool { try makeImage(sample) } }
    private func makeImage(_ sample: CMSampleBuffer) throws -> CIImage {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw GraphicsError.io("Frame without image") }
        var image = CIImage(cvPixelBuffer:buffer) // YUV + HLG/PQ/709 attachments -> working space
        if native && hdr { image = image.applyingFilter("CIToneMapHeadroom",parameters:["inputSourceHeadroom":Self.hdrHeadroom,"inputTargetHeadroom":1.0]) }
        image = image.transformed(by:transform)
        image = image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))
        return image
    }

    /// Next decoded frame in order with its presentation time (analysis); nil at the end.
    public func nextFrame() throws -> (time: Double, image: CIImage)? {
        guard let sample = next else {
            if reader.status == .failed { throw reader.error ?? GraphicsError.io("Decoding failed") }
            return nil
        }
        next = try pull()
        return (CMSampleBufferGetPresentationTimeStamp(sample).seconds, try image(sample))
    }

    /// Frame showing at `seconds` (nondecreasing calls).
    public func frame(at seconds: Double) throws -> CIImage {
        guard seconds >= previousTime - 1e-9 else { throw GraphicsError.invalid("FootageSource reads forward only") }
        previousTime = seconds
        while let sample = next, CMSampleBufferGetPresentationTimeStamp(sample).seconds <= seconds + 1e-4 {
            current = sample; next = try pull()
        }
        if reader.status == .failed { throw reader.error ?? GraphicsError.io("Decoding failed") }
        guard let sample = current ?? next else { throw GraphicsError.io("No decodable frames in \(url.lastPathComponent)") }
        currentTime = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        return try image(sample)
    }
    deinit { reader.cancelReading() }
}
