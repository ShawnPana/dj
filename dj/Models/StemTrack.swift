import Foundation
import SwiftUI

struct StemTrack: Identifiable {
    let id: String  // "drums", "bass", "vocals", "other"
    let name: String
    let color: Color
    var volume: Float = 1.0
    var isMuted: Bool = false
    var isSoloed: Bool = false

    static let allStems: [StemTrack] = [
        StemTrack(id: "drums", name: "Drums", color: .red),
        StemTrack(id: "bass", name: "Bass", color: .blue),
        StemTrack(id: "vocals", name: "Vocals", color: .green),
        StemTrack(id: "other", name: "Other", color: .orange),
    ]
}
