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
    @State private var canvasZoom=1.0
    @State private var showDraftActions=false
    var body: some View {
        VStack(spacing:0) {
            header.disabled(model.isEditingBlocked)
            Divider().overlay(Theme.line)
            HStack(spacing:0) {
                sources.frame(width:224)
                Divider().overlay(Theme.line)
                workspace.frame(maxWidth:.infinity,maxHeight:.infinity)
                Divider().overlay(Theme.line)
                controls.frame(width:272)
            }
            .disabled(model.isEditingBlocked)
            Divider().overlay(Theme.line)
            HStack(spacing:8) {
                if model.isProcessingLines || model.isCapturingLines || model.isProjectBusy {ProgressView().controlSize(.mini)}
                else {Circle().fill(model.isExporting ? Color.orange : Theme.accent).frame(width:5,height:5)}
                Text(model.status).lineLimit(1)
                Spacer()
                if let warning=model.storageWarning {Text(warning).foregroundStyle(.orange).lineLimit(1).help(warning)}
                if model.recoveryAvailable {Button("恢复草稿…") {showDraftActions=true}.buttonStyle(.borderless)}
                Text(model.title).lineLimit(1)
                Text("本地生成").padding(.leading,10)
            }.font(.system(size:10)).foregroundStyle(Theme.secondary).padding(.horizontal,18).frame(height:30)
        }
        .background(Theme.background).foregroundStyle(.white.opacity(0.88))
        .frame(minWidth:1120,minHeight:730)
        .preferredColorScheme(.dark).tint(Theme.accent)
        .sheet(isPresented:$model.showExportSheet) {ExportSheet(model:model)}
        .sheet(isPresented:$model.showColorPicker) {ReferenceColorPicker(model:model,layer:model.selectedColorLayer)}
        .sheet(item:$model.comparison) {snapshot in ComparisonSheet(model:model,snapshot:snapshot,current:model.recipe)}
        .confirmationDialog("发现上次未保存的草稿",isPresented:$showDraftActions,titleVisibility:.visible) {
            Button("恢复为新项目") {Task {await model.recoverDraft()}}
            Button("丢弃草稿",role:.destructive) {Task {await model.discardDraft()}}
            Button("稍后处理",role:.cancel) {}
        } message: {Text("恢复不会覆盖已保存的项目文件。")}
        .alert("操作未完成",isPresented:Binding(get:{model.alert != nil},set:{if !$0 {model.alert=nil}}),presenting:model.alert) { _ in Button("知道了",role:.cancel) {model.alert=nil} } message: {Text($0.message)}
    }
    private var header:some View {
        HStack(spacing:18) {
            HStack(spacing:8) {
                Image(systemName:"square.stack.3d.up.fill").font(.system(size:18)).foregroundStyle(Theme.accent)
                Text("LUMO").font(.system(size:15,weight:.semibold,design:.rounded)).tracking(2)
            }.frame(width:185,alignment:.leading)
            if model.isShowingLines {
                Label("线条提取",systemImage:"scribble.variable").font(.system(size:12,weight:.medium)).foregroundStyle(Theme.accent).frame(width:210,alignment:.leading)
            } else if model.recipe.method == .abstract {
                Picker("显示模式",selection:model.binding(\.mode)) {ForEach(DisplayMode.allCases,id:\.self) {Text($0.title).tag($0)}}
                    .pickerStyle(.segmented).frame(width:210).accessibilityIdentifier("displayMode")
            } else {
                Label("图像解构",systemImage:"square.on.square.dashed").font(.system(size:12,weight:.medium)).foregroundStyle(Theme.accent).frame(width:210,alignment:.leading)
            }
            Menu {ForEach(CompositionPreset.allCases,id:\.self) {preset in Button(preset.title) {model.apply(preset)}}} label: {Label("起始构成",systemImage:"square.grid.2x2")}
                .menuStyle(.borderlessButton).fixedSize().disabled(model.temporaryLineInput != nil)
            Spacer(minLength:0)
            Button {model.fixCurrentEffect()} label: {Label(model.isFixing ? "保存阶段中…" : (model.temporaryLineInput != nil ? "保存提线阶段" : "固定当前效果"),systemImage:"checkmark.seal")}
                .buttonStyle(.bordered).disabled(!model.canFix).help("固定整张画布，作为下一轮输入；自动保存固定前阶段，⌘Z 可撤销").accessibilityIdentifier("fixEffect")
            HStack(spacing:8) {
                Button {model.undo()} label: {Image(systemName:"arrow.uturn.backward")}.disabled(!model.canUndo).help("撤销 ⌘Z")
                Button {model.redo()} label: {Image(systemName:"arrow.uturn.forward")}.disabled(!model.canRedo).help("重做 ⇧⌘Z")
            }.buttonStyle(.borderless)
            Button {model.addSnapshot()} label: {Label("收藏",systemImage:"bookmark")}.buttonStyle(.bordered).disabled(model.temporaryLineInput != nil)
            if model.isCropping {
                Button {model.finishCrop()} label: {Label("退出框选",systemImage:"xmark.circle.fill")}
                    .buttonStyle(.bordered).help("退出框选 · Esc").accessibilityIdentifier("exitCrop")
            } else {
                Button {model.prepareCrop(longEdge:max(model.exportSettings.width,model.exportSettings.height),format:model.exportSettings.format)} label: {Label("框选局部",systemImage:"crop")}
                    .buttonStyle(.bordered).accessibilityIdentifier("startCrop")
            }
            Button {model.showExportSheet=true} label: {Label(model.isCropping ? "导出选区" : "导出…",systemImage:"square.and.arrow.up")}
                .buttonStyle(.borderedProminent).foregroundStyle(Theme.background).disabled(!model.canExport)
        }.controlSize(.small).padding(.horizontal,18).frame(height:58)
    }
    private var sources:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                VStack(alignment:.leading,spacing:4) {
                    Text("参考来源").font(.system(size:14,weight:.semibold))
                    Text(model.isShowingLines ? "保留原构成，继续调整线条" : (model.recipe.method == .abstract ? "分开取色与结构，重新构成" : "保留原图内容，分块后重新组织")).font(.system(size:10)).foregroundStyle(Theme.secondary)
                }
                if model.temporaryLineInput != nil {
                    Text("试提当前线稿").font(.system(size:12,weight:.semibold)).foregroundStyle(Theme.accent)
                    Text("直接使用刚才的构成。返回可继续编辑，满意后可保存为阶段。").font(.system(size:10)).foregroundStyle(Theme.secondary)
                } else if let fixed=model.recipe.fixedCanvas {
                    VStack(alignment:.leading,spacing:12) {
                        Text("阶段输入 · 第 \(fixed.round) 次固定").font(.system(size:12,weight:.semibold)).foregroundStyle(Theme.accent)
                        SourceThumbnail(source:fixed.reference).equatable().frame(height:115).frame(maxWidth:.infinity).padding(6).background(Theme.inset,in:RoundedRectangle(cornerRadius:7))
                        Text(model.isShowingLines ? "当前提取上方固定画面。返回构成后，可直接试提调整后的画面。" : (model.recipe.method == .abstract ? (fixed.geometry != nil ? "保留固定时的布局与形状，滑块继续变形。色彩与结构以 50 为起点，方向和色相为 0；表现参数保留原值。" : "使用固定画面的色标与结构统计生成抽象构成。再次固定后，可以保留这张新构成继续变形。") : "上一轮的全部图层已合成。打散为 0 时显示固定画面，拖动打散开始再次解构。"))
                            .font(.system(size:10)).foregroundStyle(Theme.secondary).lineSpacing(4)
                        if model.isShowingLines {
                            Button("返回构成") {model.returnToComposition()}.buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("returnComposition")
                        } else {
                            Button {model.extractFixedLines()} label: {Label("提取固定画面线条",systemImage:"scribble.variable")}.buttonStyle(.borderedProminent).foregroundStyle(Theme.background).controlSize(.small).accessibilityIdentifier("extractLines")
                            Text("可从上方固定画面提线，也可在画布上试提当前构成。").font(.system(size:9)).foregroundStyle(Theme.secondary).lineSpacing(3)
                        }
                        Button("导入新图片…") {model.importImage(color:true)}.buttonStyle(.bordered).controlSize(.small)
                        Button("恢复本轮起点") {model.restoreIterationStart()}.buttonStyle(.bordered).controlSize(.small).accessibilityIdentifier("restoreStage")
                        Text("导入后从新参考开始；可从下方阶段记录恢复。").font(.system(size:9)).foregroundStyle(Theme.secondary)
                    }
                } else {
                    ColorSourcesView(model:model)
                    if model.recipe.method == .abstract {SourceCard(model:model,color:false)}
                }
                Button {model.randomize()} label: {Label("全部随机",systemImage:"shuffle").frame(maxWidth:.infinity)}
                    .buttonStyle(.bordered).controlSize(.large).disabled(model.isShowingLines || (model.recipe.colorLocked && model.recipe.shapeLocked)).help("尊重两个来源的锁定状态")
                Divider().overlay(Theme.line)
                HStack {
                    Text("阶段与收藏").font(.system(size:12,weight:.semibold))
                    Spacer(); Text("\(model.snapshots.count)").font(.system(size:10,design:.monospaced)).foregroundStyle(Theme.secondary)
                }
                if model.snapshots.isEmpty {
                    VStack(alignment:.leading,spacing:8) {
                        Image(systemName:"bookmark").font(.system(size:17)).foregroundStyle(Theme.secondary)
                        Text("留下值得继续的构成").font(.system(size:11))
                        Text("收藏后可以恢复参数，再探索变化。").font(.system(size:10)).foregroundStyle(Theme.secondary).lineSpacing(3)
                    }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(Theme.inset,in:RoundedRectangle(cornerRadius:8))
                } else {
                    LazyVStack(spacing:8) {
                    ForEach(model.snapshots) {snapshot in
                        HStack(spacing:9) {
                            Button {model.comparison=snapshot} label: {
                                HStack(spacing:9) {
                                    SnapshotPreview(recipe:snapshot.recipe).equatable().frame(width:44,height:44).clipShape(RoundedRectangle(cornerRadius:4))
                                    VStack(alignment:.leading,spacing:4) {Text(snapshot.name).font(.system(size:11,weight:.medium)); Text(snapshot.recipe.lineExtraction.enabled ? "线条提取" : (snapshot.recipe.method == .deconstruction ? "图像解构" : snapshot.recipe.mode.title)).font(.system(size:10)).foregroundStyle(Theme.secondary)}
                                    Spacer(minLength:0)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).help("和当前画面比较").disabled(model.temporaryLineInput != nil)
                            Button {model.deleteSnapshot(snapshot.id)} label: {Image(systemName:"xmark").font(.system(size:9)).foregroundStyle(Theme.secondary)}.buttonStyle(.plain).help("删除收藏")
                        }.padding(8).background(Theme.inset,in:RoundedRectangle(cornerRadius:7))
                    }
                    }
                }
            }.padding(18)
        }.background(Theme.panel)
    }
    private var workspace:some View {
        VStack(spacing:0) {
            HStack {
                Text(model.isCropping ? "框选局部" : "构成画布").font(.system(size:11,weight:.medium)).foregroundStyle(Theme.secondary)
                Spacer(minLength:8)
                Button {canvasZoom=max(1,canvasZoom/1.5)} label: {Image(systemName:"minus.magnifyingglass")}.disabled(canvasZoom==1).accessibilityLabel("缩小画布")
                Button(canvasZoom==1 ? "适合窗口" : "\(Int(canvasZoom*100))%") {canvasZoom=1}.help("恢复适合窗口")
                Button {canvasZoom=min(8,canvasZoom*1.5)} label: {Image(systemName:"plus.magnifyingglass")}.disabled(canvasZoom==8).accessibilityLabel("放大画布")
                if model.isCropping {
                    Button("重新框选") {model.prepareCrop(longEdge:max(model.exportSettings.width,model.exportSettings.height),format:model.exportSettings.format)}.buttonStyle(.borderless).font(.system(size:10))
                    Text("Esc 退出").font(.system(size:10))
                } else {
                    if model.recipe.method == .deconstruction && !model.isShowingLines {
                        Button(model.fragmentEditing ? "结束碎片编辑" : "编辑碎片") {model.toggleFragmentEditing()}
                            .accessibilityIdentifier("editFragments")
                    }
                    if !model.isShowingLines {
                        Button("试提线稿") {model.extractLines()}.disabled(!model.canExtractLines).accessibilityIdentifier("tryLines")
                    }
                    Menu {
                        Button("方形 · 1:1") {model.edit {$0.canvasAspect=1}}
                        Button("横向 · 4:3") {model.edit {$0.canvasAspect=4.0/3}}
                        Button("纵向 · 3:4") {model.edit {$0.canvasAspect=3.0/4}}
                        Button("宽幅 · 16:9") {model.edit {$0.canvasAspect=16.0/9}}
                    } label: {Text(aspectTitle).font(.system(size:11))}.menuStyle(.borderlessButton).fixedSize().disabled(model.isShowingLines)
                }
            }.buttonStyle(.borderless).controlSize(.small).font(.system(size:10)).padding(.horizontal,24).frame(height:42)
            if model.fragmentEditing && !model.isCropping && !model.isShowingLines && model.recipe.method == .deconstruction {
                fragmentToolbar
            }
            GeometryReader {proxy in
                let available=CGSize(width:max(1,proxy.size.width-48),height:max(1,proxy.size.height-48))
                let fit=min(available.width,available.height*model.recipe.canvasAspect)
                let width=fit*canvasZoom, height=width/model.recipe.canvasAspect
                ScrollView([.horizontal,.vertical]) {
                    ZStack {
                        if let renderer=model.renderer {
                            MetalCanvas(scene:model.scene,renderer:renderer) {model.alert=StudioAlert(message:$0)}
                        } else {Text("无法创建画布").foregroundStyle(Theme.secondary)}
                        if model.recipe.method == .deconstruction && model.scene.fragments.isEmpty && model.scene.lineInput == nil {
                            VStack(spacing:10) {
                                Image(systemName:"photo.on.rectangle.angled").font(.system(size:30))
                                Text(model.recipe.colorSource == nil && model.recipe.colorLayers.dropFirst().allSatisfy {$0.source==nil} ? "导入至少一张参考图片" : "当前没有可见碎片").font(.system(size:14,weight:.medium))
                            }.foregroundStyle(Color.black.opacity(0.55)).allowsHitTesting(false)
                        }
                        if model.isCropping {
                            CropOverlay(crop:Binding(get:{model.exportSettings.crop},set:{if let crop=$0 {model.updateCrop(crop)}}),canvasAspect:model.recipe.canvasAspect,longEdge:max(model.exportSettings.width,model.exportSettings.height))
                        } else if model.fragmentEditing && model.recipe.method == .deconstruction && !model.isShowingLines {
                            FragmentEditor(model:model)
                        }
                    }.frame(width:width,height:height).clipped().shadow(color:.black.opacity(0.28),radius:20,y:8)
                    .frame(width:max(proxy.size.width,width+48),height:max(proxy.size.height,height+48))
                }.scrollDisabled(canvasZoom==1)
            }
            HStack(spacing:8) {
                Text(model.isShowingLines ? "线条提取" : (model.recipe.method == .deconstruction ? "原图碎片 · 保留纹理" : (model.recipe.mode == .shape ? (model.recipe.shapeDisplay == .outline ? "单色线条" : "单色块面") : (model.recipe.mode == .color ? "色块 · 无描边" : "色块 + 线条"))))
                Text("·")
                Text("sRGB")
                Spacer()
                Button(model.recipe.method == .deconstruction ? "换叠放" : "换颜色") {model.randomize(shape:false)}.disabled(model.isShowingLines || model.recipe.colorLocked || (model.recipe.method == .abstract && model.recipe.mode == .shape))
                Button(model.recipe.method == .deconstruction ? "重新分块" : "换结构") {model.randomize(color:false)}.disabled(model.isShowingLines || model.recipe.shapeLocked)
            }.font(.system(size:10)).foregroundStyle(Theme.secondary).buttonStyle(.borderless).padding(.horizontal,24).frame(height:42)
        }
    }
    private var aspectTitle:String {let a=model.recipe.canvasAspect; return abs(a-1)<0.01 ? "1:1" : (abs(a-4.0/3)<0.01 ? "4:3" : (abs(a-3.0/4)<0.01 ? "3:4" : "16:9"))}
    private var controls:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:24) {
                HStack {Text("调节构成").font(.system(size:14,weight:.semibold)); Spacer(); Image(systemName:"slider.horizontal.3").foregroundStyle(Theme.secondary)}
                if model.isShowingLines {
                    lineControls
                } else {
                Picker("生成方式",selection:model.binding(\.method)) {ForEach(GenerationMethod.allCases,id:\.self) {Text($0.title).tag($0)}}.pickerStyle(.segmented).accessibilityIdentifier("generationMethod")
                if model.recipe.method == .deconstruction {
                    deconstructionControls
                } else {
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
                    groupHeader("结构") {model.edit {$0.shape=$0.fixedCanvas?.geometry != nil ? .continuation : ($0.shapeSource?.features.map(ShapeParameters.init(features:)) ?? ShapeParameters())}}
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
                    groupHeader("表现") {model.edit {$0.appearance=$0.fixedCanvas?.geometry?.appearance ?? AppearanceParameters()}}
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
                }
                }
                Text(model.isShowingLines ? "后台提取完成后更新画面。松开滑块可撤销这次调节；导出沿用当前线稿。" : "拖动保留随机基础，松开后可撤销这次调节。").font(.system(size:10)).foregroundStyle(Theme.secondary).lineSpacing(3)
            }.padding(20)
        }.background(Theme.panel)
    }
    private var lineControls: some View {
        VStack(alignment:.leading,spacing:20) {
            Text("线条提取").font(.system(size:16,weight:.semibold)).foregroundStyle(Theme.accent)
            Text(model.temporaryLineInput != nil ? "试提当前画面。满意后点击上方「保存提线阶段」。" : "提取固定画面的边缘，细化线条并去除零碎噪点。").font(.system(size:10)).foregroundStyle(Theme.secondary).lineSpacing(4)
            Picker("预设",selection:model.lineBinding(\.preset)) {
                ForEach(LineExtractionPreset.allCases,id:\.self) {Text($0.title).tag($0)}
            }.pickerStyle(.segmented).accessibilityIdentifier("linePreset")
            Text(model.lineParameters.preset == .photo ? "照片：去噪较强，线条较淡。" : "插画：保留更多短线，线条较深。").font(.system(size:10)).foregroundStyle(Theme.secondary)
            Divider().overlay(Theme.line)
            VStack(spacing:18) {
                groupHeader("提线参数") {model.editLine {p in let enabled=p.enabled; p=LineExtractionParameters(); p.enabled=enabled}}
                lineParameter("透明度",\.opacity,range:0...1)
                lineParameter("对比度",\.contrast,range:0.5...3)
                lineParameter("亮度 / 阈值倾向",\.brightness,range:-0.3...0.3)
                lineParameter("线条粗细",\.thickness,range:0...3)
                lineParameter("细节阈值",\.edgeStrength,range:0...3)
            }
            Text("细节阈值越高，越倾向保留明显边缘。粗细按固定画布的像素调整，局部放大时按比例变粗。").font(.system(size:10)).foregroundStyle(Theme.secondary).lineSpacing(4)
            Toggle("叠加在提线输入上",isOn:model.lineBinding(\.overlayOriginal)).font(.system(size:11)).accessibilityIdentifier("lineOverlay")
            Button("返回构成") {model.returnToComposition()}.buttonStyle(.bordered).controlSize(.small)
            Text("返回后可继续调整原构成；提线参数会保留。再次固定线稿后，还可以继续解构或提线。").font(.system(size:10)).foregroundStyle(Theme.secondary).lineSpacing(4)
        }
    }
    private func lineParameter(_ name: String,_ path: WritableKeyPath<LineExtractionParameters,Double>,range: ClosedRange<Double>) -> some View {
        VStack(spacing:5) {
            HStack {Text(name); Spacer(); Text(model.lineParameters[keyPath:path],format:.number.precision(.fractionLength(2))).monospacedDigit().foregroundStyle(Theme.secondary)}.font(.system(size:11))
            Slider(value:model.lineBinding(path),in:range,onEditingChanged:model.sliderEditing).controlSize(.small).accessibilityLabel(name).accessibilityIdentifier(name)
        }
    }
    private var fragmentToolbar:some View {
        HStack(spacing:10) {
            let selection=model.selectedFragmentGeometry
            let locked=selection.map {model.recipe.arrangement.layers[$0.layer]?.isLocked == true} ?? false
            let pinned=selection.map {model.recipe.arrangement.fragments[$0.id]?.pinned != nil} ?? false
            Text(selection.map {"第 \($0.layer+1) 层 · 碎片 \($0.id%80+1)"} ?? "点击选中碎片，也可直接拖动")
                .foregroundStyle(Theme.secondary)
            Spacer(minLength:0)
            Button(pinned ? "解除碎片锁定" : "锁定碎片") {model.toggleSelectedPin()}.disabled(selection==nil || locked)
            Button("隐藏碎片") {model.hideSelectedFragment()}.disabled(selection==nil || locked)
            Menu("碎片编辑") {
                Button("显示隐藏碎片") {model.showHiddenFragments()}
                Button("清除全部碎片编辑") {model.edit {$0.arrangement.fragments.removeAll()}}
            }.fixedSize()
        }.controlSize(.small).font(.system(size:10)).padding(.horizontal,24).padding(.bottom,5)
    }
    private var deconstructionControls:some View {
        let p=model.cutParameters
        return VStack(alignment:.leading,spacing:16) {
            Text("保留参考图纹理，重新组织碎片。").font(.system(size:10)).foregroundStyle(Theme.secondary)
            if model.recipe.fixedCanvas == nil {
                Picker("调节范围",selection:$model.editingLayer) {
                    Text("全局").tag(false)
                    Text("第 \(model.selectedColorLayer+1) 层").tag(true)
                }.pickerStyle(.segmented).disabled(model.recipe.layer(model.selectedColorLayer).source == nil)
            }
            if let slot=model.editingCutLayer {
                HStack {
                    Button(model.cutLayerLocked ? "解锁本层布局" : "锁定本层布局") {model.toggleLayerLock(slot)}
                    Spacer()
                    Button("随全局") {model.followGlobalCuts(slot)}.disabled(model.recipe.arrangement.layers[slot] == nil || model.cutLayerLocked)
                }.controlSize(.small)
                Text(model.cutLayerLocked ? "本层分块、位置与层内叠放已锁定。" : "调节后此层使用独立参数。").font(.system(size:10)).foregroundStyle(Theme.secondary)
            }
            VStack(spacing:15) {
                HStack {
                    Text("解构与重组").font(.system(size:11,weight:.semibold))
                    Spacer()
                    if model.editingCutLayer == nil {
                        Button {model.edit {$0.shapeLocked.toggle()}} label: {Image(systemName:model.recipe.shapeLocked ? "lock.fill" : "lock.open")}
                            .buttonStyle(.plain).help("锁定随机分块").accessibilityLabel("锁定解构结构")
                    }
                    Button("重置") {model.editCuts {$0=DeconstructionParameters()}}.font(.system(size:10)).buttonStyle(.borderless).foregroundStyle(Theme.secondary)
                }
                cutSlider("分块数量",\.granularity,value:"\(p.fragmentCount) / 张")
                cutSlider("打散程度",\.breakup,left:"不打散",right:"大幅重组",strong:true)
                cutSlider("旋转幅度",\.rotation,value:"\(Int((p.rotation*(p.expandedTransforms ? 360 : 180*p.breakup)).rounded()))°",left:"不旋转",right:"顺 / 逆时针",expanded:true)
                cutSlider("碎片大小差异",\.sizeVariation,left:"原始大小",right:p.strongTransforms ? "0.05× — 5×" : "扩展范围",strong:true)
                cutSlider("整体缩放",\.overlap,left:p.strongTransforms ? "收至 0.12×" : "缩小",right:p.strongTransforms ? "扩至 4×" : "放大",strong:true)
                cutSlider("碎片间距",\.spacing,left:"聚拢",right:"拉开")
                cutSlider("局部关系保留",\.grouping,left:"独立移动",right:"成组移动")
                if !p.strongTransforms {
                    Button("启用更强变化") {model.editCuts {$0.expandedTransforms=true; $0.strongTransforms=true}}.controlSize(.small)
                }
                Divider().overlay(Theme.line)
                Toggle("有机裂边",isOn:model.cutBinding(\.organicCuts)).font(.system(size:11))
                cutSlider("碎片边缘",\.softness,left:"清晰",right:"柔软")
            }.disabled(model.cutLayerLocked)
            Button("还原原图布局") {model.resetFragmentLayout()}.controlSize(.small)
                .help("将各层打散归零并清除碎片编辑，可撤销")
            Text("改变分块数量、重新分块或切换裂边会重置该层的碎片编辑，可撤销。").font(.system(size:10)).foregroundStyle(Theme.secondary)
        }
    }
    private func cutSlider(_ name:String,_ path:WritableKeyPath<DeconstructionParameters,Double>,value:String?=nil,left:String?=nil,right:String?=nil,expanded:Bool=false,strong:Bool=false) -> some View {
        VStack(spacing:5) {
            HStack {Text(name).font(.system(size:11)); Spacer(); Text(value ?? "\(Int((model.cutParameters[keyPath:path]*100).rounded()))").font(.system(size:10,design:.monospaced)).foregroundStyle(Theme.secondary)}
            Slider(value:model.cutBinding(path,expanded:expanded,strong:strong),onEditingChanged:model.sliderEditing).controlSize(.small).accessibilityLabel(name).accessibilityIdentifier(name)
            if let left,let right {HStack {Text(left); Spacer(); Text(right)}.font(.system(size:9)).foregroundStyle(Theme.secondary)}
        }
    }
    private func groupHeader(_ title:String,reset:@escaping()->Void) -> some View {
        HStack {Text(title).font(.system(size:11,weight:.semibold)); Spacer(); Button("重置",action:reset).font(.system(size:10)).buttonStyle(.borderless).foregroundStyle(Theme.secondary)}
    }
    private func parameter(_ name:String,_ path:WritableKeyPath<GenerationRecipe,Double>,range:ClosedRange<Double>=0...1,angle:Bool=false,displayScale:Double=1,left:String?=nil,right:String?=nil) -> some View {
        VStack(spacing:5) {
            HStack {Text(name).font(.system(size:11)); Spacer(); Text(angle ? "\(Int((model.recipe[keyPath:path]*displayScale).rounded()))°" : "\(Int((model.recipe[keyPath:path]*100).rounded()))").font(.system(size:10,design:.monospaced)).foregroundStyle(Theme.secondary)}
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
    var longEdge=96
    var fill=true
    @State private var image:CGImage?
    @State private var failed=false
    static func == (a:Self,b:Self) -> Bool {a.recipe == b.recipe && a.longEdge == b.longEdge && a.fill == b.fill}
    var body:some View {
        Group {
            if let image {Image(decorative:image,scale:1).resizable().aspectRatio(contentMode:fill ? .fill : .fit)}
            else if failed {Text("预览不可用").font(.caption)}
            else {Theme.inset.overlay {if !fill {ProgressView().controlSize(.small)}}}
        }.task(id:recipe) {
            let captured=recipe, edge=longEdge
            do {
                let result=try await Task.detached(priority:.utility) {
                    guard let renderer=SnapshotRenderer.shared else {throw LumoError.message("无法预览收藏")}
                    let dimensions=ExportSettings.dimensions(aspect:captured.canvasAspect,longEdge:edge)
                    return try renderer.image(scene:SceneGenerator.generate(captured),width:dimensions.width,height:dimensions.height)
                }.value
                if !Task.isCancelled {image=result; failed=false}
            } catch {if !Task.isCancelled {failed=true}}
        }
    }
}


private struct ComparisonSheet: View {
    @ObservedObject var model:StudioModel
    let snapshot:SavedSnapshot
    let current:GenerationRecipe
    @Environment(\.dismiss) private var dismiss
    @State private var name=""
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("对比构成").font(.title2.weight(.semibold))
            HStack(alignment:.top,spacing:14) {
                panel("当前画面",recipe:current)
                panel("收藏 · "+(model.snapshots.first {$0.id==snapshot.id}?.name ?? snapshot.name),recipe:snapshot.recipe)
            }
            HStack {
                TextField("收藏名称",text:$name).frame(width:240)
                Button("保存名称") {model.renameSnapshot(snapshot.id,name:name)}.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                Spacer()
                Button("关闭",role:.cancel) {dismiss()}.keyboardShortcut(.cancelAction)
                Button("恢复此收藏") {model.restore(model.snapshots.first {$0.id==snapshot.id} ?? snapshot); dismiss()}.buttonStyle(.borderedProminent)
            }
        }.padding(24).background(Theme.panel).onAppear {name=snapshot.name}
    }
    private func panel(_ label:String,recipe:GenerationRecipe) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Text(label).font(.subheadline.weight(.medium)).lineLimit(1)
            SnapshotPreview(recipe:recipe,longEdge:720,fill:false)
                .frame(width:385,height:365).background(Theme.inset).clipped()
        }
    }
}
