import Foundation

/// Fallback thread colors.
///
/// **DST carries no color information** — it only says "change color here". So unless
/// the header has `TC:` entries, blocks are colored by cycling this list.
///
/// The order is fixed and indexed by block position, so the same file always renders
/// identically. Colors are muted and medium-saturation, varied in lightness, chosen to
/// stay distinguishable at 64 pt thumbnail size without looking like clip art.
public enum Palette {
    public static let colors: [StitchColor] = [
        StitchColor(hex: "#2E4A7D", name: "Indigo")!,
        StitchColor(hex: "#B5533C", name: "Terracotta")!,
        StitchColor(hex: "#3F7A54", name: "Fern")!,
        StitchColor(hex: "#C9A227", name: "Ochre")!,
        StitchColor(hex: "#6B4E8F", name: "Plum")!,
        StitchColor(hex: "#1F7A80", name: "Teal")!,
        StitchColor(hex: "#A23E5E", name: "Raspberry")!,
        StitchColor(hex: "#5C6B3A", name: "Olive")!,
        StitchColor(hex: "#D2762F", name: "Amber")!,
        StitchColor(hex: "#3B5FA8", name: "Cornflower")!,
        StitchColor(hex: "#8C4A2F", name: "Sienna")!,
        StitchColor(hex: "#2F6B45", name: "Pine")!,
        StitchColor(hex: "#9C5FA8", name: "Orchid")!,
        StitchColor(hex: "#4A4A52", name: "Slate")!,
        StitchColor(hex: "#B08968", name: "Fawn")!,
        StitchColor(hex: "#2A7BA8", name: "Cerulean")!
    ]

    /// Deterministic color for the block at `index`.
    public static func color(at index: Int) -> StitchColor {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}
