import SwiftUI

/// 角丸の小さなラベル（ゲインマップ・状態表示用）。
struct Chip: View {
    let text: String
    let systemImage: String?
    let color: Color
    var filled: Bool = false

    init(_ text: String, systemImage: String? = nil, color: Color, filled: Bool = false) {
        self.text = text
        self.systemImage = systemImage
        self.color = color
        self.filled = filled
    }

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(filled ? color.opacity(0.18) : Color.secondary.opacity(0.12))
        .foregroundStyle(filled ? color : .secondary)
        .clipShape(Capsule())
    }
}

extension GainMapState {
    @MainActor @ViewBuilder var chip: some View {
        switch self {
        case .checking: Chip("判定中…", color: .secondary)
        case .present:  Chip("あり", systemImage: "circle.fill", color: .accentColor, filled: true)
        case .absent:   Chip("なし", systemImage: "circle", color: .secondary)
        }
    }
}

extension RowStatus {
    @MainActor @ViewBuilder var chip: some View {
        switch self {
        case .waiting:    Chip("待機", color: .secondary)
        case .converting: Chip("変換中", systemImage: "clock", color: .blue, filled: true)
        case .done:       Chip("完了", systemImage: "checkmark", color: .green, filled: true)
        case .existing:   Chip("既存", systemImage: "checkmark.seal", color: .teal, filled: true)
        case .error:      Chip("エラー", systemImage: "exclamationmark.triangle", color: .red, filled: true)
        case .skipped:    Chip("スキップ", color: .secondary)
        }
    }
}

/// バイト数 → "8.2MB" 等の表記。
enum SizeFormat {
    static func mb(_ bytes: Int) -> String {
        String(format: "%.1fMB", Double(bytes) / 1_048_576.0)
    }
    /// 変換前 → 変換後（未確定は "…" / "-"）。
    static func beforeAfter(input: Int?, output: Int?, status: RowStatus) -> String {
        let before = input.map(mb) ?? "-"
        switch status {
        case .done, .existing:
            return "\(before) → \(output.map(mb) ?? "-")"
        case .converting:
            return "\(before) → …"
        default:
            return "\(before) → -"
        }
    }

    /// 合計の削減率ラベル。容量が減ったらマイナス表示（例 `-72%`）、増えたら `+NN%`、変化なしは `±0%`。
    /// input が 0（完了行なし）のときは空文字を返す。
    static func reductionLabel(input: Int, output: Int) -> String {
        guard input > 0 else { return "" }
        let pct = Int((100.0 * (1.0 - Double(output) / Double(input))).rounded())
        if pct == 0 { return "±0%" }
        return pct > 0 ? "-\(pct)%" : "+\(-pct)%"
    }
}
