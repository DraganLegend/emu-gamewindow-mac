import Darwin
import Foundation
import InputCore

/// One owner-only JSON file for the keymap. A missing file is an empty keymap;
/// a present file must be a private regular file with a valid profile.
enum GameKeymapStore {
    static var path: String { RuntimeDiscovery.project + "/.runtime/state/keymap.json" }

    static func load(path: String = path) throws -> MappingProfile {
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { throw SessionFailure.invalidSession }
            return try MappingProfile(bindings: [])
        }
        try StatusSession.owned(path)
        return try JSONDecoder().decode(MappingProfile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    // MARK: Named profiles (protected, never matched by egw clean)

    static var profilesDirectory: String { RuntimeDiscovery.project + "/.runtime/state/keymaps" }

    /// 1–32 characters, single line, no path separators or a leading dot.
    static func validProfileName(_ text: String) -> String? {
        let name = text.trimmingCharacters(in: .whitespaces)
        guard (1...32).contains(name.count), !name.hasPrefix("."),
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !"/\\:".unicodeScalars.contains($0) })
        else { return nil }
        return name
    }

    private static func ensureDirectory(_ directory: String) throws {
        var info = stat()
        if lstat(directory, &info) != 0 {
            guard errno == ENOENT, mkdir(directory, 0o700) == 0 else { throw SessionFailure.keyWriteFailed }
        } else {
            guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { throw SessionFailure.keyWriteFailed }
        }
    }

    static func profileNames(directory: String = profilesDirectory) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
            .filter { validProfileName($0) == $0 && (try? StatusSession.owned(directory + "/" + $0 + ".json")) != nil }
            .sorted()
    }

    static func saveProfile(_ profile: MappingProfile, name: String, directory: String = profilesDirectory) throws {
        guard let name = validProfileName(name) else { throw SessionFailure.invalidSession }
        try ensureDirectory(directory)
        try save(profile, path: directory + "/" + name + ".json")
    }

    static func loadProfile(name: String, directory: String = profilesDirectory) throws -> MappingProfile {
        guard let name = validProfileName(name) else { throw SessionFailure.invalidSession }
        let path = directory + "/" + name + ".json"
        try StatusSession.owned(path)   // must exist: a missing profile is not an empty keymap
        return try load(path: path)
    }

    /// Write a new private file next to the target, then atomically replace it.
    static func save(_ profile: MappingProfile, path: String = path) throws {
        let data = try JSONEncoder().encode(profile)
        let temporary = path + ".tmp-\(getpid())"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SessionFailure.keyWriteFailed }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        } catch {
            unlink(temporary); throw SessionFailure.keyWriteFailed
        }
        guard rename(temporary, path) == 0 else { unlink(temporary); throw SessionFailure.keyWriteFailed }
    }
}
