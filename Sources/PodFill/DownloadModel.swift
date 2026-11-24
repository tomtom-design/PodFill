import AppKit
import PodFillCore

/// The actions that need AppKit. The model itself lives in PodFillCore (DownloadModel.swift there).
extension DownloadModel {
    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = destinationURL.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { destination = url.path }
    }

    func showInFinder() {
        if newFiles.isEmpty {
            NSWorkspace.shared.open(destinationURL)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(newFiles)
        }
    }

    func addToMusic() {
        guard !newFiles.isEmpty else { return }
        let music = URL(fileURLWithPath: "/System/Applications/Music.app")
        NSWorkspace.shared.open(newFiles, withApplicationAt: music, configuration: NSWorkspace.OpenConfiguration())
    }
}
