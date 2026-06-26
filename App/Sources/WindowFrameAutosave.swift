import SwiftUI
import AppKit

/// SwiftUI の WindowGroup に AppKit のウィンドウフレーム自動保存を結びつける橋渡し。
///
/// - 起動時: 保存済みフレーム（位置・サイズ）を復元する。
/// - 以後: ウィンドウの移動・リサイズを `name` をキーに UserDefaults へ自動保存する（AppKit 管理）。
/// - フォールバック: 復元したフレームがどの画面にも表示されない（外部モニタを外した等）場合は、
///   既定サイズで主画面の中央へ戻す。AppKit 標準のクランプに加えた安全網。
struct WindowFrameAutosave: NSViewRepresentable {
    /// UserDefaults 上の保存キー（"NSWindow Frame <name>" として保存される）。
    let name: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // makeNSView の時点では view.window が未確定なため、次のランループで結びつける。
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            // 二重適用を防ぐ（SwiftUI が NSView を作り直しても 1 度だけ復元する）。
            guard window.frameAutosaveName != name else { return }

            // 保存済みフレームがあれば復元。
            window.setFrameUsingName(name)
            // どの画面にも表示されないなら既定位置（中央）へ戻す。
            if !Self.isVisibleOnAnyScreen(window.frame) {
                window.center()
            }
            // 以後の移動・リサイズを自動保存。
            window.setFrameAutosaveName(name)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// フレームがいずれかの画面の可視領域と重なっていれば「表示可能」とみなす。
    private static func isVisibleOnAnyScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }
}

/// メインウィンドウが閉じられたときにアプリを終了する橋渡し。
/// SwiftUI の WindowGroup はデフォルトで最後のウィンドウを閉じてもアプリが残るため、
/// NSWindow の willClose 通知を直接受けて NSApp.terminate を呼ぶ。
struct MainWindowTerminator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var token: NSObjectProtocol?

        func attach(to window: NSWindow) {
            guard token == nil else { return }
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in MainActor.assumeIsolated { NSApp.terminate(nil) } }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }
}
