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
    /// The app the notifications should come from (the tapped app).
    var bundleID: String?
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
        let id = (info["Track ID"] as? String) ?? (info["PersistentID"].map { "\($0)" }) ?? (info["Name"] as? String ?? "")
        let durationMs = (info["Duration"] as? Double) ?? (info["Total Time"] as? Double)
        let newPosition = info["Playback Position"] as? Double
        let previous = track
        let expected = predictedPosition()

        if let previous, previous.id != id {
            // A new track. If the last one was nearly over it's a natural segue, and the tail still in
            // the pipeline should play out; otherwise it was a skip. Spotify announces the next track
            // when its crossfade starts (up to 12 s early), and a wrong flush cuts music while a missed
            // one only lets a few seconds of the old song finish, so only a clear skip flushes.
            let skipped = previous.duration.flatMap { duration in expected.map { $0 < duration - 15 } } ?? false
            prismLog.notice("track \(previous.title, privacy: .public) → \(info["Name"] as? String ?? "", privacy: .public): expected \(expected ?? -1) of \(previous.duration ?? -1), skipped \(skipped)")
            if skipped { onEvent?(.jumped) }
        } else if previous != nil, let newPosition, let expected, abs(newPosition - expected) > 1.5 {
            prismLog.notice("seek \(expected) → \(newPosition)")
            onEvent?(.jumped)
        }

        if nowPlaying != isPlaying || previous?.id != id {
            onEvent?(nowPlaying ? .resumed : .paused)
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

    /// Asks the player app to do something (needs Automation permission the first time).
    func send(_ command: String) {
        guard let bundleID, supportsTransport else { return }
        let app = bundleID == Self.spotify ? "Spotify" : "Music"
        Task.detached {
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"\(app)\" to \(command)")?.executeAndReturnError(&error)
        }
    }

    /// Asks the player for its state (used when Prism starts mid-song).
    func refresh() {
        guard let bundleID, supportsTransport,
              NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty == false else { return }
        let app = bundleID == Self.spotify ? "Spotify" : "Music"
        let script = """
        tell application "\(app)"
            set t to current track
            return {(player state as string), (name of t), (artist of t), (album of t), (id of t as string), (player position), (duration of t)}
        end tell
        """
        Task.detached {
            var error: NSDictionary?
            guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error), result.numberOfItems == 7 else { return }
            let values = (1...7).map { result.atIndex($0)?.stringValue ?? "" }
            await MainActor.run {
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
