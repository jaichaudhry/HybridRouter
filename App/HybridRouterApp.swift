import SwiftUI

@main
struct HybridRouterApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
