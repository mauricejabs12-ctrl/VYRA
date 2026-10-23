import SwiftUI
import VYRACore
import VYRALlama

@main
struct VYRAKIApp: App {
    var body: some Scene {
        WindowGroup {
            Text("VYRA KI " + ((try? ModelInfo.catalog())?.first?.name ?? "")).preferredColorScheme(.dark)
        }
    }
}
