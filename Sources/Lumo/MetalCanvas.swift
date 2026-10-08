import SwiftUI
import MetalKit
import LumoCore

struct MetalCanvas: NSViewRepresentable {
    let scene: AbstractScene
    let renderer: MetalRenderer
    var error: (String) -> Void
    func makeCoordinator() -> Coordinator {Coordinator(renderer:renderer,error:error)}
    func makeNSView(context: Context) -> MTKView {
        let view=MTKView(frame:.zero,device:renderer.device)
        view.colorPixelFormat = .bgra8Unorm_srgb; view.framebufferOnly=true
        view.autoResizeDrawable=false; view.isPaused=true; view.enableSetNeedsDisplay=true; view.preferredFramesPerSecond=60
        view.layer?.contentsScale=NSScreen.main?.backingScaleFactor ?? 2
        (view.layer as? CAMetalLayer)?.colorspace=CGColorSpace(name:CGColorSpace.sRGB)
        context.coordinator.scene=scene; view.delegate=context.coordinator
        return view
    }
    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.scene=scene
        context.coordinator.resize(view)
        view.setNeedsDisplay(view.bounds)
    }
    final class Coordinator: NSObject, MTKViewDelegate {
        let renderer: MetalRenderer
        var scene: AbstractScene?
        var error: (String) -> Void
        var hasReportedError=false
        init(renderer:MetalRenderer,error:@escaping(String)->Void) {self.renderer=renderer; self.error=error}
        func resize(_ view: MTKView) {
            let size=view.bounds.size
            guard size.width>0,size.height>0 else {return}
            let scale=WindowMetrics.enabled ? 1536/max(size.width,size.height) : min(view.window?.backingScaleFactor ?? 2,1536/max(size.width,size.height))
            let target=CGSize(width:max(1,round(size.width*scale)),height:max(1,round(size.height*scale)))
            if view.drawableSize != target {view.drawableSize=target}
        }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) {
            resize(view)
            guard let scene, let drawable=view.currentDrawable,let pass=view.currentRenderPassDescriptor,let command=renderer.queue.makeCommandBuffer() else {return}
            do {
                try renderer.encode(scene:scene,viewport:CGRect(x:0,y:0,width:scene.aspect,height:1),pass:pass,command:command)
                if WindowMetrics.enabled {drawable.addPresentedHandler {WindowMetrics.shared.presented($0.presentedTime)}}
                command.present(drawable); command.commit()
            } catch {
                if !hasReportedError {hasReportedError=true; DispatchQueue.main.async {self.error(error.localizedDescription)}}
            }
        }
    }
}

struct CropOverlay: View {
    @Binding var crop: CropRegion
    let outputAspect: Double
    let canvasAspect: Double
    @State private var gestureStart: CropRegion?
    var body: some View {
        GeometryReader {proxy in
            let size=proxy.size
            let rect=CGRect(x:crop.x*size.width,y:crop.y*size.height,width:crop.width*size.width,height:crop.height*size.height)
            ZStack(alignment:.topLeading) {
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance:2,coordinateSpace:.named("cropCanvas")).onChanged {value in
                        crop=selection(from:value.startLocation,to:value.location,size:size)
                    })
                Path {p in p.addRect(CGRect(origin:.zero,size:size)); p.addRect(rect)}
                    .fill(.black.opacity(0.44),style:FillStyle(eoFill:true))
                    .allowsHitTesting(false)
                Rectangle().fill(.white.opacity(0.001)).overlay(Rectangle().stroke(Theme.accent,lineWidth:1.5))
                    .frame(width:rect.width,height:rect.height).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance:1,coordinateSpace:.named("cropCanvas")).onChanged {value in
                        if gestureStart == nil {gestureStart=crop}
                        let start=gestureStart!
                        crop.x=min(1-start.width,max(0,start.x+value.translation.width/size.width))
                        crop.y=min(1-start.height,max(0,start.y+value.translation.height/size.height))
                    }.onEnded {_ in gestureStart=nil})
                    .position(x:rect.midX,y:rect.midY)
                ForEach(0..<4,id:\.self) {corner in
                    let right=corner%2==1, bottom=corner>=2
                    RoundedRectangle(cornerRadius:2).fill(Theme.accent).frame(width:10,height:10)
                        .contentShape(Rectangle().inset(by:-5))
                        .gesture(DragGesture(minimumDistance:0,coordinateSpace:.named("cropCanvas")).onChanged {value in
                            if gestureStart == nil {gestureStart=crop}
                            let start=gestureStart!
                            let anchor=CGPoint(x:(right ? start.x : start.x+start.width)*size.width,y:(bottom ? start.y : start.y+start.height)*size.height)
                            crop=selection(from:anchor,to:value.location,size:size,forceRight:right,forceBottom:bottom)
                        }.onEnded {_ in gestureStart=nil})
                        .position(x:right ? rect.maxX : rect.minX,y:bottom ? rect.maxY : rect.minY)
                }
                Text("\(Int(crop.width*100))% × \(Int(crop.height*100))%")
                    .font(.system(size:10,weight:.medium,design:.monospaced)).padding(5).background(Theme.background.opacity(0.9),in:RoundedRectangle(cornerRadius:4))
                    .position(x:rect.midX,y:rect.minY>24 ? rect.minY-14 : rect.minY+14).allowsHitTesting(false)
            }.coordinateSpace(name:"cropCanvas")
        }
    }
    private func selection(from start: CGPoint,to end: CGPoint,size: CGSize,forceRight:Bool?=nil,forceBottom:Bool?=nil) -> CropRegion {
        let ax=min(1,max(0,start.x/size.width)), ay=min(1,max(0,start.y/size.height))
        let bx=min(1,max(0,end.x/size.width)), by=min(1,max(0,end.y/size.height))
        let right=forceRight ?? (bx>=ax), bottom=forceBottom ?? (by>=ay)
        let ratio=outputAspect/canvasAspect
        let maxWidth=right ? 1-ax : ax, maxHeight=bottom ? 1-ay : ay
        let rawWidth=max(abs(bx-ax),abs(by-ay)*ratio)
        let width=min(maxWidth,maxHeight*ratio,max(0.015,rawWidth)), height=width/ratio
        guard width>0.001,height>0.001 else {return crop}
        return CropRegion(x:right ? ax : ax-width,y:bottom ? ay : ay-height,width:width,height:height)
    }
}
