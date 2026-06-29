// SPDX-FileCopyrightText: 2026 Romain d'Alverny
// SPDX-License-Identifier: MIT
import SwiftUI
import DesgranaCore

struct RowCursorModifier: ViewModifier {
    let kind: OutputRow.Kind
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(pointerStyle15)
        } else {
            content
        }
    }
    @available(macOS 15, *)
    private var pointerStyle15: PointerStyle {
        switch kind {
        case .stereo:                          return .columnResize
        case .monoLinkable, .monoLinkablePrev: return .link
        case .mono:                            return .default
        }
    }
}

struct TrackListView: View {
    @EnvironmentObject private var vm: SplitViewModel
    @State private var hoveredGroupIDs: Set<Int> = []

    private func buildRows() -> [OutputRow] {
        let pairs          = vm.effectivePairs
        let names          = vm.effectiveChannelNames
        let total          = vm.sessionInfo?.numChannels ?? vm.inferredChannels ?? 0
        let pairedChannels = Set(pairs.flatMap { [$0.left, $0.right] })
        var rows: [OutputRow] = []

        for pair in pairs {
            let l = names[pair.left] ?? ""
            let r = names[pair.right] ?? ""
            let nameStr = [l, r].filter { !$0.isEmpty }.joined(separator: " & ")
            rows.append(OutputRow(
                id: pair.left,
                chLabel: String(format: "ch %02d–%02d", pair.left, pair.right),
                nameLabel: nameStr,
                kind: .stereo(left: pair.left)
            ))
        }
        if total > 0 {
            for ch in 1...total where !pairedChannels.contains(ch) {
                let nextFree = ch + 1 <= total && !pairedChannels.contains(ch + 1)
                let prevFree = ch - 1 >= 1 && !pairedChannels.contains(ch - 1)
                let kind: OutputRow.Kind = nextFree ? .monoLinkable(ch: ch)
                    : prevFree ? .monoLinkablePrev(ch: ch)
                    : .mono
                rows.append(OutputRow(
                    id: ch,
                    chLabel: String(format: "ch %02d", ch),
                    nameLabel: names[ch] ?? "",
                    kind: kind
                ))
            }
        }
        return rows.sorted { $0.id < $1.id }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                Color.clear.frame(height: 6)
                ForEach(buildRows()) { row in
                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        Group {
                            switch row.kind {
                            case .stereo: Text("stereo")
                            default:      Text("mono")
                            }
                        }
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .leading)
                        .padding(.leading, 3)
                        Text(row.nameLabel.isEmpty ? row.chLabel : row.nameLabel)
                            .foregroundStyle(row.nameLabel.isEmpty ? .tertiary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.chLabel)
                            .font(.caption)
                            .fontDesign(.monospaced)
                            .foregroundStyle(.tertiary)
                            .frame(width: 84, alignment: .trailing)
                    }
                    .font(.callout)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(hoveredGroupIDs.contains(row.id) ? Color.primary.opacity(0.06) : Color.clear)
                            .padding(.leading, -4)
                            .padding(.trailing, -4)
                    )
                    .modifier(RowCursorModifier(kind: row.kind))
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        switch row.kind {
                        case .stereo(let left): vm.unlinkPair(left: left)
                        case .monoLinkable(let ch): vm.linkChannels(ch, ch + 1)
                        case .monoLinkablePrev(let ch): vm.linkChannels(ch - 1, ch)
                        case .mono: break
                        }
                    }
                    .onHover { hovered in
                        guard hovered else { return }
                        switch row.kind {
                        case .stereo:
                            hoveredGroupIDs = [row.id]
                        case .monoLinkable(let ch):
                            hoveredGroupIDs = [ch, ch + 1]
                        case .monoLinkablePrev(let ch):
                            hoveredGroupIDs = [ch - 1, ch]
                        case .mono:
                            hoveredGroupIDs = []
                        }
                    }
                    .help({
                        switch row.kind {
                        case .stereo: return "Click to split into two mono channels"
                        case .monoLinkable(let ch): return "Click to pair with ch\(String(format: "%02d", ch + 1)) as stereo"
                        case .monoLinkablePrev(let ch): return "Click to pair with ch\(String(format: "%02d", ch - 1)) as stereo"
                        case .mono: return ""
                        }
                    }())
                }
                Color.clear.frame(height: 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onHover { if !$0 { hoveredGroupIDs = [] } }
        }
        .frame(maxHeight: 200)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.06),
                    .init(color: .black, location: 0.94),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}
