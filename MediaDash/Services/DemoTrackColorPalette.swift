import SwiftUI

/// Names in the same order as `DemoTrackColorPalette.optionColorValues` (for nonisolated filename matching).
fileprivate enum DemoTrackColorPaletteOptionNames {
    nonisolated static let inPaletteOrder: [String] = [
        "Cyan", "Pink", "Fuchsia", "Emerald", "Lily", "Scarlet", "Ochre", "Saffron",
        "Chestnut", "Cucumber", "Auburn", "Olive", "Amber", "Crimson", "Clover", "Cobalt",
        "Sienna", "Cerulean", "Khaki", "Kiwi", "Blue", "Beige", "White", "Mauve",
        "Whirlpool", "Grey", "Black", "Azure", "Lilac", "Salmon", "Teal", "Turquoise",
        "Taupe", "Mango", "Tangelo", "Yellow", "Orange", "Thistle", "Shamrock", "Eggshell",
        "Maroon", "Navy", "Mint", "Tangerine", "Begonia", "Purple", "Magenta", "Violet",
        "Umber", "Red", "Rose", "Ruby", "Aqua", "Jade", "Green", "Indigo", "Brown",
        "Cream", "Periwinkle", "Cherry", "Burgundy", "Orchid", "Chamomile", "Juniper", "Lavender",
        "Blush", "Pumpkin", "Mulberry", "Tuscan", "Coral", "Lime", "Pecan", "Jasmine",
        "Poppy", "Cabernet", "Honeyball", "Dorado", "Heliotrope", "Ultramarine", "Peach",
        "Aquamarine", "Canary"
    ]
}

/// POSTING LEGEND palette shared by Media Team (Asana demos UI) and Tools Music Demos indexer.
/// Longest name wins when matching a substring in a filename (e.g. "Crimson" before "Red").
enum DemoTrackColorPalette {

    private static let optionColorValues: [Color] = [
        Color(red: 0, green: 0.74, blue: 0.83),
        Color(red: 1, green: 0.41, blue: 0.71),
        Color(red: 1, green: 0, blue: 1),
        Color(red: 0.31, green: 0.78, blue: 0.47),
        Color(red: 0.9, green: 0.9, blue: 1),
        Color(red: 1, green: 0.14, blue: 0),
        Color(red: 0.8, green: 0.47, blue: 0.13),
        Color(red: 0.96, green: 0.77, blue: 0.19),
        Color(red: 0.58, green: 0.32, blue: 0.22),
        Color(red: 0.48, green: 0.74, blue: 0.41),
        Color(red: 0.65, green: 0.16, blue: 0.16),
        Color(red: 0.5, green: 0.5, blue: 0),
        Color(red: 1, green: 0.75, blue: 0),
        Color(red: 0.86, green: 0.08, blue: 0.24),
        Color(red: 0.28, green: 0.55, blue: 0.28),
        Color(red: 0, green: 0.28, blue: 0.67),
        Color(red: 0.63, green: 0.32, blue: 0.18),
        Color(red: 0.16, green: 0.48, blue: 0.72),
        Color(red: 0.76, green: 0.69, blue: 0.57),
        Color(red: 0.56, green: 0.83, blue: 0.29),
        .blue,
        Color(red: 0.96, green: 0.96, blue: 0.86),
        .white,
        Color(red: 0.88, green: 0.69, blue: 0.88),
        Color(red: 0.43, green: 0.71, blue: 0.72),
        .gray,
        .black,
        Color(red: 0.31, green: 0.59, blue: 1),
        Color(red: 0.78, green: 0.64, blue: 0.78),
        Color(red: 0.98, green: 0.5, blue: 0.45),
        .teal,
        Color(red: 0.25, green: 0.88, blue: 0.82),
        Color(red: 0.52, green: 0.45, blue: 0.41),
        Color(red: 1, green: 0.62, blue: 0.18),
        Color(red: 0.98, green: 0.3, blue: 0),
        .yellow,
        .orange,
        Color(red: 0.85, green: 0.75, blue: 0.85),
        Color(red: 0, green: 0.62, blue: 0.38),
        Color(red: 0.94, green: 0.92, blue: 0.84),
        Color(red: 0.5, green: 0, blue: 0),
        Color(red: 0, green: 0, blue: 0.5),
        Color(red: 0.6, green: 1, blue: 0.6),
        Color(red: 1, green: 0.6, blue: 0),
        Color(red: 0.98, green: 0.42, blue: 0.54),
        .purple,
        Color(red: 1, green: 0, blue: 0.55),
        Color(red: 0.58, green: 0, blue: 0.83),
        Color(red: 0.39, green: 0.32, blue: 0.28),
        .red,
        Color(red: 1, green: 0.41, blue: 0.53),
        Color(red: 0.88, green: 0.07, blue: 0.37),
        Color(red: 0, green: 1, blue: 1),
        Color(red: 0, green: 0.66, blue: 0.42),
        .green,
        Color(red: 0.29, green: 0, blue: 0.51),
        .brown,
        Color(red: 1, green: 0.99, blue: 0.82),
        Color(red: 0.8, green: 0.8, blue: 1),
        Color(red: 0.87, green: 0.19, blue: 0.39),
        Color(red: 0.5, green: 0, blue: 0.13),
        Color(red: 0.85, green: 0.44, blue: 0.84),
        Color(red: 0.98, green: 0.95, blue: 0.73),
        Color(red: 0.28, green: 0.36, blue: 0.33),
        Color(red: 0.9, green: 0.9, blue: 0.98),
        Color(red: 0.87, green: 0.69, blue: 0.69),
        Color(red: 1, green: 0.46, blue: 0.09),
        Color(red: 0.77, green: 0.29, blue: 0.55),
        Color(red: 0.78, green: 0.64, blue: 0.54),
        Color(red: 1, green: 0.5, blue: 0.31),
        Color(red: 0.75, green: 1, blue: 0),
        Color(red: 0.55, green: 0.42, blue: 0.27),
        Color(red: 0.97, green: 0.87, blue: 0.49),
        Color(red: 0.86, green: 0.23, blue: 0.21),
        Color(red: 0.44, green: 0.19, blue: 0.27),
        Color(red: 0.94, green: 0.78, blue: 0.31),
        Color(red: 0.72, green: 0.53, blue: 0.04),
        Color(red: 0.87, green: 0.45, blue: 1),
        Color(red: 0.25, green: 0, blue: 0.6),
        Color(red: 1, green: 0.8, blue: 0.6),
        Color(red: 0.5, green: 1, blue: 0.83),
        Color(red: 1, green: 1, blue: 0.6)
    ]

    static let options: [(name: String, color: Color)] = {
        let names = DemoTrackColorPaletteOptionNames.inPaletteOrder
        precondition(
            names.count == optionColorValues.count,
            "Palette names (\(names.count)) and colors (\(optionColorValues.count)) must stay aligned."
        )
        return zip(names, optionColorValues).map { ($0, $1) }
    }()

    /// First palette name whose lowercase form appears as a substring of `string` (longer names first).
    nonisolated static func colorNameMatchingStem(_ string: String) -> String? {
        let lower = string.lowercased()
        let byLength = DemoTrackColorPaletteOptionNames.inPaletteOrder.sorted { $0.count > $1.count }
        return byLength.first { name in
            lower.contains(name.lowercased())
        }
    }

    static func swiftUIColor(forName name: String) -> Color {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return options.first(where: { $0.name.lowercased() == lower })?.color ?? .gray
    }
}
