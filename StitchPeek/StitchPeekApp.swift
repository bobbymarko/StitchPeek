import SwiftUI

@main
struct StitchPeekApp: App {
    var body: some Scene {
        DocumentGroup(viewing: DesignDocument.self) { file in
            DocumentView(document: file.document, fileURL: file.fileURL)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}      // there is nothing to create
        }
    }
}
