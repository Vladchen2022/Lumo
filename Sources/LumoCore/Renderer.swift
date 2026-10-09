import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd

private struct MeshVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
    var blend: UInt32
}
private struct RenderUniforms { var viewport: SIMD4<Float> }
private struct LayerUniforms { var opacity: Float; var blend: UInt32 }
private struct FragmentVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
    var alpha: Float
    var blend: UInt32
}

public final class MetalRenderer: @unchecked Sendable {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let fragmentPipeline: MTLRenderPipelineState
    private let lineProcessor = LineExtractionProcessor()
    private let textureLock = NSLock()
    private var sourceTextures: [(Data,MTLTexture)] = []
    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw LumoError.message("这台 Mac 无法创建 Metal 画布。") }
        self.device = device; self.queue = queue
        guard let url = Bundle.module.url(forResource: "Lumo", withExtension: "metal", subdirectory: "Resources") else { throw LumoError.message("缺少画布资源，请重新构建应用。") }
        let source = try String(contentsOf: url, encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "lumoVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "lumoFragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm_srgb
        attachment.isBlendingEnabled = false
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.vertexFunction = library.makeFunction(name: "lumoCompositeVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "lumoCompositeFragment")
        compositePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.vertexFunction = library.makeFunction(name:"lumoImageVertex")
        descriptor.fragmentFunction = library.makeFunction(name:"lumoImageFragment")
        fragmentPipeline = try device.makeRenderPipelineState(descriptor:descriptor)
    }
    public func prepareLines(scene: AbstractScene) throws -> Data {
        guard let input = scene.lineInput, let parameters = scene.lineParameters else {throw LumoError.message("缺少固定的提线输入。")}
        let data = try lineProcessor.mask(input:input.deconstructionImage,parameters:parameters)
        _ = try sourceTexture(data:data)
        return data
    }
    private func drawImage(data: Data, aspect: Double, opacity: Float, viewport: CGRect, target: MTLTexture, command: MTLCommandBuffer) throws {
        let texture = try sourceTexture(data:data)
        func v(_ x: Float, _ y: Float) -> FragmentVertex {FragmentVertex(position:SIMD2(x*Float(aspect),y),uv:SIMD2(x,y),alpha:opacity,blend:0)}
        let vertices = [v(0,0),v(1,0),v(1,1),v(0,0),v(1,1),v(0,1)]
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture=target; pass.colorAttachments[0].loadAction = .load; pass.colorAttachments[0].storeAction = .store
        guard let buffer=vertices.withUnsafeBytes({device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}),
              let encoder=command.makeRenderCommandEncoder(descriptor:pass) else {throw LumoError.message("无法绘制线稿。")}
        var uniforms=RenderUniforms(viewport:SIMD4(Float(viewport.minX),Float(viewport.minY),Float(viewport.width),Float(viewport.height)))
        encoder.setRenderPipelineState(fragmentPipeline)
        encoder.setVertexBuffer(buffer,offset:0,index:0)
        encoder.setVertexBytes(&uniforms,length:MemoryLayout<RenderUniforms>.stride,index:1)
        encoder.setFragmentTexture(texture,index:0)
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:vertices.count); encoder.endEncoding()
    }
    public func encode(scene: AbstractScene, viewport: CGRect, pass: MTLRenderPassDescriptor, command: MTLCommandBuffer) throws {
        guard let target = pass.colorAttachments[0].texture else {throw LumoError.message("画布缺少输出纹理。")}
        func draw(_ vertices: [MeshVertex], _ pass: MTLRenderPassDescriptor) throws {
            guard !vertices.isEmpty else {return}
            guard let buffer = vertices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw LumoError.message("画布内存不足，无法绘制。") }
            var uniforms = RenderUniforms(viewport: SIMD4(Float(viewport.minX), Float(viewport.minY), Float(viewport.width), Float(viewport.height)))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
            encoder.endEncoding()
        }
        try draw(Self.mesh(scene:scene,layer:nil,background:true),pass)
        if let input=scene.lineInput,let parameters=scene.lineParameters {
            let mask = try scene.lineMask ?? prepareLines(scene:scene)
            if parameters.overlayOriginal {try drawImage(data:input.deconstructionImage,aspect:scene.aspect,opacity:1,viewport:viewport,target:target,command:command)}
            try drawImage(data:mask,aspect:scene.aspect,opacity:Float(parameters.opacity),viewport:viewport,target:target,command:command)
            return
        }
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm_srgb,width:target.width,height:target.height,mipmapped:false)
        textureDescriptor.storageMode = .private; textureDescriptor.usage = [.renderTarget,.shaderRead]
        guard let texture = device.makeTexture(descriptor:textureDescriptor) else {throw LumoError.message("无法创建颜色层，请降低画布尺寸。")}
        for index in scene.layers.indices {
            let layer = scene.layers[index]
            guard layer.enabled, layer.opacity > 0, index == 0 || layer.source != nil else {continue}
            if scene.method == .deconstruction && layer.source == nil {continue}
            let layerPass = MTLRenderPassDescriptor()
            layerPass.colorAttachments[0].texture = texture; layerPass.colorAttachments[0].loadAction = .clear; layerPass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0); layerPass.colorAttachments[0].storeAction = .store
            if scene.method == .deconstruction, let source = layer.source {
                let sourceTexture = try sourceTexture(data:source.deconstructionImage)
                let vertices = Self.fragmentMesh(scene:scene,layer:index)
                if !vertices.isEmpty {
                    guard let buffer = vertices.withUnsafeBytes({device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)}), let encoder = command.makeRenderCommandEncoder(descriptor:layerPass) else {throw LumoError.message("无法绘制图像碎片。")}
                    var uniforms = RenderUniforms(viewport:SIMD4(Float(viewport.minX),Float(viewport.minY),Float(viewport.width),Float(viewport.height)))
                    encoder.setRenderPipelineState(fragmentPipeline)
                    encoder.setVertexBuffer(buffer,offset:0,index:0)
                    encoder.setVertexBytes(&uniforms,length:MemoryLayout<RenderUniforms>.stride,index:1)
                    encoder.setFragmentTexture(sourceTexture,index:0)
                    encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:vertices.count)
                    encoder.endEncoding()
                }
            } else {try draw(Self.mesh(scene:scene,layer:index),layerPass)}
            let outputPass = MTLRenderPassDescriptor(); outputPass.colorAttachments[0].texture = target; outputPass.colorAttachments[0].loadAction = .load; outputPass.colorAttachments[0].storeAction = .store
            guard let encoder = command.makeRenderCommandEncoder(descriptor:outputPass) else {throw LumoError.message("无法合成颜色层。")}
            var settings = LayerUniforms(opacity:Float(layer.opacity),blend:scene.mode == .shape ? 0 : UInt32(layer.blend.rawValue))
            encoder.setRenderPipelineState(compositePipeline)
            encoder.setFragmentTexture(texture,index:0)
            encoder.setFragmentBytes(&settings,length:MemoryLayout<LayerUniforms>.stride,index:0)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3); encoder.endEncoding()
        }
    }
    private func sourceTexture(data: Data) throws -> MTLTexture {
        textureLock.lock(); defer {textureLock.unlock()}
        if let cached = sourceTextures.first(where:{$0.0 == data}) {return cached.1}
        let source = try ReferencePixels(data:data)
        var pixels = source.rgbaBytes
        // Unpremultiply in sRGB before upload; the sRGB texture then decodes RGB to linear light.
        for i in stride(from:0,to:pixels.count,by:4) {
            let alpha = Int(pixels[i+3])
            if alpha > 0 && alpha < 255 {for j in 0..<3 {pixels[i+j] = UInt8(min(255,(Int(pixels[i+j])*255+alpha/2)/alpha))}}
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm_srgb,width:source.width,height:source.height,mipmapped:false)
        descriptor.storageMode = .shared; descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor:descriptor) else {throw LumoError.message("原图纹理内存不足，请缩小参考图。")}
        pixels.withUnsafeBytes {texture.replace(region:MTLRegionMake2D(0,0,source.width,source.height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:source.width*4)}
        sourceTextures.insert((data,texture),at:0)
        if sourceTextures.count > 4 {sourceTextures.removeLast()}
        return texture
    }
    private static func fragmentMesh(scene: AbstractScene, layer: Int) -> [FragmentVertex] {
        var vertices: [FragmentVertex] = []
        let settings = scene.layers[layer]
        let alpha = Float(settings.blockOpacity), blend = UInt32(settings.blockBlend.rawValue)
        func vertex(_ position: SIMD2<Float>, _ uv: SIMD2<Float>, _ opacity: Float) -> FragmentVertex {FragmentVertex(position:position,uv:uv,alpha:opacity,blend:blend)}
        func triangle(_ a: FragmentVertex, _ b: FragmentVertex, _ c: FragmentVertex) {vertices.append(contentsOf:[a,b,c])}
        for fragment in scene.fragments where fragment.layer == layer {
            let points = fragment.contour, uv = fragment.textureCoordinates, count = points.count
            guard count >= 3 else {continue}
            let clearance = points.indices.map {i -> Float in
                let edge = points[(i+1)%count]-points[i], local = fragment.center-points[i]
                return abs(edge.x*local.y-edge.y*local.x)/max(simd_length(edge),0.000001)
            }.min() ?? 0
            // A site can be close to a cell edge. Keep the inward feather ring around the site
            // so its triangle fan cannot fold or overlap at high softness or fine partitioning.
            let feather = min(clearance*0.8,Float(scene.appearance.softness*0.025))
            let center = vertex(fragment.center,fragment.sourceCenter,alpha)
            let normals = points.indices.map {i -> SIMD2<Float> in
                let e1 = points[i]-points[(i+count-1)%count], e2 = points[(i+1)%count]-points[i]
                let a = e1/max(simd_length(e1),0.000001), b = e2/max(simd_length(e2),0.000001)
                let n1 = SIMD2(a.y,-a.x), n2 = SIMD2(b.y,-b.x), sum = n1+n2
                let normal = sum/max(simd_length(sum),0.000001)
                return normal/max(0.5,simd_dot(normal,n2))
            }
            for i in points.indices {
                let j = (i+1)%count
                let ai = vertex(points[i]-normals[i]*feather*0.5,uv[i],alpha)
                let aj = vertex(points[j]-normals[j]*feather*0.5,uv[j],alpha)
                triangle(center,ai,aj)
                if feather > 0 {
                    let bi = vertex(points[i]+normals[i]*feather*0.5,uv[i],0)
                    let bj = vertex(points[j]+normals[j]*feather*0.5,uv[j],0)
                    triangle(ai,bi,bj); triangle(ai,bj,aj)
                }
            }
        }
        return vertices
    }
    public func image(scene: AbstractScene, width: Int, height: Int, crop: CropRegion? = nil) throws -> CGImage {
        guard (1...4096).contains(width), (1...4096).contains(height) else { throw LumoError.message("导出宽高必须在 1–4096 像素之间。") }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor), let command = queue.makeCommandBuffer() else { throw LumoError.message("导出内存不足，请降低尺寸。") }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let viewport = crop?.viewport(aspect: scene.aspect) ?? CGRect(x: 0, y: 0, width: scene.aspect, height: 1)
        try encode(scene: scene, viewport: viewport, pass: pass, command: command)
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB), let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw LumoError.message("无法转换导出图片。") }
        return image
    }
    public func export(scene: AbstractScene, settings: ExportSettings, to url: URL) throws {
        let image = try image(scene: scene, width: settings.width, height: settings.height, crop: settings.crop)
        let type = settings.format == .png ? UTType.png.identifier : UTType.jpeg.identifier
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { throw LumoError.message("无法创建导出文件。") }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95, kCGImagePropertyProfileName: "sRGB IEC61966-2.1"]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw LumoError.message("图片编码失败。") }
        try (data as Data).write(to: url, options: .atomic)
    }
    private static func mesh(scene: AbstractScene, layer: Int?, background: Bool = false) -> [MeshVertex] {
        var output: [MeshVertex] = []
        output.reserveCapacity(70000)
        var blend: UInt32 = 0
        func vertex(_ p: SIMD2<Float>, _ c: SIMD3<Float>, _ alpha: Float) -> MeshVertex { MeshVertex(position: p, color: SIMD4(c.x,c.y,c.z,alpha), blend:blend) }
        func triangle(_ a: MeshVertex, _ b: MeshVertex, _ c: MeshVertex) { output.append(a); output.append(b); output.append(c) }
        if background {
        let bg = scene.background.linear
        let a = vertex(SIMD2(0,0),bg,1), b = vertex(SIMD2(Float(scene.aspect),0),bg,1), c = vertex(SIMD2(Float(scene.aspect),1),bg,1), d = vertex(SIMD2(0,1),bg,1)
        triangle(a,b,c); triangle(a,c,d)
        return output
        }
        for shape in scene.shapes where shape.opacity > 0 && shape.layer == layer {
            let blockOpacity = scene.mode == .shape ? Float(1) : Float(scene.layers[shape.layer].blockOpacity)
            blend = scene.mode == .shape ? 0 : UInt32(scene.layers[shape.layer].blockBlend.rawValue)
            let points = shape.contour, n = points.count
            let radius = points.map { simd_length($0 - shape.center) }.min() ?? 0.1
            let fill = scene.mode != .shape || scene.shapeDisplay == .solid
            let stroke = scene.mode == .combined || (scene.mode == .shape && scene.shapeDisplay == .outline)
            let feather = min(radius * 0.35, Float(0.00065 + scene.appearance.softness * 0.027))
            let fillColor = scene.mode == .shape ? RGBColor.ink.linear : shape.color.linear
            func shade(_ p: SIMD2<Float>) -> SIMD3<Float> {
                let amount: Float = scene.mode == .shape ? 0 : shape.gradient
                let shift = (p.x - shape.center.x + p.y - shape.center.y) / max(radius * 3, 0.001)
                return simd_clamp(fillColor * (1 + amount * shift), SIMD3(repeating: 0), SIMD3(repeating: 1))
            }
            let normals: [SIMD2<Float>] = (0..<n).map {i in
                let prev = points[(i+n-1)%n], p = points[i], next = points[(i+1)%n]
                let e1 = simd_normalize(p-prev), e2 = simd_normalize(next-p)
                let n1 = SIMD2(e1.y,-e1.x), n2 = SIMD2(e2.y,-e2.x)
                let sum = n1+n2
                let normal = simd_length_squared(sum)>0.000001 ? simd_normalize(sum) : n2
                return normal / max(0.5,simd_dot(normal,n2))
            }
            func offset(_ i: Int, _ amount: Float) -> SIMD2<Float> {points[i]+normals[i]*amount}
            if fill {
                let inner = (0..<n).map { offset($0,-feather * 0.5) }
                let outer = (0..<n).map { offset($0,feather * 0.5) }
                let center = vertex(shape.center,shade(shape.center),shape.opacity*blockOpacity)
                for i in 0..<n {
                    let j = (i+1)%n
                    let ai = vertex(inner[i],shade(inner[i]),shape.opacity*blockOpacity), aj = vertex(inner[j],shade(inner[j]),shape.opacity*blockOpacity)
                    let bi = vertex(outer[i],shade(outer[i]),0), bj = vertex(outer[j],shade(outer[j]),0)
                    triangle(center,ai,aj); triangle(ai,bi,bj); triangle(ai,bj,aj)
                }
            }
            if stroke {
                blend = 0
                let half = min(radius * 0.25, Float(0.0005 + scene.appearance.lineWidth * 0.008))
                let aa = min(half * 0.6, 0.00065)
                let ringOffsets = [-half-aa,-half+aa,half-aa,half+aa]
                let alpha: Float = shape.opacity * Float(scene.appearance.lineStrength)
                let ringAlphas: [Float] = [0,alpha,alpha,0]
                let ink = RGBColor.ink.linear
                for ring in 0..<3 { for i in 0..<n {
                    let j = (i+1)%n
                    let ai = vertex(offset(i,ringOffsets[ring]),ink,ringAlphas[ring]), aj = vertex(offset(j,ringOffsets[ring]),ink,ringAlphas[ring])
                    let bi = vertex(offset(i,ringOffsets[ring+1]),ink,ringAlphas[ring+1]), bj = vertex(offset(j,ringOffsets[ring+1]),ink,ringAlphas[ring+1])
                    triangle(ai,bi,bj); triangle(ai,bj,aj)
                } }
            }
        }
        return output
    }
}
