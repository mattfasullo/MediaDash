import XCTest
@testable import MediaDash

final class FinalsFolderOrganizationTests: XCTestCase {

    // MARK: - Pro Tools suffix stripping

    func testStripProToolsSuffix_removesTrailingDigits() {
        XCTAssertEqual(FinalsClassifier.stripProToolsSuffix("04_Adidas_30FR_Apr24_WEB_Fullmix_17"), "04_Adidas_30FR_Apr24_WEB_Fullmix")
        XCTAssertEqual(FinalsClassifier.stripProToolsSuffix("Track_01_Mix_5"), "Track_01_Mix")
        XCTAssertEqual(FinalsClassifier.stripProToolsSuffix("Track_01_Mix_123"), "Track_01_Mix")
    }

    func testStripProToolsSuffix_leavesLetterSuffixesAlone() {
        XCTAssertEqual(FinalsClassifier.stripProToolsSuffix("Track_V2"), "Track_V2")
        XCTAssertEqual(FinalsClassifier.stripProToolsSuffix("Mix_R2D2"), "Mix_R2D2")
    }

    func testStripProToolsSuffix_noSuffix() {
        XCTAssertEqual(FinalsClassifier.stripProToolsSuffix("01_Adidas_30EN_Apr15_WEB_Fullmix"), "01_Adidas_30EN_Apr15_WEB_Fullmix")
    }

    // MARK: - Full mix classification

    func testClassify_fullmix_webFullmix() {
        let (cat, base) = FinalsClassifier.classify(filename: "01_Adidas_30EN_Apr15_WEB_Fullmix.wav")
        XCTAssertEqual(cat, .fullMix(deliverable: "WEB"))
        XCTAssertEqual(base, "01_Adidas_30EN_Apr15_WEB_Fullmix")
    }

    func testClassify_fullmix_tvFullmix() {
        let (cat, _) = FinalsClassifier.classify(filename: "01_Adidas_30EN_Apr15_TV_Fullmix.wav")
        XCTAssertEqual(cat, .fullMix(deliverable: "TV"))
    }

    func testClassify_fullmix_webFM() {
        let (cat, _) = FinalsClassifier.classify(filename: "03_Adidas_6EN_Apr15_WEB_FM.wav")
        XCTAssertEqual(cat, .fullMix(deliverable: "WEB"))
    }

    func testClassify_fullmix_noDeliverable() {
        let (cat, _) = FinalsClassifier.classify(filename: "Mix_Fullmix.wav")
        XCTAssertEqual(cat, .fullMix(deliverable: nil))
    }

    func testClassify_fullmix_stripsProToolsSuffix() {
        let (cat, base) = FinalsClassifier.classify(filename: "04_Adidas_30FR_Apr24_WEB_Fullmix_17.wav")
        XCTAssertEqual(cat, .fullMix(deliverable: "WEB"))
        XCTAssertEqual(base, "04_Adidas_30FR_Apr24_WEB_Fullmix")
    }

    // MARK: - Mixout (stem) classification

    func testClassify_mixout_sfx() {
        let (cat, _) = FinalsClassifier.classify(filename: "01_Adidas_30EN_Apr15_SFX.wav")
        XCTAssertEqual(cat, .mixout)
    }

    func testClassify_mixout_sfxOnly() {
        let (cat, _) = FinalsClassifier.classify(filename: "01_Adidas_30EN_SFXOnly.wav")
        XCTAssertEqual(cat, .mixout)
    }

    func testClassify_mixout_sync() {
        let (cat, _) = FinalsClassifier.classify(filename: "01_Adidas_30EN_Apr15_Sync.wav")
        XCTAssertEqual(cat, .mixout)
    }

    func testClassify_mixout_dialOnly() {
        let (cat, _) = FinalsClassifier.classify(filename: "Spot_DialOnly.wav")
        XCTAssertEqual(cat, .mixout)
    }

    func testClassify_mixout_music() {
        let (cat, _) = FinalsClassifier.classify(filename: "01_Adidas_30EN_Apr15_Music.wav")
        XCTAssertEqual(cat, .mixout)
    }

    func testClassify_mixout_amb() {
        let (cat, _) = FinalsClassifier.classify(filename: "01_Adidas_30EN_Apr15_Amb.wav")
        XCTAssertEqual(cat, .mixout)
    }

    func testClassify_mixout_syncMix_musicMix_ambMix() {
        XCTAssertEqual(FinalsClassifier.classify(filename: "04_Adidas_30FR_Rev1_Apr24_SyncMix_15.wav").category, .mixout)
        XCTAssertEqual(FinalsClassifier.classify(filename: "04_Adidas_30FR_Rev1_Apr24_MusicMix_15.wav").category, .mixout)
        XCTAssertEqual(FinalsClassifier.classify(filename: "04_Adidas_30FR_Rev1_Apr24_AmbMix_15.wav").category, .mixout)
    }

    func testClassify_mixout_anncrMix_proToolsStem() {
        let name = "02_A&W Smash Burgers_Napkins_May5_15_AnncrMix_07.wav"
        let (cat, base) = FinalsClassifier.classify(filename: name)
        XCTAssertEqual(cat, .mixout)
        XCTAssertEqual(base, "02_A&W Smash Burgers_Napkins_May5_15_AnncrMix")
    }

    func testClassify_mixout_stemInMiddleSegment() {
        let (cat, _) = FinalsClassifier.classify(filename: "01_Adidas_30EN_Rev1_Apr24_SFX_handle.wav")
        XCTAssertEqual(cat, .mixout)
    }

    func testClassify_mixout_stripsProToolsSuffix() {
        let (cat, base) = FinalsClassifier.classify(filename: "01_Track_SFX_3.wav")
        XCTAssertEqual(cat, .mixout)
        XCTAssertEqual(base, "01_Track_SFX")
    }

    // MARK: - Video / QT reference

    func testClassify_video_mov() {
        let (cat, _) = FinalsClassifier.classify(filename: "01_Adidas_30E_Apr15.26_QT REF.mov")
        XCTAssertEqual(cat, .qtReference)
    }

    func testClassify_video_mp4() {
        let (cat, _) = FinalsClassifier.classify(filename: "Reference_Video.mp4")
        XCTAssertEqual(cat, .qtReference)
    }

    // MARK: - Non–full-mix → mixout (catch-all)

    func testClassify_catchAll_arbitraryName_isMixout() {
        let (cat, _) = FinalsClassifier.classify(filename: "RandomFile.wav")
        XCTAssertEqual(cat, .mixout)
    }

    func testClassify_catchAll_aiff_isMixout() {
        let (cat, _) = FinalsClassifier.classify(filename: "SomeTrack.aiff")
        XCTAssertEqual(cat, .mixout)
    }

    func testClassify_mixout_anncr_trailingStem() {
        let (cat, _) = FinalsClassifier.classify(filename: "Spot_15_Anncr.wav")
        XCTAssertEqual(cat, .mixout)
    }

    // MARK: - Precedence: full mix beats stem token when Fullmix is present

    func testClassify_precedence_fullmixBeforeAmbiguousStem() {
        // If the file has both a deliverable and "Fullmix", it should be a full mix
        let (cat, _) = FinalsClassifier.classify(filename: "Track_WEB_Fullmix_SFX.wav")
        // Fullmix appears; should win as fullMix not mixout
        XCTAssertEqual(cat, .fullMix(deliverable: "WEB"))
    }

    // MARK: - Move plan / collision detection

    func testBuildPlan_classifiesFilesIntoCorrectBuckets() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let files: [(String, String)] = [
            ("01_Spot_WEB_Fullmix.wav", "waveform"),
            ("01_Spot_TV_Fullmix.wav", "waveform"),
            ("01_Spot_SFX.wav", "stem"),
            ("01_Spot_Music.wav", "stem"),
            ("Ref_QT.mov", "video"),
            ("Unknown.wav", "unknown"),
        ]
        for (name, content) in files {
            try content.write(to: tmp.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let preview = FinalsFolderOrganizationUseCase.buildPlan(root: tmp)

        XCTAssertEqual(preview.fullMixes.count, 2)
        XCTAssertEqual(preview.mixouts.count, 3)
        XCTAssertEqual(preview.qtReferences.count, 1)
        XCTAssertEqual(preview.unclassified.count, 0)

        // WEB should go into 01_Fullmixes/WEB
        let webDest = preview.fullMixes.first(where: { $0.source.lastPathComponent.contains("WEB") })?.destination
        XCTAssertTrue(webDest?.path.contains("01_Fullmixes/WEB") ?? false, "WEB fullmix should be in WEB subfolder")

        // TV should go into 01_Fullmixes/TV
        let tvDest = preview.fullMixes.first(where: { $0.source.lastPathComponent.contains("TV") })?.destination
        XCTAssertTrue(tvDest?.path.contains("01_Fullmixes/TV") ?? false, "TV fullmix should be in TV subfolder")
    }

    func testDetectConflicts_returnsTrueWhenFileExists() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Create source and a pre-existing destination
        try "src".write(to: tmp.appendingPathComponent("Spot_WEB_Fullmix.wav"), atomically: true, encoding: .utf8)
        let destDir = tmp.appendingPathComponent("01_Fullmixes/WEB")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        try "existing".write(to: destDir.appendingPathComponent("Spot_WEB_Fullmix.wav"), atomically: true, encoding: .utf8)

        let preview = FinalsFolderOrganizationUseCase.buildPlan(root: tmp)
        let conflicts = FinalsFolderOrganizationUseCase.detectConflicts(in: preview)
        XCTAssertEqual(conflicts.count, 1)
    }

    func testExecute_movesFilesAndCleansBasename() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try "content".write(to: tmp.appendingPathComponent("01_Ad_WEB_Fullmix_17.wav"), atomically: true, encoding: .utf8)
        try "content".write(to: tmp.appendingPathComponent("01_Ad_SFX.wav"), atomically: true, encoding: .utf8)
        try "content".write(to: tmp.appendingPathComponent("Ref.mov"), atomically: true, encoding: .utf8)

        let preview = FinalsFolderOrganizationUseCase.buildPlan(root: tmp)
        XCTAssertTrue(FinalsFolderOrganizationUseCase.detectConflicts(in: preview).isEmpty)
        try FinalsFolderOrganizationUseCase.execute(preview: preview)

        // Suffix stripped
        let renamedFullmix = tmp.appendingPathComponent("01_Fullmixes/WEB/01_Ad_WEB_Fullmix.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedFullmix.path), "Fullmix should be renamed and moved")

        let movedSFX = tmp.appendingPathComponent("02_Mixouts/01_Ad_SFX.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedSFX.path), "SFX stem should be in 02_Mixouts")

        let movedQT = tmp.appendingPathComponent("03_Quicktime References/Ref.mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedQT.path), "Video should be in 03_Quicktime References")
    }

    func testExecute_throwsOnConflict() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try "src".write(to: tmp.appendingPathComponent("Spot_WEB_Fullmix.wav"), atomically: true, encoding: .utf8)
        let destDir = tmp.appendingPathComponent("01_Fullmixes/WEB")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        try "existing".write(to: destDir.appendingPathComponent("Spot_WEB_Fullmix.wav"), atomically: true, encoding: .utf8)

        let preview = FinalsFolderOrganizationUseCase.buildPlan(root: tmp)
        XCTAssertThrowsError(try FinalsFolderOrganizationUseCase.execute(preview: preview)) { error in
            XCTAssertTrue(error is FinalsMoveError)
        }
    }
}
