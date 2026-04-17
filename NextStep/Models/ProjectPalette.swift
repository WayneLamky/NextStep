import SwiftUI

enum ProjectPalette {
    static let colors: [Color] = [
        Color(red: 1.00, green: 0.95, blue: 0.60),
        Color(red: 1.00, green: 0.80, blue: 0.75),
        Color(red: 0.80, green: 0.95, blue: 0.85),
        Color(red: 0.80, green: 0.90, blue: 1.00),
        Color(red: 0.95, green: 0.82, blue: 1.00),
        Color(red: 1.00, green: 0.88, blue: 0.70)
    ]

    static func color(at index: Int) -> Color {
        colors[((index % colors.count) + colors.count) % colors.count]
    }

    static let count = colors.count
}
