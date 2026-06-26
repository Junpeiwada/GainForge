import SwiftUI
import AppKit

/// アプリ情報ウィンドウ。標準の「GainForge について」を置き換える専用ウィンドウとして開く
/// （GainForgeApp の AppCommands で `CommandGroup(replacing: .appInfo)`）。
/// アイコン・名称・バージョン・著作権に加え、Sparkle による更新確認 UI を持つ。
struct AboutView: View {
    @EnvironmentObject private var updater: UpdaterController

    /// Dock と同じアプリアイコン。アセットを直接読まず NSApp から取得する。
    private var appIcon: NSImage { NSApplication.shared.applicationIconImage }

    private var appName: String {
        infoString("CFBundleName") ?? "GainForge"
    }

    /// 「バージョン 1.0（1）」形式。短縮版（CFBundleShortVersionString）とビルド番号を併記。
    private var versionText: String {
        let short = infoString("CFBundleShortVersionString") ?? "?"
        let build = infoString("CFBundleVersion") ?? "?"
        return "バージョン \(short)（\(build)）"
    }

    private var copyright: String? {
        let value = infoString("NSHumanReadableCopyright")
        return (value?.isEmpty == false) ? value : nil
    }

    private let repoURL = URL(string: "https://github.com/Junpeiwada/GainForge")!

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 96, height: 96)

            Text(appName)
                .font(.title)
                .fontWeight(.semibold)

            Text(versionText)
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()
                .padding(.horizontal, 32)

            VStack(spacing: 10) {
                Button {
                    updater.checkForUpdates()
                } label: {
                    Label("更新を確認", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(!updater.canCheckForUpdates)

                Toggle("起動時に自動で更新を確認", isOn: $updater.automaticallyChecksForUpdates)
                    .toggleStyle(.checkbox)
            }
            .frame(maxWidth: 240)

            Link("GitHub リポジトリ", destination: repoURL)
                .font(.callout)

            if let copyright {
                Text(copyright)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(28)
        .frame(width: 360)
    }

    /// Info.plist の文字列値を取得するヘルパ。
    private func infoString(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
