//
//  IntentExecutor.swift
//  AmperfyKit
//
//  Cassette fork — Layer 3 Phase 3.1 (Transfer Mechanism).
//
//  Polls cassette.digital for actionable sync intents and drives them to
//  completion: marks syncing, checks the Cassette Player is reachable on the
//  LAN, resolves the album's track list server-side, and enqueues background
//  downloads (or removals). State transitions are reported back so the admin
//  test tool can observe progress.
//
//  Idempotent by design: re-running an intent skips already-owned tracks and
//  already-in-flight downloads, then completes once everything is present.
//  This makes crash/relaunch recovery and the 30s foreground poll safe.
//
//  Phase 3.1 handles `scope == "album"` only. Other scopes fail with
//  `unsupported_scope_in_phase_31`.
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

import CoreData
import Foundation
import os.log
import UIKit

@MainActor
public final class IntentExecutor {
  public static let shared = IntentExecutor()

  private let log = OSLog(subsystem: "Amperfy", category: "IntentExecutor")
  private let api = CassetteSyncAPI.shared
  private let transferSession = CassetteTransferSession.shared

  private var isRunning = false

  public init() {}

  /// Entry point for polling (foreground + 30s timer). No-op if no account or
  /// no bearer token yet, or if a run is already in progress.
  public func handlePendingIntents() async {
    // Verbose-but-temporary logging (Phase 3.1) — `print` is guaranteed
    // visible in the Xcode console, unlike os_log .info which is filtered.
    print("Cassette poll: handlePendingIntents() entered")
    guard !isRunning else {
      print("Cassette poll: skip - a run is already in progress")
      return
    }
    guard CassetteSyncAPI.bearerToken != nil else {
      print("Cassette poll: skip - NO BEARER TOKEN (re-link in Settings > Developer)")
      return
    }
    guard AmperKit.shared.storage.settings.accounts.active != nil else {
      print("Cassette poll: skip - no active account")
      return
    }

    isRunning = true
    defer { isRunning = false }

    let intents: [CassetteSyncIntent]
    do {
      print("Cassette poll: fetching pending intents from cassette.digital")
      intents = try await api.getActionableIntents()
    } catch {
      print("Cassette poll: failed to fetch intents - \(error.localizedDescription)")
      os_log(
        "failed to fetch intents: %{public}@",
        log: self.log,
        type: .error,
        error.localizedDescription
      )
      return
    }

    print("Cassette poll: received \(intents.count) actionable intent(s)")
    for intent in intents {
      await executeIntent(intent)
    }
  }

  private func executeIntent(_ intent: CassetteSyncIntent) async {
    print(
      "Cassette poll: executing intent \(intent.id) " +
        "scope=\(intent.scope) kind=\(intent.intentKind) target=\(intent.targetId)"
    )
    // Phase 3.1: album scope only.
    guard intent.scope == "album" else {
      print("Cassette poll: intent \(intent.id) - unsupported scope '\(intent.scope)', failing")
      try? await api.updateIntent(
        id: intent.id,
        state: "failed",
        error: "unsupported_scope_in_phase_31"
      )
      return
    }

    if intent.state == "pending" {
      try? await api.updateIntent(id: intent.id, state: "syncing")
    }

    // Reachability: the Cassette Player must be on the LAN to pull files.
    let reachable = await isCassettePlayerReachable()
    print("Cassette poll: intent \(intent.id) - Cassette Player reachable=\(reachable)")
    guard reachable else {
      try? await api.updateIntent(
        id: intent.id,
        state: "waiting",
        error: "cassette_player_unreachable"
      )
      return
    }

    let tracks: [CassetteSyncTrack]
    do {
      tracks = try await api.getIntentTracks(intentId: intent.id)
    } catch {
      print(
        "Cassette poll: intent \(intent.id) - track resolve failed: \(error.localizedDescription)"
      )
      try? await api.updateIntent(
        id: intent.id,
        state: "failed",
        error: "track_resolve_failed"
      )
      return
    }
    print("Cassette poll: intent \(intent.id) - resolved \(tracks.count) track(s)")

    let manager = DeviceOwnershipManager(context: AmperKit.shared.storage.main.context)

    if intent.intentKind == "remove" {
      await executeRemoval(intent: intent, tracks: tracks, manager: manager)
      return
    }

    // Add: enqueue downloads for any track not already owned.
    guard let accountInfo = AmperKit.shared.storage.settings.accounts.active else { return }
    let backendApi = AmperKit.shared.getMeta(accountInfo).backendApi

    var enqueued = 0
    for track in tracks {
      if manager.exists(cassetteLocalId: track.cassetteLocalId) { continue }
      do {
        let url = try await backendApi
          .cassetteDownloadUrl(forSubsonicTrackId: track.subsonicTrackId)
        await transferSession.enqueueDownload(
          url: url,
          cassetteLocalId: track.cassetteLocalId,
          mbid: track.mbid,
          subsonicTrackId: track.subsonicTrackId,
          fileExtension: track.fileExtension,
          intentId: intent.id
        )
        enqueued += 1
        print("Cassette poll: intent \(intent.id) - enqueued download for \(track.cassetteLocalId)")
      } catch {
        print(
          "Cassette poll: intent \(intent.id) - failed to build download URL " +
            "for \(track.subsonicTrackId): \(error.localizedDescription)"
        )
        os_log(
          "failed to build download URL for %{public}@: %{public}@",
          log: self.log,
          type: .error,
          track.subsonicTrackId,
          error.localizedDescription
        )
      }
    }
    print("Cassette poll: intent \(intent.id) - enqueued \(enqueued) new download(s)")

    // Complete the intent once everything it covers is on disk. Otherwise
    // leave it `syncing`; a later poll (or the next foreground) finalizes it
    // as background downloads land.
    let allOwned = tracks.allSatisfy { manager.exists(cassetteLocalId: $0.cassetteLocalId) }
    if allOwned {
      print("Cassette poll: intent \(intent.id) - all tracks owned, marking complete")
      try? await api.updateIntent(id: intent.id, state: "complete")
    } else {
      print("Cassette poll: intent \(intent.id) - downloads in flight, leaving syncing")
    }
  }

  private func executeRemoval(
    intent: CassetteSyncIntent,
    tracks: [CassetteSyncTrack],
    manager: DeviceOwnershipManager
  ) async {
    var removed: [String] = []
    for track in tracks {
      guard manager.exists(cassetteLocalId: track.cassetteLocalId) else { continue }
      do {
        try manager.remove(cassetteLocalId: track.cassetteLocalId)
        removed.append(track.cassetteLocalId)
      } catch {
        os_log(
          "failed to remove %{public}@: %{public}@",
          log: self.log,
          type: .error,
          track.cassetteLocalId,
          error.localizedDescription
        )
      }
    }

    print("Cassette poll: intent \(intent.id) - removed \(removed.count) owned track(s)")
    if !removed.isEmpty {
      let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
      try? await api.reportDeviceInventory(
        deviceId: deviceId,
        deviceLabel: UIDevice.current.name,
        added: [],
        removed: removed
      )
    }
    try? await api.updateIntent(id: intent.id, state: "complete")
  }

  // MARK: - Reachability

  /// A quick GET to the active account's LAN server with a 5s timeout. Any
  /// HTTP response means reachable; only network errors / timeouts mean not.
  private func isCassettePlayerReachable() async -> Bool {
    guard let serverUrl = AmperKit.shared.storage.settings.accounts.activeSetting.read
      .loginCredentials?.serverUrl,
      let url = URL(string: serverUrl)
    else { return false }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 5

    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 5
    config.waitsForConnectivity = false
    let session = URLSession(configuration: config)

    do {
      let (_, response) = try await session.data(for: request)
      return response is HTTPURLResponse
    } catch {
      return false
    }
  }
}
