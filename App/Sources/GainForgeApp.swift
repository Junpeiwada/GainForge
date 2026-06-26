import SwiftUI

@main
struct GainForgeApp: App {
    @StateObject private var model = AppViewModel()
    // 比較ビューワの共有状態。Window シーンが単一インスタンスのため、内容を差し替えて使い回す。
    @StateObject private var viewer = ViewerModel()

    /// ウィンドウフレームの自動保存キー。
    private static let frameAutosaveName = "GainForgeMainWindow"

    /// 比較ビューワウィンドウの識別子（openWindow(id:) で前面化）。
    static let viewerWindowID = "viewer"

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(viewer)
                .frame(minWidth: 720, minHeight: 460)
                .background(WindowFrameAutosave(name: Self.frameAutosaveName))
                .background(MainWindowTerminator())
        }
        .windowResizability(.contentMinSize)
        .commands {
            // アプリメニュー（About の直後）に「設定をリセット」を追加する。
            CommandGroup(after: .appInfo) {
                Button("設定をリセット") { model.resetSettings() }
                    .disabled(!model.canEditSettings)
            }
        }

        // 比較ビューワ（別ウィンドウ・単一インスタンス）。
        // 起動時は自動表示せず、行のダブルクリックでのみ開く（状態復元による再表示も抑止）。
        Window("比較ビューワ", id: Self.viewerWindowID) {
            ViewerView()
                .environmentObject(viewer)
                .background(WindowFrameAutosave(name: "GainForgeViewerWindow"))
        }
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}
