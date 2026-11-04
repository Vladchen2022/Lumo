import SwiftUI
import LumoCore

struct FragmentEditor: View {
    @ObservedObject var model: StudioModel
    @State private var dragStarted=false
    @State private var move: Move?
    private struct Move {
        var id: Int
        var offset: SIMD2<Float>
    }

    var body: some View {
        GeometryReader { proxy in
            let size=proxy.size
            Color.clear.contentShape(Rectangle())
                .onTapGesture(coordinateSpace:.local) {point in model.selectFragment(at:point,canvas:size)}
                .gesture(DragGesture(minimumDistance:3,coordinateSpace:.local)
                    .onChanged { value in
                        if !dragStarted {
                            dragStarted=true
                            model.selectFragment(at:value.startLocation,canvas:size)
                            guard let id=model.selectedFragment,
                                  model.recipe.arrangement.fragments[id]?.pinned == nil,
                                  model.recipe.arrangement.layers[id/80]?.isLocked != true else {return}
                            move=Move(id:id,offset:model.recipe.arrangement.fragments[id]?.offset ?? .zero)
                            model.sliderEditing(true)
                        }
                        if let move {
                            let delta=SIMD2(Float(value.translation.width/size.width),Float(value.translation.height/size.height))
                            model.moveFragment(move.id,offset:move.offset+delta)
                        }
                    }
                    .onEnded {_ in endMove()})
                .overlay {
                    if let fragment=model.selectedFragmentGeometry {
                        Path { path in
                            for (i,p) in fragment.contour.enumerated() {
                                let point=CGPoint(x:Double(p.x)/model.scene.aspect*size.width,y:Double(p.y)*size.height)
                                if i==0 {path.move(to:point)} else {path.addLine(to:point)}
                            }
                            path.closeSubpath()
                        }.stroke(Theme.accent,style:StrokeStyle(lineWidth:2,dash:[6,3]))
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("碎片编辑画布")
        }.onDisappear {endMove()}
    }
    private func endMove() {
        if move != nil {model.sliderEditing(false)}
        move=nil; dragStarted=false
    }
}
