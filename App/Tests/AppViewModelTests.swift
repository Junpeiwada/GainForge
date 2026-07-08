import XCTest
import Foundation
import GainForgeCore
@testable import GainForge

@MainActor
final class AppViewModelTests: XCTestCase {

    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("GainForgeAppTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// テスト専用 suite を注入した ViewModel を作る。
    private func makeVM(suiteName: String? = nil) -> AppViewModel {
        let name = suiteName ?? "gf.test.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return AppViewModel(defaults: suite)
    }

    private func touchJPEG(_ name: String) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    // MARK: - 初期状態

    func testInitialState() {
        let vm = makeVM()
        XCTAssertEqual(vm.phase, .empty)
        XCTAssertFalse(vm.canConvert)
        XCTAssertFalse(vm.canClear)
        XCTAssertTrue(vm.canEditSettings)
        XCTAssertEqual(vm.totalCount, 0)
    }

    // MARK: - 追加・重複排除・派生状態

    func testMergeAddsAndDerivesReadyPhase() throws {
        let vm = makeVM()
        let a = try touchJPEG("a.jpg")
        let b = try touchJPEG("b.jpg")
        let n = vm.mergeNewItems([a, b])
        XCTAssertEqual(n, 2)
        XCTAssertEqual(vm.totalCount, 2)
        XCTAssertEqual(vm.phase, .ready)
        XCTAssertTrue(vm.canConvert)
        XCTAssertTrue(vm.canClear)
    }

    func testMergeDedupsExistingAndWithinBatch() throws {
        let vm = makeVM()
        let a = try touchJPEG("a.jpg")
        XCTAssertEqual(vm.mergeNewItems([a]), 1)
        // 既存と同一パスは追加されない
        XCTAssertEqual(vm.mergeNewItems([a]), 0)
        // 同一バッチ内の重複も 1 件に集約
        let b = try touchJPEG("b.jpg")
        XCTAssertEqual(vm.mergeNewItems([b, b]), 1)
        XCTAssertEqual(vm.totalCount, 2)
    }

    func testClearResetsToEmpty() throws {
        let vm = makeVM()
        _ = vm.mergeNewItems([try touchJPEG("a.jpg")])
        vm.clear()
        XCTAssertEqual(vm.phase, .empty)
        XCTAssertEqual(vm.totalCount, 0)
    }

    func testRemoveByIDs() throws {
        let vm = makeVM()
        _ = vm.mergeNewItems([try touchJPEG("a.jpg"), try touchJPEG("b.jpg")])
        let firstID = vm.items.first!.id
        vm.remove(ids: [firstID])
        XCTAssertEqual(vm.totalCount, 1)
        XCTAssertFalse(vm.items.contains { $0.id == firstID })
    }

    // MARK: - 永続化

    func testSettingsPersistAcrossInstances() {
        let suite = "gf.test.persist.\(UUID().uuidString)"
        let vm1 = makeVM(suiteName: suite)
        vm1.quality = 0.8
        vm1.outputMode = .customFolder
        vm1.sdrMode = .hdrCurve
        vm1.resizeKind = .width
        vm1.resizeWidth = 2560
        vm1.resizeMegapixels = 12
        vm1.resizeHeight = 1440

        // 同じ suite を使う新インスタンスで復元される
        let vm2 = AppViewModel(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(vm2.quality, 0.8, accuracy: 0.0001)
        XCTAssertEqual(vm2.outputMode, .customFolder)
        XCTAssertEqual(vm2.sdrMode, .hdrCurve)
        XCTAssertEqual(vm2.resizeKind, .width)
        XCTAssertEqual(vm2.resizeWidth, 2560)
        XCTAssertEqual(vm2.resizeMegapixels, 12, accuracy: 0.0001)
        XCTAssertEqual(vm2.resizeHeight, 1440)
    }

    /// `resizeKind` と各数値から Core の `ResizeMode` を正しく組み立てること。
    func testResizeModeConstruction() {
        let vm = makeVM()
        vm.resizeMegapixels = 8
        vm.resizeWidth = 3840
        vm.resizeHeight = 2160

        vm.resizeKind = .original
        XCTAssertEqual(vm.resizeMode, .original)
        vm.resizeKind = .megapixels
        XCTAssertEqual(vm.resizeMode, .megapixels(8))
        vm.resizeKind = .width
        XCTAssertEqual(vm.resizeMode, .fitWidth(3840))
        vm.resizeKind = .height
        XCTAssertEqual(vm.resizeMode, .fitHeight(2160))
    }

    func testCustomFolderRestoreDropsMissingPath() {
        let suite = "gf.test.folder.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "gf.outputIsCustom")
        defaults.set("/nonexistent/path/xyz", forKey: "gf.customFolderPath")
        let vm = AppViewModel(defaults: defaults)
        XCTAssertNil(vm.customFolder, "実在しない復元パスは未選択に戻す")
    }

    func testResetSettingsRestoresDefaultsAndPersists() {
        let suite = "gf.test.reset.\(UUID().uuidString)"
        let vm = makeVM(suiteName: suite)
        vm.quality = 0.95
        vm.outputMode = .customFolder
        vm.customFolder = tmp
        vm.sdrMode = .hdrCurve
        vm.resizeKind = .megapixels
        vm.resizeMegapixels = 24

        vm.resetSettings()
        XCTAssertEqual(vm.quality, AppViewModel.Defaults.quality, accuracy: 0.0001)
        XCTAssertEqual(vm.outputMode, .sameFolder)
        XCTAssertNil(vm.customFolder)
        XCTAssertEqual(vm.sdrMode, AppViewModel.Defaults.sdrMode)
        XCTAssertEqual(vm.resizeKind, AppViewModel.Defaults.resizeKind)
        XCTAssertEqual(vm.resizeMegapixels, AppViewModel.Defaults.resizeMegapixels, accuracy: 0.0001)

        // 永続化先もリセットされ、新インスタンスで初期値が復元される
        let vm2 = AppViewModel(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(vm2.quality, AppViewModel.Defaults.quality, accuracy: 0.0001)
        XCTAssertEqual(vm2.outputMode, .sameFolder)
        XCTAssertNil(vm2.customFolder)
        XCTAssertEqual(vm2.sdrMode, AppViewModel.Defaults.sdrMode)
    }

    func testCustomFolderRestoreKeepsExistingPath() {
        let suite = "gf.test.folder2.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(tmp.path, forKey: "gf.customFolderPath")
        let vm = AppViewModel(defaults: defaults)
        XCTAssertEqual(vm.customFolder?.standardizedFileURL, tmp.standardizedFileURL)
    }

    // MARK: - 純粋ヘルパ

    func testReductionLabel() {
        XCTAssertEqual(SizeFormat.reductionLabel(input: 100, output: 28), "-72%")
        XCTAssertEqual(SizeFormat.reductionLabel(input: 100, output: 100), "±0%")
        XCTAssertEqual(SizeFormat.reductionLabel(input: 100, output: 120), "+20%")
        XCTAssertEqual(SizeFormat.reductionLabel(input: 0, output: 0), "")
    }

    func testBeforeAfterLabel() {
        XCTAssertEqual(SizeFormat.beforeAfter(input: nil, output: nil, status: .waiting), "- → -")
        XCTAssertEqual(SizeFormat.beforeAfter(input: 1_048_576, output: nil, status: .converting), "1.0MB → …")
        XCTAssertEqual(SizeFormat.beforeAfter(input: 2_097_152, output: 1_048_576, status: .done), "2.0MB → 1.0MB")
    }

    // MARK: - 出力計画（上書き判定・連番回避）

    /// 別フォルダの同名ファイルを同一出力先へ集約すると、バッチ内衝突は連番で必ず分離される。
    func testPlanDedupesIntraBatchWithSuffix() {
        let id1 = UUID(), id2 = UUID()
        let a = URL(fileURLWithPath: "/in/x/photo.jpg")
        let b = URL(fileURLWithPath: "/in/y/photo.jpeg")
        let plans = OutputPlanner.plan(
            targets: [(id1, a), (id2, b)],
            outputMode: .customFolder, customFolder: URL(fileURLWithPath: "/out"),
            allowOverwriteExisting: true, fileExists: { _ in false })
        XCTAssertEqual(plans.map { $0.output.lastPathComponent }, ["photo.heic", "photo_1.heic"])
        XCTAssertFalse(plans.contains { $0.willOverwrite })
    }

    /// 既存ファイルは上書き許可ありなら willOverwrite=true として同名を使う。
    func testPlanFlagsExistingAsOverwriteWhenAllowed() {
        let id = UUID()
        let input = URL(fileURLWithPath: "/in/photo.jpg")
        let existing = URL(fileURLWithPath: "/in/photo.heic").standardizedFileURL
        let plans = OutputPlanner.plan(
            targets: [(id, input)],
            outputMode: .sameFolder, customFolder: nil,
            allowOverwriteExisting: true,
            fileExists: { $0.standardizedFileURL == existing })
        XCTAssertEqual(plans[0].output.lastPathComponent, "photo.heic")
        XCTAssertTrue(plans[0].willOverwrite)
    }

    /// 既存ファイルは上書き不許可なら連番でずらし、既存を温存する（willOverwrite=false）。
    func testPlanAvoidsExistingWhenRenaming() {
        let id = UUID()
        let input = URL(fileURLWithPath: "/in/photo.jpg")
        let existing = URL(fileURLWithPath: "/in/photo.heic").standardizedFileURL
        let plans = OutputPlanner.plan(
            targets: [(id, input)],
            outputMode: .sameFolder, customFolder: nil,
            allowOverwriteExisting: false,
            fileExists: { $0.standardizedFileURL == existing })
        XCTAssertEqual(plans[0].output.lastPathComponent, "photo_1.heic")
        XCTAssertFalse(plans[0].willOverwrite)
    }

    // MARK: - 既存 HEIC の検出（変換せずプレビュー可能にする）

    /// 入力と同じフォルダに同名 HEIC があれば、その URL を返す。
    func testExistingFinderDetectsSameFolderHEIC() {
        let input = URL(fileURLWithPath: "/in/photo.jpg")
        let existing = URL(fileURLWithPath: "/in/photo.heic").standardizedFileURL
        let found = ExistingOutputFinder.find(
            input: input, outputMode: .sameFolder, customFolder: nil,
            fileExists: { $0.standardizedFileURL == existing })
        XCTAssertEqual(found?.standardizedFileURL, existing)
    }

    /// 指定フォルダ出力時は、入力と同じフォルダに無くても出力先フォルダの同名 HEIC を検出する。
    func testExistingFinderDetectsCustomFolderHEIC() {
        let input = URL(fileURLWithPath: "/in/photo.jpg")
        let existing = URL(fileURLWithPath: "/out/photo.heic").standardizedFileURL
        let found = ExistingOutputFinder.find(
            input: input, outputMode: .customFolder,
            customFolder: URL(fileURLWithPath: "/out"),
            fileExists: { $0.standardizedFileURL == existing })
        XCTAssertEqual(found?.standardizedFileURL, existing)
    }

    /// 同名 HEIC がどこにも無ければ nil（連番 `_1` は既存扱いにしない）。
    func testExistingFinderReturnsNilWhenAbsent() {
        let input = URL(fileURLWithPath: "/in/photo.jpg")
        let suffixed = URL(fileURLWithPath: "/in/photo_1.heic").standardizedFileURL
        let found = ExistingOutputFinder.find(
            input: input, outputMode: .sameFolder, customFolder: nil,
            fileExists: { $0.standardizedFileURL == suffixed })
        XCTAssertNil(found)
    }

    /// 追加した JPEG に同名 HEIC が同じフォルダにあると、probe 後に「既存」状態になり
    /// 出力 URL/サイズが入って比較ビューワを開ける（hasComparableOutput=true）。
    func testProbeMarksExistingWhenHEICPresent() async throws {
        let vm = makeVM()
        let jpg = try touchJPEG("photo.jpg")
        let heic = tmp.appendingPathComponent("photo.heic")
        try Data(count: 1234).write(to: heic)

        XCTAssertEqual(vm.mergeNewItems([jpg]), 1)
        // probe は detached で走るため、状態が確定するまで待つ。
        try await waitUntil { vm.items.first?.status == .existing }

        let item = try XCTUnwrap(vm.items.first)
        XCTAssertEqual(item.status, .existing)
        XCTAssertEqual(item.outputURL?.standardizedFileURL, heic.standardizedFileURL)
        XCTAssertEqual(item.outputBytes, 1234)
        XCTAssertTrue(item.hasComparableOutput)
        // 既存行は未選択なら既定の変換対象に入らない。
        XCTAssertTrue(vm.conversionTargetIDs.isEmpty)
        // 選択すれば再変換の対象になる。
        vm.selection = [item.id]
        XCTAssertEqual(vm.conversionTargetIDs, [item.id])
        XCTAssertTrue(vm.hasConvertibleSelection)
    }

    /// 再変換対象の判定表。完了・エラー・スキップ行も選択すれば再変換でき、選択なしの
    /// 「すべて変換」にも含まれる（圧縮率を変えてやり直す等）。既存は選択時のみ、変換中は常に対象外。
    func testConvertTargetDecisionTable() {
        // 選択すれば再変換できる（変換中以外すべて）。
        XCTAssertTrue(AppViewModel.isReconvertible(.waiting))
        XCTAssertTrue(AppViewModel.isReconvertible(.done))
        XCTAssertTrue(AppViewModel.isReconvertible(.error))
        XCTAssertTrue(AppViewModel.isReconvertible(.skipped))
        XCTAssertTrue(AppViewModel.isReconvertible(.existing))
        XCTAssertFalse(AppViewModel.isReconvertible(.converting))

        // 選択なしの既定対象。完了行も含むが、既存（こちらが作ったとは限らない）は外す。
        XCTAssertTrue(AppViewModel.isDefaultConvertTarget(.waiting))
        XCTAssertTrue(AppViewModel.isDefaultConvertTarget(.done))
        XCTAssertTrue(AppViewModel.isDefaultConvertTarget(.error))
        XCTAssertTrue(AppViewModel.isDefaultConvertTarget(.skipped))
        XCTAssertFalse(AppViewModel.isDefaultConvertTarget(.existing))
        XCTAssertFalse(AppViewModel.isDefaultConvertTarget(.converting))
    }

    /// 同名 HEIC が無ければ probe 後も「待機」のまま（既定の変換対象に入る）。
    func testProbeKeepsWaitingWhenNoHEIC() async throws {
        let vm = makeVM()
        let jpg = try touchJPEG("solo.jpg")
        XCTAssertEqual(vm.mergeNewItems([jpg]), 1)
        // probe 完了の目安として gainMap 判定の確定を待つ（待機のまま変わらないことを確認）。
        try await waitUntil { vm.items.first?.gainMap != .checking }
        XCTAssertEqual(vm.items.first?.status, .waiting)
        XCTAssertEqual(vm.conversionTargetIDs.count, 1)
    }

    /// 条件が満たされるまで短く待つ（detached な probe の完了待ち）。
    private func waitUntil(timeout: TimeInterval = 2.0,
                           _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("条件が時間内に満たされませんでした"); return }
            try await Task.sleep(nanoseconds: 20_000_000)   // 20ms
        }
    }
}
