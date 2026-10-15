import SwiftUI
struct MVFont {
    static let greeting = Font.system(.largeTitle, design: .rounded).weight(.bold)
    static let title = Font.system(.title2, design: .rounded).weight(.semibold)
    static let headline = Font.system(.headline, design: .rounded)
    static let body = Font.system(.body, design: .rounded)
    static let countdown = Font.system(size: 44, weight: .bold, design: .rounded)
}
