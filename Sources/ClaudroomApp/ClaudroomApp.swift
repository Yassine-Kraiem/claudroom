import SwiftUI
import AppKit
import ClaudroomCore
import ClaudroomUI

@main
struct ClaudroomMain: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            DetailView(model: model)
        } label: {
            // The app's own mark rather than an SF Symbol — and it is live: the
            // ring is the same session figure the text reports, drawn as the
            // capacity arc the icon already used.
            Image(nsImage: MenuBarGlyph.image(for: model.label))
                .renderingMode(.original)
            Text(model.label.text)
        }
        .menuBarExtraStyle(.window)

        Window("Claudroom — Usage Activity", id: DashboardWindow.id) {
            DashboardView(model: model)
        }
        .defaultSize(width: 880, height: 640)
    }
}
