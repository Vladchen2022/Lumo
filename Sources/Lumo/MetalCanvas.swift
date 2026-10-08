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
    @Binding var crop: CropRegion?
    let canvasAspect: Double
    let longEdge: Int
    @State private var gestureStart: CropRegion?
    var body: some View {
        GeometryReader {proxy in
            let size=proxy.size
            ZStack(alignment:.topLeading) {
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance:2,coordinateSpace:.named("cropCanvas")).onChanged {value in
                        crop=CropRegion.selecting(from:normalized(value.startLocation,size),to:normalized(value.location,size),minimumSize:minimum(size))
                    })
                if let crop {
                    let rect=CGRect(x:crop.x*size.width,y:crop.y*size.height,width:crop.width*size.width,height:crop.height*size.height)
                    Path {p in p.addRect(CGRect(origin:.zero,size:size)); p.addRect(rect)}
                        .fill(.black.opacity(0.44),style:FillStyle(eoFill:true)).allowsHitTesting(false)
                    Rectangle().fill(.white.opacity(0.001)).overlay(Rectangle().stroke(Theme.accent,lineWidth:1.5))
                        .frame(width:rect.width,height:rect.height).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance:1,coordinateSpace:.named("cropCanvas")).onChanged {value in
                            if gestureStart == nil {gestureStart=crop}
                            self.crop=gestureStart!.moved(by:CGSize(width:value.translation.width/size.width,height:value.translation.height/size.height))
                        }.onEnded {_ in gestureStart=nil})
                        .onHover {hover in if hover {NSCursor.openHand.push()} else {NSCursor.pop()}}
                        .position(x:rect.midX,y:rect.midY)
                    // Full edge hit areas let users resize from anywhere along an edge.
                    ForEach([CropHandle.top,.right,.bottom,.left],id: \.self) {handle in
                        let horizontal=handle == .top || handle == .bottom
                        Rectangle().fill(.white.opacity(0.001))
                            .frame(width:horizontal ? max(1,rect.width-20) : 16,height:horizontal ? 16 : max(1,rect.height-20))
                            .overlay(Capsule().fill(Theme.accent).frame(width:horizontal ? min(24,rect.width) : 4,height:horizontal ? 4 : min(24,rect.height)))
                            .contentShape(Rectangle())
                            .gesture(resizeGesture(handle,crop:crop,size:size))
                            .onHover {hover in if hover {(horizontal ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push()} else {NSCursor.pop()}}
                            .position(x:handle == .left ? rect.minX : (handle == .right ? rect.maxX : rect.midX),y:handle == .top ? rect.minY : (handle == .bottom ? rect.maxY : rect.midY))
                    }
                    ForEach([CropHandle.topLeft,.topRight,.bottomRight,.bottomLeft],id: \.self) {handle in
                        RoundedRectangle(cornerRadius:2).fill(Theme.accent).frame(width:10,height:10)
                            .contentShape(Rectangle().inset(by:-6))
                            .gesture(resizeGesture(handle,crop:crop,size:size))
                            .position(x:handle.movesRight ? rect.maxX : rect.minX,y:handle.movesBottom ? rect.maxY : rect.minY)
                    }
                    let dimensions=ExportSettings.dimensions(aspect:crop.aspect(canvasAspect:canvasAspect),longEdge:longEdge)
                    Text("\(dimensions.width) × \(dimensions.height) px")
                        .font(.system(size:10,weight:.medium,design:.monospaced)).padding(5).background(Theme.background.opacity(0.9),in:RoundedRectangle(cornerRadius:4))
                        .position(x:rect.midX,y:rect.minY>28 ? rect.minY-17 : rect.minY+17).allowsHitTesting(false)
                } else {
                    Text("拖动建立自由矩形选区 · Esc 退出")
                        .font(.system(size:12,weight:.medium)).padding(12).background(Theme.background.opacity(0.9),in:RoundedRectangle(cornerRadius:6))
                        .position(x:size.width/2,y:30).allowsHitTesting(false)
                }
            }.coordinateSpace(name:"cropCanvas")
        }
    }
    private func normalized(_ point:CGPoint,_ size:CGSize) -> CGPoint {CGPoint(x:point.x/size.width,y:point.y/size.height)}
    private func minimum(_ size:CGSize) -> CGSize {CGSize(width:min(1,12/size.width),height:min(1,12/size.height))}
    private func resizeGesture(_ handle:CropHandle,crop:CropRegion,size:CGSize) -> some Gesture {
        DragGesture(minimumDistance:0,coordinateSpace:.named("cropCanvas")).onChanged {value in
            if gestureStart == nil {gestureStart=crop}
            let start=gestureStart!
            let point=CGPoint(x:(handle.movesRight ? start.x+start.width : start.x)+value.translation.width/size.width,y:(handle.movesBottom ? start.y+start.height : start.y)+value.translation.height/size.height)
            self.crop=start.resized(handle,to:point,minimumSize:minimum(size))
        }.onEnded {_ in gestureStart=nil}
    }
}
