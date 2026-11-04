import Foundation

/// Where this app keeps its own state (`<project>/.runtime/state`): keymaps,
/// play reports, the shared frame mapping.
enum HostStorage {
    static var project: String { RuntimeDiscovery.project }
    static var build: String { project + "/.runtime/state" }
}
