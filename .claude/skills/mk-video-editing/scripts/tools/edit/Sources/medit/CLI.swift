import Foundation
import CoreImage
import MotionGraphics

let usage = """
medit analyze SOURCE --out analysis.json [--tiles 16x18] [--detect-every 0.1] [--register-region x0,y0,x1,y1] [--detect-region x0,y0,x1,y1] [--from S] [--to S]
medit render EDL.json --out movie.mp4 [--from S] [--to S] [--audio mix.wav|--no-audio] [--bitrate BPS] [--codec h264|hevc]
medit stills EDL.json --out DIR --times 1.5,10,42 [--debug]
"""

struct Args {
    var positional: [String] = [], options: [String:String] = [:], flags: Set<String> = []
    init(_ argv: [String]) throws {
        var it = argv.makeIterator()
        while let a = it.next() {
            if ["--debug","--no-audio"].contains(a) { flags.insert(a); continue }
            if a.hasPrefix("--") { guard let v = it.next() else { throw GraphicsError.invalid("Missing value for \(a)") }; options[a] = v }
            else { positional.append(a) }
        }
    }
    func double(_ key: String) throws -> Double? {
        guard let v = options[key] else { return nil }
        guard let d = Double(v), d.isFinite else { throw GraphicsError.invalid("Invalid \(key) \(v)") }
        return d
    }
}

@main struct EditCLI {
    static func main() async {
        do {
            var argv = Array(CommandLine.arguments.dropFirst())
            guard !argv.isEmpty else { throw GraphicsError.invalid(usage) }
            let command = argv.removeFirst(), args = try Args(argv)
            let result: [String:Any]
            switch command {
            case "analyze":
                guard let src = args.positional.first, let out = args.options["--out"] else { throw GraphicsError.invalid(usage) }
                var a = Analyzer()
                if let t = args.options["--tiles"] {
                    let p = t.split(separator:"x").compactMap { Int($0) }
                    guard p.count == 2, p.allSatisfy({ $0 > 0 && $0 <= 64 }) else { throw GraphicsError.invalid("--tiles COLSxROWS") }
                    a.cols = p[0]; a.rows = p[1]
                }
                if let d = try args.double("--detect-every") { a.detectEvery = max(0.01,d) }
                if let r = args.options["--register-region"] {
                    let p = r.split(separator:",").compactMap { Double($0) }
                    guard p.count == 4, p[2] > p[0], p[3] > p[1] else { throw GraphicsError.invalid("--register-region x0,y0,x1,y1 (normalized, top-left)") }
                    a.registerRegion = CGRect(x:p[0],y:p[1],width:p[2]-p[0],height:p[3]-p[1])
                }
                if let r = args.options["--detect-region"] {
                    let p = r.split(separator:",").compactMap { Double($0) }
                    guard p.count == 4, p[2] > p[0], p[3] > p[1] else { throw GraphicsError.invalid("--detect-region x0,y0,x1,y1 (normalized, top-left)") }
                    a.detectRegion = CGRect(x:p[0],y:p[1],width:p[2]-p[0],height:p[3]-p[1])
                }
                a.from = try args.double("--from") ?? 0; a.to = try args.double("--to") ?? .infinity
                result = try await a.run(url:URL(fileURLWithPath:src),out:URL(fileURLWithPath:out))
            case "render", "stills":
                guard let edlPath = args.positional.first, let out = args.options["--out"] else { throw GraphicsError.invalid(usage) }
                let edl = try EDL.load(URL(fileURLWithPath:edlPath))
                let renderer = try await Renderer(edl:edl,base:URL(fileURLWithPath:edlPath).deletingLastPathComponent())
                if command == "render" {
                    result = try await renderer.render(out:URL(fileURLWithPath:out),from:try args.double("--from") ?? 0,to:try args.double("--to"),
                        audio:args.flags.contains("--no-audio") ? nil : (args.options["--audio"] ?? edl.audio),
                        bitrate:args.options["--bitrate"].flatMap { Int($0) },codec:VideoCodec(rawValue:args.options["--codec"] ?? "h264") ?? .h264)
                } else {
                    let times = (args.options["--times"] ?? "0").split(separator:",").compactMap { Double($0) }.sorted()
                    result = try await renderer.stills(dir:URL(fileURLWithPath:out),times:times,debug:args.flags.contains("--debug"))
                }
            case "selftest": // phase correlation sign/scale check on a real frame: content moved right 6.4 px, down 3.2 px
                guard let src = args.positional.first else { throw GraphicsError.invalid("medit selftest SOURCE") }
                let source = try await FootageSource(url:URL(fileURLWithPath:src)), img = try source.frame(at:1)
                let ctx = CIContext(), pc = PhaseCorrelator(width:512,height:256)
                func gray(_ i: CIImage) -> [Float] {
                    let s = i.cropped(to:CGRect(x:1000,y:600,width:1024,height:512)).transformed(by:CGAffineTransform(translationX:-1000,y:-600)).transformed(by:CGAffineTransform(scaleX:0.5,y:0.5))
                    var px = [Float](repeating:0,count:512*256*4)
                    px.withUnsafeMutableBytes { ctx.render(s,toBitmap:$0.baseAddress!,rowBytes:512*16,bounds:CGRect(x:0,y:0,width:512,height:256),format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.linearSRGB)!) }
                    return (0..<512*256).map { px[$0*4+1] }
                }
                pc.setReference(gray(img))
                let r = pc.shift(gray(img.transformed(by:CGAffineTransform(translationX:12.8,y:-6.4))))
                result = ["dx":r.dx,"dy":r.dy,"peak":r.peak,"expected":[6.4,3.2]]
            default: throw GraphicsError.invalid(usage)
            }
            print(String(data:try JSONSerialization.data(withJSONObject:result),encoding:.utf8)!)
        } catch {
            FileHandle.standardError.write(Data("medit: \(error)\n".utf8)); exit(1)
        }
    }
}
