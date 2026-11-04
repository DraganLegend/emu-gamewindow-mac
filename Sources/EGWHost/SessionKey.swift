import CryptoKit
import Darwin
import Foundation

enum SessionFailure: String, Error {
    case invalidSession, sessionChanged, keyExistsOrInaccessible, keyWriteFailed
    case keyNotLoaded, keyCleanupFailed, keyRevocationUnconfirmed, rpcValidationFailed
}

// No persistent private key, token, issuer service or credential cache.
struct SessionKey {
    static let method = "/android.emulation.control.EmulatorController/getStatus"
    let key = P256.Signing.PrivateKey()
    let kid = UUID().uuidString

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    func publicSet() throws -> Data {
        let bytes = key.publicKey.x963Representation
        return try JSONSerialization.data(withJSONObject: ["keys": [[
            "kty": "EC", "crv": "P-256", "alg": "ES256", "use": "sig", "kid": kid,
            "x": Self.base64URL(bytes.subdata(in: 1..<33)),
            "y": Self.base64URL(bytes.subdata(in: 33..<65)),
        ]]], options: [.sortedKeys])
    }

    func token(now: Int, audiences: [String] = [Self.method]) throws -> String {
        let allowed = [Self.method, "/android.emulation.control.EmulatorController/getScreenshot",
                       "/android.emulation.control.EmulatorController/sendTouch",
                       "/android.emulation.control.EmulatorController/streamScreenshot",
                       "/android.emulation.control.EmulatorController/sendKey",
                       // Write-only: the guest clipboard is never read (getClipboard/streamClipboard stay refused).
                       "/android.emulation.control.EmulatorController/setClipboard"]
        guard !audiences.isEmpty, Set(audiences).count == audiences.count,
              audiences.allSatisfy({ allowed.contains($0) }) else { throw SessionFailure.invalidSession }
        // typ is optional (RFC 7519 §5.1). The reference Emulator/Tink
        // validator neither expects nor ignores it, so omit it here.
        // This changes no signature, claims or server-side security policy.
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": kid])
        let claims = try JSONSerialization.data(withJSONObject: [
            "iss": "gradle-utp-emulator-control", "aud": audiences,
            "iat": now - 5, "exp": now + 120,
        ])
        let input = Self.base64URL(header) + "." + Self.base64URL(claims)
        let signature = try key.signature(for: Data(input.utf8)).rawRepresentation
        return input + "." + Self.base64URL(signature)
    }
}

// Own exactly one file, never a directory or an existing/replaced inode.
struct OwnedPublicKey: Sendable {
    let path: String
    let device: dev_t
    let inode: ino_t

    init(path: String, data: Data) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SessionFailure.keyExistsOrInaccessible }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw SessionFailure.keyWriteFailed }
        self.path = path
        device = info.st_dev
        inode = info.st_ino
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw SessionFailure.keyWriteFailed }
                    offset += count
                }
            }
            guard fsync(fd) == 0 else { throw SessionFailure.keyWriteFailed }
        } catch {
            try remove()
            throw error
        }
    }

    func remove() throws {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_dev == device, info.st_ino == inode,
              info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              unlink(path) == 0 else { throw SessionFailure.keyCleanupFailed }
    }
}
