import Foundation
import CoreImage
import Vision
import MotionGraphics

/// One pass over a source: per frame linear-light tile luminance (deflicker), mean color and luma percentiles (grading),
/// frame-to-frame translation (Vision registration, for stabilization) and, every few frames, people boxes (Vision).
/// Coordinates in the output are top-left based: shifts in source pixels (y down), boxes normalized to the frame.
struct Analyzer {
    var cols = 16, rows = 18, detectEvery = 0.1, registerRegion: CGRect? = nil, detectRegion: CGRect? = nil, detectWidth = 1600.0, from = 0.0, to = Double.infinity

    func run(url: URL, out: URL) async throws -> [String:Any] {
        let source = try await FootageSource(url:url,start:from)
        let W = source.size.width, H = source.size.height
        let context = CIContext(options:[.workingColorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!,.cacheIntermediates:false])
        let linear = CGColorSpace(name:CGColorSpace.linearSRGB)!
        let sw = 320, sh = max(2,Int((Double(sw)*H/W).rounded()))
        var times: [Double] = [], tiles: [[Double]] = [], rgb: [[Double]] = [], pct: [[Double]] = [], shift: [[Double]] = []
        var people: [[String:Any]] = []
        var cumulative = CGPoint.zero, base = CGPoint.zero, refTime: Double?, lastDetect = -Double.infinity, peaks: [Double] = []
        let correlator = PhaseCorrelator(width:512,height:256)
        var regPixels = [Float](repeating:0,count:512*256*4), gray = [Float](repeating:0,count:512*256)
        var pixels = [Float](repeating:0,count:sw*sh*4)
        let started = ProcessInfo.processInfo.systemUptime
        while let (time, image) = try source.nextFrame() {
            if time < from - 1e-6 { continue }
            if time > to { break }
            try autoreleasepool {
                // Stats image: Lanczos downscale averages properly over the 12x reduction.
                let small = image.applyingFilter("CILanczosScaleTransform",parameters:["inputScale":Double(sw)/W,"inputAspectRatio":(Double(sh)/H)/(Double(sw)/W)])
                let s = small.transformed(by:CGAffineTransform(translationX:-small.extent.minX,y:-small.extent.minY))
                pixels.withUnsafeMutableBytes { context.render(s,toBitmap:$0.baseAddress!,rowBytes:sw*16,bounds:CGRect(x:0,y:0,width:sw,height:sh),format:.RGBAf,colorSpace:linear) }
                var tileSum = [Double](repeating:0,count:cols*rows), tileN = [Double](repeating:0,count:cols*rows)
                var r = 0.0, g = 0.0, b = 0.0, hist = [Int](repeating:0,count:256)
                for y in 0..<sh { // bitmap row 0 is the top of the picture
                    let ty = min(rows-1,y*rows/sh)
                    for x in 0..<sw {
                        let i = (y*sw+x)*4
                        let R = Double(pixels[i]), G = Double(pixels[i+1]), B = Double(pixels[i+2])
                        let Y = 0.2126*R+0.7152*G+0.0722*B
                        let t = ty*cols+min(cols-1,x*cols/sw); tileSum[t] += Y; tileN[t] += 1
                        r += R; g += G; b += B
                        hist[min(255,max(0,Int(pow(max(0,Y),1/2.2)*255)))] += 1
                    }
                }
                let n = Double(sw*sh)
                func percentile(_ p: Double) -> Double {
                    var acc = 0, target = Int(p*n)
                    target = max(1,target)
                    for (v,c) in hist.enumerated() { acc += c; if acc >= target { return Double(v)/255 } }
                    return 1
                }
                times.append(r4(time))
                tiles.append(zip(tileSum,tileN).map { r4($0/$1) })
                rgb.append([r4(r/n),r4(g/n),r4(b/n)])
                pct.append([percentile(0.02),percentile(0.5),percentile(0.98)].map(r4))

                // Stabilization: phase correlation of a 512x256 gray copy (the register region, default the whole frame
                // squeezed) against a reference frame, re-anchored when the reference ages or drifts far.
                let region = registerRegion ?? CGRect(x:0,y:0,width:1,height:1)
                let rx = region.minX*W, ry = (1-region.maxY)*H, rw = region.width*W, rh = region.height*H
                let kx = Double(correlator.width)/rw, ky = Double(correlator.height)/rh
                let reg = image.cropped(to:CGRect(x:rx,y:ry,width:rw,height:rh))
                    .transformed(by:CGAffineTransform(translationX:-rx,y:-ry))
                    .applyingFilter("CILanczosScaleTransform",parameters:["inputScale":ky,"inputAspectRatio":kx/ky])
                let rg = reg.transformed(by:CGAffineTransform(translationX:-reg.extent.minX,y:-reg.extent.minY))
                regPixels.withUnsafeMutableBytes { context.render(rg,toBitmap:$0.baseAddress!,rowBytes:correlator.width*16,bounds:CGRect(x:0,y:0,width:correlator.width,height:correlator.height),format:.RGBAf,colorSpace:linear) }
                for i in 0..<gray.count { gray[i] = pow(max(0,0.2126*regPixels[i*4]+0.7152*regPixels[i*4+1]+0.0722*regPixels[i*4+2]),1/2.2) }
                if refTime == nil { correlator.setReference(gray); refTime = time; base = .zero }
                var d = correlator.shift(gray)
                if time - refTime! > 2.0 || abs(d.dx) > 24 || abs(d.dy) > 16 || d.peak < 0.02 {
                    if d.peak >= 0.02 { cumulative = CGPoint(x:base.x+d.dx/kx,y:base.y+d.dy/ky) } // else hold the last position
                    base = cumulative; correlator.setReference(gray); refTime = time; d = (0,0,1)
                }
                cumulative = CGPoint(x:base.x+d.dx/kx,y:base.y+d.dy/ky)
                peaks.append(r4(d.peak))
                shift.append([r4(cumulative.x),r4(cumulative.y)])

                if time - lastDetect >= detectEvery - 1e-6 {
                    lastDetect = time
                    // Far speakers are small: detecting on a stage crop (normalized, top-left) at detectWidth px roughly
                    // doubles their size for Vision. Boxes are mapped back to full-frame coordinates.
                    let rg = detectRegion ?? CGRect(x:0,y:0,width:1,height:1)
                    let crop = CGRect(x:rg.minX*W,y:(1-rg.maxY)*H,width:rg.width*W,height:rg.height*H)
                    let ds = min(1,detectWidth/crop.width)
                    let det = image.cropped(to:crop).transformed(by:CGAffineTransform(translationX:-crop.minX,y:-crop.minY))
                        .transformed(by:CGAffineTransform(scaleX:ds,y:ds))
                    let request = VNDetectHumanRectanglesRequest()
                    request.upperBodyOnly = false
                    try VNImageRequestHandler(ciImage:det,options:[:]).perform([request])
                    let boxes: [[Double]] = (request.results ?? []).map { o in
                        let bb = o.boundingBox
                        return [r4(rg.minX+bb.minX*rg.width),r4(rg.minY+(1-bb.maxY)*rg.height),r4(bb.width*rg.width),r4(bb.height*rg.height),r4(Double(o.confidence))]
                    }
                    people.append(["f":times.count-1,"t":r4(time),"boxes":boxes])
                }
            }
        }
        let result: [String:Any] = ["source":url.path,"width":W,"height":H,"fps":source.fps,"duration":source.duration,"hdr":source.hdr,
                                    "from":from,"tiles":[cols,rows],"times":times,"luma":tiles,"rgb":rgb,"pct":pct,"shift":shift,"peaks":peaks,"people":people,
                                    "detect_region":detectRegion.map { [$0.minX,$0.minY,$0.maxX,$0.maxY] } ?? [0,0,1,1],"register_region":registerRegion.map { [$0.minX,$0.minY,$0.maxX,$0.maxY] } ?? NSNull()]
        try FileManager.default.createDirectory(at:out.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:result).write(to:out)
        return ["out":out.path,"frames":times.count,"detections":people.count,"hdr":source.hdr,"fps":source.fps,
                "ms":Int((ProcessInfo.processInfo.systemUptime-started)*1000)]
    }
}

@inline(__always) func r4(_ v: Double) -> Double { (v*10000).rounded()/10000 }
