import SwiftUI

@main
struct MarkerApp: App {
    @StateObject private var model = RoundViewModel()

    var body: some Scene {
        WindowGroup {
            RoundView(model: model)
        }
    }
}
