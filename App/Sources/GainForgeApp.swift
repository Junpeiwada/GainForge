import SwiftUI

@main
struct GainForgeApp: App {
    @StateObject private var model = AppViewModel()
    // 比較ビューワの共有状態。Window シーンが単一インスタンスのため、内容を差し替えて使い回す。
    @StateObject private var viewer = ViewerModel()
    // アプリ内自動更新（Sparkle）。生成時に自動チェックを開始し、About とメニューから共有する。
    @StateObject private var updater = UpdaterController()

    /// ウィンドウフレームの自動保存キー。
    private static let frameAutosaveName = "GainForgeMainWindow"

    /// 比較ビューワウィンドウの識別子（openWindow(id:) で前面化）。
    static let viewerWindowID = "viewer"

    /// About ウィンドウの識別子（標準 About を置換し openWindow(id:) で開く）。
    static let aboutWindowID = "about"

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(viewer)
                .frame(minWidth: 500, minHeight: 460)
                .background(WindowFrameAutosave(name: Self.frameAutosaveName))
                .background(MainWindowTerminator())
        }
        .windowResizability(.contentMinSize)
        .commands {
            AppCommands(model: model, updater: updater)
        }

        // アプリ情報（別ウィンドウ・単一インスタンス）。標準 About を置き換える。
        // 起動時は自動表示せず、メニュー「GainForge について」でのみ開く。
        Window("GainForge について", id: Self.aboutWindowID) {
            AboutView()
                .environmentObject(updater)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

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

/// アプリメニューのカスタムコマンド。標準の「About」を自前の About ウィンドウに置換し、
/// その直後に「更新を確認」「設定をリセット」を追加する。
/// （openWindow と各モデルへアクセスするため、.commands クロージャから分離した Commands 型にする）
private struct AppCommands: Commands {
    @ObservedObject var model: AppViewModel
    @ObservedObject var updater: UpdaterController
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // 標準「GainForge について」を専用 About ウィンドウに差し替える。
        CommandGroup(replacing: .appInfo) {
            Button("GainForge について") {
                openWindow(id: GainForgeApp.aboutWindowID)
            }
        }
        // About の直後に「更新を確認」「設定をリセット」を並べる。
        CommandGroup(after: .appInfo) {
            Button("更新を確認…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
            Button("設定をリセット") { model.resetSettings() }
                .disabled(!model.canEditSettings)
        }
    }
}
