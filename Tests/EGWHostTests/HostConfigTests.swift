import Testing
@testable import EGWHost

@Suite("Machine-specific config")
struct HostConfigTests {
    @Test func absentFileUsesDefaults() {
        #expect(hostConfigFixture(nil) == .init(config: .defaults, problem: nil))
        #expect(HostConfig.defaults.invalidReason == nil)
    }

    @Test func fileOverridesOnlyGivenKeys() throws {
        let loaded = try #require(hostConfigFixture(#"{"avd": "my_avd", "consolePort": 5562}"#))
        #expect(loaded.problem == nil)
        #expect(loaded.config.avd == "my_avd" && loaded.config.consolePort == 5562)
        #expect(loaded.config.grpcPort == HostConfig.defaults.grpcPort)
        #expect(loaded.config.appName == HostConfig.defaults.appName)
    }

    @Test func unsafeOrInvalidFilesAreIgnored() {
        #expect(hostConfigFixture(#"{"avd": "a"}"#, mode: 0o666)?.problem == "unsafe_file")
        #expect(hostConfigFixture("not json")?.problem == "unreadable")
        #expect(hostConfigFixture(#"{"avd": "../x"}"#)?.problem == "invalid_avd")
        #expect(hostConfigFixture(#"{"avd": "a b"}"#)?.problem == "invalid_avd")
        #expect(hostConfigFixture(#"{"grpcPort": 80}"#)?.problem == "invalid_grpcPort")
        #expect(hostConfigFixture(#"{"consolePort": 5555}"#)?.problem == "invalid_consolePort")
        #expect(hostConfigFixture(#"{"grpcPort": 5555, "consolePort": 5554}"#)?.problem == "invalid_grpcPort")
        #expect(hostConfigFixture(#"{"bundleIdentifier": "nodots"}"#)?.problem == "invalid_bundleIdentifier")
        #expect(hostConfigFixture(#"{"appName": "a/b"}"#)?.problem == "invalid_appName")
        #expect(hostConfigFixture(#"{"appName": ""}"#)?.problem == "invalid_appName")
        // An ignored file never leaks partial values.
        #expect(hostConfigFixture(#"{"avd": "ok_avd", "grpcPort": 1}"#)?.config == .defaults)
    }

    @Test func projectResolutionOrder() {
        let projects: Set<String> = ["/env", "/plist", "/a/repo"]
        let check: (String) -> Bool = { projects.contains($0) }
        func resolve(_ env: String?, _ plist: String?, _ exe: String?, _ cwd: String?) -> String {
            HostPaths.resolveProject(environment: env, bundleRoot: plist, executable: exe, workingDirectory: cwd, check: check)
        }
        #expect(resolve("/env", "/plist", "/a/repo/.build/x/egw-host", nil) == "/env")
        #expect(resolve("relative", "/plist", nil, nil) == "/plist")
        #expect(resolve("/missing", nil, "/a/repo/.build/arm64-apple-macosx/debug/egw-host", nil) == "/a/repo")
        #expect(resolve(nil, nil, "/Applications/EmuGameWindow.app/Contents/MacOS/egw-host", "/a/repo/docs") == "/a/repo")
        #expect(resolve(nil, nil, "/Applications/EmuGameWindow.app/Contents/MacOS/egw-host", "/tmp") == "")
    }

    @Test func thisCheckoutResolvesWithItsConfig() {
        // The test binary lives under this project, so the walk-up finds it.
        #expect(!HostPaths.project.isEmpty && HostPaths.looksLikeProject(HostPaths.project))
        #expect(HostPaths.loaded.problem == nil)
        #expect(RuntimeDiscovery.avd == HostPaths.config.avd && RuntimeDiscovery.grpcPort == HostPaths.config.grpcPort)
    }
}
