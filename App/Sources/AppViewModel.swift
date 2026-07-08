import Foundation
import AppKit
import SwiftUI
import GainForgeCore

@MainActor
final class AppViewModel: ObservableObject {

    // MARK: - 一覧
    @Published private(set) var items: [FileItem] = []

    /// 一覧テーブルの選択行。変換対象の決定（選択優先・なければ全件）と
    /// 削除・Finder 表示などの行操作で共有する。FileTableView の Table がここへ束縛する。
    @Published var selection: Set<FileItem.ID> = []

    // MARK: - 設定（UserDefaults に永続化）
    @Published var quality: Double {
        didSet { defaults.set(quality, forKey: Keys.quality) }
    }
    @Published var outputMode: OutputMode {
        didSet { defaults.set(outputMode == .customFolder, forKey: Keys.outputIsCustom) }
    }
    @Published var customFolder: URL? {
        didSet { defaults.set(customFolder?.path, forKey: Keys.customFolderPath) }
    }
    /// ゲインマップ無し（SDR）入力の変換方式。HDR 入力（ゲインマップ付き）には影響しない。
    @Published var sdrMode: SDRConversion {
        didSet { defaults.set(sdrMode.rawValue, forKey: Keys.sdrMode) }
    }

    // MARK: - リサイズ設定
    // 方式（種別）と各方式の数値を別々に保持・永続化する。方式を切り替えても各値を覚えておき、
    // 変換時に `resizeMode`（ResizeMode）へ組み立てる。全経路で縮小のみ・アスペクト維持。
    @Published var resizeKind: ResizeKind {
        didSet { defaults.set(resizeKind.rawValue, forKey: Keys.resizeKind) }
    }
    @Published var resizeMegapixels: Double {
        didSet { defaults.set(resizeMegapixels, forKey: Keys.resizeMegapixels) }
    }
    @Published var resizeWidth: Int {
        didSet { defaults.set(resizeWidth, forKey: Keys.resizeWidth) }
    }
    @Published var resizeHeight: Int {
        didSet { defaults.set(resizeHeight, forKey: Keys.resizeHeight) }
    }

    /// UI の種別＋数値から Core の `ResizeMode` を組み立てる（変換時に参照）。
    var resizeMode: ResizeMode {
        switch resizeKind {
        case .original:   return .original
        case .megapixels: return .megapixels(resizeMegapixels)
        case .width:      return .fitWidth(resizeWidth)
        case .height:     return .fitHeight(resizeHeight)
        }
    }

    // MARK: - 実行状態
    @Published private(set) var isConverting = false
    private var cancelRequested = false
    /// 処理中に計画外の既存ファイルへ衝突し、安全のためバッチを止めたか（完了後の通知に使う）。
    private var haltedByUnexpected = false
    /// `.hdrML` 選択時に LUT を読めず `.hdrCurve` へ降格した旨を、この起動中に通知済みか
    /// （降格は全ファイル共通のためバッチのたびに出さず一度だけ知らせる）。
    private var didNotifyMLFallback = false

    // MARK: - probe（読み込みメタ取得）のスロットル
    // 大量フォルダ投入時に画像デコードが一斉起動してメモリ/CPU が跳ねないよう同時数を抑える。
    private var probeQueue: [FileItem.ID] = []
    private var activeProbes = 0
    private let maxProbeConcurrency = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 4))

    private let defaults: UserDefaults
    private enum Keys {
        static let quality = "gf.quality"
        static let outputIsCustom = "gf.outputIsCustom"
        static let customFolderPath = "gf.customFolderPath"
        static let sdrMode = "gf.sdrMode"
        static let resizeKind = "gf.resizeKind"
        static let resizeMegapixels = "gf.resizeMegapixels"
        static let resizeWidth = "gf.resizeWidth"
        static let resizeHeight = "gf.resizeHeight"
    }

    /// 設定の初期値。初回起動時の既定値と「設定リセット」の戻り先を一元管理する。
    enum Defaults {
        static let quality = 0.6
        static let outputMode = OutputMode.sameFolder
        // 既定は従来挙動（SDR 画像は SDR HEIC で保存）。HDR 補正はユーザーが明示選択する。
        static let sdrMode = SDRConversion.sdr
        // 既定はリサイズなし。各方式の初期値は一般的な値（切替時に個別に覚える）。
        static let resizeKind = ResizeKind.original
        static let resizeMegapixels = 8.0
        static let resizeWidth = 3840
        static let resizeHeight = 2160
    }

    /// - Parameter defaults: 設定の永続化先。テストでは専用 suite を注入する。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let q = defaults.object(forKey: Keys.quality) as? Double
        self.quality = q ?? Defaults.quality
        self.outputMode = defaults.bool(forKey: Keys.outputIsCustom) ? .customFolder : .sameFolder
        self.sdrMode = defaults.string(forKey: Keys.sdrMode)
            .flatMap(SDRConversion.init(rawValue:)) ?? Defaults.sdrMode
        self.resizeKind = defaults.string(forKey: Keys.resizeKind)
            .flatMap(ResizeKind.init(rawValue:)) ?? Defaults.resizeKind
        self.resizeMegapixels = (defaults.object(forKey: Keys.resizeMegapixels) as? Double) ?? Defaults.resizeMegapixels
        self.resizeWidth = (defaults.object(forKey: Keys.resizeWidth) as? Int) ?? Defaults.resizeWidth
        self.resizeHeight = (defaults.object(forKey: Keys.resizeHeight) as? Int) ?? Defaults.resizeHeight
        // 復元したフォルダが実在しなければ「未選択」に戻す（削除済みパスを使い回さない）。
        if let p = defaults.string(forKey: Keys.customFolderPath) {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
            self.customFolder = exists ? URL(fileURLWithPath: p) : nil
        } else {
            self.customFolder = nil
        }
    }

    // MARK: - 派生状態

    var phase: AppPhase {
        if isConverting { return .converting }
        if items.isEmpty { return .empty }
        if items.contains(where: { $0.status == .waiting }) { return .ready }
        return .finished
    }

    /// 今回の変換で処理する対象行の ID 群。
    /// - 選択があれば、選択された「変換中以外の行」を対象にする。完了・既存・エラー・スキップ・
    ///   待機のいずれも、選択すれば何度でも再変換できる（品質を変えてやり直す等）。出力先に
    ///   既存 HEIC があれば上書き確認ダイアログが出る。
    /// - 選択がなければ既定の変換対象（待機・完了・エラー・スキップ）を全件処理する。完了行も
    ///   含めて毎回やり直す。ただし既存（変換前から在った HEIC）はこちらが作ったとは限らないため、
    ///   既定では外す（再変換したいときは行を選択する）。
    /// 選択に変換中行や削除済み ID が混ざっていても、変換可能な行だけに絞られる。
    var conversionTargetIDs: [FileItem.ID] {
        let selectedConvertible = items.filter {
            selection.contains($0.id) && Self.isReconvertible($0.status)
        }
        if !selectedConvertible.isEmpty { return selectedConvertible.map { $0.id } }
        return items.filter { Self.isDefaultConvertTarget($0.status) }.map { $0.id }
    }

    /// 変換対象の件数（変換ボタンの表示・活性判定に使う）。
    var conversionTargetCount: Int { conversionTargetIDs.count }

    /// 選択に再変換可能な行（変換中以外）が 1 つでも含まれているか。
    /// ボタン表示を「すべて変換」/「選択を変換」で切り替える基準。
    var hasConvertibleSelection: Bool {
        items.contains { Self.isReconvertible($0.status) && selection.contains($0.id) }
    }

    /// 選択して再変換できる状態か。変換中以外はすべて対象（既存行も選べばやり直せる）。
    static func isReconvertible(_ status: RowStatus) -> Bool {
        status != .converting
    }

    /// 選択なしの「すべて変換」で既定の対象とみなす状態か。
    /// 待機・完了・エラー・スキップを含む（完了行も毎回やり直す）。既存（変換前から在った HEIC）は
    /// こちらが作ったとは限らないため既定では外し、変換中は対象外にする。
    static func isDefaultConvertTarget(_ status: RowStatus) -> Bool {
        switch status {
        case .waiting, .done, .error, .skipped: return true
        case .existing, .converting: return false
        }
    }

    var canConvert: Bool { isConverting || conversionTargetCount > 0 }
    var canClear: Bool { !items.isEmpty && !isConverting }
    var canEditSettings: Bool { !isConverting }

    // MARK: - 集計（ステータスバー用）

    var totalCount: Int { items.count }
    var completedCount: Int {
        items.filter { $0.status == .done || $0.status == .error || $0.status == .skipped }.count
    }
    var errorCount: Int { items.filter { $0.status == .error }.count }
    var skippedCount: Int { items.filter { $0.status == .skipped }.count }

    /// 完了行の合計（変換前サイズ, 変換後サイズ）。
    var sizeTotals: (input: Int, output: Int) {
        items.filter { $0.status == .done }.reduce(into: (0, 0)) { acc, item in
            acc.0 += item.inputBytes ?? 0
            acc.1 += item.outputBytes ?? 0
        }
    }

    // MARK: - ドロップ受け入れ

    /// ドロップされた URL 群（ファイル / フォルダ）を一覧に追加する。
    /// フォルダの再帰収集はバックグラウンドで行い、巨大階層でも UI を止めない（M-3）。
    func addDropped(_ urls: [URL]) {
        Task {
            let images = await Task.detached(priority: .utility) {
                urls.flatMap { GainForge.collectInputImages($0) }.map { $0.standardizedFileURL }
            }.value
            mergeNewItems(images)
        }
    }

    /// 収集済み入力画像（JPEG / PNG）URL を重複排除して一覧へ追加する（同期・MainActor）。
    /// 戻り値は実際に追加した件数。テストはこの同期 API を直接叩く。
    @discardableResult
    func mergeNewItems(_ images: [URL]) -> Int {
        var seen = Set(items.map { $0.inputURL.standardizedFileURL })
        var added: [FileItem] = []
        for url in images {
            let std = url.standardizedFileURL
            guard seen.insert(std).inserted else { continue }   // 既存・同バッチ内の重複を排除
            added.append(FileItem(inputURL: std))
        }
        guard !added.isEmpty else { return 0 }
        items.append(contentsOf: added)
        for item in added { enqueueProbe(item.id) }
        return added.count
    }

    /// 行のサムネ・サイズ・ゲインマップ有無の取得をキューへ積む。
    private func enqueueProbe(_ id: FileItem.ID) {
        probeQueue.append(id)
        pumpProbes()
    }

    /// 同時実行数の上限までキューから probe を起動する。1 件完了するたびに呼び直して補充する。
    private func pumpProbes() {
        while activeProbes < maxProbeConcurrency, !probeQueue.isEmpty {
            let id = probeQueue.removeFirst()
            guard let url = items.first(where: { $0.id == id })?.inputURL else { continue }
            activeProbes += 1
            // 既存 HEIC の検出先は出力設定に依存する。起動時点の設定をキャプチャして detached へ渡す。
            let mode = outputMode
            let folder = customFolder
            Task.detached(priority: .utility) { [weak self] in
                let size = GainForge.fileSize(url)
                let hasGain = GainForge.hasGainMap(url)
                let png = ImageProbe.thumbnailPNG(for: url)
                let existing = ExistingOutputFinder.find(
                    input: url, outputMode: mode, customFolder: folder,
                    fileExists: { FileManager.default.fileExists(atPath: $0.path) })
                let existingBytes = existing.map { GainForge.fileSize($0) }
                await self?.finishProbe(id: id, size: size, hasGain: hasGain, png: png,
                                        existing: existing, existingBytes: existingBytes)
            }
        }
    }

    /// probe 1 件の完了。結果を反映し、空いたスロットへ次を補充する。
    private func finishProbe(id: FileItem.ID, size: Int, hasGain: Bool, png: Data?,
                            existing: URL?, existingBytes: Int?) {
        activeProbes -= 1
        applyProbe(id: id, size: size, hasGain: hasGain, png: png,
                   existing: existing, existingBytes: existingBytes)
        pumpProbes()
    }

    /// probe 結果を行へ反映する。変換が先に走って確定済みの値は上書きしない（H-3）。
    private func applyProbe(id: FileItem.ID, size: Int, hasGain: Bool, png: Data?,
                           existing: URL?, existingBytes: Int?) {
        update(id) { item in
            if item.inputBytes == nil { item.inputBytes = size }
            item.gainMap = hasGain ? .present : .absent
            if let png, item.thumbnail == nil { item.thumbnail = NSImage(data: png) }
            // 変換前から対応する HEIC があれば「既存」にし、変換せずに比較ビューワで開けるようにする。
            // 変換が先に走って確定済みの行（変換中/完了/エラー）は触らない（H-3）。
            if item.status == .waiting, let existing {
                item.status = .existing
                item.outputURL = existing
                item.outputBytes = existingBytes
            }
        }
    }

    // MARK: - 行操作

    func remove(ids: Set<FileItem.ID>) {
        guard !isConverting else { return }
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)   // 消えた行の ID を選択に残さない
    }

    func clear() {
        guard canClear else { return }
        items.removeAll()
        selection.removeAll()
    }

    // MARK: - 設定リセット

    /// 設定値（品質・出力先・指定フォルダ）を初期値に戻す。
    /// 一覧やウィンドウ位置・サイズには影響しない。didSet 経由で永続化も更新される。
    func resetSettings() {
        guard canEditSettings else { return }
        quality = Defaults.quality
        outputMode = Defaults.outputMode
        customFolder = nil
        sdrMode = Defaults.sdrMode
        resizeKind = Defaults.resizeKind
        resizeMegapixels = Defaults.resizeMegapixels
        resizeWidth = Defaults.resizeWidth
        resizeHeight = Defaults.resizeHeight
    }

    /// 行を更新する小ヘルパ。
    private func update(_ id: FileItem.ID, _ mutate: (inout FileItem) -> Void) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[idx])
    }

    // MARK: - バッチ変換

    func convertOrCancel() {
        if isConverting {
            cancelRequested = true
        } else {
            startConversion()
        }
    }

    private func startConversion() {
        // バッチ開始時点の変換対象（選択優先・なければ全件）をスナップショットする。
        let targetIDs = conversionTargetIDs
        guard !targetIDs.isEmpty else { return }

        // 出力先を事前計画する。バッチ内衝突は連番で必ず回避し、既存ファイルへの上書きを検出する。
        let targets: [(id: FileItem.ID, input: URL)] = targetIDs.compactMap { id in
            guard let input = items.first(where: { $0.id == id })?.inputURL else { return nil }
            return (id, input)
        }
        let exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
        var plans = OutputPlanner.plan(targets: targets, outputMode: outputMode,
                                       customFolder: customFolder,
                                       allowOverwriteExisting: true, fileExists: exists)

        // 既存ファイルを上書きする行があれば、開始前にユーザーへ確認する（予期せぬ上書きの防止）。
        let overwriting = plans.filter { $0.willOverwrite }
        if !overwriting.isEmpty {
            switch presentOverwriteConfirmation(overwriting) {
            case .cancel:
                return
            case .overwrite:
                break   // 計画どおり上書きする。
            case .rename:
                // 既存を温存し、連番で保存し直す。
                plans = OutputPlanner.plan(targets: targets, outputMode: outputMode,
                                           customFolder: customFolder,
                                           allowOverwriteExisting: false, fileExists: exists)
            }
        }

        // id → (出力先, 上書き可否) の対応表。各タスクはこの確定値で書き出す（実行時の再計算なし）。
        let planByID = Dictionary(uniqueKeysWithValues:
            plans.map { ($0.id, (output: $0.output, overwrite: $0.willOverwrite)) })
        let orderedIDs = plans.map { $0.id }

        // ML/LUT 方式を選んでいるのに LUT を読めないと、ゲインマップ無し画像はカーブ法へ降格する。
        // 実際に降格対象（ゲインマップ無し）を含むバッチを始める時、この起動中一度だけ通知する。
        if sdrMode == .hdrML, !GainForge.isMLGainLUTAvailable, !didNotifyMLFallback,
           items.contains(where: { orderedIDs.contains($0.id) && $0.gainMap != .present }) {
            didNotifyMLFallback = true
            presentMLFallbackNotice()
        }

        isConverting = true
        cancelRequested = false
        haltedByUnexpected = false

        let quality = self.quality
        let sdrMode = self.sdrMode
        let resize = self.resizeMode

        // 同時実行数はコア数を基準に上限でクランプする。1 枚のエンコードは ImageIO/CoreImage の
        // ネイティブ呼び出しで途中中断できないため、上限は中止時に待たされる枚数の上限でもある。
        // メモリ過多の抑制と中止の体感を優先し、低めの上限にしている（速く止めたいなら 2 へ）。
        let maxConcurrent = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 3))

        Task {
            // バッチ開始時点の変換対象のみ処理する。変換中に追加された行はこのスナップショットに
            // 含まれず、次回の変換で処理される（画面仕様）。
            let waitingIDs = orderedIDs
            var next = 0

            // maxConcurrent 件を上限に並列実行し、1 件完了するたびに次の 1 件を投入する
            // スライディングウィンドウ方式。各タスクは完了後に MainActor へ戻って該当行だけを
            // 更新するため、一覧は 1 件ずつライブ更新される。
            await withTaskGroup(of: Void.self) { group in
                var inFlight = 0

                // 初期ウィンドウを投入。
                while inFlight < maxConcurrent, next < waitingIDs.count, !cancelRequested {
                    if let op = conversionOperation(for: waitingIDs[next],
                                                    plan: planByID[waitingIDs[next]],
                                                    quality: quality, sdrMode: sdrMode, resize: resize) {
                        group.addTask(priority: .userInitiated, operation: op)
                        inFlight += 1
                    }
                    next += 1
                }

                // 1 件完了するたびに次の待機行を 1 件投入する。
                // 中止要求後は新規投入を止め、実行中（in-flight）のみ完走させる（画面仕様）。
                while await group.next() != nil {
                    inFlight -= 1
                    while next < waitingIDs.count, !cancelRequested {
                        let id = waitingIDs[next]
                        next += 1
                        if let op = conversionOperation(for: id, plan: planByID[id],
                                                        quality: quality, sdrMode: sdrMode, resize: resize) {
                            group.addTask(priority: .userInitiated, operation: op)
                            inFlight += 1
                            break
                        }
                        // 行が消えていた場合は次の待機行を試す。
                    }
                }
            }

            isConverting = false
            cancelRequested = false

            // 処理中に計画外の既存ファイルへ衝突して中断していたら、その旨を通知する。
            if haltedByUnexpected {
                haltedByUnexpected = false
                presentHaltedNotice()
            }
        }
    }

    /// 1 行分の変換オペレーションを生成する（行が存在しなければ nil）。
    /// 呼び出した時点で当該行を「変換中」にし、返すクロージャ本体は detached で実画像を変換し、
    /// 完了後に MainActor へ戻って結果を反映する。並列実行される各タスクの本体に相当する。
    private func conversionOperation(
        for id: FileItem.ID,
        plan: (output: URL, overwrite: Bool)?,
        quality: Double,
        sdrMode: SDRConversion,
        resize: ResizeMode
    ) -> (@Sendable () async -> Void)? {
        guard let plan, let input = items.first(where: { $0.id == id })?.inputURL else { return nil }

        update(id) { $0.status = .converting }

        let output = plan.output
        let overwrite = plan.overwrite
        let dir = output.deletingLastPathComponent()

        return { [weak self] in
            // エラーは Sendable な文字列メッセージへ畳んで境界を越える（any Error は非 Sendable）。
            let outcome: ConversionOutcome = await Task.detached(priority: .userInitiated) {
                do {
                    // 出力先フォルダを用意（指定フォルダが無い場合）。
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    // 出力先は事前計画で確定済み。GUI はゲインマップ無しも常に変換（force: true）。
                    // ゲインマップ無し入力の扱い（SDR 保存 / HDR 補正）は sdrMode に従う。
                    let r = try GainForge.convert(input: input, output: output, quality: quality,
                                                  force: true, overwrite: overwrite, sdrMode: sdrMode,
                                                  resize: resize)
                    return .success(r)
                } catch let e as GainForgeError {
                    // 計画外の既存ファイルへの衝突は「中断」扱いにしてバッチを止める。
                    if case .outputExists = e { return .blocked(e.localizedDescription) }
                    return .failure(e.localizedDescription)
                } catch {
                    // GainForgeError は LocalizedError 準拠のため localizedDescription で日本語メッセージが得られる。
                    return .failure(error.localizedDescription)
                }
            }.value

            await self?.applyOutcome(id: id, outcome: outcome)
        }
    }

    /// 変換タスクの結果（Task 境界を越えるため Sendable）。
    private enum ConversionOutcome: Sendable {
        case success(ConversionResult)
        case failure(String)
        case blocked(String)   // 計画外の既存ファイルへ衝突し、バッチを止めるべき結果
    }

    /// 変換結果を該当行へ反映する（並列タスクの完了コールバック / MainActor）。
    private func applyOutcome(id: FileItem.ID, outcome: ConversionOutcome) {
        switch outcome {
        case .success(let r):
            update(id) { item in
                item.status = .done
                item.outputURL = r.outputURL
                item.outputBytes = r.outputBytes
                if item.inputBytes == nil { item.inputBytes = r.inputBytes }
            }
        case .failure(let message):
            update(id) { item in
                item.status = .error
                item.errorMessage = message
            }
        case .blocked(let message):
            update(id) { item in
                item.status = .error
                item.errorMessage = message
            }
            // 事前計画に無い予期せぬ既存ファイル。以後の予期せぬ上書きを避けるためバッチを止める。
            haltedByUnexpected = true
            cancelRequested = true
        }
    }

    // MARK: - 確認ダイアログ（AppKit）

    /// 既存ファイルを上書きする行があるとき、続行方法をユーザーへ確認する。
    private func presentOverwriteConfirmation(_ overwriting: [OutputPlan]) -> OverwriteResolution {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "出力先に既存ファイルがあります（\(overwriting.count) 件）"
        alert.informativeText = Self.overwriteList(overwriting)
            + "\n\n「上書き」既存を置き換えます／「別名で保存」既存を残し連番で保存します。"
        alert.addButton(withTitle: "上書き")
        alert.addButton(withTitle: "別名で保存")
        alert.addButton(withTitle: "キャンセル")
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .overwrite
        case .alertSecondButtonReturn: return .rename
        default:                       return .cancel
        }
    }

    /// `.hdrML`（ML/LUT）を選んでいるが LUT を読み込めず、明部加重カーブ（`.hdrCurve`）へ
    /// 自動降格することを知らせる（この起動中一度だけ）。ゲインマップ無し SDR 画像のみに作用し、
    /// ゲインマップ付き画像（生転写）には影響しない。
    private func presentMLFallbackNotice() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "HDR補正（ML/LUT）の学習データを読み込めません"
        alert.informativeText = "ゲインマップの無い SDR 画像は、明部加重カーブ（HDR補正（カーブ））で"
            + "代替して補正します。ゲインマップ付きの画像には影響しません。"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// 処理中に計画外の既存ファイルへ衝突してバッチを止めたことを知らせる。
    private func presentHaltedNotice() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "予期せぬ既存ファイルのため変換を中断しました"
        alert.informativeText = "変換中に、計画になかった同名ファイルが出力先に現れたため、"
            + "安全のため残りの変換を停止しました。状況を確認のうえ、もう一度変換してください。"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// 上書き対象の出力ファイル名を箇条書きにする（多すぎる場合は省略）。
    private static func overwriteList(_ plans: [OutputPlan], limit: Int = 10) -> String {
        var text = plans.prefix(limit).map { "・\($0.output.lastPathComponent)" }.joined(separator: "\n")
        if plans.count > limit { text += "\n・ほか \(plans.count - limit) 件" }
        return text
    }
}
