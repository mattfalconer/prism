import AppKit
import CoreAudio

/// Something Prism can listen to.
struct AudioSource: Identifiable, Hashable {
    let id: String
    let name: String
    let target: TapTarget
    /// The app whose icon and notifications represent this source.
    let bundleID: String?

    static let spotify = AudioSource(id: NowPlaying.spotify, name: "Spotify", target: .apps([NowPlaying.spotify]),
                                     bundleID: NowPlaying.spotify)
    static let system = AudioSource(id: "system", name: "All Mac Audio", target: .system, bundleID: nil)

    static func app(bundleID: String, name: String) -> AudioSource {
        // Safari and other WebKit apps play through the shared WebKit GPU process.
        if bundleID == "com.apple.Safari" {
            return AudioSource(id: bundleID, name: name, target: .apps(["com.apple.WebKit.GPU"]), bundleID: bundleID)
        }
        return AudioSource(id: bundleID, name: name, target: .apps([bundleID]), bundleID: bundleID)
    }

    var icon: NSImage? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Music apps worth offering even when they're quiet, plus whatever is making sound right now.
    static func available() -> [AudioSource] {
        let known = [("com.spotify.client", "Spotify"), ("com.apple.Music", "Music"), ("com.apple.Safari", "Safari"),
                     ("com.google.Chrome", "Chrome"), ("company.thebrowser.Browser", "Arc"), ("com.tidal.desktop", "TIDAL"),
                     ("com.deezer.deezer-desktop", "Deezer"), ("com.amazon.music", "Amazon Music")]
        var sources: [AudioSource] = []
        var seen = Set<String>()
        for (id, name) in known where NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil {
            sources.append(.app(bundleID: id, name: name))
            seen.insert(id)
        }
        for process in AudioObjects.processes where AudioObjects.isRunningOutput(process) {
            let pid = AudioObjects.pid(ofProcess: process)
            guard pid != getpid(), let app = NSRunningApplication(processIdentifier: pid),
                  let id = app.bundleIdentifier, !seen.contains(id), app.activationPolicy == .regular else { continue }
            sources.append(.app(bundleID: id, name: app.localizedName ?? id))
            seen.insert(id)
        }
        return sources
    }
}
