import Foundation
import CryptoKit

// Fail before publishing a feed signed with a valid but unrelated key. Never
// print secret contents, including when validation fails.
do {
    guard CommandLine.arguments.count == 3 else { throw CocoaError(.fileReadInvalidFileName) }
    let encoded = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let seed = Data(base64Encoded: encoded), seed.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])), format: nil) as? [String: Any]
    guard privateKey.publicKey.rawRepresentation.base64EncodedString() == info?["SUPublicEDKey"] as? String else { throw CocoaError(.fileReadCorruptFile) }
    print("Studio update-signing key matches the pinned public key.")
} catch {
    FileHandle.standardError.write(Data("Invalid or mismatched Studio update-signing key.\n".utf8))
    exit(1)
}
