import PodFillCore
import SwiftUI

@main
struct PodFillApp: App {
    // The CLT SDK has no SwiftUIMacros plugin, so @State is unavailable: the model is owned here instead.
    private let model = DownloadModel()

    var body: some Scene {
        Window("PodFill", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 560, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Update Downloader") { model.updateDownloader() }
                    .disabled(model.isBusy || model.needsSetup)
                Button("Run Setup Again…") { model.setUp() }
                    .disabled(model.isBusy)
            }
        }
    }
}
