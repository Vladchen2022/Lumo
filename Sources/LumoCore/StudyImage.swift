import Foundation
import CoreGraphics
import ImageIO

public enum StudyImage {
    public static func load(_ url:URL,maxEdge:Int=2048) throws -> CGImage {
        let granted=url.startAccessingSecurityScopedResource()
        defer {if granted {url.stopAccessingSecurityScopedResource()}}
        let options=[kCGImageSourceShouldCache:false] as CFDictionary
        guard let source=CGImageSourceCreateWithURL(url as CFURL,options),
              let image=CGImageSourceCreateThumbnailAtIndex(source,0,[
                kCGImageSourceCreateThumbnailFromImageAlways:true,
                kCGImageSourceCreateThumbnailWithTransform:true,
                kCGImageSourceThumbnailMaxPixelSize:max(1,min(2048,maxEdge))
              ] as CFDictionary) else {throw LumoError.message("无法读取图片。")}
        return image
    }

    /// Use existing alpha if present, otherwise use a luminance matte.
    public static func silhouette(_ url:URL) throws -> SilhouetteStudy {
        let image=try load(url)
        let pixels=try ReferencePixels(image:image)
        let rgba=pixels.rgbaBytes
        let hasAlpha=stride(from:3,to:rgba.count,by:4).contains {rgba[$0]<250}
        var matte=[UInt8](repeating:255,count:rgba.count)
        var lo:UInt8=255, hi:UInt8=0
        for i in stride(from:0,to:rgba.count,by:4) {
            let value:UInt8
            if hasAlpha {value=rgba[i+3]}
            else {
                let y=(Int(rgba[i])*54+Int(rgba[i+1])*183+Int(rgba[i+2])*19)/256
                value=UInt8(max(0,min(255,(y-32)*255/192)))
            }
            matte[i+3]=value; lo=min(lo,value); hi=max(hi,value)
        }
        guard hi>32, Int(hi)-Int(lo)>32 else {throw LumoError.message("剪影需要透明背景，或有明显明暗差异的黑白遮罩。")}
        guard let provider=CGDataProvider(data:Data(matte) as CFData),
              let mask=CGImage(width:pixels.width,height:pixels.height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:pixels.width*4,
                  space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),
                  provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else {throw LumoError.message("无法生成剪影遮罩。")}
        let data=try ReferencePixels.png(mask)
        var source=SourceReference(name:url.lastPathComponent,thumbnail:Data())
        source.renderImage=data
        return SilhouetteStudy(source:source,aspect:Double(mask.width)/Double(mask.height))
    }
}
