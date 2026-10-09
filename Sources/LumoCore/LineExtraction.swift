import Foundation
import CoreGraphics
import CLineTop

public enum LineExtractionPreset: String, Codable, CaseIterable, Sendable {
    case photo, illustration
    public var title: String {self == .photo ? "照片" : "插画"}
}

public struct LineExtractionParameters: Codable, Equatable, Sendable {
    public var enabled = false
    public var preset = LineExtractionPreset.photo
    public var opacity = 1.0
    public var contrast = 1.0
    public var brightness = 0.0
    public var thickness = 0.0
    public var edgeStrength = 2.0
    public var overlayOriginal = false
    public init() {}
    public var isValid: Bool {
        opacity.isFinite && (0...1).contains(opacity) && contrast.isFinite && (0.5...3).contains(contrast) &&
        brightness.isFinite && (-0.3...0.3).contains(brightness) && thickness.isFinite && (0...3).contains(thickness) &&
        edgeStrength.isFinite && (0...3).contains(edgeStrength)
    }
    /// Opacity and background are GPU presentation controls; they never repeat extraction.
    public func hasSameMask(as other: Self) -> Bool {
        preset == other.preset && contrast == other.contrast && brightness == other.brightness &&
        thickness == other.thickness && edgeStrength == other.edgeStrength
    }
}

/// Detect on the complete fixed canvas once, then share its mask between preview and all exports.
/// A serial cache bounds memory and allows superseded slider tasks to exit before starting OpenCV.
public final class LineExtractionProcessor: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [(Data, LineExtractionParameters, Data)] = []
    public init() {}
    public func mask(input: Data, parameters: LineExtractionParameters) throws -> Data {
        guard parameters.isValid else {throw LumoError.message("线条提取参数无效。")}
        try Task.checkCancellation()
        lock.lock(); defer {lock.unlock()}
        try Task.checkCancellation()
        if let match = cache.first(where:{$0.0 == input && $0.1.hasSameMask(as:parameters)}) {return match.2}
        let source = try ReferencePixels(data:input)
        guard (1...4096).contains(source.width), (1...4096).contains(source.height) else {throw LumoError.message("固定画布长边不能超过 4096 像素。")}
        var alpha = [UInt8](repeating:0,count:source.width*source.height)
        if source.width >= 3 && source.height >= 3 {
            let success = source.rgbaBytes.withUnsafeBufferPointer {rgba in
                alpha.withUnsafeMutableBufferPointer {mask in
                    LumoExtractLineMask(rgba.baseAddress,source.width,source.height,parameters.preset == .photo,
                                        parameters.edgeStrength,parameters.contrast,parameters.brightness,parameters.thickness,mask.baseAddress)
                }
            }
            guard success else {throw LumoError.message("无法抽取线条，请返回构成后重新固定画面。")}
        }
        try Task.checkCancellation()
        var rgba = [UInt8](repeating:0,count:alpha.count*4)
        for i in alpha.indices {rgba[i*4+3] = alpha[i]}
        guard let provider = CGDataProvider(data:Data(rgba) as CFData),
              let image = CGImage(width:source.width,height:source.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:source.width*4,
                                  space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else {throw LumoError.message("无法创建线稿。")}
        let data = try ReferencePixels.png(image)
        try Task.checkCancellation()
        cache.insert((input,parameters,data),at:0)
        if cache.count > 3 {cache.removeLast()}
        return data
    }
}
