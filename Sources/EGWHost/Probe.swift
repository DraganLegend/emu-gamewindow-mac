import Darwin
import Foundation

struct ProbeFailure: Error {
    let code: String
    let message: String
    let exitCode: Int32
}

enum ProbeOptions {
    static func invalid(_ message: String) -> ProbeFailure {
        ProbeFailure(code: "invalid_arguments", message: message, exitCode: 64)
    }
}

/// Entry point. Run with no arguments inside the packaged app it shows the
/// launcher; otherwise one subcommand per call (see `--help`).
@main
struct Probe {
    static func emit(_ object: [String: Any]) {
        // Only fixed keys and validated values are emitted; never raw errors.
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            FileHandle.standardError.write(Data("could not encode the result\n".utf8))
            exit(70)
        }
        print(text)
    }

    static let help = """
    usage: egw-host <command>
      status                      where the emulator is (discovery files + process table; no key, no RPC)
                                  exit 0 running / 3 stopped / 4 starting / 5 lost / 6 ambiguous
      game-view --auto --usb-off-confirmed --seconds <30...14400> [--fast-path] [--present <mode>]
                [--rotate <0|90|180|270>] [--stream-rotation-map <cw|ccw|none>] [--flip-frames] [--game-in-use]
                                  open the game window (frames over gRPC, input as touches)
      stream-spike --session <json> --seconds <5...300>   receive frames only and print fps / latency
      terminate --confirmed       send one SIGTERM to the emulator and wait up to 60 s (never SIGKILL)
      power-key --usb-off-confirmed --mode <short|long|chord>   press the Android power key
      space                       disk overview (read-only)
      clean [--include-build] [--apply --confirmed]   list, or move regenerable files to the Trash
    """

    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            switch args.first {
            case nil:
                guard Bundle.main.object(forInfoDictionaryKey: "EGWRole") as? String == LauncherModel.role else {
                    print(help); exit(64)
                }
                Launcher.show()
            case "--help":
                print(help)
            case "status":
                guard args.count == 1 else { throw ProbeOptions.invalid("status takes no arguments.") }
                let finding = RuntimeDiscovery.find()
                emit(RuntimeStatus.report(finding))
                exit(RuntimeStatus.exitCode(finding.state))
            case "game-view":
                let report = GameViewSession.execute(try GameViewOptions.parse(args))
                print(String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
                if !report.transportCompleted { exit(1) }
            case "stream-spike":
                let report = await StreamSpike.interruptible(try StreamSpikeOptions.parse(args))
                print(String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
                if !report.transportCompleted { exit(1) }
            case "terminate":
                guard args == ["terminate", "--confirmed"] else {
                    throw ProbeOptions.invalid("terminate only accepts --confirmed (one SIGTERM, never forced).")
                }
                let report = Shutdown.terminate()
                print(String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
                if !report.exited { exit(1) }
            case "power-key":
                guard args.count == 4, args[1] == "--usb-off-confirmed", args[2] == "--mode",
                      let mode = Shutdown.PowerMode(rawValue: args[3]) else {
                    throw ProbeOptions.invalid("power-key needs --usb-off-confirmed --mode <short|long|chord>.")
                }
                let report = await Shutdown.powerKey(mode: mode, usbOffConfirmed: true)
                print(String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
                if !report.completed { exit(1) }
            case "space":
                guard args.count == 1 else { throw ProbeOptions.invalid("space takes no arguments.") }
                emit(SpaceReport.report(policy: SpacePolicy.current(), plan: SpaceCleaner.plan(includeBuild: true)))
            case "clean":
                let flags = Set(args.dropFirst())
                guard flags.count == args.count - 1,
                      flags.isSubset(of: ["--include-build", "--apply", "--confirmed"]),
                      flags.contains("--apply") == flags.contains("--confirmed") else {
                    throw ProbeOptions.invalid("clean only accepts --include-build; --apply needs --confirmed.")
                }
                let root = RuntimeDiscovery.project
                let plan = SpaceCleaner.plan(root: root, includeBuild: flags.contains("--include-build"))
                var report = SpaceCleaner.report(plan, root: root)
                if flags.contains("--apply") {
                    let applied = SpaceCleaner.apply(plan)
                    report["applied"] = true; report["movedToTrash"] = applied.moved
                    report["movedBytes"] = applied.movedBytes
                    report["skipped"] = applied.skipped.map { $0.hasPrefix(root + "/") ? String($0.dropFirst(root.count + 1)) : $0 }
                } else { report["applied"] = false }
                emit(report)
            default:
                throw ProbeOptions.invalid("unknown command; see --help.")
            }
        } catch let failure as ProbeFailure {
            emit(["error": failure.code, "message": failure.message, "rpcAttempted": false])
            exit(failure.exitCode)
        } catch {
            emit(["error": "local_failure", "rpcAttempted": false])
            exit(70)
        }
    }
}
