//
//  CassetteSyncAPI.swift
//  AmperfyKit
//
//  Cassette fork — Layer 3 Phase 3.1 (Transfer Mechanism).
//
//  Thin client for cassette.digital's /api/sync/* endpoints, authenticated
//  with the bearer token persisted at login (Settings.cassetteBearerToken).
//  Used by IntentExecutor (polling / state transitions) and
//  CassetteTransferSession (inventory reporting).
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import Foundation
import os.log
import UIKit

// MARK: - CassetteSyncError

public enum CassetteSyncError: Error {
  case notAuthenticated
  case unsupportedBackend
  case badURL
  case http(Int)
  case invalidResponse
}

extension Notification.Name {
  /// Posted when a sync request gets a 401 — the bearer token was revoked
  /// (e.g. the device was removed from the account on the dashboard) or
  /// expired. The app shows a one-per-launch "reconnect?" alert that runs
  /// the re-link flow instead of silently dying.
  public static let cassetteTokenRejected = Notification.Name("CassetteTokenRejected")

  /// Posted (main thread) when `CassetteSyncStatus.isActive` flips — a library
  /// sync wave started or finished. The Home screen swaps its "Syncing your
  /// library" banner in over the Resume card while it is true.
  public static let cassetteSyncActiveChanged = Notification.Name("CassetteSyncActiveChanged")

  /// Posted (main thread) when a fresh /api/sync/account pull changes the account
  /// avatar (the chosen preset/emoji or the photo URL) — set on another device.
  /// The nav-bar account chip re-renders in place, so a change made on desktop
  /// shows up here without a relaunch or a navigation.
  public static let cassetteAccountAvatarChanged = Notification.Name("CassetteAccountAvatarChanged")
}

/// cassette: the one place the app asks "is a library sync wave moving right now?"
///
/// A wave = the phone still has owned tracks to pull. The intent executor is the
/// authority: a poll that enqueues downloads, or leaves any intent `syncing`
/// (downloads in flight), is active; a poll where everything it covers is already
/// on disk is idle. This deliberately does NOT track the 30s poll itself — that
/// would blink the banner on every quiet check. Counts (albums/tracks) are a
/// follow-up; today this is just the on/off the banner needs.
@MainActor
public enum CassetteSyncStatus {
  public private(set) static var isActive = false

  /// Called at the end of each intent pass with whether real sync work remains.
  /// Posts `.cassetteSyncActiveChanged` only on a real transition, so observers
  /// don't churn on every poll.
  public static func setActive(_ active: Bool) {
    guard active != isActive else { return }
    isActive = active
    NotificationCenter.default.post(name: .cassetteSyncActiveChanged, object: nil)
  }
}

// MARK: - CassetteSyncIntent

public struct CassetteSyncIntent: Sendable, Decodable {
  public let id: String
  public let scope: String
  public let targetId: String
  public let state: String
  public let intentKind: String
  /// Which device this intent is for. The server stamps every intent with a
  /// device (explicit or resolved-primary); nil only on legacy rows from the
  /// single-device era.
  public let targetDeviceId: String?

  enum CodingKeys: String, CodingKey {
    case id
    case scope
    case targetId = "target_id"
    case state
    case intentKind = "intent_kind"
    case targetDeviceId = "target_device_id"
  }
}

// MARK: - CassetteSyncTrack

public struct CassetteSyncTrack: Sendable, Decodable {
  public let subsonicTrackId: String
  public let cassetteLocalId: String
  public let mbid: String?
  public let title: String?
  public let duration: Int?
  public let fileExtension: String

  enum CodingKeys: String, CodingKey {
    case subsonicTrackId = "subsonic_track_id"
    case cassetteLocalId = "cassette_local_id"
    case mbid
    case title
    case duration
    case fileExtension = "file_extension"
  }
}

// MARK: - CassetteSyncAlbumCover

/// Album-level cover bundled into the tracks response so the phone can
/// materialize the album art locally — no display-time getCoverArt fetch.
/// `url` is the full original (faithful: full image, square, no crop);
/// `thumbUrl` is an edge-resized grid size. Null when the album has no
/// resolved catalog cover (the phone then falls back to its lazy fetch).
public struct CassetteSyncAlbumCover: Sendable, Decodable {
  public let url: String
  public let thumbUrl: String?

  enum CodingKeys: String, CodingKey {
    case url
    case thumbUrl = "thumb_url"
  }
}

// MARK: - CassetteSyncArtist

/// The album artist's catalog image, bundled into the tracks response so the
/// phone materializes the artist's artwork locally too (matching the web).
/// `imageUrl` is the full original; `thumbUrl` is edge-resized. Null when the
/// artist has no catalog image.
public struct CassetteSyncArtist: Sendable, Decodable {
  public let imageUrl: String
  public let thumbUrl: String?

  enum CodingKeys: String, CodingKey {
    case imageUrl = "image_url"
    case thumbUrl = "thumb_url"
  }
}

// MARK: - CassetteIntentTracksResponse

/// The `/intents/:id/tracks` envelope: the resolvable track list plus the
/// album's bundled cover + artist image (Fast Album Art).
public struct CassetteIntentTracksResponse: Sendable, Decodable {
  public let tracks: [CassetteSyncTrack]
  public let cover: CassetteSyncAlbumCover?
  public let artist: CassetteSyncArtist?
}

// MARK: - CassetteDeviceArtworkAlbum

/// One owned album in the artwork backfill manifest: the album artist's
/// catalog image and the album's catalog cover, keyed by (artistName,
/// albumName) so the phone can match it to a local album. All four image
/// fields are nullable — only an already-stored catalog image is returned.
///
/// `contentVersion` is a short, deterministic hash of the four artwork URLs:
/// same URLs ⇒ same version, any change ⇒ a new version. The phone records the
/// last-applied version per album and refreshes the artwork on-device when it
/// changes (content reconciliation increment 2) — not just when it's missing.
public struct CassetteDeviceArtworkAlbum: Sendable, Decodable {
  public let artistName: String
  public let albumName: String
  public let artistImageUrl: String?
  public let artistThumbUrl: String?
  public let coverUrl: String?
  public let coverThumbUrl: String?
  /// True when cover_url is the user's OWN chosen cover (an override), not our
  /// catalog. The phone adopts the cover onto the local library only when this is
  /// true. Optional so an older server response (without the field) still decodes.
  public let coverIsOverride: Bool?
  /// Fingerprint of the LAN folder cover's bytes on the paired Mac. Non-nil ONLY
  /// when the album has no user pick — the server nulls it whenever coverIsOverride
  /// is true — so acting on it can never take a pick back. Optional so a response
  /// from an older server still decodes.
  public let localCoverVersion: String?
  public let contentVersion: String

  enum CodingKeys: String, CodingKey {
    case artistName = "artist_name"
    case albumName = "album_name"
    case artistImageUrl = "artist_image_url"
    case artistThumbUrl = "artist_thumb_url"
    case coverUrl = "cover_url"
    case coverThumbUrl = "cover_thumb_url"
    case coverIsOverride = "cover_is_override"
    case localCoverVersion = "local_cover_version"
    case contentVersion = "content_version"
  }
}

// MARK: - CassetteDeviceArtworkResponse

/// The `/devices/:device_id/artwork` envelope: the artwork backfill manifest
/// for every album the device owns (read-only — heals already-synced albums).
public struct CassetteDeviceArtworkResponse: Sendable, Decodable {
  public let albums: [CassetteDeviceArtworkAlbum]
}

// MARK: - CassetteTrackFreshnessEntry

/// One owned track in the content-freshness sweep manifest: the audio
/// sibling of CassetteDeviceArtworkAlbum. Keyed by cassetteLocalId (the
/// same identity DeviceOwnershipMO stores), with subsonicTrackId carried
/// too since some lookups key on it instead.
///
/// `audioVersion` is a content fingerprint of the track's own file on the
/// paired Mac. nil means UNKNOWN (the hub hasn't successfully hashed this
/// file yet) — never treat nil as "changed". A device that has never
/// recorded a fingerprint for this track ADOPTS whatever value arrives
/// here on first sight rather than re-fetching (the file it already has
/// IS current; there's nothing to correct). Only a stored, non-nil value
/// that differs from this one means the bytes actually changed — e.g. a
/// re-rip that fixed an audio-quality issue without changing the title or
/// duration, which cassetteLocalId can't see by design.
public struct CassetteTrackFreshnessEntry: Sendable, Decodable {
  public let cassetteLocalId: String
  public let subsonicTrackId: String
  public let audioVersion: String?

  enum CodingKeys: String, CodingKey {
    case cassetteLocalId = "cassette_local_id"
    case subsonicTrackId = "subsonic_track_id"
    case audioVersion = "audio_version"
  }
}

// MARK: - CassetteTrackFreshnessResponse

/// The `/devices/:device_id/track-freshness` envelope: the content-freshness
/// sweep manifest for every track the device owns.
public struct CassetteTrackFreshnessResponse: Sendable, Decodable {
  public let tracks: [CassetteTrackFreshnessEntry]
}

// MARK: - CassetteDeviceGroupingItem

/// One owned track's catalog-blind album grouping, returned additively on the
/// `/api/sync/device-inventory` response. `groupKey` is the web's
/// buildAlbumGroupKey for the track's album bucket — the device keys its AlbumMO
/// by it so its albums match the web. `displayAlbum`/`displayArtist` are the
/// web's canonical card labels; `albumArtRef` is the catalog cover URL (or nil →
/// fall back to the local cover proxy keyed by subsonicTrackId).
public struct CassetteDeviceGroupingItem: Sendable, Decodable {
  public let cassetteLocalId: String?
  public let subsonicTrackId: String
  public let groupKey: String
  public let displayAlbum: String
  public let displayArtist: String
  /// The artist's NORMALIZED cloud identity key (the web's artist_group_key —
  /// `inherited-artist:<name>` / `catalog-artist:<id>`). The device keys its
  /// ArtistMO by it so an artist's IDENTITY matches the web while its NAME stays
  /// the library-stylized display. Optional so an older cloud response (before the
  /// field) still decodes → the regroup falls back to today's synthetic id.
  public let artistGroupKey: String?
  public let albumArtRef: String?
  /// The track's own title + duration (additive). Present once the cloud deploy
  /// includes them; lets the device materialize a SongMO for an owned track it
  /// never library-synced (AlbumRegrouper), so "owned" always equals "visible".
  /// Optional so an older cloud response still decodes.
  public let trackTitle: String?
  public let duration: Int?
  /// The track's 1-based position on its disc, so a materialized SongMO sorts in
  /// album order. Optional/nullable (only ripped-and-linked tracks carry it).
  public let discTrackIndex: Int?
  /// Album release year from the cloud (override ?? catalog), same source as
  /// the web rail. Optional so older deploys still decode; nil means leave the
  /// local Subsonic year alone.
  public let year: Int?

  enum CodingKeys: String, CodingKey {
    case cassetteLocalId = "cassette_local_id"
    case subsonicTrackId = "subsonic_track_id"
    case groupKey = "group_key"
    case displayAlbum = "display_album"
    case displayArtist = "display_artist"
    case artistGroupKey = "artist_group_key"
    case albumArtRef = "album_art_ref"
    case trackTitle = "track_title"
    case duration
    case discTrackIndex = "disc_track_index"
    case year
  }
}

// MARK: - CassetteDeviceInventoryResponse

/// The `/api/sync/device-inventory` response envelope. Both fields are optional
/// on the wire (older deploys omit them) so this decodes cleanly to an empty
/// grouping rather than throwing.
public struct CassetteDeviceInventoryResponse: Sendable, Decodable {
  public let grouping: [CassetteDeviceGroupingItem]
  public let groupingModelVersion: Int

  enum CodingKeys: String, CodingKey {
    case grouping
    case groupingModelVersion = "grouping_model_version"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.grouping = try c
      .decodeIfPresent([CassetteDeviceGroupingItem].self, forKey: .grouping) ?? []
    self.groupingModelVersion = try c.decodeIfPresent(Int.self, forKey: .groupingModelVersion) ?? 0
  }
}

// MARK: - CassetteAccount

/// The authenticated caller's OWN account identity from `/api/sync/account`.
/// `name` is the (nullable) Cassette display name; `email` is the account
/// email the user signs in with. The account menu prefers `name`, falls back
/// to `email`, so the status row shows the user's ACCOUNT — not the paired
/// Player's LAN hostname.
public struct CassetteAccount: Sendable, Decodable {
  public let email: String
  public let name: String?
  /// Profile photo URL when set; null falls back to avatarPreset. Optional
  /// decode so older deploys keep the silhouette glyph.
  public let image: String?
  /// Default disc when image is null: silhouette | initials | color id.
  /// Optional decode → "silhouette" (the existing person glyph).
  public let avatarPreset: String
  /// Cassette §C: account-sourced Server Mode (browse/stream filter). Optional
  /// decode so a server that doesn't yet emit the field — or an older deploy —
  /// decodes cleanly as `false` (on-device-only) instead of failing.
  public let serverMode: Bool
  /// The paired Cassette Player's sidecar HTTP port (default 5173), distinct from
  /// the Navidrome LAN port (loginCredentials.serverUrl). The phone reaches the
  /// sidecar at `http://<lanHost>:<sidecarPort>` for on-demand scan-first
  /// convergence (pull-to-refresh → POST /api/library/converge). Optional decode:
  /// null when no player is paired or an older sidecar/deploy doesn't emit it.
  public let sidecarPort: Int?

  /// Cassette Phase 2b: account-sourced download quality tier ("lossless" |
  /// "high" | "efficient") the phone applies to the music it downloads. Optional
  /// decode → "high" for older deploys that don't emit it.
  public let downloadQuality: String

  /// Cassette Diagnostics: account-level consent that gates AUTO diagnostic
  /// reports (crash / hang / unhandled_error). Rides the same cross-device rail
  /// as themeId/iconId — the web/dashboard owns it, the phone mirrors it. OPT-OUT:
  /// optional decode → true for older deploys / anonymous, so uploads stay
  /// always-on out of the box. Manual `user_feedback` is unaffected by this.
  public let diagnosticsConsent: Bool

  enum CodingKeys: String, CodingKey {
    case email, name, image, avatarPreset, serverMode, sidecarPort, downloadQuality,
      diagnosticsConsent
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.email = try c.decode(String.self, forKey: .email)
    self.name = try c.decodeIfPresent(String.self, forKey: .name)
    self.image = try c.decodeIfPresent(String.self, forKey: .image)
    self.avatarPreset = try c.decodeIfPresent(String.self, forKey: .avatarPreset) ?? "silhouette"
    self.serverMode = try c.decodeIfPresent(Bool.self, forKey: .serverMode) ?? false
    self.sidecarPort = try c.decodeIfPresent(Int.self, forKey: .sidecarPort)
    self.downloadQuality = try c.decodeIfPresent(String.self, forKey: .downloadQuality) ?? "high"
    self.diagnosticsConsent = try c
      .decodeIfPresent(Bool.self, forKey: .diagnosticsConsent) ?? true
  }
}

// MARK: - CassetteSyncAPI

public final class CassetteSyncAPI: @unchecked Sendable {
  public static let shared = CassetteSyncAPI()

  private static let apiBase = "https://cassette.digital"
  private let log = OSLog(subsystem: "Amperfy", category: "CassetteSyncAPI")

  // Ephemeral session with the auth-preserving delegate so the bearer
  // header survives any Vercel redirect (URLSession.shared drops it).
  private lazy var session: URLSession = .init(
    configuration: .ephemeral,
    delegate: CassetteAuthPreservingDelegate(),
    delegateQueue: nil
  )

  public init() {}

  // MARK: Token

  /// The bearer token persisted at login. Read straight from UserDefaults so
  /// this is safe to call off the main actor.
  public static var bearerToken: String? {
    UserDefaults.standard
      .string(forKey: PersistentStorage.UserDefaultsKey.CassetteBearerToken.rawValue)
  }

  // MARK: Account identity (account-menu status line)

  /// The caller's Cassette ACCOUNT identity, cached from `/api/sync/account`.
  /// Persisted to UserDefaults (raw keys, mirroring `lastSyncAt`) so the
  /// account menu reads it synchronously, off the main actor, surviving
  /// relaunch and offline opens. `nil` until the first successful fetch.
  nonisolated private static let accountNameKey = "cassette.accountName"
  nonisolated private static let accountEmailKey = "cassette.accountEmail"
  nonisolated private static let accountImageKey = "cassette.accountImage"
  nonisolated private static let accountAvatarPresetKey = "cassette.accountAvatarPreset"
  nonisolated private static let sidecarPortKey = "cassette.sidecarPort"
  /// Cassette Phase 2b: last-known account-sourced download quality tier, read by
  /// the download URL builder so it honors the web-set quality synchronously.
  nonisolated static let downloadQualityKey = "cassette.downloadQuality"

  /// The paired Player's sidecar HTTP port, cached from `/api/sync/account`.
  /// `nil`/0 when unknown (no player paired, or a sidecar/deploy that predates
  /// the field) — callers must treat nil as "on-demand convergence unavailable"
  /// and fall back to lazy convergence (watcher + heartbeat).
  public static var sidecarPort: Int? {
    let value = UserDefaults.standard.integer(forKey: sidecarPortKey)
    return value > 0 ? value : nil
  }

  public static var accountName: String? {
    let value = UserDefaults.standard.string(forKey: accountNameKey)
    return (value?.isEmpty == false) ? value : nil
  }

  public static var accountEmail: String? {
    let value = UserDefaults.standard.string(forKey: accountEmailKey)
    return (value?.isEmpty == false) ? value : nil
  }

  /// Profile photo URL from `/api/sync/account`, cached for the nav chip.
  public static var accountImage: String? {
    let value = UserDefaults.standard.string(forKey: accountImageKey)
    return (value?.isEmpty == false) ? value : nil
  }

  /// Default disc id when there is no photo (`silhouette` when unset).
  public static var accountAvatarPreset: String {
    UserDefaults.standard.string(forKey: accountAvatarPresetKey) ?? "silhouette"
  }

  /// Store the fetched account so the menu can render it without a network
  /// round-trip. A `nil`/empty name clears the stored name (so a later
  /// name removal upstream doesn't leave a stale label).
  nonisolated static func persistAccount(_ account: CassetteAccount) {
    let defaults = UserDefaults.standard
    // Snapshot the avatar-affecting fields BEFORE we overwrite them, so a change
    // pulled from another device can repaint the account chip in place.
    let previousAvatarPreset = defaults.string(forKey: accountAvatarPresetKey)
    let previousImage = defaults.string(forKey: accountImageKey)
    defaults.set(account.email, forKey: accountEmailKey)
    if let name = account.name, !name.isEmpty {
      defaults.set(name, forKey: accountNameKey)
    } else {
      defaults.removeObject(forKey: accountNameKey)
    }
    if let image = account.image, !image.isEmpty {
      defaults.set(image, forKey: accountImageKey)
    } else {
      defaults.removeObject(forKey: accountImageKey)
    }
    defaults.set(account.avatarPreset, forKey: accountAvatarPresetKey)

    // Avatar changed on another device → repaint the account chip in place (the
    // preset/emoji or the photo URL moved). Same "detect change, post, refresh
    // without a relaunch" pattern Server Mode uses below.
    let newImage = (account.image?.isEmpty == false) ? account.image : nil
    if previousAvatarPreset != account.avatarPreset || previousImage != newImage {
      DispatchQueue.main.async {
        NotificationCenter.default.post(name: .cassetteAccountAvatarChanged, object: nil)
      }
    }

    // Persist the paired Player's sidecar port so the pull-to-refresh path can
    // reach the sidecar synchronously, off the main actor. 0 clears it (no
    // player / older sidecar) so a stale port can't linger after unpair.
    defaults.set(account.sidecarPort ?? 0, forKey: sidecarPortKey)

    // Cassette §C: persist the account-sourced Server Mode so the library filter
    // reads it synchronously (immediately on launch/offline). The server value
    // is authoritative — no phone-side toggle, no local override. If it changed
    // since the last fetch, post filterChangedNotification so library views
    // re-filter without a relaunch.
    let serverModeKey = CassetteLibraryFilterProvider.serverModeDefaultsKey
    let previousServerMode = defaults.bool(forKey: serverModeKey)
    defaults.set(account.serverMode, forKey: serverModeKey)
    if previousServerMode != account.serverMode {
      DispatchQueue.main.async {
        NotificationCenter.default.post(
          name: CassetteLibraryFilterProvider.filterChangedNotification,
          object: nil
        )
      }
    }

    // Cassette Phase 2b: persist the account-sourced download quality so the
    // download URL builder honors it synchronously (web-authoritative — the
    // Devices page owns this; the phone reads it here).
    defaults.set(account.downloadQuality, forKey: downloadQualityKey)

    // Cassette Diagnostics: mirror the account-level diagnostics consent onto the
    // device (same cross-device rail as theme/icon). This gates AUTO reports only;
    // the effective gate is (local toggle AND this synced consent). Manual
    // user_feedback is never gated. Web/dashboard is authoritative.
    DiagnosticsConfig.syncedConsent = account.diagnosticsConsent
  }

  // MARK: Device identity

  /// Stable per-vendor device id — the key the whole sync layer (inventory,
  /// intents, and now the user_devices registry) uses for this phone.
  public static var deviceId: String {
    UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
  }

  /// Human label ("Michael's iPhone").
  public static var deviceLabel: String {
    UIDevice.current.name
  }

  /// HTTP header values must be ASCII; device names often aren't (curly
  /// apostrophes). Header carries the lossy form, registerDevice's JSON body
  /// carries the exact one.
  private static var deviceLabelHeaderValue: String {
    let ascii = deviceLabel.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 }
    let cleaned = String(String.UnicodeScalarView(ascii))
    return cleaned.isEmpty ? "iPhone" : cleaned
  }

  // MARK: Endpoints

  /// Register (upsert) this device in the cassette.digital first-class
  /// device registry (user_devices). Called at pairing and once per launch;
  /// the registry row is what makes the phone visible on the dashboard,
  /// independent of any downloads. Idempotent — safe to call repeatedly.
  public func registerDevice() async throws {
    // iOS 26 SDK: UIDevice.current is MainActor-isolated, so reading
    // `model` from this nonisolated context now requires an await.
    // Compile fix only — no behavior change to the spine.
    let body: [String: Any] = await [
      "device_id": Self.deviceId,
      "device_label": Self.deviceLabel,
      "platform": "ios",
      "model": UIDevice.current.model,
      "app_version": Bundle.main
        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
    ]
    _ = try await send(method: "POST", path: "/api/sync/devices", json: body)
    print("Cassette sync: device registered (\(Self.deviceId))")
  }

  /// Non-terminal intents THIS device should act on: brand-new (`pending`),
  /// resuming after a crash (`syncing`), and parked-on-unreachable
  /// (`waiting`). executeIntent is idempotent, so re-seeing `syncing` is safe.
  ///
  /// Device filter: the intents list is account-wide, so it includes intents
  /// targeted at the user's OTHER devices (the Android phone). Acting on
  /// those would download their albums here and race their state machine —
  /// only own-device intents pass. nil targets are legacy single-device rows;
  /// the iPhone (the original device) keeps honoring them.
  public func getActionableIntents() async throws -> [CassetteSyncIntent] {
    struct Envelope: Decodable { let intents: [CassetteSyncIntent] }
    let data = try await get(path: "/api/sync/intents")
    let all = try JSONDecoder().decode(Envelope.self, from: data).intents
    let actionable: Set<String> = ["pending", "syncing", "waiting"]
    let myDeviceId = Self.deviceId
    return all.filter {
      actionable.contains($0.state) &&
        ($0.targetDeviceId == nil || $0.targetDeviceId == myDeviceId)
    }
  }

  public func getIntentTracks(intentId: String) async throws -> CassetteIntentTracksResponse {
    let data = try await get(path: "/api/sync/intents/\(intentId)/tracks")
    return try JSONDecoder().decode(CassetteIntentTracksResponse.self, from: data)
  }

  /// The authenticated caller's OWN account identity (name + email), resolved
  /// server-side from the bearer token. Read-only and self-scoped. The result
  /// is persisted to UserDefaults (`Self.persistAccount`) so the account menu
  /// can render it synchronously, surviving relaunch and offline opens.
  @discardableResult
  public func getAccount() async throws -> CassetteAccount {
    let data = try await get(path: "/api/sync/account")
    let account = try JSONDecoder().decode(CassetteAccount.self, from: data)
    Self.persistAccount(account)
    return account
  }

  /// Cassette Phase 2c: push the phone-chosen download quality UP to the account
  /// (the hub), so the web reflects it and the next `/api/sync/account` fetch
  /// won't clobber the local choice. Also updates the local UserDefaults key the
  /// download URL builder reads, so the change applies immediately. Fire-and-
  /// forget from the Playback picker.
  public func setDownloadQuality(_ tier: String) async throws {
    UserDefaults.standard.set(tier, forKey: Self.downloadQualityKey)
    _ = try await send(
      method: "PATCH",
      path: "/api/account/download-quality",
      json: ["download_quality_tier": tier]
    )
  }

  /// Cassette Diagnostics: push the phone's diagnostics opt-out UP to the account
  /// (the hub), so the choice rides the same cross-device rail as theme/icon and
  /// the next `/api/sync/account` fetch reflects it instead of clobbering it. Also
  /// updates the local synced-consent mirror so the gate applies immediately.
  /// Signed-in only: with no bearer token the client is anonymous (always-on), so
  /// there's nothing to sync and the device-local toggle governs alone.
  /// Fire-and-forget from the Diagnostics toggle.
  public func setDiagnosticsConsent(_ enabled: Bool) async throws {
    guard Self.bearerToken != nil else { return }
    DiagnosticsConfig.syncedConsent = enabled
    _ = try await send(
      method: "PATCH",
      path: "/api/account/diagnostics",
      json: ["diagnostics_consent": enabled]
    )
  }

  /// Read-only artwork backfill manifest for a device's owned albums — the
  /// album artist's catalog image + the album's catalog cover, per owned
  /// album. Used to heal already-synced libraries without a remove/re-add.
  public func getDeviceArtwork(deviceId: String) async throws
    -> CassetteDeviceArtworkResponse {
    let encoded = deviceId.addingPercentEncoding(
      withAllowedCharacters: .urlPathAllowed
    ) ?? deviceId
    let data = try await get(path: "/api/sync/devices/\(encoded)/artwork")
    return try JSONDecoder().decode(CassetteDeviceArtworkResponse.self, from: data)
  }

  /// Read-only content-freshness sweep manifest for a device's owned tracks —
  /// the audio sibling of getDeviceArtwork. Used to notice a re-rip that
  /// changed a track's bytes without changing its identity (title/duration),
  /// which is otherwise invisible to every other sync signal.
  public func getTrackFreshness(deviceId: String) async throws
    -> CassetteTrackFreshnessResponse {
    let encoded = deviceId.addingPercentEncoding(
      withAllowedCharacters: .urlPathAllowed
    ) ?? deviceId
    let data = try await get(path: "/api/sync/devices/\(encoded)/track-freshness")
    return try JSONDecoder().decode(CassetteTrackFreshnessResponse.self, from: data)
  }

  public func updateIntent(
    id: String,
    state: String,
    error: String? = nil
  ) async throws {
    var body: [String: Any] = ["state": state]
    if let error { body["error_message"] = error }
    _ = try await send(method: "PUT", path: "/api/sync/intents/\(id)", json: body)
  }

  /// Differential device-inventory report. `added` entries are upserted,
  /// `removed` localIds are deleted, for this device.
  public func reportDeviceInventory(
    deviceId: String,
    deviceLabel: String?,
    added: [(cassetteLocalId: String, mbid: String?, downloadedAt: Date)],
    removed: [String]
  ) async throws {
    var body: [String: Any] = ["device_id": deviceId]
    if let deviceLabel { body["device_label"] = deviceLabel }

    let iso = ISO8601DateFormatter()
    if !added.isEmpty {
      body["added"] = added.map { entry -> [String: Any] in
        var row: [String: Any] = [
          "cassette_local_id": entry.cassetteLocalId,
          "downloaded_at": iso.string(from: entry.downloadedAt),
        ]
        row["mbid"] = entry.mbid as Any? ?? NSNull()
        return row
      }
    }
    if !removed.isEmpty {
      body["removed"] = removed.map { ["cassette_local_id": $0] }
    }
    if added.isEmpty, removed.isEmpty { return }
    _ = try await send(method: "POST", path: "/api/sync/device-inventory", json: body)
  }

  /// Full-state device-inventory report — the device's COMPLETE owned-set as a
  /// true snapshot (not a delta). The server replaces every row for this device
  /// with `items` and stamps `inventory_as_of`, the freshness signal the
  /// reconciler gates removes on. Unlike the differential report, an empty
  /// device is meaningful here (`items: []` == "I hold nothing"), so this never
  /// early-returns on an empty list.
  /// Returns the server's decoded device-inventory response — carrying the
  /// additive per-track album grouping (Phase 1) the regroup applies — or nil if
  /// the body can't be decoded (older deploy). `@discardableResult` so callers
  /// that only care about the side effect (the report itself) are unchanged.
  @discardableResult
  public func reportFullInventory(
    deviceId: String,
    deviceLabel: String?,
    items: [(cassetteLocalId: String, mbid: String?, downloadedAt: Date)]
  ) async throws
    -> CassetteDeviceInventoryResponse? {
    var body: [String: Any] = ["device_id": deviceId, "full_state": true]
    if let deviceLabel { body["device_label"] = deviceLabel }

    let iso = ISO8601DateFormatter()
    body["items"] = items.map { entry -> [String: Any] in
      var row: [String: Any] = [
        "cassette_local_id": entry.cassetteLocalId,
        "downloaded_at": iso.string(from: entry.downloadedAt),
      ]
      row["mbid"] = entry.mbid as Any? ?? NSNull()
      return row
    }
    let data = try await send(method: "POST", path: "/api/sync/device-inventory", json: body)
    do {
      return try JSONDecoder().decode(CassetteDeviceInventoryResponse.self, from: data)
    } catch {
      // Silent nil used to hide decode failures (e.g. a single bad grouping
      // row), which meant regroup never ran and album years stayed empty.
      print(
        "Cassette sync: device-inventory response decode failed - \(error.localizedDescription)"
      )
      return nil
    }
  }

  // MARK: Play spine (cross-surface listening history)

  /// Batch-report completed plays to the cloud play spine (`/api/sync/plays`).
  /// Append-only + no server-side dedup, so the caller must only send plays it
  /// hasn't sent before (the ScrobbleSyncer stamps `cloudSyncedAt` on success).
  /// Identity is `cassetteLocalId`, computed on-device via `CassetteLocalID` so
  /// it keys on the same id as the web-computed library index. `mbid`,
  /// `durationPlayedSeconds` and `completionRatio` are optional. Send ≤ 500 per
  /// call (the endpoint's cap).
  public func recordPlays(
    _ plays: [(
      cassetteLocalId: String,
      mbid: String?,
      playedAt: Date,
      durationPlayedSeconds: Int?,
      completionRatio: Double?
    )]
  ) async throws {
    guard !plays.isEmpty else { return }
    let iso = ISO8601DateFormatter()
    let rows: [[String: Any]] = plays.map { play -> [String: Any] in
      var row: [String: Any] = [
        "cassette_local_id": play.cassetteLocalId,
        "played_at": iso.string(from: play.playedAt),
        "source_device": "ios",
      ]
      row["mbid"] = play.mbid as Any? ?? NSNull()
      row["duration_played_seconds"] = play.durationPlayedSeconds as Any? ?? NSNull()
      row["completion_ratio"] = play.completionRatio as Any? ?? NSNull()
      return row
    }
    _ = try await send(method: "POST", path: "/api/sync/plays", json: ["plays": rows])
  }

  // MARK: Cloud playlists (user_playlists)

  /// GET /api/sync/playlists — account playlists. Pass `includeItems: true` for
  /// full membership (used to materialise local PlaylistMO rows).
  public func listPlaylists(includeItems: Bool = false, since: Date? = nil) async throws
    -> [CassetteCloudPlaylist] {
    var query: [String] = []
    if includeItems { query.append("include=items") }
    if let since {
      let iso = ISO8601DateFormatter().string(from: since)
      let encoded = iso.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? iso
      query.append("since=\(encoded)")
    }
    let path = query.isEmpty
      ? "/api/sync/playlists"
      : "/api/sync/playlists?\(query.joined(separator: "&"))"
    let data = try await get(path: path)
    return try JSONDecoder().decode(ListPlaylistsResponse.self, from: data).playlists
  }

  public func getPlaylist(id: String) async throws -> CassetteCloudPlaylist {
    let data = try await get(path: "/api/sync/playlists/\(id)")
    return try JSONDecoder().decode(PlaylistEnvelope.self, from: data).playlist
  }

  public func createPlaylist(
    id: String,
    name: String,
    description: String? = nil
  ) async throws -> CassetteCloudPlaylist {
    var body: [String: Any] = ["id": id, "name": name]
    if let description { body["description"] = description }
    let data = try await send(method: "POST", path: "/api/sync/playlists", json: body)
    return try JSONDecoder().decode(PlaylistEnvelope.self, from: data).playlist
  }

  public func updatePlaylist(
    id: String,
    name: String? = nil,
    description: String? = nil
  ) async throws -> CassetteCloudPlaylist {
    var body: [String: Any] = [:]
    if let name { body["name"] = name }
    if let description { body["description"] = description }
    let data = try await send(method: "PUT", path: "/api/sync/playlists/\(id)", json: body)
    return try JSONDecoder().decode(PlaylistEnvelope.self, from: data).playlist
  }

  public func deletePlaylist(id: String) async throws {
    _ = try await send(method: "DELETE", path: "/api/sync/playlists/\(id)", json: [:])
  }

  public func applyPlaylistOps(
    playlistId: String,
    ops: [CassettePlaylistOp]
  ) async throws -> CassetteCloudPlaylist {
    let bodyData = try JSONEncoder().encode(CassettePlaylistOpsBody(ops: ops))
    let data = try await send(
      method: "POST",
      path: "/api/sync/playlists/\(playlistId)/ops",
      body: bodyData
    )
    return try JSONDecoder().decode(PlaylistOpsEnvelope.self, from: data).playlist
  }

  // MARK: Cloud favorites / Saved

  public func listFavorites(since: Date? = nil) async throws -> [CassetteCloudFavorite] {
    var path = "/api/sync/favorites"
    if let since {
      let iso = ISO8601DateFormatter().string(from: since)
      let encoded = iso.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? iso
      path += "?since=\(encoded)"
    }
    let data = try await get(path: path)
    return try JSONDecoder().decode(ListFavoritesResponse.self, from: data).favorites
  }

  public func upsertFavorite(
    cassetteLocalId: String,
    mbid: String?,
    trackTitle: String?,
    artistName: String?,
    albumName: String?
  ) async throws {
    var body: [String: Any] = [
      "cassette_local_id": cassetteLocalId,
      "event_at": ISO8601DateFormatter().string(from: Date()),
      "source_device": "ios",
    ]
    body["mbid"] = mbid as Any? ?? NSNull()
    if let trackTitle { body["track_title"] = trackTitle }
    if let artistName { body["artist_name"] = artistName }
    if let albumName { body["album_name"] = albumName }
    _ = try await send(method: "POST", path: "/api/sync/favorites", json: body)
  }

  public func removeFavorite(cassetteLocalId: String) async throws {
    // DELETE with JSON body — URLSession needs httpBody on a custom request.
    guard let token = Self.bearerToken else { throw CassetteSyncError.notAuthenticated }
    guard let url = URL(string: Self.apiBase + "/api/sync/favorites") else {
      throw CassetteSyncError.badURL
    }
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.timeoutInterval = 20
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    applyDeviceHeaders(&request)
    let body: [String: Any] = [
      "cassette_local_id": cassetteLocalId,
      "event_at": ISO8601DateFormatter().string(from: Date()),
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    _ = try await perform(request)
  }

  /// GET /api/sync/plays?since=<iso> — cloud play history, newest first, plays
  /// strictly newer than `since` (server default page size when `since == nil`).
  /// Strictly READ-ONLY. Used by `CloudPlayReconciler` to fold in plays made on
  /// the user's OTHER devices (e.g. their computer) so recency is synchronized
  /// cross-device.
  public func fetchPlays(
    since: Date?,
    excludeSource: String? = nil
  ) async throws
    -> [CassetteCloudPlay] {
    var query: [String] = []
    if let since {
      // Match `recordPlays`' formatter (second precision); the server parses
      // either. `get(path:)` does no percent-encoding, so encode here.
      let iso = ISO8601DateFormatter()
      let sinceStr = iso.string(from: since)
      let encoded = sinceStr
        .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? sinceStr
      query.append("since=\(encoded)")
    }
    // Drop our OWN device's plays server-side so the newest-N page is spent on
    // cross-device history, not our own listening (which is already local recency).
    if let excludeSource {
      query.append("exclude_source=\(excludeSource)")
    }
    let path = query.isEmpty ? "/api/sync/plays" : "/api/sync/plays?\(query.joined(separator: "&"))"
    let data = try await get(path: path)
    return try JSONDecoder().decode(PlaysResponse.self, from: data).plays
  }

  private struct PlaysResponse: Decodable {
    let plays: [CassetteCloudPlay]
  }

  /// One ranked song from `POST /api/sync/popular-rank`.
  public struct PopularRankItem: Decodable, Sendable {
    public let cassetteLocalId: String
    public let title: String
    public let playCount: Int

    private enum CodingKeys: String, CodingKey {
      case cassetteLocalId = "cassette_local_id"
      case title
      case playCount = "play_count"
    }
  }

  private struct PopularRankResponse: Decodable {
    let items: [PopularRankItem]
  }

  /// POST /api/sync/popular-rank — cloud play-count ranking for an artist's
  /// owned songs (same order as the web/desktop artist rail). Caller sends
  /// cassette_local_id + title; server returns play_count ↓, title A→Z,
  /// capped at 20. Offline callers should fall back to a local tally with
  /// the same comparator.
  public func rankPopular(
    items: [(cassetteLocalId: String, title: String)]
  ) async throws -> [PopularRankItem] {
    guard !items.isEmpty else { return [] }
    let rows: [[String: Any]] = items.map { item in
      [
        "cassette_local_id": item.cassetteLocalId,
        "title": item.title,
      ]
    }
    let data = try await send(
      method: "POST",
      path: "/api/sync/popular-rank",
      json: ["items": rows]
    )
    return try JSONDecoder().decode(PopularRankResponse.self, from: data).items
  }

  // MARK: On-demand convergence (B2 pull-to-refresh)

  public enum ConvergeResult: Sendable {
    case converged // sidecar reported a completed scan-first pass
    case timeout // sidecar still working past its window — proceed lazily
    case unavailable // no sidecar port known, or LAN host unresolved
    case unreachable // network error reaching the sidecar
  }

  /// Drive an on-demand scan-first convergence on the paired Player's sidecar
  /// over the LAN, then return so the caller can re-report inventory + reconcile.
  /// The sidecar base is `http://<host-of-serverUrl>:<sidecarPort>` — the phone's
  /// serverUrl carries Navidrome's host:4533, so we keep the host and swap the
  /// port for the sidecar's (advertised via /api/sync/account). This is a LAN
  /// call to the sidecar — NOT cassette.digital — so it carries no bearer/device
  /// headers. Blocks up to ~95s (just past the sidecar's 90s convergeMaxWait).
  /// Best-effort: every failure returns a non-fatal result so pull-to-refresh
  /// degrades to lazy convergence (the watcher + heartbeat), never an error wall.
  public func convergeOnPlayer(serverUrl: String?) async -> ConvergeResult {
    guard let port = Self.sidecarPort, port > 0 else { return .unavailable }
    guard let serverUrl,
          let comps = URLComponents(string: serverUrl),
          let host = comps.host
    else { return .unavailable }

    var sidecar = URLComponents()
    sidecar.scheme = comps.scheme ?? "http"
    sidecar.host = host
    sidecar.port = port
    sidecar.path = "/api/library/converge"
    guard let url = sidecar.url else { return .unavailable }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 95
    let lanSession = URLSession(configuration: .ephemeral)
    do {
      let (data, response) = try await lanSession.data(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        return .unreachable
      }
      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         (json["converged"] as? Bool) == true {
        return .converged
      }
      return .timeout
    } catch {
      return .unreachable
    }
  }

  // MARK: HTTP plumbing

  private func get(path: String) async throws -> Data {
    guard let token = Self.bearerToken else { throw CassetteSyncError.notAuthenticated }
    guard let url = URL(string: Self.apiBase + path) else { throw CassetteSyncError.badURL }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 20
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    applyDeviceHeaders(&request)
    return try await perform(request)
  }

  private func send(method: String, path: String, json: [String: Any]) async throws -> Data {
    try await send(
      method: method,
      path: path,
      body: try JSONSerialization.data(withJSONObject: json)
    )
  }

  private func send(method: String, path: String, body: Data) async throws -> Data {
    guard let token = Self.bearerToken else { throw CassetteSyncError.notAuthenticated }
    guard let url = URL(string: Self.apiBase + path) else { throw CassetteSyncError.badURL }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 20
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    applyDeviceHeaders(&request)
    request.httpBody = body
    return try await perform(request)
  }

  /// Device identity rides every sync request. Server-side, a bearer-authed
  /// request carrying X-Cassette-Device-Id bumps user_devices.last_seen_at
  /// (the keep-alive that keeps the dashboard's device view honest) and
  /// stamps the token <-> device link used by unpair.
  private func applyDeviceHeaders(_ request: inout URLRequest) {
    request.setValue(Self.deviceId, forHTTPHeaderField: "X-Cassette-Device-Id")
    request.setValue(Self.deviceLabelHeaderValue, forHTTPHeaderField: "X-Cassette-Device-Label")
  }

  private func perform(_ request: URLRequest) async throws -> Data {
    // Verbose-but-temporary logging (Phase 3.1) — `print` is visible in the
    // Xcode console regardless of os_log level filtering.
    let label = "\(request.httpMethod ?? "?") \(request.url?.path ?? "?")"
    print("Cassette sync: -> \(label)")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      print("Cassette sync: <- \(label) invalid (non-HTTP) response")
      throw CassetteSyncError.invalidResponse
    }
    print("Cassette sync: <- \(label) \(http.statusCode)")
    guard (200 ..< 300).contains(http.statusCode) else {
      os_log(
        "sync request %{public}@ failed: %d",
        log: self.log,
        type: .error,
        request.url?.path ?? "?",
        http.statusCode
      )
      if http.statusCode == 401 {
        // Token revoked (device unpaired on the dashboard) or expired.
        // Let the app surface a reconnect prompt instead of dying silently.
        NotificationCenter.default.post(name: .cassetteTokenRejected, object: nil)
      }
      throw CassetteSyncError.http(http.statusCode)
    }
    return data
  }

  // MARK: - Mixtape

  /// POST /api/mixtape/generate — whole-library "Smart Mixtape", no seed, no
  /// body. Ephemeral: the server never saves anything until `saveMixtape` is
  /// called explicitly.
  public func generateMixtape() async throws -> CassetteMixtapeResponse {
    let data = try await send(method: "POST", path: "/api/mixtape/generate", json: [:])
    return try JSONDecoder().decode(CassetteMixtapeResponse.self, from: data)
  }

  /// POST /api/mixtape/radio — seeded from one track. Pass whatever identity
  /// is on hand; the server matches on cassette_local_id, mbid, or
  /// subsonic_track_id, in that priority order.
  public func startMixtapeRadio(
    cassetteLocalId: String?,
    mbid: String?,
    subsonicTrackId: String?
  ) async throws -> CassetteMixtapeResponse {
    let body: [String: Any] = [
      "cassette_local_id": cassetteLocalId as Any? ?? NSNull(),
      "mbid": mbid as Any? ?? NSNull(),
      "subsonic_track_id": subsonicTrackId as Any? ?? NSNull(),
    ]
    let data = try await send(method: "POST", path: "/api/mixtape/radio", json: body)
    return try JSONDecoder().decode(CassetteMixtapeResponse.self, from: data)
  }

  /// POST /api/mixtape/door — one of the six mood presets. Cached server-side
  /// once per (account, door) per day; `rebuild: true` forces a fresh take
  /// and replaces that day's cached build.
  public func generateDoorMixtape(
    doorKey: String,
    rebuild: Bool = false
  ) async throws -> CassetteMixtapeResponse {
    let body: [String: Any] = ["door_key": doorKey, "rebuild": rebuild]
    let data = try await send(method: "POST", path: "/api/mixtape/door", json: body)
    return try JSONDecoder().decode(CassetteMixtapeResponse.self, from: data)
  }

  /// POST /api/mixtape/save — the only mixtape endpoint that writes anything.
  /// Post back exactly the name/description/tracks a generate/radio/door call
  /// returned; the server persists it as a real playlist and returns its id.
  public func saveMixtape(
    name: String,
    description: String,
    tracks: [CassetteMixtapeTrack]
  ) async throws -> String {
    let bodyData = try JSONEncoder().encode(CassetteSaveMixtapeBody(
      name: name,
      description: description,
      tracks: tracks
    ))
    let data = try await send(method: "POST", path: "/api/mixtape/save", body: bodyData)
    return try JSONDecoder().decode(CassetteSaveMixtapeResponse.self, from: data).playlistId
  }
}

// MARK: - CassetteAuthPreservingDelegate

/// Re-applies the Authorization header across redirects. Vercel may issue a
/// redirect before the route handler runs, and URLSession strips Authorization
/// on cross-request redirects by default.
final class CassetteAuthPreservingDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> ()
  ) {
    var newRequest = request
    if let auth = task.originalRequest?.value(forHTTPHeaderField: "Authorization") {
      newRequest.setValue(auth, forHTTPHeaderField: "Authorization")
    }
    completionHandler(newRequest)
  }
}

// MARK: - CassettePlaylistOp

/// Wire-shaped playlist mutation op for POST /api/sync/playlists/:id/ops.
/// Sendable so MainActor callers can hand it to this nonisolated client.
public enum CassettePlaylistOp: Encodable, Sendable {
  case add(
    itemId: String,
    cassetteLocalId: String,
    mbid: String?,
    position: Double,
    addedAt: String,
    addedByDevice: String
  )
  case remove(itemId: String)
  case reorder(itemId: String, position: Double)

  private enum CodingKeys: String, CodingKey {
    case op
    case itemId = "item_id"
    case cassetteLocalId = "cassette_local_id"
    case mbid
    case position
    case addedAt = "added_at"
    case addedByDevice = "added_by_device"
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .add(itemId, cassetteLocalId, mbid, position, addedAt, addedByDevice):
      try container.encode("add", forKey: .op)
      try container.encode(itemId, forKey: .itemId)
      try container.encode(cassetteLocalId, forKey: .cassetteLocalId)
      try container.encode(mbid, forKey: .mbid)
      try container.encode(position, forKey: .position)
      try container.encode(addedAt, forKey: .addedAt)
      try container.encode(addedByDevice, forKey: .addedByDevice)
    case let .remove(itemId):
      try container.encode("remove", forKey: .op)
      try container.encode(itemId, forKey: .itemId)
    case let .reorder(itemId, position):
      try container.encode("reorder", forKey: .op)
      try container.encode(itemId, forKey: .itemId)
      try container.encode(position, forKey: .position)
    }
  }
}

private struct CassettePlaylistOpsBody: Encodable {
  let ops: [CassettePlaylistOp]
}

// MARK: - CassetteCloudPlaylist

public struct CassetteCloudPlaylistItem: Sendable, Decodable {
  public let id: String
  public let cassetteLocalId: String
  public let mbid: String?
  public let position: Double
  public let removedAt: String?

  enum CodingKeys: String, CodingKey {
    case id
    case cassetteLocalId = "cassette_local_id"
    case mbid
    case position
    case removedAt = "removed_at"
  }
}

public struct CassetteCloudPlaylist: Sendable, Decodable {
  public let id: String
  public let name: String
  public let description: String?
  public let coverImageUrl: String?
  // cassette (cover unification): server-picked preset for a playlist with no
  // user cover. Optional (absent on older servers → nil). Rendered from the phone's
  // BUNDLED preset asset, so it's local + offline; the user's own pick still wins.
  public let derivedCoverUrl: String?
  public let updatedAt: String?
  public let deletedAt: String?
  public let items: [CassetteCloudPlaylistItem]?

  enum CodingKeys: String, CodingKey {
    case id, name, description, items
    case coverImageUrl = "cover_image_url"
    case derivedCoverUrl = "derived_cover_url"
    case updatedAt = "updated_at"
    case deletedAt = "deleted_at"
  }
}

private struct ListPlaylistsResponse: Decodable {
  let playlists: [CassetteCloudPlaylist]
}

private struct PlaylistEnvelope: Decodable {
  let playlist: CassetteCloudPlaylist
}

private struct PlaylistOpsEnvelope: Decodable {
  let playlist: CassetteCloudPlaylist
}

// MARK: - CassetteCloudFavorite

public struct CassetteCloudFavorite: Sendable, Decodable {
  public let cassetteLocalId: String
  public let mbid: String?
  public let trackTitle: String?
  public let artistName: String?
  public let albumName: String?
  public let eventAt: String?

  enum CodingKeys: String, CodingKey {
    case cassetteLocalId = "cassette_local_id"
    case mbid
    case trackTitle = "track_title"
    case artistName = "artist_name"
    case albumName = "album_name"
    case eventAt = "event_at"
  }
}

private struct ListFavoritesResponse: Decodable {
  let favorites: [CassetteCloudFavorite]
}

// MARK: - Mixtape DTOs

/// One track as returned by generate/radio/door and posted back to save —
/// same shape both directions, matching the web app's SavedMixtapeTrack.
public struct CassetteMixtapeTrack: Sendable, Codable {
  public let title: String
  public let artist: String
  public let album: String?
  public let durationSeconds: Int?
  public let cassetteLocalId: String
  public let mbid: String?
  public let subsonicTrackId: String?
}

/// Procedural art motif for a mood-door mixtape (shape + hex color) — nil for
/// the whole-library/radio generators, which render a plain gradient instead.
public struct CassetteMixtapeArt: Sendable, Codable {
  public let shape: String
  public let color: String
}

/// The response shape ALL THREE generators (generate/radio/door) return.
/// Ephemeral — nothing is saved server-side until `saveMixtape` posts this
/// exact shape back to /api/mixtape/save.
public struct CassetteMixtapeResponse: Sendable, Decodable {
  public let name: String
  public let description: String?
  public let art: CassetteMixtapeArt?
  public let tracks: [CassetteMixtapeTrack]
  /// Present only for a door-seeded mixtape — which mood preset generated it,
  /// needed to wire up the Rebuild action. nil for generate/radio.
  public let doorKey: String?
}

private struct CassetteSaveMixtapeBody: Encodable {
  let name: String
  let description: String
  let tracks: [CassetteMixtapeTrack]
}

private struct CassetteSaveMixtapeResponse: Decodable {
  let playlistId: String
}

// MARK: - CassetteCloudPlay

/// One play returned by `GET /api/sync/plays` — the subset the Home recency
/// reconciler needs. Mirrors the server `PlayJson` wire shape.
public struct CassetteCloudPlay: Decodable {
  public let cassetteLocalId: String
  public let mbid: String?
  public let playedAt: Date
  public let sourceDevice: String?

  private enum CodingKeys: String, CodingKey {
    case cassetteLocalId = "cassette_local_id"
    case mbid
    case playedAt = "played_at"
    case sourceDevice = "source_device"
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.cassetteLocalId = try c.decode(String.self, forKey: .cassetteLocalId)
    self.mbid = try c.decodeIfPresent(String.self, forKey: .mbid)
    self.sourceDevice = try c.decodeIfPresent(String.self, forKey: .sourceDevice)
    let raw = try c.decode(String.self, forKey: .playedAt)
    guard let date = CassetteCloudPlay.parseISO(raw) else {
      throw DecodingError.dataCorruptedError(
        forKey: .playedAt,
        in: c,
        debugDescription: "played_at is not an ISO-8601 timestamp: \(raw)"
      )
    }
    self.playedAt = date
  }

  /// The server emits JS `toISOString()` (fractional seconds + `Z`); tolerate a
  /// plain second-precision stamp too.
  private static func parseISO(_ s: String) -> Date? {
    let withFrac = ISO8601DateFormatter()
    withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = withFrac.date(from: s) { return d }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: s)
  }
}

// MARK: - CloudPlayReconciler

/// Folds cloud play history made on the user's OTHER devices (e.g. their
/// computer) into this device's local recency, so the Home "Recent" shelf
/// reflects cross-device listening. It only ever ADVANCES a `Song`'s
/// `lastTimePlayed` (never decrements, never touches `playCount`), and is
/// read-only against the network (`GET /api/sync/plays`).
///
/// Identity chain: a cloud play's `cassette_local_id` → the indexed
/// `DeviceOwnershipMO` (owned/downloaded tracks) → its `subsonicTrackId` → the
/// local `Song`. Cloud plays for tracks not on this device have no local Song
/// and are skipped — they couldn't appear in a local shelf anyway.
public enum CloudPlayReconciler {
  /// How far back to re-scan cloud plays on every run. A forward-only "newest
  /// playedAt" watermark stranded cross-device history: the phone's OWN plays are
  /// always the newest, so the watermark raced to "now" and every play from
  /// another device — always at an earlier timestamp — fell permanently behind it
  /// and was never fetched again. Instead we re-scan this bounded recent window
  /// every run and lean on advance-only idempotency (re-applying a play already
  /// folded in is a no-op), so cross-device plays are always caught and the pass
  /// self-heals. The server caps the page at its own limit, newest-first, which is
  /// plenty for a "Recent" shelf.
  nonisolated private static let recencyWindow: TimeInterval = 60 * 60 * 24 * 90 // 90 days

  /// Fetch recent cloud plays and advance the matching local Songs'
  /// `lastTimePlayed` so the Home "Recent" shelf reflects listening on the user's
  /// OTHER devices (e.g. their computer). Returns `true` if any Song changed, so
  /// the caller can refresh recency-driven UI. Advance-only (never decrements,
  /// never bumps `playCount`) and read-only against the network — safe to re-run.
  @MainActor
  public static func reconcile(storage: PersistentStorage, account: Account) async -> Bool {
    guard CassetteSyncAPI.bearerToken != nil else { return false }

    let since = Date().addingTimeInterval(-recencyWindow)
    let plays: [CassetteCloudPlay]
    do {
      // exclude our own "ios" plays — we only need OTHER devices' listening, and
      // dropping ours keeps the newest-N page spent on cross-device history.
      plays = try await CassetteSyncAPI.shared.fetchPlays(since: since, excludeSource: "ios")
    } catch {
      print("Cassette recency: fetchPlays FAILED: \(error)")
      return false
    }
    // cassette recency diagnostics — temporary. Founder pastes the Xcode console;
    // this maps the funnel from cloud plays → local recency advances so we can see
    // exactly where cross-device recency is (or isn't) landing. Remove once green.
    print("Cassette recency: fetched \(plays.count) cloud plays since \(since)")
    guard !plays.isEmpty else { return false }

    let ownership = DeviceOwnershipManager(context: storage.main.context)
    var changed = false
    // Funnel counters: how many plays survive each resolution step.
    var fromOtherDevice = 0, ownedMatch = 0, hadSubsonicId = 0, songResolved = 0, advanced = 0

    for play in plays {
      if play.sourceDevice != "ios" { fromOtherDevice += 1 }
      // Resolve by the stable mbid first (survives the fingerprint drift between
      // this phone and the hub), then the cassette_local_id fingerprint.
      let ownedOpt = (play.mbid.flatMap { try? ownership.fetchOne(mbid: $0) })
        ?? (try? ownership.fetchOne(cassetteLocalId: play.cassetteLocalId))
      guard let owned = ownedOpt else { continue }
      ownedMatch += 1
      guard let subsonicId = owned.subsonicTrackId else { continue }
      hadSubsonicId += 1
      guard let song = storage.main.library.getSong(for: account, id: subsonicId)
      else { continue }
      songResolved += 1
      // Advance-only: never move a Song's recency backwards, never bump count.
      if let current = song.lastTimePlayed, current >= play.playedAt { continue }
      song.lastTimePlayed = play.playedAt
      advanced += 1
      changed = true
    }
    print(
      "Cassette recency: \(plays.count) plays (\(fromOtherDevice) off-device) → "
        +
        "\(ownedMatch) owned / \(hadSubsonicId) with subsonicId / \(songResolved) song resolved / "
        + "\(advanced) recency advanced"
    )

    if changed { storage.main.saveContext() }
    return changed
  }
}
