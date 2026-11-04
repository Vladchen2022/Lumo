import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LumoCore

struct ExercisePane: View {
    let scene: AbstractScene
    let renderer: MetalRenderer
    private enum Exercise: String, CaseIterable {
        case values="三个明度", focus="一个焦点", temperature="冷暖关系"
        var task:String {
            switch self {
            case .values: "用黑、灰、白重画构成。先画占面积最大的块，再补小形状。"
            case .focus: "只保留一个视觉焦点。允许挪动或省掉和它竞争的块面。"
            case .temperature: "把参考重画成一套不同的冷暖配色，保留大块明暗。"
            }
        }
        var questions:[String] {
            switch self {
            case .values: ["最大明暗块仍然清楚", "次要细节合并进了大块", "缩小后还能读出构成"]
            case .focus: ["第一眼落在预定的位置", "次要部分没有抢焦点", "留白有完整的大形"]
            case .temperature: ["最大的冷暖关系明确", "换色后明暗层次仍在", "点缀色只放在必要位置"]
            }
        }
    }
    @State private var exercise=Exercise.values
    @State private var minutes=5
    @State private var deadline:Date?
    @State private var finished=false
    @State private var reference:CGImage?
    @State private var drawing:CGImage?
    @State private var reviewed:Set<String>=[]
    @State private var failure:String?
    @State private var reading=false

    var body: some View {
        VStack(alignment:.leading,spacing:13) {
            HStack(spacing:15) {
                Picker("任务",selection:$exercise) {
                    ForEach(Exercise.allCases,id:\.self) {Text($0.rawValue).tag($0)}
                }.frame(width:220).disabled(deadline != nil || finished)
                Stepper("\(minutes) 分钟",value:$minutes,in:1...30).fixedSize().disabled(deadline != nil || finished)
                Spacer()
                timer
            }
            Text(exercise.task).font(.system(size:12)).foregroundStyle(Theme.secondary)
            HStack(alignment:.top,spacing:14) {
                VStack(alignment:.leading,spacing:6) {
                    Text("本轮参考").font(.system(size:11,weight:.medium))
                    StudyThumbnail(image:reference,label:"本轮构成参考")
                }.frame(maxWidth:.infinity)
                if finished {
                    VStack(alignment:.leading,spacing:6) {
                        HStack {
                            Text("你的习作").font(.system(size:11,weight:.medium))
                            Spacer()
                            Button(reading ? "读取中…" : "导入习作…") {importDrawing()}.disabled(reading)
                        }
                        if let drawing {StudyThumbnail(image:drawing,label:"本轮习作")}
                        else {
                            Text("导入一张练习结果进行比较")
                                .font(.system(size:11)).foregroundStyle(Theme.secondary)
                                .frame(maxWidth:.infinity,maxHeight:.infinity).background(Theme.background,in:RoundedRectangle(cornerRadius:5))
                        }
                    }.frame(maxWidth:.infinity)
                }
            }.frame(maxHeight:.infinity)
            if finished {
                VStack(alignment:.leading,spacing:4) {
                    Text("对照后自查").font(.system(size:11,weight:.semibold)).foregroundStyle(Theme.accent)
                    ForEach(exercise.questions,id:\.self) {question in
                        Toggle(question,isOn:Binding(get:{reviewed.contains(question)},set:{on in
                            if on {reviewed.insert(question)} else {reviewed.remove(question)}
                        })).font(.system(size:11))
                    }
                }
            }
            if let failure {Text(failure).foregroundStyle(.orange).font(.system(size:11))}
            HStack {
                Button("保存参考 PNG…") {saveReference()}.disabled(reference == nil)
                Spacer()
                if finished {Button("再练一轮") {reset()}}
                else if deadline != nil {Button("结束练习") {finish()}}
                else {
                    Button("开始计时") {deadline=Date().addingTimeInterval(Double(minutes)*60)}
                        .buttonStyle(.borderedProminent).foregroundStyle(Theme.background).disabled(reference==nil)
                }
            }
        }.task(id:scene) {
            do {
                let image=try await StudyJobs.run {try StudyJobs.render(scene,renderer,longEdge:1024)}
                if !Task.isCancelled {reference=image}
            } catch {if !Task.isCancelled {failure=error.localizedDescription}}
        }
    }
    @ViewBuilder private var timer: some View {
        if let deadline {
            TimelineView(.periodic(from:.now,by:1)) {context in
                let seconds=max(0,Int(ceil(deadline.timeIntervalSince(context.date))))
                Text(String(format:"%02d:%02d",seconds/60,seconds%60)).monospacedDigit().font(.system(size:20,weight:.medium))
                    .onChange(of:seconds,initial:true) {_,value in if value==0 {finish()}}
            }
        } else if finished {Text("练习结束").foregroundStyle(Theme.accent)}
    }
    private func finish() {deadline=nil; finished=true}
    private func reset() {deadline=nil; finished=false; drawing=nil; reviewed=[]; failure=nil}
    private func importDrawing() {
        guard let url=StudyFiles.openImage(title:"导入练习结果") else {return}
        reading=true; failure=nil
        Task {
            defer {reading=false}
            do {drawing=try await StudyJobs.run {try StudyImage.load(url)}}
            catch {failure=error.localizedDescription}
        }
    }
    private func saveReference() {
        guard let reference else {return}
        let panel=NSSavePanel(); panel.allowedContentTypes=[.png]
        panel.nameFieldStringValue="Lumo-练习参考.png"; panel.title="保存练习参考"
        guard panel.runModal() == .OK,let url=panel.url else {return}
        Task {
            do {try await StudyJobs.run {try ReferencePixels.png(reference).write(to:url,options:.atomic)}}
            catch {failure=error.localizedDescription}
        }
    }
}
