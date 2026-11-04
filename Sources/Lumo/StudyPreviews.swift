import SwiftUI
import AppKit
import LumoCore
import UniformTypeIdentifiers

enum StudyJobs {
    static func run<T:Sendable>(_ work:@escaping @Sendable ()throws->T) async throws -> T {
        let task=Task.detached(priority:.userInitiated) {try work()}
        return try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})
    }
    static func render(_ scene:AbstractScene,_ renderer:MetalRenderer,longEdge:Int=520,crop:CropRegion?=nil) throws -> CGImage {
        let size=ExportSettings.dimensions(aspect:crop?.aspect(canvasAspect:scene.aspect) ?? scene.aspect,longEdge:longEdge)
        return try renderer.image(scene:scene,width:size.width,height:size.height,crop:crop)
    }
}

@MainActor enum StudyFiles {
    static func openImage(title:String) -> URL? {
        let panel=NSOpenPanel()
        panel.allowedContentTypes=[.png,.jpeg,.tiff,.heic]
        panel.canChooseDirectories=false; panel.allowsMultipleSelection=false; panel.title=title
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct StudyThumbnail: View {
    var image: CGImage?
    var label: String
    var body: some View {
        GeometryReader {proxy in
            ZStack {
                Theme.background
                if let image {
                    Image(decorative:image,scale:1).resizable().scaledToFit()
                        .frame(width:proxy.size.width,height:proxy.size.height)
                } else {ProgressView().controlSize(.small)}
            }
        }.clipShape(RoundedRectangle(cornerRadius:5)).accessibilityLabel(label)
    }
}

struct AreaStudyReadout: View {
    let scene: AbstractScene
    let palette: AreaPalette
    let renderer: MetalRenderer
    @State private var measured:[Double]?
    @State private var failed=false
    var body: some View {
        VStack(alignment:.leading,spacing:7) {
            HStack {Text("可见面积估算"); Spacer(); Text("目标 / 实际")}
                .font(.system(size:10)).foregroundStyle(Theme.secondary)
            ForEach(0..<3,id:\.self) {i in
                HStack {
                    RoundedRectangle(cornerRadius:2).fill(palette.colors[i].swiftUI).frame(width:12,height:12)
                    Text(["主色","辅色","点缀"][i]); Spacer()
                    Text("\(Int((palette.weights[i]*100).rounded()))% / "+(measured.map {"\(Int(($0[i]*100).rounded()))%"} ?? "…"))
                        .monospacedDigit()
                }.font(.system(size:11))
            }
            if failed {Text("暂时无法估算面积").font(.system(size:10)).foregroundStyle(.orange)}
        }.task(id:scene) {
            measured=nil; failed=false
            do {
                let values=try await StudyJobs.run {
                    let image=try StudyJobs.render(scene,renderer,longEdge:192)
                    return try StudyAnalysis.visibleShares(image:image,palette:palette)
                }
                if !Task.isCancelled {measured=values}
            } catch {if !Task.isCancelled {failed=true}}
        }
    }
}

struct VariantPane: View {
    let recipe: GenerationRecipe
    let renderer: MetalRenderer
    let choose: (GenerationRecipe)->Void
    @State private var base:GenerationRecipe
    @State private var axis:VariantAxis
    @State private var images:[CGImage]=[]
    @State private var selection:Int?
    @State private var failed=false

    init(recipe:GenerationRecipe,renderer:MetalRenderer,choose:@escaping(GenerationRecipe)->Void) {
        self.recipe=recipe; self.renderer=renderer; self.choose=choose
        _base=State(initialValue:recipe)
        _axis=State(initialValue:recipe.method == .deconstruction ? .breakup : .density)
    }
    private struct Key: Equatable {var recipe:GenerationRecipe; var axis:VariantAxis}
    private var axes:[VariantAxis] {
        if recipe.method == .deconstruction {return [.breakup,.spacing]}
        if recipe.mode == .shape || recipe.study?.palette != nil {return [.density,.scale,.direction]}
        return [.density,.scale,.direction,.hue,.brightness]
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Picker("变化的参数",selection:$axis) {
                    ForEach(axes,id:\.self) {Text($0.title).tag($0)}
                }.frame(width:235).accessibilityIdentifier("studyVariantAxis")
                Spacer()
                Button("以当前预览为起点") {base=recipe; selection=nil}
            }
            if failed {Text("变体预览未完成").font(.caption).foregroundStyle(.orange)}
            GeometryReader {proxy in
                let cardHeight=max(70,(proxy.size.height-60)/2)
                LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:12),count:3),spacing:12) {
                    ForEach(Array(axis.values(around:base).enumerated()),id:\.offset) {i,value in
                        Button {
                            selection=i
                            choose(axis.applying(value,to:base))
                        } label: {
                            VStack(alignment:.leading,spacing:6) {
                                StudyThumbnail(image:images.indices.contains(i) ? images[i] : nil,label:"变体 \(i+1)")
                                    .frame(height:cardHeight)
                                HStack {
                                    Text(axis.title+" "+axis.label(value)).font(.system(size:11,weight:.medium))
                                    Spacer()
                                    if selection==i {Image(systemName:"checkmark.circle.fill")}
                                }.foregroundStyle(selection==i ? Theme.accent : .white.opacity(0.8))
                            }.padding(6).background(Theme.inset,in:RoundedRectangle(cornerRadius:7))
                        }.buttonStyle(.plain).disabled(!images.indices.contains(i))
                            .accessibilityLabel("选择变体 \(i+1)，\(axis.title) \(axis.label(value))")
                    }
                }
            }
        }.task(id:Key(recipe:base,axis:axis)) {
            images=[]; selection=nil; failed=false
            let baseline=base, selectedAxis=axis
            do {
                let rendered=try await StudyJobs.run {
                    try selectedAxis.values(around:baseline).map {v in
                        try Task.checkCancellation()
                        return try StudyJobs.render(SceneGenerator.generate(selectedAxis.applying(v,to:baseline)),renderer,longEdge:440)
                    }
                }
                if !Task.isCancelled {images=rendered}
            } catch {if !Task.isCancelled {failed=true}}
        }
    }
}

struct CropStudyPane: View {
    let scene: AbstractScene
    let renderer: MetalRenderer
    let choose:(CropRegion)->Void
    private enum Ratio: String,CaseIterable {case square="1:1", wide="4:3", tall="3:4"
        var aspect:Double {switch self {case .square: 1; case .wide: 4/3; case .tall: 3/4}}
    }
    private struct Card: Sendable, Identifiable {
        let crop: StudyCrop
        let image: CGImage
        var id:CropStudyKind {crop.kind}
    }
    @State private var ratio=Ratio.wide
    @State private var cards:[Card]=[]
    @State private var failed=false

    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {
                Picker("候选比例",selection:$ratio) {ForEach(Ratio.allCases,id:\.self) {Text($0.rawValue).tag($0)}}
                    .pickerStyle(.segmented).frame(width:235)
                Spacer()
            }
            if cards.isEmpty {
                VStack {
                    if failed {Text("当前画面的明暗边界太少，无法区分取景候选")} else {ProgressView("正在比较取景…")}
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                HStack(alignment:.top,spacing:12) {
                    ForEach(cards) {card in
                        VStack(alignment:.leading,spacing:8) {
                            StudyThumbnail(image:card.image,label:card.crop.kind.title).frame(height:250)
                            Text(card.crop.kind.title).font(.system(size:13,weight:.medium))
                            Button("使用此选区") {choose(card.crop.region)}.accessibilityLabel("使用\(card.crop.kind.title)选区")
                        }.padding(8).frame(maxWidth:.infinity).background(Theme.inset,in:RoundedRectangle(cornerRadius:7))
                    }
                }
                Text("候选依据留白与明暗边缘的分布；选中后仍可自由改变比例和位置。")
                    .font(.system(size:11)).foregroundStyle(Theme.secondary)
                Spacer(minLength:0)
            }
        }.task(id:ratio) {
            cards=[]; failed=false
            let aspect=ratio.aspect
            do {
                let results=try await StudyJobs.run {
                    let input=try StudyJobs.render(scene,renderer,longEdge:224)
                    let regions=try StudyAnalysis.crops(image:input,canvasAspect:scene.aspect,outputAspect:aspect)
                    return try regions.map {crop in
                        try Task.checkCancellation()
                        return Card(crop:crop,image:try StudyJobs.render(scene,renderer,longEdge:420,crop:crop.region))
                    }
                }
                if !Task.isCancelled {cards=results; failed=results.isEmpty}
            } catch {if !Task.isCancelled {failed=true}}
        }
    }
}
