import SwiftUI

/// Global UI scale factor. Read via `@Environment(\.uiScale)` in any view and
/// multiply into font sizes, frame dimensions, and paddings. Driven by
/// Cmd+= / Cmd+- / Cmd+0 shortcuts in ContentView. Text stays crisp because
/// views re-layout at the new size instead of bitmap-scaling.
private struct UIScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    var uiScale: Double {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}
