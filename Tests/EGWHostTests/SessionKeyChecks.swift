import CryptoKit
import Darwin
import Foundation
@testable import EGWHost

// Foundation helpers stay separate from Testing for the installed CLT.
func verifySessionKeyContract(audiences: [String] = [SessionKey.method]) throws -> Bool {
    let key = SessionKey()
    let now = 1234567890
    let token = try key.token(now: now, audiences: audiences)
    let parts = token.split(separator: ".")
    func decode(_ value: Substring) -> Data {
        var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text)!
    }
    let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
    let header = try JSONSerialization.jsonObject(with: decode(parts[0])) as! [String: String]
    let publicObject = try JSONSerialization.jsonObject(with: key.publicSet()) as! [String: [[String: String]]]
    let jwk = publicObject["keys"]![0]
    let publicBytes = Data([4]) + decode(Substring(jwk["x"]!)) + decode(Substring(jwk["y"]!))
    let publicKey = try P256.Signing.PublicKey(x963Representation: publicBytes)
    let claims = try JSONSerialization.jsonObject(with: decode(parts[1])) as! [String: Any]
    return publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8))
        && signature.rawRepresentation.count == 64 && jwk["d"] == nil
        && jwk["kid"] == key.kid && jwk["crv"] == "P-256"
        && header["alg"] == "ES256" && header["kid"] == key.kid && header["typ"] == nil
        && claims["iss"] as? String == "gradle-utp-emulator-control"
        && claims["aud"] as? [String] == audiences
        && claims["iat"] as? Int == now - 5 && claims["exp"] as? Int == now + 120
}

func verifyExclusiveKeyFile() throws -> Bool {
    let path = NSTemporaryDirectory() + "egw-public-test-" + UUID().uuidString + ".jwk"
    let original = Data("PUBLIC_TEST".utf8)
    let file = try OwnedPublicKey(path: path, data: original)
    var duplicateRejected = false
    do { _ = try OwnedPublicKey(path: path, data: Data("OTHER".utf8)) }
    catch SessionFailure.keyExistsOrInaccessible { duplicateRejected = true }
    var info = stat()
    let permissionsOK = lstat(path, &info) == 0 && info.st_mode & 0o777 == 0o600
    let unchanged = try Data(contentsOf: URL(fileURLWithPath: path)) == original
    try file.remove() // exactly this test's one file, never a directory
    var secondRemovalRejected = false
    do { try file.remove() } catch SessionFailure.keyCleanupFailed { secondRemovalRejected = true }
    return duplicateRejected && permissionsOK && unchanged && secondRemovalRejected
}
