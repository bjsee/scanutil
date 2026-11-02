import AppKit
import ScannerKit
import SwiftUI

public struct ContentView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                previewPane
                    .frame(minWidth: 480)
                scansPane
                    .frame(minWidth: 260, idealWidth: 340)
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 900, minHeight: 560)
        .task {
            await model.connect()
        }
    }

    private var previewPane: some View {
        ZStack {
            Color.black
            if let image = model.previewImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if case .failed(let text) = model.status {
                Label(text, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.white)
                    .padding()
                    .multilineTextAlignment(.center)
            } else {
                ProgressView().controlSize(.large)
            }
            if model.status == .capturing {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Aufnahme läuft …").foregroundStyle(.white)
                }
                .padding(20)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var scansPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Letzte Scans").font(.headline).padding(12)
            Divider()
            if model.scans.isEmpty {
                Text("Noch kein Scan.\nLeertaste drückt den Auslöser.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.scans) { item in
                            ScanRow(item: item, archive: model.archiveURL)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Button {
                Task { await model.scan() }
            } label: {
                Label("Scannen", systemImage: "camera.shutter.button")
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(model.status != .ready)
            .help("Leertaste")

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText).font(.callout)
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.red)
                } else if let format = model.captureFormat {
                    Text("Aufnahme \(format.description), Schärfe 0 (Archivmodus)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Archiv im Finder zeigen") {
                NSWorkspace.shared.activateFileViewerSelecting([model.archiveURL])
            }
            .buttonStyle(.link)
        }
        .padding(10)
    }

    private var statusText: String {
        switch model.status {
        case .disconnected: "Nicht verbunden"
        case .connecting: "Verbinde …"
        case .ready: model.device.map { "Bereit: \($0.name)" } ?? "Bereit"
        case .capturing: "Aufnahme läuft"
        case .failed: "Nicht verfügbar"
        }
    }
}

private struct ScanRow: View {
    let item: ScanItem
    let archive: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let thumbnail = item.thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .border(.quaternary)
            }
            Text(item.record.storedAt.formatted(date: .abbreviated, time: .standard)).font(.caption)
            Text("\(item.record.original.width)×\(item.record.original.height), \(ByteCountFormatter.string(fromByteCount: Int64(item.record.original.bytes), countStyle: .file))")
                .font(.caption2).foregroundStyle(.secondary)
            Text("SHA-256 \(item.record.original.sha256.prefix(12))…")
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Im Finder zeigen") {
                NSWorkspace.shared.activateFileViewerSelecting([archive.appendingPathComponent(item.record.original.path)])
            }
        }
    }
}
