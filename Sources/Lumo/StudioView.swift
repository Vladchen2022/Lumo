import SwiftUI
import LumoCore

enum Theme {
    static let background=Color(red:0.075,green:0.085,blue:0.10)
    static let panel=Color(red:0.10,green:0.115,blue:0.13)
    static let inset=Color(red:0.135,green:0.15,blue:0.165)
    static let accent=Color(red:0.62,green:0.88,blue:0.78)
    static let secondary=Color(red:0.60,green:0.64,blue:0.67)
    static let line=Color.white.opacity(0.075)
}
extension LumoCore.RGBColor {var swiftUI:Color {Color(.sRGB,red:r,green:g,blue:b,opacity:1)}}

struct StudioView: View {
    @ObservedObject var model:StudioModel
    var body: some View {
        VStack(spacing:0) {
            header
            Divider().overlay(Theme.line)
            HStack(spacing:0) {
                sources.frame(width:224)
                Divider().overlay(Theme.line)
                workspace.frame(maxWidth:.infinity,maxHeight:.infinity)
                Divider().overlay(Theme.line)
                controls.frame(width:272)
            }
            Divider().overlay(Theme.line)
            HStack(spacing:8) {
                Circle().fill(model.isExporting ? Color.orange : Theme.accent).frame(width:5,height:5)
                Text(model.status).lineLimit(1)
                Spacer()
                Text(model.title).lineLimit(1)
                Text("本地生成").padding(.leading,10)
            }.font(.system(size:10)).foregroundStyle(Theme.secondary).padding(.horizontal,18).frame(height:30)
        }
        .background(Theme.background).foregroundStyle(.white.opacity(0.88))
        .frame(minWidth:1120,minHeight:730)
        .preferredColorScheme(.dark).tint(Theme.accent)
        .sheet(isPresented:$model.showExportSheet) {ExportSheet(model:model)}
        .sheet(isPresented:$model.showColorPicker) {ReferenceColorPicker(model:model,layer:model.selectedColorLayer)}
        .alert("操作未完成",isPresented:Binding(get:{model.alert != nil},set:{if !$0 {model.alert=nil}}),presenting:model.alert) { _ in Button("知道了",role:.cancel) {model.alert=nil} } message: {Text($0.message)}
    }
    private var header:some View {
        HStack(spacing:18) {
            HStack(spacing:8) {
                Image(systemName:"square.stack.3d.up.fill").font(.system(size:18)).foregroundStyle(Theme.accent)
                Text("LUMO").font(.system(size:15,weight:.semibold,design:.rounded)).tracking(2)
            }.frame(width:185,alignment:.leading)
            Picker("显示模式",selection:model.binding(\.mode)) {ForEach(DisplayMode.allCases,id:\.self) {Text($0.title).tag($0)}}
                .pickerStyle(.segmented).frame(width:210).accessibilityIdentifier("displayMode")
            Menu {ForEach(CompositionPreset.allCases,id:\.self) {preset in Button(preset.title) {model.apply(preset)}}} label: {Label("起始构成",systemImage:"square.grid.2x2")}
                .menuStyle(.borderlessButton).fixedSize()
            Spacer(minLength:0)
            HStack(spacing:8) {
                Button {model.undo()} label: {Image(systemName:"arrow.uturn.backward")}.disabled(!model.canUndo).help("撤销 ⌘Z")
                Button {model.redo()} label: {Image(systemName:"arrow.uturn.forward")}.disabled(!model.canRedo).help("重做 ⇧⌘Z")
            }.buttonStyle(.borderless)
            Button {model.addSnapshot()} label: {Label("收藏",systemImage:"bookmark")}.buttonStyle(.bordered)
            if model.exportSettings.crop != nil {
                Button {model.finishCrop()} label: {Label("退出框选",systemImage:"xmark.circle.fill")}
                    .buttonStyle(.bordered).help("退出框选 · Esc").accessibilityIdentifier("exitCrop")
            }
            Button {model.showExportSheet=true} label: {Label(model.exportSettings.crop == nil ? "框选 / 导出" : "导出选区",systemImage:"square.and.arrow.up")}
                .buttonStyle(.borderedProminent).foregroundStyle(Theme.background).disabled(model.renderer == nil || model.isExporting)
        }.controlSize(.small).padding(.horizontal,18).frame(height:58)
    }
    private var sources:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                VStack(alignment:.leading,spacing:4) {
                    Text("参考来源").font(.system(size:14,weight:.semibold))
                    Text("分开取色与结构，重新构成").font(.system(size:10)).foregroundStyle(Theme.secondary)
                }
                ColorSourcesView(model:model)
                SourceCard(model:model,color:false)
                Button {model.randomize()} label: {Label("全部随机",systemImage:"shuffle").frame(maxWidth:.infinity)}
                    .buttonStyle(.bordered).controlSize(.large).disabled(model.recipe.colorLocked && model.recipe.shapeLocked).help("尊重两个来源的锁定状态")
                Divider().overlay(Theme.line)
                HStack {
                    Text("收藏").font(.system(size:12,weight:.semibold))
                    Spacer(); Text("\(model.snapshots.count)").font(.system(size:10,design:.monospaced)).foregroundStyle(Theme.secondary)
                }
                if model.snapshots.isEmpty {
                    VStack(alignment:.leading,spacing:8) {
                        Image(systemName:"bookmark").font(.system(size:17)).foregroundStyle(Theme.secondary)
                        Text("留下值得继续的构成").font(.system(size:11))
                        Text("收藏后可以恢复参数，再探索变化。").font(.system(size:10)).foregroundStyle(Theme.secondary).lineSpacing(3)
                    }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(Theme.inset,in:RoundedRectangle(cornerRadius:8))
                } else {
                    ForEach(model.snapshots) {snapshot in
                        HStack(spacing:9) {
                            Button {model.restore(snapshot)} label: {
                                HStack(spacing:9) {
                                    SnapshotPreview(recipe:snapshot.recipe).equatable().frame(width:44,height:44).clipShape(RoundedRectangle(cornerRadius:4))
                                    VStack(alignment:.leading,spacing:4) {Text(snapshot.name).font(.system(size:11,weight:.medium)); Text(snapshot.recipe.mode.title).font(.system(size:10)).foregroundStyle(Theme.secondary)}
                                    Spacer(minLength:0)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Button {model.deleteSnapshot(snapshot.id)} label: {Image(systemName:"xmark").font(.system(size:9)).foregroundStyle(Theme.secondary)}.buttonStyle(.plain).help("删除收藏")
                        }.padding(8).background(Theme.inset,in:RoundedRectangle(cornerRadius:7))
                    }
                }
            }.padding(18)
        }.background(Theme.panel)
    }
    private var workspace:some View {
        VStack(spacing:0) {
            HStack {
                Text(model.exportSettings.crop == nil ? "构成画布" : "框选局部").font(.system(size:11,weight:.medium)).foregroundStyle(Theme.secondary)
                Spacer()
                if model.exportSettings.crop != nil {
                    Text("Esc 退出").font(.system(size:10))
                } else {
                    Menu {
                        Button("方形 · 1:1") {model.edit {$0.canvasAspect=1}}
                        Button("横向 · 4:3") {model.edit {$0.canvasAspect=4.0/3}}
                        Button("纵向 · 3:4") {model.edit {$0.canvasAspect=3.0/4}}
                        Button("宽幅 · 16:9") {model.edit {$0.canvasAspect=16.0/9}}
                    } label: {Text(aspectTitle).font(.system(size:11))}.menuStyle(.borderlessButton).fixedSize()
                }
            }.padding(.horizontal,24).frame(height:42)
            GeometryReader {proxy in
                let available=CGSize(width:max(1,proxy.size.width-48),height:max(1,proxy.size.height-48))
                let width=min(available.width,available.height*model.recipe.canvasAspect), height=width/model.recipe.canvasAspect
                ZStack {
                    if let renderer=model.renderer {
                        MetalCanvas(scene:model.scene,renderer:renderer) {model.alert=StudioAlert(message:$0)}
                    } else {Text("无法创建画布").foregroundStyle(Theme.secondary)}
                    if let crop=model.exportSettings.crop {
                        CropOverlay(crop:Binding(get:{model.exportSettings.crop ?? crop},set:{model.exportSettings.crop=$0}),outputAspect:Double(model.exportSettings.width)/Double(model.exportSettings.height),canvasAspect:model.recipe.canvasAspect)
                    }
                }.frame(width:width,height:height).contentShape(Rectangle()).clipped().shadow(color:.black.opacity(0.28),radius:20,y:8)
                    .position(x:proxy.size.width/2,y:proxy.size.height/2)
            }
            HStack(spacing:8) {
                Text(model.recipe.mode == .shape ? (model.recipe.shapeDisplay == .outline ? "单色线条" : "单色块面") : (model.recipe.mode == .color ? "色块 · 无描边" : "色块 + 线条"))
                Text("·")
                Text("sRGB")
                Spacer()
                Button("换颜色") {model.randomize(shape:false)}.disabled(model.recipe.colorLocked || model.recipe.mode == .shape)
                Button("换结构") {model.randomize(color:false)}.disabled(model.recipe.shapeLocked)
            }.font(.system(size:10)).foregroundStyle(Theme.secondary).buttonStyle(.borderless).padding(.horizontal,24).frame(height:42)
        }
    }
    private var aspectTitle:String {let a=model.recipe.canvasAspect; return abs(a-1)<0.01 ? "1:1" : (abs(a-4.0/3)<0.01 ? "4:3" : (abs(a-3.0/4)<0.01 ? "3:4" : "16:9"))}
    private var controls:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                HStack {Text("调节构成").font(.system(size:14,weight:.semibold)); Spacer(); Image(systemName:"slider.horizontal.3").foregroundStyle(Theme.secondary)}
                if model.recipe.mode == .shape {
                    Picker("形状表现",selection:model.binding(\.shapeDisplay)) {ForEach(ShapeDisplay.allCases,id:\.self) {Text($0.title).tag($0)}}.pickerStyle(.segmented)
                }
                VStack(spacing:16) {
                    groupHeader("色彩") {model.edit {$0.color=ColorParameters()}}
                    parameter("色相",\.color.hue,range:-180...180,angle:true)
                    parameter("饱和度",\.color.saturation)
                    parameter("明度",\.color.brightness)
                    parameter("明暗对比",\.color.contrast)
                }.disabled(model.recipe.mode == .shape).opacity(model.recipe.mode == .shape ? 0.38 : 1)
                Divider().overlay(Theme.line)
                VStack(spacing:16) {
                    groupHeader("结构") {model.edit {$0.shape=$0.shapeSource?.features.map(ShapeParameters.init(features:)) ?? ShapeParameters()}}
                    parameter("密度",\.shape.density)
                    parameter("块面尺度",\.shape.scale)
                    parameter("大小差异",\.shape.variation)
                    parameter("曲直",\.shape.curvature,left:"棱角",right:"曲线")
                    parameter("有机起伏",\.shape.organic,left:"平整",right:"流动 / 凹凸")
                    parameter("侵蚀细节",\.shape.erosion,left:"简洁",right:"斑驳")
                    parameter("拉伸",\.shape.stretch)
                    parameter("方向",\.shape.direction,range:-180...180,angle:true)
                }
                Divider().overlay(Theme.line)
                VStack(spacing:16) {
                    groupHeader("表现") {model.edit {$0.appearance=AppearanceParameters()}}
                    if model.recipe.mode != .shape || model.recipe.shapeDisplay == .solid {parameter("边缘软硬",\.appearance.softness,left:"清晰",right:"柔软")}
                    if model.recipe.mode == .combined || (model.recipe.mode == .shape && model.recipe.shapeDisplay == .outline) {
                        parameter("线条粗细",\.appearance.lineWidth)
                        parameter("线条强度",\.appearance.lineStrength)
                    }
                }
                DisclosureGroup("高级调节") {
                    VStack(spacing:16) {
                        parameter("聚散",\.shape.clustering,left:"分散",right:"聚集")
                        parameter("方向一致性",\.shape.coherence)
                        parameter("主色占比",\.color.dominance).disabled(model.recipe.mode == .shape)
                    }.padding(.top,16)
                }.font(.system(size:11,weight:.medium)).foregroundStyle(Theme.secondary)
                Text("拖动保留随机基础，松开后可撤销这次调节。").font(.system(size:10)).foregroundStyle(Theme.secondary).lineSpacing(3)
            }.padding(20)
        }.background(Theme.panel)
    }
    private func groupHeader(_ title:String,reset:@escaping()->Void) -> some View {
        HStack {Text(title).font(.system(size:11,weight:.semibold)); Spacer(); Button("重置",action:reset).font(.system(size:10)).buttonStyle(.borderless).foregroundStyle(Theme.secondary)}
    }
    private func parameter(_ name:String,_ path:WritableKeyPath<GenerationRecipe,Double>,range:ClosedRange<Double>=0...1,angle:Bool=false,left:String?=nil,right:String?=nil) -> some View {
        VStack(spacing:5) {
            HStack {Text(name).font(.system(size:11)); Spacer(); Text(angle ? "\(Int(model.recipe[keyPath:path].rounded()))°" : "\(Int((model.recipe[keyPath:path]*100).rounded()))").font(.system(size:10,design:.monospaced)).foregroundStyle(Theme.secondary)}
            Slider(value:model.binding(path),in:range,onEditingChanged:model.sliderEditing).controlSize(.small).accessibilityLabel(name).accessibilityIdentifier(name)
            if let left,let right {HStack {Text(left); Spacer(); Text(right)}.font(.system(size:9)).foregroundStyle(Theme.secondary)}
        }
    }
}

private struct SourceCard:View {
    @ObservedObject var model:StudioModel
    let color:Bool
    private var source:SourceReference? {color ? model.recipe.colorSource : model.recipe.shapeSource}
    private var locked:Bool {color ? model.recipe.colorLocked : model.recipe.shapeLocked}
    private var importing:Bool {color ? model.importingColor : model.importingShape}
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Text(color ? "颜色来源" : "形状来源").font(.system(size:11,weight:.semibold))
                Spacer()
                Button {model.edit {if color {$0.colorLocked.toggle()} else {$0.shapeLocked.toggle()}}} label: {Image(systemName:locked ? "lock.fill" : "lock.open").font(.system(size:11)).foregroundStyle(locked ? Theme.accent : Theme.secondary)}
                    .buttonStyle(.plain).help(locked ? "已锁定：随机时保持此来源" : "锁定此来源，随机时保持不变").accessibilityLabel(color ? "锁定颜色" : "锁定结构")
            }
            Button {model.importImage(color:color)} label: {
                ZStack {
                    RoundedRectangle(cornerRadius:7).fill(Theme.inset)
                    if let source {SourceThumbnail(source:source).equatable().padding(5)}
                    else {
                        VStack(spacing:7) {
                            Image(systemName:color ? "photo.badge.plus" : "square.on.circle").font(.system(size:22,weight:.light)).foregroundStyle(Theme.accent.opacity(0.8))
                            Text("导入参考图片").font(.system(size:11))
                            Text(color ? "提取颜色及占比" : "提取方向、疏密与曲直").font(.system(size:9)).foregroundStyle(Theme.secondary)
                        }
                    }
                    if importing {Theme.background.opacity(0.7); ProgressView().controlSize(.small)}
                }.frame(height:100).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(color ? "导入颜色参考" : "导入形状参考")
            HStack {
                Text(source?.name ?? "随机来源").font(.system(size:9)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if source != nil {Button {model.clearSource(color:color)} label: {Image(systemName:"xmark.circle").font(.system(size:10))}.buttonStyle(.plain).foregroundStyle(Theme.secondary).help("清除参考")}
            }
            if color {
                HStack(spacing:3) {ForEach(Array(SceneGenerator.palette(for:model.recipe).enumerated()),id:\.offset) {entry in Rectangle().fill(entry.element.color.swiftUI).frame(maxWidth:.infinity).frame(height:15)}}.clipShape(RoundedRectangle(cornerRadius:3))
            }
            Button {model.randomize(color:color,shape:!color)} label: {Label(color ? "换颜色" : "换结构",systemImage:"arrow.triangle.2.circlepath").frame(maxWidth:.infinity)}.buttonStyle(.bordered).controlSize(.small).disabled(locked)
        }
    }
}
private struct SourceThumbnail:View,Equatable {
    let source:SourceReference
    var body:some View {if let image=NSImage(data:source.thumbnail) {Image(nsImage:image).resizable().scaledToFit()} else {Image(systemName:"photo")}}
}
private enum SnapshotRenderer {static let shared = try? MetalRenderer()}
private struct SnapshotPreview:View,Equatable {
    let recipe:GenerationRecipe
    @State private var image:CGImage?
    static func == (a:Self,b:Self) -> Bool {a.recipe == b.recipe}
    var body:some View {
        Group {
            if let image {Image(decorative:image,scale:1).resizable().scaledToFill()}
            else {Theme.inset}
        }.task(id:recipe) {
            let captured = recipe
            image = try? await Task.detached(priority:.utility) {
                guard let renderer = SnapshotRenderer.shared else {throw LumoError.message("无法预览收藏")}
                return try renderer.image(scene:SceneGenerator.generate(captured),width:96,height:96)
            }.value
        }
    }
}
