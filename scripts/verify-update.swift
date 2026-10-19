import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4,
      let key = Data(base64Encoded: args[1]),
      let signature = Data(base64Encoded: args[3]),
      let archive = FileManager.default.contents(atPath: args[2]),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key)
else {
    FileHandle.standardError.write(Data("usage: verify-update <public-key> <archive> <signature>\n".utf8))
    exit(2)
}
exit(publicKey.isValidSignature(signature, for: archive) ? 0 : 1)
