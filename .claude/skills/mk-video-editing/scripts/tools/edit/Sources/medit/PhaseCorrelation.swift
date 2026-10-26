import Foundation
import Accelerate

/// Sub-pixel global translation between two grayscale images by FFT phase correlation (robust to brightness flicker).
/// Images are row-major, row 0 at the top, `width` x `height` powers of two.
final class PhaseCorrelator {
    let width: Int, height: Int
    private let log2w: vDSP_Length, log2h: vDSP_Length, setup: FFTSetup
    private let window: [Float]
    private var refRe: [Float], refIm: [Float]
    private var re: [Float], im: [Float]

    init(width: Int, height: Int) {
        precondition(width.nonzeroBitCount == 1 && height.nonzeroBitCount == 1)
        self.width = width; self.height = height
        log2w = vDSP_Length(log2(Double(width))); log2h = vDSP_Length(log2(Double(height)))
        setup = vDSP_create_fftsetup(max(log2w,log2h),FFTRadix(kFFTRadix2))!
        let n = width*height
        window = (0..<n).map { i in
            let x = Double(i%width)/Double(width-1), y = Double(i/width)/Double(height-1)
            return Float((0.5-0.5*cos(2 * .pi*x))*(0.5-0.5*cos(2 * .pi*y)))
        }
        refRe = [Float](repeating:0,count:n); refIm = refRe; re = refRe; im = refRe
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    private func forward(_ pixels: [Float], _ outRe: inout [Float], _ outIm: inout [Float]) {
        let n = width*height
        var mean: Float = 0; vDSP_meanv(pixels,1,&mean,vDSP_Length(n))
        for i in 0..<n { outRe[i] = (pixels[i]-mean)*window[i]; outIm[i] = 0 }
        outRe.withUnsafeMutableBufferPointer { r in outIm.withUnsafeMutableBufferPointer { m in
            var s = DSPSplitComplex(realp:r.baseAddress!,imagp:m.baseAddress!)
            vDSP_fft2d_zip(setup,&s,1,0,log2w,log2h,FFTDirection(FFT_FORWARD))
        }}
    }

    func setReference(_ pixels: [Float]) { forward(pixels,&refRe,&refIm) }

    /// Displacement (dx, dy) of `pixels` content relative to the reference (positive = moved right/down), and peak strength.
    func shift(_ pixels: [Float]) -> (dx: Double, dy: Double, peak: Double) {
        forward(pixels,&re,&im)
        let n = width*height
        for i in 0..<n { // cross power spectrum: cur * conj(ref), normalized
            let a = re[i], b = im[i], c = refRe[i], d = -refIm[i]
            let x = a*c-b*d, y = a*d+b*c, m = max(1e-12,sqrt(x*x+y*y))
            re[i] = x/m; im[i] = y/m
        }
        re.withUnsafeMutableBufferPointer { r in im.withUnsafeMutableBufferPointer { m in
            var s = DSPSplitComplex(realp:r.baseAddress!,imagp:m.baseAddress!)
            vDSP_fft2d_zip(setup,&s,1,0,log2w,log2h,FFTDirection(FFT_INVERSE))
        }}
        var best: Float = -.infinity, bi = 0
        for i in 0..<n where re[i] > best { best = re[i]; bi = i }
        let px = bi%width, py = bi/width
        func v(_ x: Int, _ y: Int) -> Double { Double(re[((y+height)%height)*width+(x+width)%width]) }
        func sub(_ l: Double, _ c: Double, _ r: Double) -> Double { let d = l-2*c+r; return abs(d) < 1e-12 ? 0 : max(-0.5,min(0.5,0.5*(l-r)/d)) }
        var dx = Double(px)+sub(v(px-1,py),v(px,py),v(px+1,py)), dy = Double(py)+sub(v(px,py-1),v(px,py),v(px,py+1))
        if dx > Double(width)/2 { dx -= Double(width) }
        if dy > Double(height)/2 { dy -= Double(height) }
        return (dx,dy,Double(best)/Double(n))
    }
}
