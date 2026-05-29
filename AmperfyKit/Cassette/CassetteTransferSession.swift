//
//  CassetteTransferSession.swift
//  AmperfyKit
//
//  Cassette fork — Layer 3 Phase 3.1 (Transfer Mechanism).
//
//  Owns the single background URLSession ("digital.cassette.transfers") that
//  pulls owned files from the user's Cassette Player over the LAN. Wi-Fi only,
//  resumes across app relaunches. On completion it moves the file into
//  CassetteMusic/, records a DeviceOwnershipMO row, and reports the addition
//  to cassette.digital's device inventory.
//
//  Per-download metadata is stored in the task's `taskDescription` (a JSON
//  blob). The system restores background tasks — including their
//  taskDescription — when it relaunches the app to deliver completions, so no
//  separate sidecar file is needed to survive a cold launch.
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

// MARK: - Transfer metadata

/// Stored in the download task's taskDescription so it survives a cold launch.
struct CassetteTransferMetadata: Codable {
  let cassetteLocalId: String
  let mbid: String?
  let subsonicTrackId: String?
  let ext: String
  let intentId: String
}

// MARK: - CassetteTransferSession

public final class CassetteTransferSession: NSObject, @unchecked Sendable {
  public static let shared = CassetteTransferSession()

  public static let backgroundIdentifier = "digital.cassette.transfers"

  private let log = OSLog(subsystem: "Amperfy", category: "CassetteTransferSession")
  private let fileStorage = CassetteFileStorage.shared
  private let syncAPI = CassetteSyncAPI.shared

  // Stored background-events completion handler (set by the AppDelegate).
  private var backgroundCompletionHandler: (() -> Void)?

  // In-memory guard against double-enqueueing the same track within a run.
  private let inFlightLock = NSLock()
  private var inFlightLocalIds = Set<String>()

  private lazy var session: URLSession = {
    let config = URLSessionConfiguration
      .background(withIdentifier: Self.backgroundIdentifier)
    config.allowsCellularAccess = false // Wi-Fi only (acceptance criterion)
    config.isDiscretionary = false // start as soon as possible
    config.sessionSendsLaunchEvents = true // wake the app on completion
    config.waitsForConnectivity = true // auto-resume when network returns

    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    return URLSession(configuration: config, delegate: self, delegateQueue: queue)
  }()

  override private init() {
    super.init()
    // Touch the session so iOS reconnects to any restored background tasks.
    _ = session
  }

  // MARK: - Enqueue

  /// Enqueue a background download. No-op if the same track is already
  /// in-flight (including tasks restored after a relaunch).
  public func enqueueDownload(
    url: URL,
    cassetteLocalId: String,
    mbid: String?,
    subsonicTrackId: String?,
    fileExtension ext: String,
    intentId: String
  ) async {
    // Skip if a task for this track already exists.
    if await isAlreadyInFlight(cassetteLocalId: cassetteLocalId) { return }
    guard markInFlight(cassetteLocalId) else { return }

    let metadata = CassetteTransferMetadata(
      cassetteLocalId: cassetteLocalId,
      mbid: mbid,
      subsonicTrackId: subsonicTrackId,
      ext: ext,
      intentId: intentId
    )
    let task = session.downloadTask(with: url)
    if let data = try? JSONEncoder().encode(metadata),
       let json = String(data: data, encoding: .utf8) {
      task.taskDescription = json
    }
    task.resume()
    print("Cassette transfer: enqueued background download for \(cassetteLocalId) (.\(ext))")
    os_log("enqueued download for %{public}@", log: self.log, type: .info, cassetteLocalId)
  }

  private func markInFlight(_ cassetteLocalId: String) -> Bool {
    inFlightLock.lock()
    defer { inFlightLock.unlock() }
    return inFlightLocalIds.insert(cassetteLocalId).inserted
  }

  private func containsInFlight(_ cassetteLocalId: String) -> Bool {
    inFlightLock.lock()
    defer { inFlightLock.unlock() }
    return inFlightLocalIds.contains(cassetteLocalId)
  }

  private func isAlreadyInFlight(cassetteLocalId: String) async -> Bool {
    if containsInFlight(cassetteLocalId) { return true }

    let tasks: [URLSessionTask] = await withCheckedContinuation { continuation in
      session.getAllTasks { continuation.resume(returning: $0) }
    }
    for task in tasks {
      guard task.state == .running || task.state == .suspended,
            let desc = task.taskDescription,
            let data = desc.data(using: .utf8),
            let meta = try? JSONDecoder().decode(CassetteTransferMetadata.self, from: data)
      else { continue }
      if meta.cassetteLocalId == cassetteLocalId { return true }
    }
    return false
  }

  // MARK: - Background events (called from AppDelegate)

  public func handleBackgroundEvents(completionHandler: @escaping () -> Void) {
    backgroundCompletionHandler = completionHandler
  }
}

// MARK: - URLSessionDownloadDelegate

extension CassetteTransferSession: URLSessionDownloadDelegate {
  public func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    guard let desc = downloadTask.taskDescription,
          let data = desc.data(using: .utf8),
          let meta = try? JSONDecoder().decode(CassetteTransferMetadata.self, from: data)
    else {
      print("Cassette transfer: download finished with no/invalid metadata")
      os_log("download finished with no/invalid metadata", log: self.log, type: .error)
      return
    }
    print("Cassette transfer: download finished for \(meta.cassetteLocalId), moving into place")

    // The temp file at `location` is only valid synchronously here — move it
    // into place immediately.
    do {
      try fileStorage.moveTempFile(
        location,
        to: meta.cassetteLocalId,
        extension: meta.ext
      )
    } catch {
      os_log(
        "failed to move temp file for %{public}@: %{public}@",
        log: self.log,
        type: .error,
        meta.cassetteLocalId,
        error.localizedDescription
      )
      clearInFlight(meta.cassetteLocalId)
      return
    }

    // Record ownership + report inventory off the delegate queue.
    Task { @MainActor in
      await self.recordAndReport(meta)
    }
  }

  public func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    guard let desc = task.taskDescription,
          let data = desc.data(using: .utf8),
          let meta = try? JSONDecoder().decode(CassetteTransferMetadata.self, from: data)
    else { return }
    if let error {
      os_log(
        "download failed for %{public}@: %{public}@",
        log: self.log,
        type: .error,
        meta.cassetteLocalId,
        error.localizedDescription
      )
      clearInFlight(meta.cassetteLocalId)
    }
  }

  public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    DispatchQueue.main.async {
      let handler = self.backgroundCompletionHandler
      self.backgroundCompletionHandler = nil
      handler?()
    }
  }

  @MainActor
  private func recordAndReport(_ meta: CassetteTransferMetadata) async {
    let context = AmperKit.shared.storage.main.context
    let manager = DeviceOwnershipManager(context: context)
    do {
      try manager.record(
        cassetteLocalId: meta.cassetteLocalId,
        mbid: meta.mbid,
        subsonicTrackId: meta.subsonicTrackId,
        fileExtension: meta.ext
      )
      print("Cassette transfer: recorded ownership for \(meta.cassetteLocalId)")
    } catch {
      os_log(
        "failed to record ownership for %{public}@: %{public}@",
        log: self.log,
        type: .error,
        meta.cassetteLocalId,
        error.localizedDescription
      )
    }

    let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
    let deviceLabel = UIDevice.current.name
    do {
      try await syncAPI.reportDeviceInventory(
        deviceId: deviceId,
        deviceLabel: deviceLabel,
        added: [(cassetteLocalId: meta.cassetteLocalId, mbid: meta.mbid, downloadedAt: Date())],
        removed: []
      )
      print("Cassette transfer: reported inventory addition for \(meta.cassetteLocalId)")
    } catch {
      os_log(
        "failed to report inventory for %{public}@: %{public}@",
        log: self.log,
        type: .error,
        meta.cassetteLocalId,
        error.localizedDescription
      )
    }

    clearInFlight(meta.cassetteLocalId)
  }

  private func clearInFlight(_ cassetteLocalId: String) {
    inFlightLock.lock()
    inFlightLocalIds.remove(cassetteLocalId)
    inFlightLock.unlock()
  }
}
