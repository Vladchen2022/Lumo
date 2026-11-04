import SwiftUI
import AppKit
import LumoCore

private enum StudyTool: String, CaseIterable, Identifiable {
    case values, variants, guides, area, tone, crops, texture, edges, silhouette, exercise
    var id: Self {self}
    var title: String {
        switch self {
        case .values: "三值明暗"; case .variants: "单变量变体"; case .guides: "焦点与留白"
        case .area: "配色面积"; case .tone: "保明暗换色"; case .crops: "局部取景"
        case .texture: "自然肌理"; case .edges: "边缘分级"; case .silhouette: "剪影遮罩"; case .exercise: "限时练习"
        }
    }
    var icon: String {
        switch self {
        case .values: "circle.lefthalf.filled"; case .variants: "square.grid.3x2"; case .guides: "scope"
        case .area: "chart.pie"; case .tone: "paintpalette"; case .crops: "crop"
        case .texture: "square.3.layers.3d"; case .edges: "scribble"; case .silhouette: "rectangle.inset.filled"; case .exercise: "timer"
        }
    }
    var prompt: String {
        switch self {
        case .values: "用黑、灰、白检查大关系。关闭三值后，原有配色会回来。"
        case .variants: "只变化选中的一项。每张都沿用当前构成的种子和其他参数。"
        case .guides: "给眼睛一个落点，也给画面留下呼吸空间。选区域类型后在预览上拖框。"
        case .area: "给颜色安排主次。面积以合成后的像素为准，目标比例用于引导色块分配。"
        case .tone: "保留每个像素的相对亮度，换一套冷暖关系。"
        case .crops: "从同一画面找三种构图倾向，选中后可以继续自由调整矩形。"
        case .texture: "在现有构成上叠加抽象色彩分布，观察团聚、断裂和走向。"
        case .edges: "把锐利、柔和与融边放在不同位置。后画的区域优先。"
        case .silhouette: "用自己的透明剪影或黑白遮罩，试一套内部色块。"
        case .exercise: "设一个短时任务，练完后把习作和参考并排看。"
        }
    }
}

struct StudyDesk: View {
    @ObservedObject var model: StudioModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: GenerationRecipe
    @State private var preview: AbstractScene
    @State private var tool=StudyTool.values
    @State private var guideRole=GuideRole.primary
    @State private var edgeStyle=StudyEdge.sharp
    @State private var error: String?
    @State private var loadingMask=false
    private let original: GenerationRecipe

    init(model: StudioModel) {
        self.model=model
        original=model.recipe
        _draft=State(initialValue:model.recipe)
        _preview=State(initialValue:model.scene)
    }
    private var settings: StudySettings {draft.study ?? StudySettings()}
    private var abstract: Bool {draft.method == .abstract}
    private var colored: Bool {abstract && draft.mode != .shape}

    var body: some View {
        HStack(spacing:0) {
            navigation
            Divider()
            VStack(alignment:.leading,spacing:14) {
                VStack(alignment:.leading,spacing:5) {
                    Text(tool.title).font(.system(size:22,weight:.semibold))
                    Text(tool.prompt).font(.system(size:12)).foregroundStyle(Theme.secondary).lineSpacing(3)
                }
                Divider()
                content.frame(maxWidth:.infinity,maxHeight:.infinity)
                Divider()
                footer
            }.padding(22)
        }
        .frame(width:1040,height:700).background(Theme.panel).tint(Theme.accent).preferredColorScheme(.dark)
        .onChange(of:draft) {_,updated in preview=SceneGenerator.generate(updated)}
        .alert("操作未完成",isPresented:Binding(get:{error != nil},set:{if !$0 {error=nil}})) {
            Button("知道了",role:.cancel) {error=nil}
        } message: {Text(error ?? "")}
    }

    private var navigation: some View {
        VStack(alignment:.leading,spacing:5) {
            Label("构成研究台",systemImage:"square.grid.2x2").font(.system(size:15,weight:.semibold)).padding(.bottom,12)
            ForEach(StudyTool.allCases) {item in
                Button {tool=item} label: {
                    Label(item.title,systemImage:item.icon).font(.system(size:12,weight:tool==item ? .semibold : .regular))
                        .foregroundStyle(tool==item ? Theme.accent : .white.opacity(0.82))
                        .frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,8).padding(.horizontal,9)
                        .background(tool==item ? Theme.accent.opacity(0.13) : .clear,in:RoundedRectangle(cornerRadius:6))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Spacer(minLength:0)
            Text("预览可随时关闭。").font(.system(size:10)).foregroundStyle(Theme.secondary)
        }.padding(14).frame(width:163).frame(maxHeight:.infinity,alignment:.top).background(Theme.background.opacity(0.56))
    }

    @ViewBuilder private var content: some View {
        if let renderer=model.renderer {
            switch tool {
            case .variants:
                VariantPane(recipe:draft,renderer:renderer) {draft=$0}
            case .crops:
                CropStudyPane(scene:preview,renderer:renderer) {region in
                    guard apply() else {return}
                    model.prepareCrop(longEdge:max(model.exportSettings.width,model.exportSettings.height),format:model.exportSettings.format)
                    model.updateCrop(region)
                    dismiss()
                }
            case .exercise:
                ExercisePane(scene:preview,renderer:renderer)
            default:
                HStack(alignment:.top,spacing:16) {
                    canvas(renderer).frame(maxWidth:.infinity,maxHeight:.infinity)
                    ScrollView {
                        inspector.frame(maxWidth:.infinity,alignment:.leading).padding(.trailing,5)
                    }.frame(width:231)
                }
            }
        } else {Text("当前无法创建预览")}
    }

    private var footer: some View {
        HStack {
            Text(draft == original ? "当前构成" : "研究预览 · 应用后可一次撤销")
                .font(.system(size:11)).foregroundStyle(Theme.secondary)
            Spacer()
            Button("关闭") {dismiss()}.keyboardShortcut(.cancelAction)
            Button("应用到画布") {if apply() {dismiss()}}
                .buttonStyle(.borderedProminent).foregroundStyle(Theme.background).disabled(draft==original || loadingMask)
        }
    }

    @discardableResult private func apply() -> Bool {
        guard model.recipe==original,!model.isEditingBlocked,!model.isShowingLines else {
            error="当前构成已变化，请关闭并重新打开研究台。"; return false
        }
        model.edit {$0=draft}
        model.status="已应用研究设置；⌘Z 可撤销"
        return true
    }

    private func change(_ update:(inout StudySettings)->Void) {
        var next=settings
        update(&next)
        draft.study=next == StudySettings() ? nil : next
        draft.version=draft.currentVersion
    }

    private func canvas(_ renderer:MetalRenderer) -> some View {
        GeometryReader {proxy in
            let w=max(1,min(proxy.size.width-16,(proxy.size.height-16)*preview.aspect))
            ZStack {
                MetalCanvas(scene:preview,renderer:renderer) {error=$0}
                if tool == .guides && abstract {
                    let marks=GuideRole.allCases.compactMap {role in
                        settings.guides?.regions[role].map {StudyMark(region:$0,title:role.title,color:guideColor(role))}
                    }
                    StudyRegionEditor(marks:marks,color:guideColor(guideRole)) {region in
                        change {
                            var guides=$0.guides ?? CompositionGuides()
                            guides.regions[guideRole]=region; $0.guides=guides
                        }
                    }
                } else if tool == .edges && abstract {
                    StudyRegionEditor(marks:settings.edges.map {StudyMark(region:$0.region,title:$0.style.title,color:edgeColor($0.style))},
                                      color:edgeColor(edgeStyle)) {region in
                        change {
                            if $0.edges.count==12 {$0.edges.removeFirst()}
                            $0.edges.append(EdgeZone(region:region,style:edgeStyle))
                        }
                    }
                }
            }.frame(width:w,height:w/preview.aspect).clipped()
                .position(x:proxy.size.width/2,y:proxy.size.height/2)
        }.background(Theme.background,in:RoundedRectangle(cornerRadius:8))
    }

    private func guideColor(_ role:GuideRole) -> Color {
        switch role {case .primary: Theme.accent; case .secondary: .orange; case .empty: .cyan}
    }
    private func edgeColor(_ edge:StudyEdge) -> Color {
        switch edge {case .sharp: .orange; case .soft: Theme.accent; case .lost: .cyan}
    }

    @ViewBuilder private var inspector: some View {
        VStack(alignment:.leading,spacing:14) {
            switch tool {
            case .values: valueControls
            case .guides: guideControls
            case .area: areaControls
            case .tone: toneControls
            case .texture: textureControls
            case .edges: edgeControls
            case .silhouette: maskControls
            default: EmptyView()
            }
        }.padding(2)
    }
    private var valueControls: some View {
        VStack(alignment:.leading,spacing:16) {
            Toggle("显示三值",isOn:Binding(get:{settings.values != nil},set:{on in
                change {$0.values=on ? (settings.values ?? ThreeValues()) : nil}
            })).accessibilityIdentifier("studyValuesEnabled")
            if let values=settings.values {
                studySlider("黑／灰分界",value:values.low,range:0.02...0.97,id:"studyLow") { value in
                    change {$0.values?.low=min(value,values.high-0.02)}
                }
                studySlider("灰／白分界",value:values.high,range:0.03...0.99,id:"studyHigh") { value in
                    change {$0.values?.high=max(value,values.low+0.02)}
                }
                HStack(spacing:2) {
                    ForEach([Color.black,Color(white:0.5),.white],id:\.self) {color in
                        Rectangle().fill(color).frame(height:22)
                    }
                }.clipShape(RoundedRectangle(cornerRadius:4))
                Button("恢复默认分界") {change {$0.values=ThreeValues()}}
            }
        }
    }
    @ViewBuilder private var guideControls: some View {
        if abstract {
            Picker("要标记的区域",selection:$guideRole) {
                ForEach(GuideRole.allCases,id:\.self) {Text($0.title).tag($0)}
            }.pickerStyle(.segmented)
            Text("拖出矩形。主焦点吸引更多块面和对比；重叠时留白优先。")
                .font(.system(size:11)).foregroundStyle(Theme.secondary)
            ForEach(GuideRole.allCases,id:\.self) {role in
                HStack {
                    Circle().fill(guideColor(role)).frame(width:7,height:7)
                    Text(role.title)
                    Spacer()
                    if settings.guides?.regions[role] != nil {
                        Button("清除") {
                            change {
                                $0.guides?.regions.removeValue(forKey:role)
                                if $0.guides?.regions.isEmpty == true {$0.guides=nil}
                            }
                        }.buttonStyle(.borderless)
                    } else {Text("未标记").foregroundStyle(Theme.secondary)}
                }.font(.system(size:11))
            }
            if let guides=settings.guides {
                studySlider("引导强度",value:guides.strength,range:0...1) {value in change {$0.guides?.strength=value}}
                Button("清除所有引导") {change {$0.guides=nil}}
            }
        } else {availability("切换到「抽象生成」后，可引导新块面的分布。")}
    }
    @ViewBuilder private var areaControls: some View {
        if colored {
            Toggle("启用角色配色",isOn:Binding(get:{settings.palette != nil},set:{value in
                let colors=SceneGenerator.palette(for:draft,sixSlots:true)
                change {state in
                    if value {
                        var plan=AreaPalette()
                        plan.main=colors[0].color; plan.support=colors[1].color; plan.accent=colors[2].color
                        state.palette=plan
                    } else {state.palette=nil}
                }
            })).accessibilityIdentifier("studyAreaEnabled")
            if let palette=settings.palette {
                rolePicker("主色",\.main); rolePicker("辅色",\.support); rolePicker("点缀色",\.accent)
                studySlider("目标辅色",value:palette.supportShare,range:0...0.8) {value in
                    change {$0.palette?.supportShare=min(value,0.98-palette.accentShare)}
                }
                studySlider("目标点缀色",value:palette.accentShare,range:0...0.5) {value in
                    change {$0.palette?.accentShare=min(value,0.98-palette.supportShare)}
                }
                if settings.values != nil {Button("切回彩色预览") {change {$0.values=nil}}}
                if let renderer=model.renderer {AreaStudyReadout(scene:preview,palette:palette,renderer:renderer)}
                Text("将合成后的可见像素归到最接近的角色色，包含底色和混色。目标与实际会因遮挡而有偏差。")
                    .font(.system(size:10)).foregroundStyle(Theme.secondary)
            }
        } else {availability("在抽象生成的「颜色」或「组合」模式下使用角色配色。")}
    }
    private func rolePicker(_ title:String,_ path:WritableKeyPath<AreaPalette,LumoCore.RGBColor>) -> some View {
        ColorPicker(title,selection:Binding(get:{(settings.palette ?? AreaPalette())[keyPath:path].swiftUI},set:{color in
            guard let c=NSColor(color).usingColorSpace(.sRGB) else {return}
            func clamp(_ v:CGFloat)->Double {min(1,max(0,Double(v)))}
            change {$0.palette?[keyPath:path]=LumoCore.RGBColor(clamp(c.redComponent),clamp(c.greenComponent),clamp(c.blueComponent))}
        }),supportsOpacity:false)
    }
    private var toneControls: some View {
        VStack(alignment:.leading,spacing:12) {
            if settings.values != nil {
                Text("当前显示三值稿，颜色暂时不可见。").font(.system(size:11)).foregroundStyle(Theme.secondary)
                Button("切回彩色预览") {change {$0.values=nil}}
            }
            Picker("冷暖方案",selection:Binding(get:{settings.tone},set:{tone in change {$0.tone=tone}})) {
                Text("原配色").tag(ToneStudy?.none)
                ForEach(ToneStudy.allCases,id:\.self) {Text($0.title).tag(Optional($0))}
            }.pickerStyle(.radioGroup).accessibilityIdentifier("studyTone")
            Text("高光和深暗部可能没有足够空间容纳高饱和颜色，会自动降低饱和度。")
                .font(.system(size:11)).foregroundStyle(Theme.secondary)
        }
    }
    private var textureControls: some View {
        VStack(alignment:.leading,spacing:14) {
            Toggle("叠加肌理",isOn:Binding(get:{settings.texture != nil},set:{on in change {$0.texture=on ? TextureStudy() : nil}}))
                .accessibilityIdentifier("studyTextureEnabled")
            if let texture=settings.texture {
                Picker("分布",selection:Binding(get:{texture.kind},set:{kind in change {$0.texture?.kind=kind}})) {
                    ForEach(TextureKind.allCases,id:\.self) {Text($0.title).tag($0)}
                }.pickerStyle(.segmented)
                studySlider("强度",value:texture.amount,range:0...1) {value in change {$0.texture?.amount=value}}
                studySlider("细密程度",value:texture.scale,range:0...1) {value in change {$0.texture?.scale=value}}
                studySlider("走向",value:texture.direction,range:-180...180,angle:true) {value in change {$0.texture?.direction=value}}
                Text("肌理跟随结构种子；改变导出尺寸或框选范围不会重新随机。").font(.system(size:11)).foregroundStyle(Theme.secondary)
            }
        }
    }
    @ViewBuilder private var edgeControls: some View {
        if abstract {
            Picker("边缘",selection:$edgeStyle) {
                ForEach(StudyEdge.allCases,id:\.self) {Text($0.title).tag($0)}
            }.pickerStyle(.segmented)
            Text("在预览上拖框。锐利保留清晰轮廓，柔化减弱描边，融边扩大过渡并移除该处描边。")
                .font(.system(size:11)).foregroundStyle(Theme.secondary)
            Text("\(settings.edges.count) / 12 个区域").font(.system(size:11)).foregroundStyle(Theme.secondary)
            Button("移除最后一个") {change {if !$0.edges.isEmpty {$0.edges.removeLast()}}}.disabled(settings.edges.isEmpty)
            Button("清除边缘分级") {change {$0.edges=[]}}.disabled(settings.edges.isEmpty)
        } else {availability("边缘分级用于「抽象生成」的块面和轮廓。")}
    }
    private var maskControls: some View {
        VStack(alignment:.leading,spacing:14) {
            Button(loadingMask ? "正在读取…" : "导入剪影…") {importMask()}.disabled(loadingMask)
                .accessibilityIdentifier("studyMaskImport")
            Text("优先使用图片的透明通道。黑白图默认保留亮部；黑色剪影可反相。")
                .font(.system(size:11)).foregroundStyle(Theme.secondary)
            if let mask=settings.silhouette {
                Text(mask.source.name).lineLimit(2).font(.system(size:11))
                Toggle("反相遮罩",isOn:Binding(get:{settings.silhouette?.inverted==true},set:{value in change {$0.silhouette?.inverted=value}}))
                Button("移除剪影") {change {$0.silhouette=nil}}
                Text("预览用白底。PNG 的剪影外部透明，JPEG 使用白底。").font(.system(size:11)).foregroundStyle(Theme.secondary)
            }
        }
    }
    private func availability(_ text:String) -> some View {
        Label(text,systemImage:"info.circle").font(.system(size:11)).foregroundStyle(Theme.secondary)
    }
    private func studySlider(_ title:String,value:Double,range:ClosedRange<Double>,id:String?=nil,angle:Bool=false,update:@escaping(Double)->Void) -> some View {
        VStack(alignment:.leading,spacing:4) {
            HStack {
                Text(title); Spacer()
                Text(angle ? "\(Int(value.rounded()))°" : "\(Int((value*100).rounded()))%").monospacedDigit().foregroundStyle(Theme.secondary)
            }.font(.system(size:11))
            Slider(value:Binding(get:{value},set:update),in:range).accessibilityLabel(title).accessibilityIdentifier(id ?? title)
        }
    }
    private func importMask() {
        guard let url=StudyFiles.openImage(title:"导入剪影遮罩") else {return}
        loadingMask=true
        Task {
            defer {loadingMask=false}
            do {
                let mask=try await StudyJobs.run {try StudyImage.silhouette(url)}
                change {$0.silhouette=mask}
            } catch {self.error=error.localizedDescription}
        }
    }
}

private struct StudyMark {
    var region: CropRegion
    var title: String
    var color: Color
}
private struct StudyRegionEditor: View {
    let marks:[StudyMark]
    let color:Color
    var commit:(CropRegion)->Void
    @State private var current:CropRegion?
    var body: some View {
        GeometryReader {proxy in
            let size=proxy.size
            ZStack(alignment:.topLeading) {
                Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance:4,coordinateSpace:.local)
                    .onChanged {drag in
                        guard size.width>0,size.height>0 else {return}
                        let a=CGPoint(x:drag.startLocation.x/size.width,y:drag.startLocation.y/size.height)
                        let b=CGPoint(x:drag.location.x/size.width,y:drag.location.y/size.height)
                        current=CropRegion.selecting(from:a,to:b)
                    }.onEnded {_ in
                        if let current {commit(current)}
                        current=nil
                    })
                ForEach(Array(marks.enumerated()),id:\.offset) {_,mark in outline(mark,size:size)}
                if let current {outline(StudyMark(region:current,title:"",color:color),size:size)}
            }
        }.accessibilityLabel("区域标记画布")
    }
    private func outline(_ mark:StudyMark,size:CGSize)->some View {
        let r=mark.region
        return Rectangle().fill(mark.color.opacity(0.08)).overlay {
            Rectangle().strokeBorder(mark.color,style:StrokeStyle(lineWidth:1.5,dash:[5,4]))
        }.overlay(alignment:.topLeading) {
            if !mark.title.isEmpty {
                Text(mark.title).font(.system(size:10)).padding(4).background(Theme.background.opacity(0.85)).foregroundStyle(mark.color)
            }
        }.frame(width:r.width*size.width,height:r.height*size.height)
            .position(x:(r.x+r.width/2)*size.width,y:(r.y+r.height/2)*size.height)
            .allowsHitTesting(false)
    }
}
