import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd

public enum ReferenceAnalyzer {
    private struct Sample { var lab: SIMD3<Double>; var alpha: Double }
    public static func analyze(url: URL, forColor: Bool) throws -> SourceReference {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary), let rawType = CGImageSourceGetType(source) else { throw LumoError.message("无法读取这张图片。请选择 PNG、JPEG、HEIC 或 TIFF。") }
        let type = rawType as String
        guard [UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier, "public.heif", UTType.tiff.identifier].contains(type) else { throw LumoError.message("目前支持 PNG、JPEG、HEIC 和 TIFF 参考图。") }
        if let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int {
            guard width>0,height>0,Double(width)*Double(height)<=250_000_000 else {throw LumoError.message("参考图超过 2.5 亿像素，请先缩小图片。当前来源未改变。")}
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 256, kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source,0,options as CFDictionary) else { throw LumoError.message("图片解码失败，当前来源未改变。") }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let succeeded = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image,in: CGRect(x:0,y:0,width:width,height:height)); return true
        }
        guard succeeded else { throw LumoError.message("无法分析图片的色彩。") }
        var samples: [Sample] = [], gray = [Double](repeating:1,count:width*height)
        for i in 0..<(width*height) {
            let a = Double(pixels[i*4+3])/255
            guard a > 0.025 else { continue }
            let color = RGBColor(min(1,Double(pixels[i*4])/255/a),min(1,Double(pixels[i*4+1])/255/a),min(1,Double(pixels[i*4+2])/255/a))
            samples.append(Sample(lab: oklab(color), alpha: a))
            gray[i] = color.luminance*a + (1-a)
        }
        guard !samples.isEmpty else { throw LumoError.message("这张图片完全透明，没有可提取的内容。") }
        let thumbnail = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(thumbnail,UTType.png.identifier as CFString,1,nil) else { throw LumoError.message("无法保存参考缩略图。") }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else { throw LumoError.message("无法保存参考缩略图。") }
        if forColor {
            var reference = SourceReference(name:url.lastPathComponent,thumbnail:thumbnail as Data,palette:cluster(samples))
            var samplingOptions = options; samplingOptions[kCGImageSourceThumbnailMaxPixelSize] = 2048
            if let preview = CGImageSourceCreateThumbnailAtIndex(source,0,samplingOptions as CFDictionary), let data = try? ReferencePixels.png(preview), data.count <= 16*1024*1024 {reference.samplingImage = data}
            return reference
        }
        return SourceReference(name:url.lastPathComponent,thumbnail:thumbnail as Data,features:try features(gray,width:width,height:height))
    }
    private static func cluster(_ samples: [Sample]) -> [PaletteEntry] {
        let stride = max(1,samples.count/8192)
        let data = samples.enumerated().compactMap { $0.offset % stride == 0 ? $0.element : nil }
        var centers = [data[data.count/2].lab]
        while centers.count < 6 {
            let candidate = data.max { lhs,rhs in
                centers.map { simd_length_squared(lhs.lab-$0) }.min()! < centers.map { simd_length_squared(rhs.lab-$0) }.min()!
            }!
            if centers.map({ simd_length_squared(candidate.lab-$0) }).min()! < 0.00003 { break }
            centers.append(candidate.lab)
        }
        var weights = [Double](repeating:0,count:centers.count)
        for _ in 0..<12 {
            var sums = [SIMD3<Double>](repeating:.zero,count:centers.count)
            weights = [Double](repeating:0,count:centers.count)
            for sample in data {
                var nearest = 0, distance = Double.infinity
                for j in centers.indices { let d = simd_length_squared(sample.lab-centers[j]); if d < distance { distance = d; nearest = j } }
                sums[nearest] += sample.lab * sample.alpha; weights[nearest] += sample.alpha
            }
            for j in centers.indices where weights[j] > 0 { centers[j] = sums[j]/weights[j] }
        }
        let total = weights.reduce(0,+)
        return centers.indices.filter { weights[$0] > total * 0.0001 }.map { PaletteEntry(rgb(centers[$0]),weights[$0]/total) }.sorted { $0.weight > $1.weight }
    }
    private static func features(_ values: [Double], width: Int, height: Int) throws -> ShapeFeatures {
        guard width >= 3, height >= 3 else { throw LumoError.message("图片太小，无法提取结构特征。") }
        var xx=0.0, yy=0.0, xy=0.0, edgeCount=0, strongCount=0
        for y in 1..<(height-1) { for x in 1..<(width-1) {
            let gx = values[y*width+x+1]-values[y*width+x-1], gy = values[(y+1)*width+x]-values[(y-1)*width+x]
            let magnitude = hypot(gx,gy)
            if magnitude > 0.035 { edgeCount += 1; xx += gx*gx; yy += gy*gy; xy += gx*gy }
            if magnitude > 0.25 { strongCount += 1 }
        } }
        guard edgeCount > 3 else { throw LumoError.message("这张图片没有足够的结构变化。请选择有线条或块面关系的图片。") }
        let mean = values.reduce(0,+)/Double(values.count)
        let threshold = mean-0.08
        var visited = [Bool](repeating:false,count:values.count), areas: [Int] = []
        for index in values.indices where !visited[index] && values[index] < threshold {
            var queue = [index], head = 0; visited[index] = true
            while head < queue.count {
                let i = queue[head]; head += 1
                let x = i%width, y = i/width
                let neighbors = [x>0 ? i-1 : -1, x+1<width ? i+1 : -1, y>0 ? i-width : -1, y+1<height ? i+width : -1]
                for neighbor in neighbors where neighbor >= 0 && !visited[neighbor] && values[neighbor] < threshold { visited[neighbor] = true; queue.append(neighbor) }
            }
            if queue.count >= 4 { areas.append(queue.count) }
        }
        areas.sort()
        let coherence = min(1,hypot(xx-yy,2*xy)/max(0.00001,xx+yy))
        let direction = (atan2(2*xy,xx-yy)/2 + .pi/2)*180 / .pi
        let edgeFraction = Double(edgeCount)/Double(values.count)
        let medianArea = areas.isEmpty ? 0.03 : Double(areas[areas.count/2])/Double(values.count)
        let scale = min(0.88,max(0.12,0.20+sqrt(medianArea)*1.3))
        let roughness = min(0.95,max(0.05,0.18+coherence*0.52+Double(strongCount)/Double(max(1,edgeCount))*0.25))
        return ShapeFeatures(direction:direction > 180 ? direction-180 : direction,coherence:coherence,roughness:roughness,density:min(0.9,max(0.10,sqrt(edgeFraction)*2)),scale:scale)
    }
    private static func oklab(_ color: RGBColor) -> SIMD3<Double> {
        let v = color.linear, r = Double(v.x), g = Double(v.y), b = Double(v.z)
        let l = cbrt(0.4122214708*r+0.5363325363*g+0.0514459929*b), m = cbrt(0.2119034982*r+0.6806995451*g+0.1073969566*b), s = cbrt(0.0883024619*r+0.2817188376*g+0.6299787005*b)
        return SIMD3(0.2104542553*l+0.793617785*m-0.0040720468*s,1.9779984951*l-2.428592205*m+0.4505937099*s,0.0259040371*l+0.7827717662*m-0.808675766*s)
    }
    private static func rgb(_ lab: SIMD3<Double>) -> RGBColor {
        let l = pow(lab.x+0.3963377774*lab.y+0.2158037573*lab.z,3), m = pow(lab.x-0.1055613458*lab.y-0.0638541728*lab.z,3), s = pow(lab.x-0.0894841775*lab.y-1.291485548*lab.z,3)
        func gamma(_ v: Double) -> Double { let c = min(1,max(0,v)); return c <= 0.0031308 ? c*12.92 : 1.055*pow(c,1/2.4)-0.055 }
        return RGBColor(gamma(4.0767416621*l-3.3077115913*m+0.2309699292*s),gamma(-1.2684380046*l+2.6097574011*m-0.3413193965*s),gamma(-0.0041960863*l-0.7034186147*m+1.707614701*s))
    }
}

/// Color-managed, oriented reference pixels used only by the picker, never by scene generation.
public struct ReferencePixels: @unchecked Sendable {
    public let image: CGImage
    public let width: Int, height: Int
    private let pixels: [UInt8]
    public init(data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData,nil), let image = CGImageSourceCreateImageAtIndex(source,0,nil), image.width*image.height <= 16_777_216 else {throw LumoError.message("无法读取取色预览。")}
        self.image = image; width = image.width; height = image.height
        pixels = try Self.convert(image)
    }
    public func color(x: Double, y: Double) -> RGBColor? {
        guard (0...1).contains(x), (0...1).contains(y) else {return nil}
        let index = (min(height-1,Int(y*Double(height)))*width+min(width-1,Int(x*Double(width))))*4
        let alpha = Double(pixels[index+3])/255
        guard alpha > 0.025 else {return nil}
        return RGBColor(min(1,Double(pixels[index])/255/alpha),min(1,Double(pixels[index+1])/255/alpha),min(1,Double(pixels[index+2])/255/alpha))
    }
    public static func originalColor(url: URL, x: Double, y: Double) throws -> RGBColor? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary), let image = CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCache:false] as CFDictionary) else {throw LumoError.message("原图无法读取。")}
        let orientation = (CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any])?[kCGImagePropertyOrientation] as? Int ?? 1
        let point: (Double,Double)
        switch orientation {
        case 2:point=(1-x,y); case 3:point=(1-x,1-y); case 4:point=(x,1-y); case 5:point=(y,x)
        case 6:point=(y,1-x); case 7:point=(1-y,1-x); case 8:point=(1-y,x); default:point=(x,y)
        }
        let px = min(image.width-1,max(0,Int(point.0*Double(image.width)))), py = min(image.height-1,max(0,Int(point.1*Double(image.height))))
        guard let pixel = image.cropping(to:CGRect(x:px,y:py,width:1,height:1)) else {return nil}
        let data = try png(pixel), pixels = try ReferencePixels(data:data)
        return pixels.color(x:0,y:0)
    }
    public static func png(_ image: CGImage) throws -> Data {
        let pixels = try convert(image)
        guard let provider = CGDataProvider(data:Data(pixels) as CFData), let managed = CGImage(width:image.width,height:image.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else {throw LumoError.message("无法转换取色预览。")}
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else {throw LumoError.message("无法保存取色预览。")}
        CGImageDestinationAddImage(destination,managed,nil)
        guard CGImageDestinationFinalize(destination) else {throw LumoError.message("无法保存取色预览。")}
        return data as Data
    }
    private static func convert(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating:0,count:image.width*image.height*4)
        let success = pixels.withUnsafeMutableBytes {bytes -> Bool in
            guard let c = CGContext(data:bytes.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {return false}
            c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height)); return true
        }
        guard success else {throw LumoError.message("无法转换参考色彩。")}; return pixels
    }
}
