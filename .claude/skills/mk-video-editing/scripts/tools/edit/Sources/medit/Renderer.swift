import Foundation
import CoreImage
import AVFoundation
import MotionGraphics

/// Uniformly resampled 1-D signals with Gaussian smoothing.
struct Signal {
    let t0: Double, dt: Double, v: [Double]
    func at(_ t: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        let x = (t-t0)/dt, i = Int(floor(x))
        if i < 0 { return v[0] }; if i >= v.count-1 { return v[v.count-1] }
        let f = x-Double(i); return v[i]*(1-f)+v[i+1]*f
    }
    func smoothed(_ sigma: Double) -> Signal {
        guard sigma > 0, v.count > 2 else { return self }
        let r = Int((3*sigma/dt).rounded(.up)), w = (-r...r).map { exp(-0.5*pow(Double($0)*dt/sigma,2)) }
        let out = v.indices.map { i -> Double in
            var s = 0.0, n = 0.0
            for k in -r...r { let j = min(v.count-1,max(0,i+k)); s += v[j]*w[k+r]; n += w[k+r] }
            return s/n
        }
        return Signal(t0:t0,dt:dt,v:out)
    }
    /// Lazy operator: the value only moves once the input leaves a +-zone around it.
    func deadzoned(_ zone: Double) -> Signal {
        guard zone > 0, var cur = v.first else { return self }
        return Signal(t0:t0,dt:dt,v:v.map { x in
            if x > cur+zone { cur = x-zone } else if x < cur-zone { cur = x+zone }
            return cur
        })
    }
    static func resample(times: [Double], values: [Double], from: Double, to: Double, dt: Double) -> Signal {
        let n = max(2,Int(((to-from)/dt).rounded(.up))+1)
        var j = 0
        let out = (0..<n).map { k -> Double in
            let t = from+Double(k)*dt
            while j+1 < times.count && times[j+1] <= t { j += 1 }
            if times.isEmpty { return 0 }
            if t <= times[0] { return values[0] }
            if j+1 >= times.count { return values[times.count-1] }
            let f = (t-times[j])/max(1e-9,times[j+1]-times[j]); return values[j]*(1-f)+values[j+1]*f
        }
        return Signal(t0:from,dt:dt,v:out)
    }
}

/// Per-clip state: decoder, stabilization path, smoothed subject, deflicker gains.
final class ClipState {
    let clip: Clip, url: URL, W: Double, H: Double
    private var source: FootageSource?, lastTime = -Double.infinity
    private var shiftX: Signal?, shiftY: Signal?, subject: (x: Signal, y: Signal, h: Signal)?
    private var times: [Double] = [], luma: [[Double]] = [], cols = 0, rows = 0, window = 1
    let rawSubject: [[Double]]

    init(clip: Clip, base: URL) async throws {
        self.clip = clip
        url = resolve(clip.source,base)
        let info = try await FootageSource.info(url:url)
        W = info.size.width; H = info.size.height
        let from = clip.in-3, to = clip.out+3
        // stabilize 0 = off: the crop ignores the measured camera path and follows the speaker in frame space
        // (phone footage is already stabilized in camera; registration errors on moving slides cause sudden jumps).
        let stabilized = clip.stabilize > 0
        var rawX: Signal?, rawY: Signal?
        if let a = clip.analysis {
            let json = try JSONSerialization.jsonObject(with:Data(contentsOf:resolve(a,base))) as! [String:Any]
            times = json["times"] as! [Double]
            let shift = json["shift"] as! [[Double]]
            luma = json["luma"] as! [[Double]]
            let tiles = json["tiles"] as! [Int]; cols = tiles[0]; rows = tiles[1]
            let sx = Signal.resample(times:times,values:shift.map { $0[0] },from:from,to:to,dt:1/120)
            let sy = Signal.resample(times:times,values:shift.map { $0[1] },from:from,to:to,dt:1/120)
            rawX = sx; rawY = sy
            if stabilized {
                // stabilize 1 = world locked (tripod); between 0 and 1 blends toward the operator's smoothed path.
                let s = min(1,clip.stabilize), lx = sx.smoothed(1.2), ly = sy.smoothed(1.2)
                shiftX = Signal(t0:sx.t0,dt:sx.dt,v:zip(sx.v,lx.v).map { s*$0+(1-s)*$1 })
                shiftY = Signal(t0:sy.t0,dt:sy.dt,v:zip(sy.v,ly.v).map { s*$0+(1-s)*$1 })
            }
            if let d = clip.deflicker { window = d.window > 0 ? d.window : Self.flickerPeriod(luma:luma) }
        }
        if let tr = clip.track {
            let json = try JSONSerialization.jsonObject(with:Data(contentsOf:resolve(tr,base))) as! [String:Any]
            var samples = (json["samples"] as! [[Double]]).filter { $0[0] >= from-5 && $0[0] <= to+5 }
            // Tracks are world space (camera path removed) unless "space" is "frame"; convert to what the crop uses.
            let frameSpace = (json["space"] as? String) == "frame"
            if frameSpace == stabilized, let rawX, let rawY {
                let k = stabilized ? -1.0 : 1.0
                let w = info.size.width, h = info.size.height
                samples = samples.map { var v = $0; v[1] += k*rawX.at(v[0])/w; v[2] += k*rawY.at(v[0])/h; return v }
            }
            rawSubject = samples
            if !samples.isEmpty {
                let t = samples.map { $0[0] }, ax = clip.anchor[0], ay = clip.anchor[1]
                let x = Signal.resample(times:t,values:samples.map { $0[1]+$0[3]*ax },from:from,to:to,dt:1/30)
                let y = Signal.resample(times:t,values:samples.map { $0[2]+$0[4]*ay },from:from,to:to,dt:1/30)
                let h = Signal.resample(times:t,values:samples.map { $0[4] },from:from,to:to,dt:1/30)
                subject = (x.deadzoned(clip.deadzone).smoothed(clip.followSmooth),
                           y.deadzoned(clip.deadzone*0.6).smoothed(clip.followSmooth*1.5),
                           h.smoothed(clip.fitSmooth))
            }
        } else { rawSubject = [] }
    }

    /// Dominant period (frames) of the global luminance ripple, by autocorrelation of the detrended signal.
    static func flickerPeriod(luma: [[Double]]) -> Int {
        let g = luma.map { $0.reduce(0,+)/Double($0.count) }
        guard g.count > 64 else { return 1 }
        let trend = Signal(t0:0,dt:1,v:g).smoothed(8).v, d = zip(g,trend).map { $0-$1 }
        var best = 1, bestR = 0.0
        let e = d.reduce(0) { $0+$1*$1 }
        guard e > 0 else { return 1 }
        for lag in 2...min(40,d.count/4) {
            var r = 0.0
            for i in 0..<(d.count-lag) { r += d[i]*d[i+lag] }
            r /= e
            if r > bestR+0.02 { bestR = r; best = lag }
            if bestR > 0.3 && r < bestR*0.5 { break }
        }
        return bestR > 0.2 ? best : 1
    }

    func shift(_ t: Double) -> CGPoint { CGPoint(x:shiftX?.at(t) ?? 0,y:shiftY?.at(t) ?? 0) }

    /// Opens (or reopens, on a backward/far jump) the decoder for time t. Async; frame(at:) itself is synchronous so the
    /// whole per-frame Core Image chain can run inside one autorelease pool.
    func prepare(at t: Double) async throws {
        if source == nil || t < lastTime-1e-6 || t-lastTime > 4 { source = try await FootageSource(url:url,start:t) }
    }
    func frame(at t: Double) throws -> CIImage {
        guard let source else { throw GraphicsError.invalid("ClipState.prepare(at:) was not called") }
        lastTime = t
        let img = try source.frame(at:t)
        framePTS = source.currentTime
        return img
    }
    private(set) var framePTS = 0.0
    func release() { source = nil; lastTime = -.infinity }

    /// Analysis frame nearest to a decoded frame's presentation time.
    private func frameIndex(_ t: Double) -> Int? {
        guard !times.isEmpty else { return nil }
        var lo = 0, hi = times.count-1
        while lo < hi { let m = (lo+hi+1)/2; if times[m] <= t { lo = m } else { hi = m-1 } }
        if lo+1 < times.count && abs(times[lo+1]-t) < abs(times[lo]-t) { lo += 1 }
        return lo
    }

    /// Multiplicative gain map (linear light) that flattens the luminance ripple of each tile toward its moving average.
    func deflickerGain(_ t: Double) -> CIImage? {
        guard let d = clip.deflicker, d.strength > 0, window > 1, let k = frameIndex(t) else { return nil }
        let half = window/2, lo = max(0,k-half), hi = min(luma.count-1,lo+window-1)
        var data = [Float](repeating:1,count:cols*rows*4)
        for ty in 0..<rows { for tx in 0..<cols {
            let i = ty*cols+tx
            var avg = 0.0; for f in lo...hi { avg += luma[f][i] }; avg /= Double(hi-lo+1)
            let cur = luma[k][i], gain = cur > 0.002 ? min(1.3,max(0.77,avg/cur)) : 1
            let g = Float(1+d.strength*(gain-1))
            let row = ty // bitmap rows run top-down, as in the analysis (a flipped map overcorrects rolling-shutter flicker)
            let p = (row*cols+tx)*4; data[p] = g; data[p+1] = g; data[p+2] = g; data[p+3] = 1
        }}
        if ProcessInfo.processInfo.environment["MEDIT_DEBUG_DEFLICKER"] != nil {
            let mean = stride(from:0,to:data.count,by:4).map { Double(data[$0]) }.reduce(0,+)/Double(cols*rows)
            FileHandle.standardError.write(Data("deflicker t=\(String(format:"%.4f",t)) k=\(k) tk=\(String(format:"%.4f",times[k])) window=\(window) gain=\(String(format:"%.4f",mean))\n".utf8))
        }
        let img = CIImage(bitmapData:Data(bytes:data,count:data.count*4),bytesPerRow:cols*16,size:CGSize(width:cols,height:rows),format:.RGBAf,colorSpace:nil)
        return img.samplingLinear().clampedToExtent().transformed(by:CGAffineTransform(scaleX:W/Double(cols),y:H/Double(rows)))
            .cropped(to:CGRect(x:0,y:0,width:W,height:H))
    }

    struct Shot { var crop: CGRect; var blur: Double; var dim: Double; var subject: CGRect? } // crop: source px, top-left

    /// Virtual camera at clip-local time `local` for an output aspect.
    func shot(local: Double, aspect: Double) -> Shot {
        let keys = clip.camera, srcT = clip.source(local)
        // Fill-forward key values.
        var filled: [(t: Double, zoom: Double, fit: Double?, x: Double, y: Double, follow: Double, fx: Double, fy: Double, ease: Easing, blur: Double, dim: Double)] = []
        for k in keys {
            let p = filled.last
            filled.append((k.t, k.zoom ?? (k.fit == nil ? p?.zoom ?? 1 : p?.zoom ?? 1), k.fit ?? (k.zoom != nil ? nil : p?.fit), k.x ?? p?.x ?? 0.5, k.y ?? p?.y ?? 0.5,
                           k.follow ?? p?.follow ?? (subject == nil ? 0 : 1), k.frame?[0] ?? p?.fx ?? 0.5, k.frame?[1] ?? p?.fy ?? 0.5,
                           easing(k.ease), k.blur ?? p?.blur ?? 0, k.dim ?? p?.dim ?? 0))
        }
        var i = 0; while i+1 < filled.count && filled[i+1].t <= local { i += 1 }
        let a = filled[i], b = i+1 < filled.count ? filled[i+1] : filled[i]
        let p = b.t > a.t ? b.ease.evaluate((local-a.t)/(b.t-a.t)) : 0
        func lerp(_ u: Double, _ v: Double) -> Double { u+(v-u)*p }
        let sx = subject?.x.at(srcT), sy = subject?.y.at(srcT), sh = subject?.h.at(srcT)
        func zoomOf(_ k: (t: Double, zoom: Double, fit: Double?, x: Double, y: Double, follow: Double, fx: Double, fy: Double, ease: Easing, blur: Double, dim: Double)) -> Double {
            if let fit = k.fit, let sh, sh > 0.01 { let ch = sh*H/fit; return W/(ch*aspect) }
            return k.zoom
        }
        let zoom = exp(lerp(log(min(clip.maxZoom,max(0.2,zoomOf(a)))),log(min(clip.maxZoom,max(0.2,zoomOf(b))))))
        let follow = sx == nil ? 0 : lerp(a.follow,b.follow)
        var cw = W/zoom, ch = cw/aspect
        let fx = lerp(a.fx,b.fx), fy = lerp(a.fy,b.fy)
        var cx = lerp(a.x,b.x)*W, cy = lerp(a.y,b.y)*H
        if let sx, let sy {
            let tx = sx*W-(fx-0.5)*cw, ty = sy*H-(fy-0.5)*ch
            cx += (tx-cx)*follow; cy += (ty-cy)*follow
        }
        let s = shift(srcT); cx += s.x; cy += s.y
        // Keep the crop inside the frame and the safe area.
        var bounds = CGRect(x:0,y:0,width:W,height:H)
        if let safe = clip.safe, safe.count == 4 { bounds = bounds.intersection(CGRect(x:safe[0]*W,y:safe[1]*H,width:(safe[2]-safe[0])*W,height:(safe[3]-safe[1])*H)) }
        if cw > bounds.width { cw = bounds.width; ch = cw/aspect }
        if ch > bounds.height { ch = bounds.height; cw = ch*aspect }
        cx = min(bounds.maxX-cw/2,max(bounds.minX+cw/2,cx)); cy = min(bounds.maxY-ch/2,max(bounds.minY+ch/2,cy))
        var subj: CGRect?
        if let raw = rawSubject.last(where: { $0[0] <= srcT }) ?? rawSubject.first { subj = CGRect(x:raw[1]*W+s.x,y:raw[2]*H+s.y,width:raw[3]*W,height:raw[4]*H) }
        return Shot(crop:CGRect(x:cx-cw/2,y:cy-ch/2,width:cw,height:ch),blur:lerp(a.blur,b.blur),dim:lerp(a.dim,b.dim),subject:subj)
    }
}

func resolve(_ path: String, _ base: URL) -> URL { path.hasPrefix("/") ? URL(fileURLWithPath:path) : base.appendingPathComponent(path) }

func applyGrade(_ image: CIImage, _ g: Grade, extent: CGRect) -> CIImage {
    var img = image
    if g.gain != [1,1,1] && g.gain.count == 3 {
        img = img.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:g.gain[0],y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:g.gain[1],z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:g.gain[2],w:0)])
    }
    if g.exposure != 0 { img = img.applyingFilter("CIExposureAdjust",parameters:["inputEV":g.exposure]) }
    if g.temperature != 6500 || g.tint != 0 {
        img = img.applyingFilter("CITemperatureAndTint",parameters:["inputNeutral":CIVector(x:6500,y:0),"inputTargetNeutral":CIVector(x:g.temperature,y:g.tint)])
    }
    if g.highlights != 1 || g.shadows != 0 { img = img.applyingFilter("CIHighlightShadowAdjust",parameters:["inputHighlightAmount":g.highlights,"inputShadowAmount":g.shadows]) }
    if g.contrast != 1 || g.saturation != 1 { img = img.applyingFilter("CIColorControls",parameters:["inputContrast":g.contrast,"inputSaturation":g.saturation,"inputBrightness":0]) }
    if g.vibrance != 0 { img = img.applyingFilter("CIVibrance",parameters:["inputAmount":g.vibrance]) }
    if let h = g.hueShift {
        img = img.applyingFilter("CIColorCubeWithColorSpace",parameters:["inputCubeDimension":HueCube.size,"inputCubeData":HueCube.data(h),
                                                                        "inputColorSpace":CGColorSpace(name:CGColorSpace.sRGB)!])
    }
    if g.gamma != 1 { img = img.applyingFilter("CIGammaAdjust",parameters:["inputPower":g.gamma]) }
    if g.lift != 0 {
        let k = 1-g.lift
        img = img.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:k,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:k,z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:k,w:0),"inputBiasVector":CIVector(x:g.lift*0.05,y:g.lift*0.05,z:g.lift*0.05,w:0)])
    }
    if g.sharpen > 0 { img = img.applyingFilter("CIUnsharpMask",parameters:["inputRadius":1.6,"inputIntensity":g.sharpen]) }
    // CIVignetteEffect centered on the output frame (CIVignette with a large radius clipped the corners to black).
    if g.vignette > 0 {
        img = img.applyingFilter("CIVignetteEffect",parameters:["inputCenter":CIVector(x:extent.midX,y:extent.midY),
                                                                "inputRadius":hypot(extent.width,extent.height)*0.42,
                                                                "inputIntensity":g.vignette,"inputFalloff":0.6])
    }
    return img.cropped(to:extent)
}

/// Color cube for Grade.hueShift, built once per parameter set.
enum HueCube {
    static let size = 33
    private static var cache: [[Double]:Data] = [:]
    private static let lock = NSLock()
    static func data(_ p: [Double]) -> Data {
        lock.lock(); defer { lock.unlock() }
        if let d = cache[p] { return d }
        let (center, width, shift, minSat) = (p[0], p[1], p[2], p[3])
        var cube = [Float](repeating:0,count:size*size*size*4)
        for bi in 0..<size { for gi in 0..<size { for ri in 0..<size {
            let r = Double(ri)/Double(size-1), g = Double(gi)/Double(size-1), b = Double(bi)/Double(size-1)
            let mx = max(r,g,b), mn = min(r,g,b), c = mx-mn
            var (ro, go, bo) = (r, g, b)
            if c > 1e-6 {
                var h = mx == r ? 60*((g-b)/c) : mx == g ? 60*((b-r)/c+2) : 60*((r-g)/c+4)
                if h < 0 { h += 360 }
                let s = c/mx
                var d = abs(h-center).truncatingRemainder(dividingBy:360); if d > 180 { d = 360-d }
                let wh = d < width ? 0.5*(1+cos(Double.pi*d/width)) : 0
                let x = min(1,max(0,(s-(minSat-0.15))/0.25)), ws = x*x*(3-2*x)
                if wh*ws > 0 {
                    var nh = (h+shift*wh*ws).truncatingRemainder(dividingBy:360); if nh < 0 { nh += 360 }
                    let k = nh/60, i = Int(k)%6, f = k-floor(k)
                    let p0 = mx-c, q = mx-c*f, t = mx-c*(1-f)
                    (ro, go, bo) = [(mx,t,p0),(q,mx,p0),(p0,mx,t),(p0,q,mx),(t,p0,mx),(mx,p0,q)][i]
                }
            }
            let o = ((bi*size+gi)*size+ri)*4
            cube[o] = Float(ro); cube[o+1] = Float(go); cube[o+2] = Float(bo); cube[o+3] = 1
        }}}
        let d = cube.withUnsafeBufferPointer { Data(buffer:$0) }
        cache[p] = d
        return d
    }
}

final class Renderer {
    let edl: EDL, base: URL, compositor: Compositor, extent: CGRect
    var states: [Int:ClipState] = [:]
    var overlaySources: [Int:VideoSource] = [:]

    init(edl: EDL, base: URL) async throws {
        self.edl = edl; self.base = base
        compositor = try Compositor(width:edl.width,height:edl.height)
        extent = compositor.extent
    }

    private func state(_ i: Int) async throws -> ClipState {
        if let s = states[i] { return s }
        let s = try await ClipState(clip:edl.clips[i],base:base); states[i] = s; return s
    }

    private func clipImage(_ i: Int, time T: Double, debug: Bool = false) throws -> CIImage {
        guard let st = states[i] else { throw GraphicsError.invalid("clip \(i) not prepared") }
        let clip = st.clip, local = T-clip.at, srcT = clip.source(local)
        var img = try st.frame(at:srcT)
        if let gain = st.deflickerGain(st.framePTS) { img = img.applyingFilter("CIMultiplyCompositing",parameters:[kCIInputBackgroundImageKey:gain]) }
        let shot = st.shot(local:local,aspect:extent.width/extent.height)
        if debug { return debugFrame(img,st,shot) }
        let c = shot.crop, ciY = st.H-c.maxY, scale = extent.width/c.width
        img = img.clampedToExtent().transformed(by:CGAffineTransform(translationX:-c.minX,y:-ciY)).cropped(to:CGRect(x:0,y:0,width:c.width,height:c.height))
        img = img.applyingFilter("CILanczosScaleTransform",parameters:["inputScale":scale,"inputAspectRatio":1])
        img = img.transformed(by:CGAffineTransform(translationX:-img.extent.minX,y:-img.extent.minY)).clampedToExtent().cropped(to:extent)
        if let g = clip.grade { img = applyGrade(img,g,extent:extent) }
        if let g = edl.look { img = applyGrade(img,g,extent:extent) }
        if shot.blur > 0.05 { img = img.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:["inputRadius":shot.blur]).cropped(to:extent) }
        var fade = 1-min(1,max(0,shot.dim))
        if clip.fadeIn > 0 { fade *= min(1,local/clip.fadeIn) }
        if clip.fadeOut > 0 { fade *= min(1,(clip.duration-local)/clip.fadeOut) }
        if fade < 0.999 { img = img.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:fade,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:fade,z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:fade,w:0)]) }
        return img
    }

    /// Full source frame (stabilization off) with the crop (red), raw subject box (green) and safe area (yellow).
    private func debugFrame(_ src: CIImage, _ st: ClipState, _ shot: ClipState.Shot) -> CIImage {
        let scale = min(extent.width/st.W,extent.height/st.H)
        func outline(_ r: CGRect, _ color: CIColor, _ w: Double = 3) -> CIImage {
            let ci = CGRect(x:r.minX*scale,y:(st.H-r.maxY)*scale,width:r.width*scale,height:r.height*scale)
            let c = CIImage(color:color)
            return [CGRect(x:ci.minX,y:ci.minY,width:ci.width,height:w),CGRect(x:ci.minX,y:ci.maxY-w,width:ci.width,height:w),
                    CGRect(x:ci.minX,y:ci.minY,width:w,height:ci.height),CGRect(x:ci.maxX-w,y:ci.minY,width:w,height:ci.height)]
                .map { c.cropped(to:$0) }.reduce(CIImage.empty()) { $1.composited(over:$0) }
        }
        var img = src.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        if let safe = st.clip.safe, safe.count == 4 { img = outline(CGRect(x:safe[0]*st.W,y:safe[1]*st.H,width:(safe[2]-safe[0])*st.W,height:(safe[3]-safe[1])*st.H),CIColor(red:1,green:0.9,blue:0)).composited(over:img) }
        if let s = shot.subject { img = outline(s,CIColor(red:0,green:1,blue:0.3)).composited(over:img) }
        img = outline(shot.crop,CIColor(red:1,green:0.1,blue:0.1),4).composited(over:img)
        return img.composited(over:CIImage(color:.black).cropped(to:extent)).cropped(to:extent)
    }

    private func prepareOverlay(_ i: Int, time T: Double) async throws {
        let o = edl.overlays[i], local = T-o.at
        guard local >= 0 else { return }
        if let d = o.duration, local >= d { overlaySources[i] = nil; return }
        if overlaySources[i] == nil { overlaySources[i] = try await VideoSource(url:resolve(o.source,base),start:max(0,o.from+local-0.05)) }
    }

    private func overlayImage(_ i: Int, time T: Double) throws -> CIImage? {
        let o = edl.overlays[i], local = T-o.at
        guard local >= 0 else { return nil }
        if let d = o.duration, local >= d { return nil }
        guard let src = overlaySources[i], o.from+local < src.duration else { overlaySources[i] = nil; return nil }
        var img = try src.image(at:o.from+local,size:extent.size)
        var a = o.opacity
        if o.fadeIn > 0 { a *= min(1,local/o.fadeIn) }
        if let d = o.duration, o.fadeOut > 0 { a *= min(1,max(0,(d-local)/o.fadeOut)) }
        if a < 0.999 { img = img.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:a,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:a,z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:a,w:0),"inputAVector":CIVector(x:0,y:0,z:0,w:a)]) }
        return img
    }

    /// Async setup (decoders, overlay readers), then the frame is composed synchronously inside an autorelease pool:
    /// every Core Image step autoreleases intermediates that retain the 4K source frame, and an async main never drains
    /// the default pool (decoder memory grew ~5 GB/s in renders before this).
    func frame(at T: Double, debug: Bool = false) async throws -> CIImage {
        let active = edl.clips.indices.filter { T >= edl.clips[$0].at && T < edl.clips[$0].at+edl.clips[$0].duration }
        for (i,s) in states where !active.contains(i) && T > s.clip.at+s.clip.duration { s.release(); states[i] = nil }
        for i in active { let st = try await state(i); try await st.prepare(at:st.clip.source(T-st.clip.at)) }
        if !debug { for i in edl.overlays.indices { try await prepareOverlay(i,time:T) } }
        return try autoreleasepool { try compose(at:T,active:active,debug:debug) }
    }

    private func compose(at T: Double, active: [Int], debug: Bool) throws -> CIImage {
        var img = CIImage(color:.black).cropped(to:extent)
        for (n,i) in active.enumerated() {
            let c = try clipImage(i,time:T,debug:debug)
            let p = n > 0 && edl.clips[i].transition > 0 ? min(1,(T-edl.clips[i].at)/edl.clips[i].transition) : 1
            img = p >= 0.999 ? c : compositor.composite(c,over:img,opacity:p)
        }
        if debug { return img }
        for i in edl.overlays.indices { if let o = try overlayImage(i,time:T) { img = compositor.composite(o,over:img,mode:CompositeMode(rawValue:edl.overlays[i].blend) ?? .normal) } }
        var fade = 1.0
        if edl.fadeIn > 0 { fade = min(fade,T/edl.fadeIn) }
        if edl.fadeOut > 0 { fade = min(fade,(edl.end-T)/edl.fadeOut) }
        fade = max(0,fade)
        if fade < 0.999 { img = img.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:fade,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:fade,z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:fade,w:0)]) }
        return img.cropped(to:extent)
    }

    func render(out: URL, from: Double, to: Double?, audio: String?, bitrate: Int?, codec: VideoCodec) async throws -> [String:Any] {
        let end = min(to ?? edl.end,edl.end), first = Int((from*edl.fps).rounded()), last = Int((end*edl.fps).rounded())
        guard last > first else { throw GraphicsError.invalid("Empty render range") }
        try FileManager.default.createDirectory(at:out.deletingLastPathComponent(),withIntermediateDirectories:true)
        var sound: AudioSource?
        if let audio { sound = try await AudioSource(url:resolve(audio,base),start:Double(first)/edl.fps,duration:Double(last-first)/edl.fps) }
        let writer = try VideoWriter(url:out,width:edl.width,height:edl.height,fps:edl.fps,codec:codec,audio:sound,bitrate:bitrate ?? 16_000_000)
        let started = ProcessInfo.processInfo.systemUptime
        for f in first..<last {
            let img = try await frame(at:Double(f)/edl.fps)
            try await writer.append(img,frame:f-first,compositor:compositor)
            if (f-first) % 300 == 299 {
                let el = ProcessInfo.processInfo.systemUptime-started
                FileHandle.standardError.write(Data("medit: \(f-first+1)/\(last-first) frames, \(String(format:"%.1f",Double(f-first+1)/el)) fps\n".utf8))
            }
        }
        try await writer.finish()
        let ms = (ProcessInfo.processInfo.systemUptime-started)*1000
        return ["out":out.path,"frames":last-first,"fps":edl.fps,"from":from,"to":end,"ms":Int(ms),"render_fps":Double(last-first)/(ms/1000)]
    }

    func stills(dir: URL, times: [Double], debug: Bool) async throws -> [String:Any] {
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        var files: [String] = []
        for t in times {
            let name = String(format:"%08.3f",t)
            let img = try await frame(at:t)
            let url = dir.appendingPathComponent("\(name).png"); try ImageAsset.writePNG(compositor.image(img),to:url); files.append(url.path)
            if debug {
                states.values.forEach { $0.release() } // the debug pass re-reads the same frame
                let d = try await frame(at:t,debug:true)
                let durl = dir.appendingPathComponent("\(name)_debug.png"); try ImageAsset.writePNG(compositor.image(d),to:durl); files.append(durl.path)
                states.values.forEach { $0.release() }
            }
        }
        return ["out":dir.path,"files":files]
    }
}
