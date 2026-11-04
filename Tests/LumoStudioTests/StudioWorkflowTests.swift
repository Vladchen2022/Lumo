import XCTest
import LumoCore
@testable import Lumo

final class StudioWorkflowTests: XCTestCase {
    @MainActor func testFixAndDeleteRestoreTheEntireCompositionState() async throws {
        let model=StudioModel()
        let original=model.recipe
        model.addSnapshot()
        let initial=model.snapshots
        await model.fixEffect(longEdge:256)
        XCTAssertNotNil(model.recipe.fixedCanvas)
        XCTAssertEqual(model.snapshots.count,2)
        let fixed=model.recipe, stages=model.snapshots
        model.undo()
        XCTAssertEqual(model.recipe,original)
        XCTAssertEqual(model.snapshots,initial)
        model.redo()
        XCTAssertEqual(model.recipe,fixed)
        XCTAssertEqual(model.snapshots,stages)
        model.deleteSnapshot(stages[0].id)
        XCTAssertEqual(model.snapshots,initial)
        model.undo()
        XCTAssertEqual(model.snapshots,stages)
    }

    @MainActor func testTemporaryLinesDoNotChangeProjectUntilSavedAsStage() async throws {
        let model=StudioModel()
        let original=model.project
        await model.captureLines(longEdge:256)
        for _ in 0..<150 where model.isProcessingLines {try await Task.sleep(for:.milliseconds(20))}
        XCTAssertFalse(model.isProcessingLines)
        XCTAssertNotNil(model.scene.lineMask)
        XCTAssertEqual(model.project,original)
        model.editLine {$0.opacity=0.4}
        XCTAssertEqual(model.scene.lineParameters?.opacity,0.4)
        model.undo()
        XCTAssertEqual(model.scene.lineParameters?.opacity,1)
        await model.fixEffect(longEdge:256)
        XCTAssertTrue(model.recipe.lineExtraction.enabled)
        XCTAssertNil(model.temporaryLineInput)
        XCTAssertEqual(model.snapshots.first?.recipe,original.recipe)
        model.undo()
        XCTAssertEqual(model.project,original)
    }

    @MainActor func testAutosaveRecoversUnsavedEditsAsANewDocument() async throws {
        let root=FileManager.default.temporaryDirectory.appending(path:UUID().uuidString,directoryHint:.isDirectory)
        defer {try? FileManager.default.removeItem(at:root)}
        let url=root.appending(path:"draft.lumo")
        let writer=StudioModel(io:ProjectIO(draftURL:url))
        await writer.checkDraft()
        writer.edit {$0.color.hue=87}
        writer.addSnapshot()
        for _ in 0..<60 {
            if FileManager.default.fileExists(atPath:url.path) {break}
            try await Task.sleep(for:.milliseconds(50))
        }
        let reader=StudioModel(io:ProjectIO(draftURL:url))
        await reader.checkDraft()
        XCTAssertTrue(reader.recoveryAvailable)
        await reader.recoverDraft()
        XCTAssertEqual(reader.recipe,writer.recipe)
        XCTAssertEqual(reader.snapshots.map(\.id),writer.snapshots.map(\.id))
        XCTAssertNil(reader.projectURL)
        XCTAssertTrue(reader.isDirty)
        await reader.clearDraft()
    }

    func testRecoveryStoreCannotReplaceOrRemoveANewerDraftWithStaleWork() async throws {
        let root=FileManager.default.temporaryDirectory.appending(path:UUID().uuidString,directoryHint:.isDirectory)
        defer {try? FileManager.default.removeItem(at:root)}
        let io=ProjectIO(draftURL:root.appending(path:"draft.lumo"))
        var project=LumoProject(); project.recipe.color.hue=42
        _=try await io.updateDraft(project,revision:2)
        _=try await io.updateDraft(nil,revision:1)
        let recovered=try await io.recoverDraft()
        XCTAssertEqual(recovered,project)
        _=try await io.updateDraft(nil,revision:3)
        _=try await io.updateDraft(project,revision:2)
        let hasDraft=await io.hasDraft()
        XCTAssertFalse(hasDraft)
    }
}
