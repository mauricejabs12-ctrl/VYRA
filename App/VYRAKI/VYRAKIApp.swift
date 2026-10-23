import SwiftUI
import VYRACore
import VYRALlama

@main
struct VYRAKIApp: App {
    var body: some Scene {
        WindowGroup {
            Text("VYRA KI " + (ModelInfo.catalog().first?.name ?? "")).preferredColorScheme(.dark)
        }
    }
}
