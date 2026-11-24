import PodFillCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: DownloadModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            setupBanner

            VStack(alignment: .leading, spacing: 6) {
                Text("Spotify links").font(.headline)
                TextEditor(text: $model.urlText)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 90)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    .disabled(model.isRunning)
                Text("Paste playlist, album or track links, one per line.").font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Save to").font(.headline)
                HStack {
                    Text(model.destination.abbreviatingHome)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    Button("Choose…") { model.chooseDestination() }.disabled(model.isRunning)
                }
            }

            HStack {
                if model.isRunning {
                    Button("Cancel", role: .cancel) { model.cancel() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Download") { model.start() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canDownload)
                }
                Button("Update downloader") { model.updateDownloader() }
                    .disabled(model.isBusy || model.needsSetup)
                if model.isUpdating { ProgressView().controlSize(.small) }
                Spacer()
            }

            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let info = model.info {
                Text(info).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            progress

            // No songs before setup; hiding the empty list keeps the banner and the log on screen at the minimum size.
            if model.needsSetup {
                Spacer(minLength: 0)
            } else {
                songList
            }

            if model.finished {
                HStack {
                    Button("Show in Finder") { model.showInFinder() }
                    Button("Add to Music") { model.addToMusic() }
                        .disabled(model.newFiles.isEmpty)
                    Spacer()
                    Text("\(model.newFiles.count) new file\(model.newFiles.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            DisclosureGroup("Log", isExpanded: $model.showLog) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.log.isEmpty ? "Nothing yet." : model.log)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(height: 140)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .onChange(of: model.log) { proxy.scrollTo("end") }
                }
            }
        }
        .padding(20)
    }

    /// First launch: PodFill downloads its own engine into ~/Library/Application Support/PodFill.
    @ViewBuilder private var setupBanner: some View {
        if model.needsSetup {
            VStack(alignment: .leading, spacing: 8) {
                Text("One-time setup").font(.headline)
                Text("PodFill first downloads its engine: spotDL, Python, ffmpeg and Deno (about 450 MB on disk, all in PodFill's own folder). It needs an internet connection and takes a few minutes.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Set up") { model.setUp() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy)
                    if model.isSettingUp {
                        Text(model.setupStep).font(.callout).lineLimit(1)
                    }
                }
                if model.isSettingUp {
                    if let percent = model.setupPercent {
                        ProgressView(value: percent, total: 100)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder private var progress: some View {
        if model.isRunning || model.finished {
            VStack(alignment: .leading, spacing: 4) {
                if model.overallTotal > 0 {
                    ProgressView(value: Double(model.overallDone), total: Double(model.overallTotal))
                    Text("\(model.overallDone) of \(model.overallTotal)").font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView().progressViewStyle(.linear)
                    Text("Reading Spotify…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var songList: some View {
        List(model.songs) { song in
            HStack {
                Image(systemName: song.status.symbol).foregroundStyle(song.status.color).frame(width: 18)
                Text(song.name).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(song.status.label).font(.caption).foregroundStyle(song.status.color).lineLimit(1)
            }
        }
        .listStyle(.inset)
        .frame(minHeight: 140)
        .overlay {
            if model.songs.isEmpty {
                Text("Songs will appear here").foregroundStyle(.tertiary)
            }
        }
    }
}

extension SongStatus {
    var label: String {
        switch self {
        case .searching: "Searching"
        case .downloading: "Downloading"
        case .tagging: "Tagging"
        case .done: "Done"
        case .alreadyHad: "Already had it"
        case .failed(let why): "Failed: \(why)"
        }
    }
    var symbol: String {
        switch self {
        case .searching: "magnifyingglass"
        case .downloading: "arrow.down.circle"
        case .tagging: "tag"
        case .done: "checkmark.circle.fill"
        case .alreadyHad: "checkmark.circle"
        case .failed: "exclamationmark.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .done: .green
        case .failed: .red
        case .alreadyHad: .secondary
        default: .accentColor
        }
    }
}

extension String {
    var abbreviatingHome: String { (self as NSString).abbreviatingWithTildeInPath }
}
