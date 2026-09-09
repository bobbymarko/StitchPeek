import StitchKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Declared in the host app's Info.plist under `UTExportedTypeDeclarations`.
    static let tajimaDST = UTType(exportedAs: "com.bobbymarko.stitchpeek.tajima-dst")

    /// Embrilliance's identifier for the same format, imported in the host app's Info.plist.
    /// On a machine where Embrilliance is installed, this is the type a .dst actually
    /// resolves to, so the document has to accept it or Open With will not work.
    static let embrillianceDST = UTType(importedAs: "com.britonleap.dst")
}

/// A read-only DST document.
///
/// StitchPeek never writes DST, so `writableContentTypes` is empty and the write path
/// refuses. `DocumentGroup(viewing:)` gives us Open, Open Recent, and double-click-to-open
/// for free once the type is declared.
struct DesignDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.tajimaDST, .embrillianceDST] }
    static var writableContentTypes: [UTType] { [] }

    let design: Design
    let filename: String?

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.design = try DSTParser.parse(data: data)
        self.filename = configuration.file.filename
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.fileWriteNoPermission)
    }
}
