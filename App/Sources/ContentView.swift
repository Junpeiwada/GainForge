import SwiftUI

/// 単一ウィンドウ・画面遷移なし。ツールバー / 一覧テーブル / ステータスバーの 3 エリア。
struct ContentView: View {
    @EnvironmentObject var model: AppViewModel
    @EnvironmentObject var viewer: ViewerModel

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView()
            Divider()
            FileTableView { item in
                viewer.display(item)
            }
            Divider()
            // 実行ボタン（変換 / クリア）は画面下端・ステータスバーの直上に固定表示する。
            FooterBarView()
            Divider()
            StatusBarView()
        }
        // 削除 / クリアで表示中の行が消えたら比較ビューワを空にする。
        .onChange(of: model.items) { _, items in
            viewer.closeIfRemoved(existingIDs: Set(items.map { $0.id }))
        }
        // ビューワが開いている間は、行選択に追従して表示画像を切り替える（単一選択時のみ）。
        .onChange(of: model.selection) { _, sel in
            guard viewer.isPresented, sel.count == 1,
                  let item = model.items.first(where: { sel.contains($0.id) }) else { return }
            viewer.display(item)
        }
    }
}
