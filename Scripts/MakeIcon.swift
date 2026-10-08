import AppKit

let folder=URL(fileURLWithPath:CommandLine.arguments[1])
try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels=size*scale
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
        let context=NSGraphicsContext.current!.cgContext
        context.scaleBy(x:CGFloat(pixels)/1024,y:CGFloat(pixels)/1024)
        let base=CGPath(roundedRect:CGRect(x:38,y:38,width:948,height:948),cornerWidth:205,cornerHeight:205,transform:nil)
        context.addPath(base); context.clip()
        context.setFillColor(CGColor(srgbRed:0.10,green:0.15,blue:0.16,alpha:1)); context.fill(CGRect(x:0,y:0,width:1024,height:1024))
        context.setFillColor(CGColor(srgbRed:0.64,green:0.88,blue:0.77,alpha:1))
        context.move(to:CGPoint(x:185,y:268)); context.addLine(to:CGPoint(x:250,y:810)); context.addLine(to:CGPoint(x:720,y:760)); context.addLine(to:CGPoint(x:615,y:270)); context.closePath(); context.fillPath()
        context.setFillColor(CGColor(srgbRed:0.95,green:0.44,blue:0.28,alpha:1))
        context.fillEllipse(in:CGRect(x:465,y:210,width:400,height:400))
        context.setStrokeColor(CGColor(srgbRed:0.10,green:0.15,blue:0.16,alpha:1)); context.setLineWidth(12)
        context.move(to:CGPoint(x:183,y:265)); context.addLine(to:CGPoint(x:610,y:270)); context.addLine(to:CGPoint(x:715,y:756)); context.strokePath()
        NSGraphicsContext.restoreGraphicsState()
        let name="icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(name))
    }
}
