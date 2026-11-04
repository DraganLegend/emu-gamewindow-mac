import Testing
@testable import EGWHost

@Suite("Ephemeral session credential")
struct SessionKeyTests {
    @Test func signatureAndClaims() throws {
        #expect(try verifySessionKeyContract())
    }
    @Test func exclusiveFileOwnership() throws {
        #expect(try verifyExclusiveKeyFile())
    }
}
