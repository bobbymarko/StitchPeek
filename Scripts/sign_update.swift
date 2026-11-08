// Ed25519 signing for StitchPeek updates.
//
//     swift Scripts/sign_update.swift generate
//     swift Scripts/sign_update.swift public-key
//     swift Scripts/sign_update.swift sign   <file>              > file.sig
//     swift Scripts/sign_update.swift verify <file> <file.sig> <public-key-base64>
//
// The app embeds the public key and refuses any downloaded update whose signature does not
// verify. The private key never enters the repository: it lives at
// ~/.config/stitchpeek/update-signing-key (mode 600). Back it up — losing it means the
// installed apps can no longer verify, and therefore never install, another update until
// someone reinstalls by hand.

import CryptoKit
import Foundation

let keyURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/stitchpeek/update-signing-key")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadPrivateKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOf: keyURL, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("no signing key at \(keyURL.path) — run `generate` first") }
    return key
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "generate":
    if FileManager.default.fileExists(atPath: keyURL.path) {
        fail("a key already exists at \(keyURL.path); refusing to overwrite it")
    }
    let key = Curve25519.Signing.PrivateKey()
    try FileManager.default.createDirectory(
        at: keyURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: keyURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "public-key":
    print(loadPrivateKey().publicKey.rawRepresentation.base64EncodedString())

case "sign":
    guard args.count == 2 else { fail("usage: sign <file>") }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])) else { fail("cannot read \(args[1])") }
    print(try loadPrivateKey().signature(for: data).base64EncodedString())

case "verify":
    guard args.count == 4 else { fail("usage: verify <file> <file.sig> <public-key-base64>") }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: args[1])),
          let sigText = try? String(contentsOf: URL(fileURLWithPath: args[2]), encoding: .utf8),
          let signature = Data(base64Encoded: sigText.trimmingCharacters(in: .whitespacesAndNewlines)),
          let rawKey = Data(base64Encoded: args[3]),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
    else { fail("unreadable input") }
    if key.isValidSignature(signature, for: data) {
        print("signature OK")
    } else {
        fail("SIGNATURE INVALID")
    }

default:
    fail("usage: sign_update.swift generate | public-key | sign <file> | verify <file> <sig> <public-key>")
}
