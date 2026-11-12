import AppKit
import StitchKit
import SwiftUI

/// Viewer for one Wilcom `.emb`.
///
/// An EMB's stitches live in an encrypted stream that StitchPeek never reads, so there is no
/// stitch canvas, scrubber or recolouring here: this shows the preview picture saved in the file
/// and the design facts stored beside it. DST files keep their own window (`CollectionWindow`).
struct EMBWindow: View {
    let url: URL?

    private enum Load {
        case loading
        case loaded(EMBDesign, NSImage?)
        case failed(String)
    }

    @State private var load: Load = .loading

    var body: some View {
        Group {
            switch load {
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView("Can't Read This File", systemImage: "exclamationmark.triangle", description: Text(message))
            case .loaded(let design, let image):
                EMBDetail(design: design, image: image)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .navigationTitle(url?.lastPathComponent ?? "EMB")
        .task(id: url) {
            guard let url else {
                load = .failed("No file was given.")
                return
            }
            load = .loading
            do {
                let design = try await Task.detached(priority: .userInitiated) {
                    try EMBReader.parse(contentsOf: url)
                }.value
                let picture = EMBRenderer.previewImage(for: design)
                    .map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                load = .loaded(design, picture)
            } catch {
                load = .failed(error.localizedDescription)
            }
        }
    }
}

private struct EMBDetail: View {
    let design: EMBDesign
    let image: NSImage?

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(24)
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                } else {
                    Label("No preview in this file", systemImage: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                        ForEach(Array(design.infoRows.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                Text(row.label).foregroundStyle(.secondary)
                                Text(row.value).textSelection(.enabled)
                            }
                        }
                    }

                    if !design.threads.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Threads").font(.headline)
                            ForEach(design.threads, id: \.stop) { thread in
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(Color(red: Double(thread.red) / 255, green: Double(thread.green) / 255, blue: Double(thread.blue) / 255))
                                        .overlay(Circle().strokeBorder(.separator))
                                        .frame(width: 16, height: 16)
                                    Text("\(thread.stop + 1)")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(minWidth: 18, alignment: .trailing)
                                    Text(thread.name.isEmpty ? thread.hexString : thread.name)
                                    if !thread.chart.isEmpty, thread.chart != "Default" {
                                        Text(thread.chart).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    Text(thread.hexString)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }

                    Text("The picture and facts are the preview data saved in the file. The stitches are stored in a protected part of the file that StitchPeek does not read.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 340)
        }
    }
}
