import Foundation
import MotionGraphics

/// Edit decision list (edl.json). Times: `at` and overlay/fade times are timeline seconds; `in`/`out` are source seconds;
/// camera key `t` is seconds from the clip's start on the timeline. Normalized coordinates are top-left based fractions of
/// the source frame (x of width, y of height). See tools/edit/README.md.
struct EDL: Decodable {
    var width = 1920, height = 1080, fps = 30.0
    var audio: String?
    var duration: Double?
    var clips: [Clip]
    var overlays: [Overlay] = []
    var look: Grade?
    var fadeIn = 0.0, fadeOut = 0.0

    enum CodingKeys: String, CodingKey { case width, height, fps, audio, duration, clips, overlays, look, fadeIn = "fade_in", fadeOut = "fade_out" }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy:CodingKeys.self)
        width = try c.decodeIfPresent(Int.self,forKey:.width) ?? 1920; height = try c.decodeIfPresent(Int.self,forKey:.height) ?? 1080
        fps = try c.decodeIfPresent(Double.self,forKey:.fps) ?? 30; audio = try c.decodeIfPresent(String.self,forKey:.audio)
        duration = try c.decodeIfPresent(Double.self,forKey:.duration); clips = try c.decode([Clip].self,forKey:.clips)
        overlays = try c.decodeIfPresent([Overlay].self,forKey:.overlays) ?? []; look = try c.decodeIfPresent(Grade.self,forKey:.look)
        fadeIn = try c.decodeIfPresent(Double.self,forKey:.fadeIn) ?? 0; fadeOut = try c.decodeIfPresent(Double.self,forKey:.fadeOut) ?? 0
    }
    static func load(_ url: URL) throws -> EDL {
        let edl = try JSONDecoder().decode(EDL.self,from:Data(contentsOf:url))
        guard edl.width > 0, edl.height > 0, edl.width % 2 == 0, edl.height % 2 == 0, edl.fps > 0, edl.fps <= 120 else { throw GraphicsError.invalid("EDL needs even width/height and 0 < fps <= 120") }
        for (i,c) in edl.clips.enumerated() {
            guard c.out > c.in, c.in >= 0, c.at >= 0, c.speed > 0 else { throw GraphicsError.invalid("clip \(i): needs 0 <= in < out, at >= 0 and speed > 0") }
            guard !c.camera.isEmpty, zip(c.camera,c.camera.dropFirst()).allSatisfy({ $0.t < $1.t }) else { throw GraphicsError.invalid("clip \(i): camera keys need increasing t") }
        }
        return edl
    }
    var end: Double { duration ?? max(clips.map { $0.at+$0.duration }.max() ?? 0, overlays.map { $0.at+($0.duration ?? 0) }.max() ?? 0) }
}

struct Clip: Decodable {
    var source: String, `in`: Double, out: Double, at: Double
    var analysis: String?, track: String?
    /// 1 = world-locked stabilization from the analysis path; 0 = off (in-camera stabilized phone footage).
    var stabilize = 1.0, followSmooth = 0.8, deadzone = 0.02, fitSmooth = 2.0
    /// Tightest crop as source width / crop width (3.6 on 4K -> 1080p = 1.8x upscale); caps `fit` and `zoom` keys.
    var maxZoom = 3.6
    var anchor = [0.5,0.4]
    var safe: [Double]?
    var deflicker: Deflicker?
    var grade: Grade?
    var camera: [CameraKey]
    var transition = 0.0, fadeIn = 0.0, fadeOut = 0.0
    /// Playback speed (0.5 = half-speed slow motion; 60 fps sources stay smooth at 0.5 on a 30 fps timeline).
    var speed = 1.0
    var label: String?
    /// Timeline duration.
    var duration: Double { (out - self.in) / speed }
    /// Source time at clip-local timeline time.
    func source(_ local: Double) -> Double { self.in + local * speed }

    enum CodingKeys: String, CodingKey {
        case source, `in`, out, at, analysis, track, stabilize, deadzone, anchor, safe, deflicker, grade, camera, transition, speed, label
        case maxZoom = "max_zoom"
        case followSmooth = "follow_smooth", fitSmooth = "fit_smooth", fadeIn = "fade_in", fadeOut = "fade_out"
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy:CodingKeys.self)
        source = try c.decode(String.self,forKey:.source); self.in = try c.decode(Double.self,forKey:.in)
        out = try c.decode(Double.self,forKey:.out); at = try c.decode(Double.self,forKey:.at)
        analysis = try c.decodeIfPresent(String.self,forKey:.analysis); track = try c.decodeIfPresent(String.self,forKey:.track)
        stabilize = try c.decodeIfPresent(Double.self,forKey:.stabilize) ?? 1
        maxZoom = try c.decodeIfPresent(Double.self,forKey:.maxZoom) ?? 3.6
        followSmooth = try c.decodeIfPresent(Double.self,forKey:.followSmooth) ?? 0.8
        fitSmooth = try c.decodeIfPresent(Double.self,forKey:.fitSmooth) ?? 2
        deadzone = try c.decodeIfPresent(Double.self,forKey:.deadzone) ?? 0.02
        anchor = try c.decodeIfPresent([Double].self,forKey:.anchor) ?? [0.5,0.4]
        safe = try c.decodeIfPresent([Double].self,forKey:.safe)
        deflicker = try c.decodeIfPresent(Deflicker.self,forKey:.deflicker); grade = try c.decodeIfPresent(Grade.self,forKey:.grade)
        camera = try c.decodeIfPresent([CameraKey].self,forKey:.camera) ?? [CameraKey(t:0)]
        transition = try c.decodeIfPresent(Double.self,forKey:.transition) ?? 0
        fadeIn = try c.decodeIfPresent(Double.self,forKey:.fadeIn) ?? 0; fadeOut = try c.decodeIfPresent(Double.self,forKey:.fadeOut) ?? 0
        speed = try c.decodeIfPresent(Double.self,forKey:.speed) ?? 1
        label = try c.decodeIfPresent(String.self,forKey:.label)
    }
}

/// Virtual camera key. Missing fields inherit from the previous key. `fit` (subject box height / crop height) overrides
/// `zoom` (source width / crop width) when a track is present. `follow` blends the fixed point (x, y) with the subject,
/// placed at `frame` in the output. `ease` shapes the move INTO this key: linear, in, out, inOut, smooth, cut, outExpo...
struct CameraKey: Decodable {
    var t: Double
    var zoom: Double?, fit: Double?, x: Double?, y: Double?, follow: Double?, frame: [Double]?, ease: String?, blur: Double?, dim: Double?
    init(t: Double) { self.t = t }
}

struct Deflicker: Decodable {
    var strength = 1.0, window = 0 // window in source frames; 0 = detect the flicker period
    enum CodingKeys: String, CodingKey { case strength, window }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy:CodingKeys.self)
        strength = try c.decodeIfPresent(Double.self,forKey:.strength) ?? 1; window = try c.decodeIfPresent(Int.self,forKey:.window) ?? 0
    }
}

/// Primary grade. exposure in stops; gain = linear RGB multipliers (white balance); temperature/tint = target neutral for
/// CITemperatureAndTint (6500/0 = none); contrast/saturation 1 = none; lift raises blacks (0..0.1); gamma power 1 = none;
/// highlights 1 = none (lower recovers), shadows 0 = none (positive opens); sharpen 0..1; vignette 0..1.
/// hueShift [center°, width°, shift°, minSaturation]: secondary correction that rotates only saturated colors near
/// `center` (cosine falloff to 0 at ±width; saturation below minSaturation − 0.15 untouched, so skin is protected).
struct Grade: Decodable {
    var exposure = 0.0, gain = [1.0,1.0,1.0], temperature = 6500.0, tint = 0.0, contrast = 1.0, saturation = 1.0, vibrance = 0.0
    var lift = 0.0, gamma = 1.0, highlights = 1.0, shadows = 0.0, sharpen = 0.0, vignette = 0.0
    var hueShift: [Double]?
    enum CodingKeys: String, CodingKey { case exposure, gain, temperature, tint, contrast, saturation, vibrance, lift, gamma, highlights, shadows, sharpen, vignette, hueShift = "hue_shift" }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy:CodingKeys.self)
        func v(_ k: CodingKeys, _ def: Double) throws -> Double { try c.decodeIfPresent(Double.self,forKey:k) ?? def }
        exposure = try v(.exposure,0); gain = try c.decodeIfPresent([Double].self,forKey:.gain) ?? [1,1,1]
        temperature = try v(.temperature,6500); tint = try v(.tint,0); contrast = try v(.contrast,1); saturation = try v(.saturation,1)
        vibrance = try v(.vibrance,0); lift = try v(.lift,0); gamma = try v(.gamma,1); highlights = try v(.highlights,1)
        shadows = try v(.shadows,0); sharpen = try v(.sharpen,0); vignette = try v(.vignette,0)
        hueShift = try c.decodeIfPresent([Double].self,forKey:.hueShift)
        if let h = hueShift, h.count != 4 { throw GraphicsError.invalid("hue_shift needs [center, width, shift, min_saturation]") }
    }
}

struct Overlay: Decodable {
    var source: String, at: Double, from = 0.0, duration: Double?, opacity = 1.0, fadeIn = 0.0, fadeOut = 0.0, blend = "normal"
    enum CodingKeys: String, CodingKey { case source, at, from, duration, opacity, blend, fadeIn = "fade_in", fadeOut = "fade_out" }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy:CodingKeys.self)
        source = try c.decode(String.self,forKey:.source); at = try c.decode(Double.self,forKey:.at)
        from = try c.decodeIfPresent(Double.self,forKey:.from) ?? 0; duration = try c.decodeIfPresent(Double.self,forKey:.duration)
        opacity = try c.decodeIfPresent(Double.self,forKey:.opacity) ?? 1; blend = try c.decodeIfPresent(String.self,forKey:.blend) ?? "normal"
        fadeIn = try c.decodeIfPresent(Double.self,forKey:.fadeIn) ?? 0; fadeOut = try c.decodeIfPresent(Double.self,forKey:.fadeOut) ?? 0
    }
}

func easing(_ name: String?) -> Easing {
    switch name ?? "inOut" {
    case "linear": return .linear
    case "in": return .inCubic
    case "out": return .outCubic
    case "inOut": return .inOutCubic
    case "cut": return .hold
    default: return Easing(rawValue:name!) ?? .inOutCubic
    }
}
