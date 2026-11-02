import AppKit
import Foundation
import os

let prismLog = Logger(subsystem: "com.mattfalconer.Prism", category: "live")

/// Follows Spotify and Apple Music through the notifications they broadcast, so the pipeline can
/// hold on pause (instant, no latency on resume) and drop stale audio on a skip or seek.
@Observable
final class NowPlaying {
    struct Track: Equatable {
        var id: String
        var title: String
        var artist: String
        var album: String
        var duration: Double?
        var artwork: URL?
    }

    enum Event { case paused, resumed, jumped }

    private(set) var track: Track?
    private(set) var isPlaying = false
    /// True when macOS refused to let Prism control the player (Automation permission).
    private(set) var automationDenied = false
    /// The app the notifications should come from (the tapped app). Changing it forgets the last
    /// app's track, so the header and the pause hold never show or act on another app's state.
    var bundleID: String? {
        didSet {
            guard bundleID != oldValue else { return }
            track = nil
            isPlaying = false
            position = nil
            automationDenied = false
        }
    }
    var onEvent: ((Event) -> Void)?

    private var position: Double?
    private var positionStamp = Date()
    private var observers: [NSObjectProtocol] = []
    private var artworkCache: [String: URL] = [:]

    static let spotify = "com.spotify.client"
    static let music = "com.apple.Music"

    init() {
        let center = DistributedNotificationCenter.default()
        for (name, app) in [("com.spotify.client.PlaybackStateChanged", Self.spotify), ("com.apple.Music.playerInfo", Self.music)] {
            observers.append(center.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] note in
                nonisolated(unsafe) let info = note.userInfo ?? [:]
                MainActor.assumeIsolated { self?.receive(info, from: app) }
            })
        }
    }

    var supportsTransport: Bool { bundleID == Self.spotify || bundleID == Self.music }

    private func predictedPosition(at date: Date = Date()) -> Double? {
        guard let position else { return nil }
        return isPlaying ? position + date.timeIntervalSince(positionStamp) : position
    }

    #if PROMO
    private var promoLocked = false

    func promoShow(title: String, artist: String, album: String, artwork: URL) {
        promoLocked = true
        bundleID = Self.spotify
        isPlaying = true
        track = Track(id: "promo", title: title, artist: artist, album: album, duration: nil, artwork: artwork)
    }
    #endif

    private func receive(_ info: [AnyHashable: Any], from app: String) {
        guard app == bundleID else { return }
        #if PROMO
        if promoLocked { return }
        #endif
        let state = info["Player State"] as? String ?? ""
        let nowPlaying = state == "Playing"
        let id = (info["Track ID"] as? String) ?? Self.persistentID(info["PersistentID"]) ?? (info["Name"] as? String ?? "")
        let durationMs = (info["Duration"] as? Double) ?? (info["Total Time"] as? Double)
        let previous = track
        let expected = predictedPosition()
        // Music's notifications carry no position: keep time from the start of each track instead.
        let newPosition = info["Playback Position"] as? Double
            ?? (app == Self.music ? (previous?.id == id ? expected : 0) : nil)
        let duration = previous?.duration

        if let previous, previous.id != id {
            // A new track. If the last one was nearly over it's a natural segue, and the tail still in
            // the pipeline should play out; otherwise it was a skip. Spotify announces the next track
            // when its crossfade starts (up to 12 s early), and a wrong flush cuts music while a missed
            // one only lets a few seconds of the old song finish, so only a clear skip flushes.
            let skipped = previous.duration.flatMap { duration in expected.map { $0 < duration - 15 } } ?? false
            prismLog.notice("track \(previous.title, privacy: .public) → \(info["Name"] as? String ?? "", privacy: .public): expected \(expected ?? -1) of \(previous.duration ?? -1), skipped \(skipped)")
            if skipped { onEvent?(.jumped) }
        } else if previous != nil, let newPosition, let expected, abs(newPosition - expected) > 1.5 {
            // Back to the start from the last few seconds is the same track looping (repeat one), not a seek.
            let looped = newPosition < 3 && duration.map { expected > $0 - 15 } == true
            prismLog.notice("\(looped ? "loop" : "seek", privacy: .public) \(expected) → \(newPosition)")
            if !looped { onEvent?(.jumped) }
        }

        if nowPlaying != isPlaying || previous?.id != id {
            // A player that stops at the end of a playlist or album is seconds ahead of what Prism is
            // playing: let that tail play out instead of holding it.
            let reachedEnd = !nowPlaying && previous?.id == id
                && duration.flatMap { duration in expected.map { $0 > duration - 2.5 } } == true
            if reachedEnd {
                prismLog.notice("end of \(previous?.title ?? "", privacy: .public): letting the tail play out")
            } else {
                onEvent?(nowPlaying ? .resumed : .paused)
            }
        }

        isPlaying = nowPlaying
        position = newPosition
        positionStamp = Date()
        track = Track(id: id, title: info["Name"] as? String ?? "", artist: info["Artist"] as? String ?? "",
                      album: info["Album"] as? String ?? "", duration: durationMs.map { $0 / 1000 },
                      artwork: artworkCache[id] ?? (previous?.id == id ? previous?.artwork : nil))
        if app == Self.spotify, track?.artwork == nil { fetchSpotifyArtwork(id) }
    }

    /// Spotify's public oEmbed endpoint gives the cover for a track URI without any sign-in.
    private func fetchSpotifyArtwork(_ id: String) {
        guard id.hasPrefix("spotify:track:"),
              let url = URL(string: "https://open.spotify.com/oembed?url=https://open.spotify.com/track/\(id.dropFirst(14))")
        else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let thumbnail = (json["thumbnail_url"] as? String).flatMap(URL.init(string:)) else { return }
            artworkCache[id] = thumbnail
            if track?.id == id { track?.artwork = thumbnail }
        }
    }

    /// Music's PersistentID arrives as a number; AppleScript's `persistent ID` is the same 64 bits in hex.
    private static func persistentID(_ value: Any?) -> String? {
        if let number = value as? NSNumber { return String(format: "%016llX", UInt64(bitPattern: number.int64Value)) }
        return value.map { "\($0)" }
    }

    /// AppleScript isn't safe to run on several threads at once: overlapping calls fail at random.
    private static let scripts = DispatchQueue(label: "com.mattfalconer.Prism.applescript")

    /// Runs a script against the player on the script queue; notes when Automation permission is denied.
    private func run(_ source: String, then handle: (@Sendable (NSAppleEventDescriptor) -> Void)? = nil) {
        Self.scripts.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            let denied = (error?[NSAppleScript.errorNumber] as? Int) == -1743   // errAEEventNotPermitted
            let worked = error == nil
            Task { @MainActor in
                if denied { self.automationDenied = true } else if worked { self.automationDenied = false }
            }
            if let result, error == nil { handle?(result) }
        }
    }

    /// Asks the player app to do something (needs Automation permission the first time).
    func send(_ command: String) {
        guard let bundleID, supportsTransport else { return }
        let app = bundleID == Self.spotify ? "Spotify" : "Music"
        run("tell application \"\(app)\" to \(command)")
    }

    /// Asks the player for its state (used when Prism starts mid-song).
    func refresh() {
        guard let bundleID, supportsTransport,
              NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty == false else { return }
        let app = bundleID == Self.spotify ? "Spotify" : "Music"
        let script = """
        tell application "\(app)"
            set t to current track
            return {(player state as string), (name of t), (artist of t), (album of t), (\(app == "Music" ? "persistent ID" : "id") of t as string), (player position), (duration of t)}
        end tell
        """
        run(script) { result in
            guard result.numberOfItems == 7 else { return }
            let values = (1...7).map { result.atIndex($0)?.stringValue ?? "" }
            Task { @MainActor in
                let state = values[0].lowercased().contains("playing") ? "Playing" : "Paused"
                var duration = Double(values[6]) ?? 0
                if app == "Music" { duration *= 1000 }
                self.receive(["Player State": state, "Name": values[1], "Artist": values[2], "Album": values[3],
                              "Track ID": values[4], "Playback Position": Double(values[5]) ?? 0, "Duration": duration],
                             from: bundleID)
            }
        }
    }
}
