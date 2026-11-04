import Foundation
import LumoCore

/// Project writes and draft writes run off the window's main actor.
actor ProjectIO {
    private let draftURL: URL
    private var draftRevision: UInt64 = 0

    init(draftURL: URL = URL.applicationSupportDirectory.appending(path:"Lumo/Recovery.lumo")) {
        self.draftURL=draftURL
    }

    func open(_ url: URL) throws -> LumoProject {try ProjectStore.open(url)}
    func save(_ project: LumoProject, to url: URL) throws -> Int {try ProjectStore.save(project,to:url)}
    func hasDraft() -> Bool {FileManager.default.fileExists(atPath:draftURL.path)}
    func recoverDraft() throws -> LumoProject {try ProjectStore.open(draftURL)}

    func updateDraft(_ project: LumoProject?, revision: UInt64) throws -> Int? {
        guard revision>draftRevision else {return nil}
        draftRevision=revision
        if let project {
            try FileManager.default.createDirectory(at:draftURL.deletingLastPathComponent(),withIntermediateDirectories:true)
            return try ProjectStore.save(project,to:draftURL)
        }
        if hasDraft() {try FileManager.default.removeItem(at:draftURL)}
        return nil
    }
}
