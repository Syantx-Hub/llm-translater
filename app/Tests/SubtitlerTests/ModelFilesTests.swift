import Foundation
import Testing
@testable import Subtitler

/// Uses a temporary models directory via `ModelFiles.rootOverride`; serialized because
/// that override is global.
@Suite(.serialized) @MainActor final class ModelFilesTests {
    private let root: URL
    private let speech = ModelCatalog.speech[0]
    private let otherSpeech = ModelCatalog.speech[3]
    private let translation = ModelCatalog.translation[0]

    init() throws {
        root = try makeTemporaryDirectory()
        ModelFiles.rootOverride = root
    }

    deinit {
        ModelFiles.rootOverride = nil
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes what a finished WhisperKit download leaves on disk, including Hub's cache.
    private func installSpeech(_ model: ModelInfo, complete: Bool = true, skip: String? = nil) throws {
        let folder = ModelFiles.localURL(for: model)
        for file in ModelFiles.requiredSpeechFiles where file != skip {
            let url = folder.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("weights".utf8).write(to: url)
        }
        if complete {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(ModelFiles.completeMarker).path, contents: nil)
        }
        let cache = try #require(ModelFiles.allFiles(for: model).last)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("etag".utf8).write(to: cache.appendingPathComponent("config.json.metadata"))
    }

    private func installGGUF(_ model: ModelInfo, contents: String = "GGUF\u{3}rest-of-model") throws {
        let url = ModelFiles.localURL(for: model)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: Install detection

    @Test func completeSpeechModelIsInstalled() throws {
        try installSpeech(speech)
        #expect(ModelFiles.isInstalled(speech))
    }

    @Test func speechModelWithoutMarkerIsNotInstalled() throws {
        try installSpeech(speech, complete: false)
        #expect(!ModelFiles.isInstalled(speech))
    }

    /// The incident where a race left weight.bin missing but the marker present.
    @Test func speechModelMissingWeightsIsNotInstalled() throws {
        try installSpeech(speech, skip: "TextDecoder.mlmodelc/weights/weight.bin")
        #expect(!ModelFiles.isInstalled(speech))
    }

    @Test func ggufNeedsTheMagicHeader() throws {
        try installGGUF(translation)
        #expect(ModelFiles.isInstalled(translation))
        try installGGUF(translation, contents: "<html>not found</html>")
        #expect(!ModelFiles.isInstalled(translation))
    }

    // MARK: Deletion

    @Test func deletingASpeechModelRemovesItsFilesAndDownloadCache() throws {
        try installSpeech(speech)
        let files = ModelFiles.allFiles(for: speech)
        #expect(files.count == 2)
        #expect(files.allSatisfy(exists))

        try ModelFiles.delete(speech)

        #expect(!files.contains(where: exists))
        #expect(!ModelFiles.isInstalled(speech))
    }

    @Test func deletingOneModelLeavesOthersIntact() throws {
        try installSpeech(speech)
        try installSpeech(otherSpeech)
        try installGGUF(translation)

        try ModelFiles.delete(speech)

        #expect(ModelFiles.isInstalled(otherSpeech))
        #expect(ModelFiles.isInstalled(translation))
        #expect(ModelFiles.allFiles(for: otherSpeech).allSatisfy(exists))
    }

    @Test func deletingATranslationModelRemovesTheFile() throws {
        try installGGUF(translation)
        try ModelFiles.delete(translation)
        #expect(!exists(ModelFiles.localURL(for: translation)))
    }

    @Test func deletingAModelThatIsNotInstalledSucceeds() throws {
        try ModelFiles.delete(speech)
        try ModelFiles.delete(translation)
    }

    @Test func deleteRefusesWhileTheModelIsDownloading() throws {
        try installSpeech(speech)
        let download = try DownloadLock(root: root, id: speech.id, name: speech.name)
        #expect(throws: ModelFilesError.busy(speech.name)) { try ModelFiles.delete(speech) }
        #expect(ModelFiles.isInstalled(speech))
        download.release()
        try ModelFiles.delete(speech)
        #expect(!ModelFiles.isInstalled(speech))
    }

    @Test func emptyWeightsDoNotCountAsInstalled() throws {
        try installSpeech(speech)
        let weights = ModelFiles.localURL(for: speech).appendingPathComponent("TextDecoder.mlmodelc/weights/weight.bin")
        try Data().write(to: weights)
        #expect(!ModelFiles.isInstalled(speech))
    }

    @Test func installReplacesThePreviousCopyAndCache() throws {
        try installSpeech(speech)
        let staged = root.appendingPathComponent("staged-\(UUID().uuidString)")
        for file in ModelFiles.requiredSpeechFiles {
            let url = staged.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("new".utf8).write(to: url)
        }
        try ModelFiles.markComplete(staged, name: speech.name)
        try ModelFiles.install(staged, as: speech)

        #expect(ModelFiles.isInstalled(speech))
        #expect(!exists(staged))
        #expect(!exists(ModelFiles.allFiles(for: speech)[1])) // old download cache is gone
        let decoder = ModelFiles.localURL(for: speech).appendingPathComponent("TextDecoder.mlmodelc/weights/weight.bin")
        #expect(try String(contentsOf: decoder, encoding: .utf8) == "new")
    }

    @Test func markCompleteRejectsAnIncompleteDownload() throws {
        let staged = root.appendingPathComponent("partial")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        #expect(throws: ModelFilesError.incomplete(speech.name)) { try ModelFiles.markComplete(staged, name: speech.name) }
        #expect(!exists(staged.appendingPathComponent(ModelFiles.completeMarker)))
    }

    @Test func abandonedStagingFoldersAreRemovedUnlessStillDownloading() throws {
        let abandoned = ModelFiles.staging.appendingPathComponent("\(speech.id)-\(UUID().uuidString)")
        let active = ModelFiles.staging.appendingPathComponent("\(translation.id)-\(UUID().uuidString)")
        for folder in [abandoned, active] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let running = try DownloadLock(root: root, id: translation.id, name: translation.name)

        ModelFiles.removeAbandonedDownloads()

        #expect(!exists(abandoned))
        #expect(exists(active))
        running.release()
    }

    @Test func downloadLockIsExclusiveAcrossHolders() throws {
        let first = try DownloadLock(root: root, id: speech.id, name: speech.name)
        #expect(throws: ModelFilesError.busy(speech.name)) {
            _ = try DownloadLock(root: root, id: speech.id, name: speech.name)
        }
        first.release()
        let again = try DownloadLock(root: root, id: speech.id, name: speech.name)
        again.release()
    }

    // MARK: ModelStore

    @Test func storeDeleteRemovesFilesFromDiskAndClearsSelection() throws {
        try installSpeech(speech)
        try installGGUF(translation)
        let store = ModelStore(defaults: makeDefaults())
        #expect(store.status(of: speech) == .installed)
        #expect(store.speechModel == speech)
        #expect(store.translationModel == translation)

        store.delete(speech)
        store.delete(translation)

        #expect(!ModelFiles.allFiles(for: speech).contains(where: exists))
        #expect(!exists(ModelFiles.localURL(for: translation)))
        #expect(store.status(of: speech) == .notInstalled)
        #expect(store.status(of: translation) == .notInstalled)
        #expect(store.speechModel == nil)
        #expect(store.translationModel == nil)
        #expect(store.needsSetup)
    }

    @Test func storeSelectsAnInstalledModelWhenTheChosenOneIsMissing() throws {
        try installSpeech(otherSpeech)
        let defaults = makeDefaults()
        defaults.set(speech.id, forKey: "selectedSpeech")
        let store = ModelStore(defaults: defaults)
        #expect(store.selectedSpeech == otherSpeech.id)
        #expect(!store.needsSetup)
    }

    @Test func storeWontDeleteOrSwapModelsInUse() throws {
        try installSpeech(speech)
        try installSpeech(otherSpeech)
        let store = ModelStore(defaults: makeDefaults())
        store.selectedSpeech = speech.id
        store.inUse = [speech.id]

        store.delete(speech)
        store.select(otherSpeech)

        #expect(ModelFiles.isInstalled(speech))
        #expect(store.selectedSpeech == speech.id)
    }

    @Test func storeDeleteFallsBackToAnotherInstalledModel() throws {
        try installSpeech(speech)
        try installSpeech(otherSpeech)
        let store = ModelStore(defaults: makeDefaults())
        store.selectedSpeech = speech.id

        store.delete(speech)

        #expect(store.selectedSpeech == otherSpeech.id)
        #expect(!store.needsSetup)
    }

    @Test func legacyOffSelectionMigratesToTranscribeOnly() throws {
        let defaults = makeDefaults()
        defaults.set(ModelStore.translationOff, forKey: "selectedTranslation")
        let store = ModelStore(defaults: defaults)
        #expect(store.legacyTranscribeOnly)
        #expect(store.selectedTranslation == ModelCatalog.defaultTranslation)
        let state = AppState(models: store, style: CaptionStyle(defaults: defaults))
        #expect(state.mode == .transcribe)
    }

    @Test func storeReportsInstalledBytes() throws {
        try installGGUF(translation)
        let store = ModelStore(defaults: makeDefaults())
        #expect(store.installedBytes > 0)
    }
}
