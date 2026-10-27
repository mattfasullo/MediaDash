import AppKit
import XCTest
@testable import MediaDash

final class FinderCommandBridgeTests: XCTestCase {

    func testShouldActivateApp_skipsArrangeFinalsOnly() {
        let arrange = FinderCommandPayload(action: .arrangeFinals, paths: ["/tmp/x"])
        let stage = FinderCommandPayload(action: .stage, paths: ["/tmp/x"])
        let file = FinderCommandPayload(action: .file, paths: ["/tmp/x"])
        let prep = FinderCommandPayload(action: .prep, paths: ["/tmp/x"])
        XCTAssertFalse(FinderFocus.shouldActivateApp(for: [arrange]))
        XCTAssertTrue(FinderFocus.shouldActivateApp(for: [stage]))
        XCTAssertTrue(FinderFocus.shouldActivateApp(for: [file]))
        XCTAssertTrue(FinderFocus.shouldActivateApp(for: [prep]))
        XCTAssertTrue(FinderFocus.shouldActivateApp(for: [arrange, stage]))
    }

    func testPayloadDecodesFileAndPrep() throws {
        let file = try JSONDecoder().decode(FinderCommandPayload.self, from: Data(#"{"action":"file","paths":["/tmp/a"]}"#.utf8))
        XCTAssertEqual(file.action, .file)
        let prep = try JSONDecoder().decode(FinderCommandPayload.self, from: Data(#"{"action":"prep","paths":["/tmp/b"]}"#.utf8))
        XCTAssertEqual(prep.action, .prep)
    }

    @MainActor
    func testHandleOpenURLQueryFallbackFile() {
        _ = FinderCommandBridge.shared.dequeuePending()
        let url = URL(string: "mediadash://finder?action=file&path=/tmp/Clip.wav")!
        XCTAssertTrue(FinderCommandBridge.shared.handleOpenURL(url))
        let pending = FinderCommandBridge.shared.dequeuePending()
        XCTAssertEqual(pending.first?.action, .file)
        XCTAssertEqual(pending.first?.paths, ["/tmp/Clip.wav"])
    }

    func testPayloadDecodesArrangeFinals() throws {
        let json = Data(#"{"action":"arrangeFinals","paths":["/tmp/x"]}"#.utf8)
        let payload = try JSONDecoder().decode(FinderCommandPayload.self, from: json)
        XCTAssertEqual(payload.action, .arrangeFinals)
        XCTAssertEqual(payload.paths, ["/tmp/x"])
    }

    @MainActor
    func testHandleOpenURLQueryFallbackArrangeFinals() {
        _ = FinderCommandBridge.shared.dequeuePending()
        let url = URL(string: "mediadash://finder?action=arrangeFinals&path=/tmp/Finals")!
        XCTAssertTrue(FinderCommandBridge.shared.handleOpenURL(url))
        let pending = FinderCommandBridge.shared.dequeuePending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.action, .arrangeFinals)
        XCTAssertEqual(pending.first?.paths, ["/tmp/Finals"])
    }

    func testArrangeFinals_emptyFolder() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        XCTAssertEqual(FinalsFinderArrange.run(url: tmp), .empty)
    }

    func testArrangeFinals_movesClassifiableFiles() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try "mix".write(to: tmp.appendingPathComponent("Spot_WEB_Fullmix.wav"), atomically: true, encoding: .utf8)
        try "stem".write(to: tmp.appendingPathComponent("Spot_SFX.wav"), atomically: true, encoding: .utf8)

        XCTAssertEqual(
            FinalsFinderArrange.run(url: tmp),
            .arranged(fileCount: 2, folderName: tmp.lastPathComponent)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: tmp.appendingPathComponent("01_WAV_2448_Fullmixes/WEB/Spot_WEB_Fullmix.wav").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: tmp.appendingPathComponent("02_WAV_2448_Mixouts/Spot_SFX.wav").path
            )
        )
    }

    func testServicesProvider_readsFolderFromPasteboard() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pboard = NSPasteboard.withUniqueName()
        pboard.clearContents()
        XCTAssertTrue(pboard.writeObjects([tmp as NSURL]))
        XCTAssertEqual(MediaDashServicesProvider.folderURLs(from: pboard), [tmp])
    }

    func testArrangeFinals_skipsFiles() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertEqual(FinalsFinderArrange.run(url: file), .skippedNotDirectory)
    }

    func testDatedFolderName_usesStandardFormat() {
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 26
        let date = Calendar(identifier: .gregorian).date(from: components)!
        XCTAssertEqual(FinalsFinderArrange.datedFolderName(for: date), "Oct26.26")

        components.month = 11
        components.day = 5
        let nov = Calendar(identifier: .gregorian).date(from: components)!
        XCTAssertEqual(FinalsFinderArrange.datedFolderName(for: nov), "Nov05.26")
    }

    func testPrepareRoots_wrapsLooseFilesThenArranges() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let mix = parent.appendingPathComponent("Spot_WEB_Fullmix.wav")
        let stem = parent.appendingPathComponent("Spot_SFX.wav")
        try "mix".write(to: mix, atomically: true, encoding: .utf8)
        try "stem".write(to: stem, atomically: true, encoding: .utf8)

        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 26
        let now = Calendar(identifier: .gregorian).date(from: components)!

        let prepared = FinalsFinderArrange.prepareRoots(from: [mix, stem], now: now)
        XCTAssertTrue(prepared.moveFailures.isEmpty)
        XCTAssertEqual(prepared.roots.count, 1)
        let dated = parent.appendingPathComponent("Oct26.26")
        XCTAssertEqual(prepared.roots.first?.path, dated.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mix.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dated.appendingPathComponent("Spot_WEB_Fullmix.wav").path))

        XCTAssertEqual(
            FinalsFinderArrange.run(url: dated),
            .arranged(fileCount: 2, folderName: "Oct26.26")
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: dated.appendingPathComponent("01_WAV_2448_Fullmixes/WEB/Spot_WEB_Fullmix.wav").path
            )
        )
    }

    func testPrepareRoots_leavesFoldersInPlace() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "mix".write(to: folder.appendingPathComponent("Spot_WEB_Fullmix.wav"), atomically: true, encoding: .utf8)

        let prepared = FinalsFinderArrange.prepareRoots(from: [folder])
        XCTAssertEqual(prepared.roots.map(\.path), [folder.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Spot_WEB_Fullmix.wav").path))
    }

    func testServicesProvider_readsFileFromPasteboard() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: file) }

        let pboard = NSPasteboard.withUniqueName()
        pboard.clearContents()
        XCTAssertTrue(pboard.writeObjects([file as NSURL]))
        XCTAssertEqual(MediaDashServicesProvider.itemURLs(from: pboard), [file])
        XCTAssertTrue(MediaDashServicesProvider.folderURLs(from: pboard).isEmpty)
    }
}
