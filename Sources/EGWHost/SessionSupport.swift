import Darwin
import Foundation

/// The Emulator's active JWK set must be empty except for keys this app adds
/// for one session (and removes again). Anything else means another client
/// is using the instance, so the session stops.
enum KeyStore {
    static func validate(_ config: SessionConfig, expected: Data? = nil) throws -> Data {
        try StatusSession.owned(config.active)
        let data = try Data(contentsOf: URL(fileURLWithPath: config.active))
        let object = try JSONSerialization.jsonObject(with: data)
        guard let keys = (object as? [String: Any])?["keys"] as? [[String: Any]], keys.isEmpty,
              !FileManager.default.fileExists(atPath: config.jwks + "/egw-status.jwk") else {
            throw SessionFailure.sessionChanged
        }
        if let expected, expected != data { throw SessionFailure.sessionChanged }
        return data
    }
}

/// Milliseconds from a clock that also advances while the Mac sleeps, so a
/// hold or a token never gains extra time across sleep.
enum HostMonotonicClock {
    private static let nanosPerTick: Double = {
        var info = mach_timebase_info_data_t()
        precondition(mach_timebase_info(&info) == KERN_SUCCESS && info.numer != 0 && info.denom != 0)
        return Double(info.numer) / Double(info.denom)
    }()
    static func milliseconds() -> Int64 {
        let value = Double(mach_continuous_time()) * nanosPerTick / 1_000_000
        return value < Double(Int64.max) ? Int64(value) : Int64.max
    }
}

/// One touch contact as sent to `sendTouch`.
struct TouchContact: Codable, Sendable, Equatable {
    let id: Int32
    let x: Int32
    let y: Int32
    let pressure: Int32

    var release: Self { .init(id: id, x: x, y: y, pressure: 0) }
}
