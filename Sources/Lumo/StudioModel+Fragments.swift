import SwiftUI
import LumoCore

extension StudioModel {
    var editingCutLayer: Int? {
        editingLayer && recipe.fixedCanvas == nil && recipe.layer(selectedColorLayer).source != nil ? selectedColorLayer : nil
    }
    var cutParameters: DeconstructionParameters {
        editingCutLayer.flatMap {recipe.arrangement.layers[$0]?.parameters} ?? recipe.deconstruction
    }
    var cutLayerLocked: Bool {
        editingCutLayer.flatMap {recipe.arrangement.layers[$0]?.isLocked} ?? false
    }
    var layerOrder: [Int] {recipe.method == .deconstruction ? recipe.arrangement.layerOrder : [0,1,2]}

    func editCuts(_ update: (inout DeconstructionParameters)->Void) {
        let slot=editingCutLayer
        edit {r in
            if let slot {
                var layer=r.arrangement.layers[slot] ?? LayerDeconstruction(parameters:r.deconstruction)
                guard !layer.isLocked else {return}
                update(&layer.parameters)
                r.arrangement.layers[slot]=layer
            } else {update(&r.deconstruction)}
        }
    }
    func cutBinding<T>(_ path:WritableKeyPath<DeconstructionParameters,T>, expanded:Bool=false, strong:Bool=false) -> Binding<T> {
        Binding(get:{self.cutParameters[keyPath:path]},set:{value in
            self.editCuts {
                $0[keyPath:path]=value
                if expanded || strong {$0.expandedTransforms=true}
                if strong {$0.strongTransforms=true}
            }
        })
    }
    func followGlobalCuts(_ slot:Int) {edit {$0.arrangement.layers.removeValue(forKey:slot)}}
    func toggleLayerLock(_ slot:Int) {
        edit {r in
            var layer=r.arrangement.layers[slot] ?? LayerDeconstruction(parameters:r.deconstruction)
            if layer.isLocked {layer.lockedShapeSeed=nil; layer.lockedColorSeed=nil}
            else {layer.lockedShapeSeed=r.shapeSeed; layer.lockedColorSeed=r.colorSeed}
            r.arrangement.layers[slot]=layer
        }
    }
    func moveLayer(_ slot:Int, nextTo target:Int) {
        guard slot != target, recipe.method == .deconstruction else {return}
        edit {r in
            var order=r.arrangement.layerOrder
            guard let from=order.firstIndex(of:slot),let to=order.firstIndex(of:target) else {return}
            order.remove(at:from); order.insert(slot,at:to)
            r.arrangement.layerOrder=order
        }
    }
    static func resetFragmentLayout(_ recipe:inout GenerationRecipe) {
        recipe.deconstruction.breakup=0
        recipe.arrangement.fragments.removeAll()
        for slot in Array(recipe.arrangement.layers.keys) {recipe.arrangement.layers[slot]?.parameters.breakup=0}
    }
    func resetFragmentLayout() {edit {Self.resetFragmentLayout(&$0)}}
    func toggleFragmentEditing() {
        guard recipe.method == .deconstruction,!isShowingLines else {return}
        if isCropping {finishCrop()}
        fragmentEditing.toggle()
        if !fragmentEditing {selectedFragment=nil}
    }
    var selectedFragmentGeometry: ImageFragment? {scene.fragments.first {$0.id==selectedFragment}}
    func selectFragment(at point:CGPoint,canvas:CGSize) {
        selectedFragment=scene.fragment(at:SIMD2(Float(point.x/canvas.width*scene.aspect),Float(point.y/canvas.height)))?.id
    }
    func moveFragment(_ id:Int,offset:SIMD2<Float>) {
        guard recipe.arrangement.fragments[id]?.pinned == nil, recipe.arrangement.layers[id/80]?.isLocked != true else {return}
        edit {r in
            var value=r.arrangement.fragments[id] ?? FragmentAdjustment()
            value.offset=SIMD2(min(4,max(-4,offset.x)),min(4,max(-4,offset.y)))
            r.arrangement.fragments[id] = value == FragmentAdjustment() ? nil : value
        }
    }
    func toggleSelectedPin() {
        guard let fragment=selectedFragmentGeometry,recipe.arrangement.layers[fragment.layer]?.isLocked != true else {return}
        edit {r in
            var value=r.arrangement.fragments[fragment.id] ?? FragmentAdjustment()
            if value.pinned == nil {
                value.pinned=fragment; value.pinnedAspect=r.canvasAspect; value.offset = .zero
            } else {value.pinned=nil; value.pinnedAspect=nil}
            r.arrangement.fragments[fragment.id] = value == FragmentAdjustment() ? nil : value
        }
    }
    func hideSelectedFragment() {
        guard let id=selectedFragment,recipe.arrangement.layers[id/80]?.isLocked != true else {return}
        edit {$0.arrangement.fragments[id,default:FragmentAdjustment()].hidden=true}
    }
    func showHiddenFragments() {
        edit {r in
            for id in Array(r.arrangement.fragments.keys) {
                r.arrangement.fragments[id]?.hidden=false
                if r.arrangement.fragments[id] == FragmentAdjustment() {r.arrangement.fragments[id]=nil}
            }
        }
    }
}
