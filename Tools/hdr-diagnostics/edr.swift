// edr.swift — 現在のディスプレイの EDR（拡張ダイナミックレンジ）ヘッドルームを表示する。
//
// ゲインマップ HDR は「SDR 白より上」に明部を伸ばすため、表示側にヘッドルームが無いと
// 効果が一切見えない。maxEDR=1.0（=輝度最大など）だと SDR→HDR 変換の効果はゼロに見える。
//
// 使い方: swiftc edr.swift -o edr && ./edr
import AppKit
guard let s = NSScreen.main else { print("no screen"); exit(0) }
print(String(format: "maxEDR(現在)          = %.3f", s.maximumExtendedDynamicRangeColorComponentValue))
print(String(format: "maxPotentialEDR(最大)  = %.3f", s.maximumPotentialExtendedDynamicRangeColorComponentValue))
print("→ maxEDR が 1.0 なら、この画面ではゲインマップHDRの明部拡張は一切表示されません")
print("→ maxPotential が 1.0 なら、そもそも HDR 表示非対応のディスプレイです")
