import InputCore
import Testing
@testable import EGWHost

@Suite("Launcher decisions")
struct LauncherTests {
    @Test func buttonsFollowRuntimeState() {
        var model = LauncherModel()
        #expect(model.canStart && !model.canPlay && model.canQuit)
        model.state = .running
        #expect(!model.canStart && model.canPlay)
        model.playing = true
        #expect(!model.canPlay && !model.canQuit)
        model.playing = false; model.state = .stopped; model.starting = true
        #expect(!model.canStart && !model.canQuit)
        for state in [RuntimeDiscovery.State.starting, .lost, .ambiguous] {
            let other = LauncherModel(state: state)
            #expect(!other.canStart && !other.canPlay)
        }
    }

    @Test func playArgumentsAreFixedAndBounded() {
        #expect(LauncherModel.playArguments(minutes: 120, rotate: 90) ==
                ["game-view", "--auto", "--usb-off-confirmed", "--game-in-use", "--seconds", "7200", "--rotate", "90"])
        #expect(LauncherModel.playArguments(minutes: 45, rotate: 0) == nil)
        #expect(LauncherModel.playArguments(minutes: 60, rotate: 45) == nil)
        // The fixed arguments parse with the real game-view parser.
        for minutes in LauncherModel.minutesChoices {
            let args = LauncherModel.playArguments(minutes: minutes, rotate: 270) ?? []
            #expect((try? GameViewOptions.parse(args))?.auto == true)
        }
        #expect(LauncherModel.startArguments(script: "/p/egw", audio: true) == ["/p/egw", "start", "--audio"])
        #expect(LauncherModel.startArguments(script: "/p/egw", audio: false) == ["/p/egw", "start"])
        #expect(LauncherModel.startArguments(script: "/p/egw", audio: false, officialWindow: true) == ["/p/egw", "start", "--window"])
    }

    @Test func summariesNeverEchoRawText() {
        let good = #"{"transportCompleted":true,"contactsHeldAtEnd":0,"touchRequests":12,"touchFailures":0,"keyRevoked":true}"#
        #expect(launcherSummary(good).hasPrefix("上次遊玩：正常結束"))
        let bad = #"{"transportCompleted":false,"error":"session_changed","contactsHeldAtEnd":1}"#
        let text = launcherSummary(bad)
        #expect(text.contains("session_changed") && text.contains("殘留觸點 1"))
        let odd = #"{"transportCompleted":false,"error":"秘密"}"#
        #expect(!launcherSummary(odd).contains("秘密"))
        #expect(launcherSummary("not json") == "上次遊玩：沒有可讀的報告")
    }

    @Test func keymapText() throws {
        #expect(LauncherModel.keymapText(nil).contains("無法讀取"))
        #expect(LauncherModel.keymapText(try MappingProfile(bindings: [])).contains("尚未設定"))
        let stick = JoystickBinding(center: .init(x: 0.2, y: 0.8), radius: 0.1, up: 13, down: 1, left: 0, right: 2)
        let profile = try MappingProfile(bindings: [.init(keyCode: 14, label: "E", point: .init(x: 0.5, y: 0.5))], joystick: stick)
        #expect(LauncherModel.keymapText(profile) == "按鍵設定：E＋WASD 搖桿")
    }
}
