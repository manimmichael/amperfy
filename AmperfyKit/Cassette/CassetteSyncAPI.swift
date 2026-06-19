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

public extension Notification.Name {
  /// Posted when a sync request gets a 401 — the bearer token was revoked
  /// (e.g. the device was removed from the account on the dashboard) or
  /// expired. The app shows a one-per-launch "reconnect?" alert that runs
  /// the re-link flow instead of silently dying.
  static let cassetteTokenRejected = Notification.Name("CassetteTokenRejected")
}

// MARK: - CassetteSyncIntent

public struct CassetteSyncIntent: Sendable, Decodable {
  public let id: String
  public let scope: String
  public let targetId: String
  public let state: String
  public let intentKind: String

  enum CodingKeys: String, CodingKey {
    case id
    case scope
    case targetId = "target_id"
    case state
    case intentKind = "intent_kind"
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
public struct CassetteDeviceArtworkAlbum: Sendable, Decodable {
  public let artistName: String
  public let albumName: String
  public let artistImageUrl: String?
  public let artistThumbUrl: String?
  public let coverUrl: String?
  public let coverThumbUrl: String?

  enum CodingKeys: String, CodingKey {
    case artistName = "artist_name"
    case albumName = "album_name"
    case artistImageUrl = "artist_image_url"
    case artistThumbUrl = "artist_thumb_url"
    case coverUrl = "cover_url"
    case coverThumbUrl = "cover_thumb_url"
  }
}

// MARK: - CassetteDeviceArtworkResponse

/// The `/devices/:device_id/artwork` envelope: the artwork backfill manifest
/// for every album the device owns (read-only — heals already-synced albums).
public struct CassetteDeviceArtworkResponse: Sendable, Decodable {
  public let albums: [CassetteDeviceArtworkAlbum]
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

  /// Non-terminal intents the device should act on: brand-new (`pending`),
  /// resuming after a crash (`syncing`), and parked-on-unreachable
  /// (`waiting`). executeIntent is idempotent, so re-seeing `syncing` is safe.
  public func getActionableIntents() async throws -> [CassetteSyncIntent] {
    struct Envelope: Decodable { let intents: [CassetteSyncIntent] }
    let data = try await get(path: "/api/sync/intents")
    let all = try JSONDecoder().decode(Envelope.self, from: data).intents
    let actionable: Set<String> = ["pending", "syncing", "waiting"]
    return all.filter { actionable.contains($0.state) }
  }

  public func getIntentTracks(intentId: String) async throws -> CassetteIntentTracksResponse {
    let data = try await get(path: "/api/sync/intents/\(intentId)/tracks")
    return try JSONDecoder().decode(CassetteIntentTracksResponse.self, from: data)
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
  public func reportFullInventory(
    deviceId: String,
    deviceLabel: String?,
    items: [(cassetteLocalId: String, mbid: String?, downloadedAt: Date)]
  ) async throws {
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
    _ = try await send(method: "POST", path: "/api/sync/device-inventory", json: body)
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
    guard let token = Self.bearerToken else { throw CassetteSyncError.notAuthenticated }
    guard let url = URL(string: Self.apiBase + path) else { throw CassetteSyncError.badURL }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 20
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    applyDeviceHeaders(&request)
    request.httpBody = try JSONSerialization.data(withJSONObject: json)
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
