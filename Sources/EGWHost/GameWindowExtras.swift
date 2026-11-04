import AppKit
import Darwin
import Foundation
import GRPCCore
import ImageIO
import UniformTypeIdentifiers

/// Where the picture sits inside the game area: as large as fits, centered,
/// keeping the display aspect ratio (black bars elsewhere).
enum GameLayout {
    static let toolbarWidth: CGFloat = 52

    static func fit(displayWidth: Int, displayHeight: Int, in area: CGSize) -> CGRect {
        guard displayWidth > 0, displayHeight > 0, area.width > 0, area.height > 0 else { return .zero }
        let scale = min(area.width / CGFloat(displayWidth), area.height / CGFloat(displayHeight))
        let size = CGSize(width: (CGFloat(displayWidth) * scale).rounded(.down),
                          height: (CGFloat(displayHeight) * scale).rounded(.down))
        return CGRect(x: ((area.width - size.width) / 2).rounded(.down),
                      y: ((area.height - size.height) / 2).rounded(.down), width: size.width, height: size.height)
    }
}

/// Android system buttons over gRPC `sendKey` (allowed with `aud`).
/// Back/Home/Recents use the documented W3C key names; volume uses evdev codes.
enum AndroidKey: String, CaseIterable, Sendable {
    case back, home, recents, volumeUp, volumeDown

    var label: String {
        switch self {
        case .back: return "返回"
        case .home: return "主畫面"
        case .recents: return "最近使用"
        case .volumeUp: return "音量＋"
        case .volumeDown: return "音量－"
        }
    }

    /// One key press (down + up) as the Emulator expects it.
    var event: Android_Emulation_Control_KeyboardEvent {
        var event = Android_Emulation_Control_KeyboardEvent()
        event.eventType = .keypress
        switch self {
        case .back: event.key = "GoBack"
        case .home: event.key = "GoHome"
        case .recents: event.key = "AppSwitch"
        case .volumeUp: event.codeType = .evdev; event.keyCode = 115
        case .volumeDown: event.codeType = .evdev; event.keyCode = 114
        }
        return event
    }

    static func send<Transport: ClientTransport>(_ key: AndroidKey, using client: GRPCClient<Transport>, token: String) async -> Bool {
        var options = CallOptions.defaults
        options.timeout = .milliseconds(3000); options.waitForReady = false
        let controller = Android_Emulation_Control_EmulatorController.Client(wrapping: client)
        return (try? await controller.sendKey(key.event, metadata: ["authorization": "Bearer \(token)"], options: options)) != nil
    }
}

/// Screenshots of what the game window shows. Saved under the project (no
/// Pictures/Desktop access needed) as new owner-only files, and copied to
/// the Mac clipboard for pasting.
enum GameScreenshot {
    static var directory: String { RuntimeDiscovery.project + "/.runtime/screenshots" }

    static func fileName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "EGW-\(formatter.string(from: date)).png"
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Writes a new private PNG; never replaces an existing file or follows a link.
    static func save(_ image: CGImage, directory: String = directory, date: Date = Date()) -> String? {
        var info = stat()
        if lstat(directory, &info) != 0 { guard mkdir(directory, 0o700) == 0 else { return nil } }
        else { guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { return nil } }
        guard let data = pngData(image) else { return nil }
        let path = directory + "/" + fileName(at: date)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle.write(contentsOf: data); try handle.close() } catch { return nil }
        return path
    }
}
