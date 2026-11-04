import Foundation
@testable import EGWHost

// Keep Foundation encoding separate from Testing. The installed CLT omits the
// _Testing_Foundation cross-import module; no Testing/Foundation helpers needed.
func encodeOutcome(_ outcome: StatusOutcome) throws -> String {
    String(decoding: try JSONEncoder().encode(outcome), as: UTF8.self)
}
