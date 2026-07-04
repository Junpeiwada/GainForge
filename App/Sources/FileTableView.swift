import SwiftUI
import AppKit

/// 中央のファイル一覧テーブル（ドロップ受付兼用）。空のときは Empty state。
struct FileTableView: View {
    @EnvironmentObject var model: AppViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var isTargeted = false

    /// 行を比較ビューワで開く。ContentView から注入し、ViewerModel への直接依存を持たせない。
    /// （FileTableView が ViewerModel を @EnvironmentObject で持つと、viewer の @Published 変化で
    ///  Table ごと再描画され、選択が意図せずリセットされる問題が起きるため）
    var onOpenViewer: (FileItem) -> Void

    var body: some View {
        ZStack {
            if model.items.isEmpty {
                EmptyStateView()
            } else {
                table
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(dropHighlight)
        // 一覧テーブル領域全体で D&D を受け付ける。
        .dropDestination(for: URL.self) { urls, _ in
            model.addDropped(urls)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private var table: some View {
        Table(model.items, selection: $model.selection) {
            TableColumn("") { item in
                cell { thumbnail(item) }
            }
            .width(44)

            TableColumn("ファイル名") { item in
                cell {
                    Text(item.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.inputURL.path)
                }
            }
            .width(min: 140, ideal: 220)

            TableColumn("ゲインマップ") { item in
                cell { item.gainMap.chip }
            }
            .width(90)

            TableColumn("状態") { item in
                cell {
                    HStack(spacing: 6) {
                        item.status.chip
                        if item.status == .error, let msg = item.errorMessage {
                            Image(systemName: "info.circle").foregroundStyle(.secondary).help(msg)
                        }
                        // 出力 HEIC を持つ行（完了 / 既存）：比較ビューワを開く / 内容を差し替える。
                        if item.hasComparableOutput {
                            Button { openViewer(item) } label: {
                                Image(systemName: "rectangle.split.2x1")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.tint)
                            .help("変換前後を比較ビューワで表示")
                        }
                    }
                }
            }
            .width(120)

            TableColumn("サイズ") { item in
                cell {
                    Text(SizeFormat.beforeAfter(input: item.inputBytes, output: item.outputBytes, status: item.status))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 110, ideal: 140)
        }
        // ダブルクリック / Return で開く挙動は Table 標準の primaryAction に任せる。
        // 以前は各セルへ simultaneousGesture を貼っていたが、選択のたびに全セルの
        // ジェスチャ認識器が作り直されて行移動が重くなるため、per-cell ジェスチャは廃止した。
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            rowMenu(ids)
        } primaryAction: { ids in
            guard ids.count == 1, let item = model.items.first(where: { ids.contains($0.id) }) else { return }
            openViewer(item)
        }
        .onDeleteCommand { if !model.selection.isEmpty { model.remove(ids: model.selection) } }
        // Esc で選択を解除し、変換対象を「全件」に戻せるようにする（隠れモード対策）。
        .onExitCommand { model.selection.removeAll() }
    }

    /// セル内容を左寄せ・全幅で配置する。ダブルクリックでの表示は Table 全体の
    /// primaryAction が担うため、ここではジェスチャを持たせない（per-cell ジェスチャは
    /// 選択ごとに作り直されて行移動を重くするため廃止した）。
    private func cell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func thumbnail(_ item: FileItem) -> some View {
        if let img = item.thumbnail {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 32, height: 32)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }

    @ViewBuilder
    private func rowMenu(_ ids: Set<FileItem.ID>) -> some View {
        Button("一覧から削除") { model.remove(ids: ids) }
            .disabled(model.isConverting)
        Button("Finder で表示") {
            let urls = model.items.filter { ids.contains($0.id) }.map { $0.inputURL }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
        // 完了行は出力 HEIC を Finder で表示。
        let outputs = model.items.filter { ids.contains($0.id) }.compactMap { $0.outputURL }
        if !outputs.isEmpty {
            Button("出力 HEIC を Finder で表示") {
                NSWorkspace.shared.activateFileViewerSelecting(outputs)
            }
        }
        // 出力 HEIC を持つ行（完了 / 既存）を単一選択しているときは比較ビューワも開ける。
        if ids.count == 1, let item = model.items.first(where: { ids.contains($0.id) }),
           item.hasComparableOutput {
            Button("比較ビューワで表示") { openViewer(item) }
        }
    }

    private func openViewer(_ item: FileItem) {
        onOpenViewer(item)
        openWindow(id: GainForgeApp.viewerWindowID)
    }

    @ViewBuilder
    private var dropHighlight: some View {
        if isTargeted {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor, lineWidth: 2)
                .padding(2)
        }
    }
}

/// 一覧が空のときのプレースホルダ。
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("ここに JPEG / PNG / フォルダをドラッグ&ドロップ")
                .font(.title3)
            Text("フォルダ内の *.jpg / *.jpeg / *.png を再帰的に読み込みます")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
