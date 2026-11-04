import Foundation
import InputCore

// This CLT's Testing+Foundation cross-import overlay has no Swift module.
// Keep Foundation-only serialization helpers separate, as existing tests do.
func decodeInvalidProfileFixture() throws -> MappingProfile {
    try JSONDecoder().decode(MappingProfile.self, from: Data(#"{"schema":2,"bindings":[]}"#.utf8))
}

func profileRoundTripFixture(_ profile: MappingProfile) throws -> Bool {
    try JSONDecoder().decode(MappingProfile.self, from: JSONEncoder().encode(profile)) == profile
}
