//
//  DeviceOwnershipManager.swift
//  AmperfyKit
//
//  Cassette fork — Layer 3 Phase 3.1 (Transfer Mechanism).
//
//  CRUD over DeviceOwnershipMO — the authoritative record of which owned
//  files live on this phone. Standalone from Amperfy's cache and from the
//  library views (Phase 3.2 wires visibility/playback).
//
//  All work is wrapped in `context.performAndWait` so the manager is safe
//  to call from the background URLSession delegate queue as well as the
//  main actor. Pass the context captured on the main actor
//  (AmperKit.shared.storage.main.context).
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

public final class DeviceOwnershipManager {
  private let log = OSLog(subsystem: "Amperfy", category: "DeviceOwnershipManager")
  private let context: NSManagedObjectContext
  private let fileStorage: CassetteFileStorage

  public init(
    context: NSManagedObjectContext,
    fileStorage: CassetteFileStorage = .shared
  ) {
    self.context = context
    self.fileStorage = fileStorage
  }

  /// Insert or update the ownership record for a downloaded track. The file
  /// is expected to already be in place (CassetteFileStorage.moveTempFile).
  @discardableResult
  public func record(
    cassetteLocalId: String,
    mbid: String?,
    subsonicTrackId: String?,
    fileExtension: String,
    downloadedAt: Date = Date()
  ) throws
    -> NSManagedObjectID {
    var resultID: NSManagedObjectID!
    var caught: Error?
    context.performAndWait {
      do {
        let existing = try fetchOneInternal(cassetteLocalId: cassetteLocalId)
        let ownership = existing ?? DeviceOwnershipMO(context: context)
        ownership.cassetteLocalId = cassetteLocalId
        ownership.mbid = mbid
        ownership.subsonicTrackId = subsonicTrackId
        ownership.filePath = "\(cassetteLocalId).\(fileExtension)"
        ownership.downloadedAt = downloadedAt
        ownership.fileSizeBytes = fileStorage.fileSize(
          for: cassetteLocalId,
          extension: fileExtension
        )
        try context.save()
        resultID = ownership.objectID
      } catch {
        caught = error
      }
    }
    if let caught { throw caught }
    return resultID
  }

  /// Delete the ownership record and its backing file. Idempotent.
  public func remove(cassetteLocalId: String) throws {
    var caught: Error?
    context.performAndWait {
      do {
        guard let existing = try fetchOneInternal(cassetteLocalId: cassetteLocalId)
        else { return }
        let ext = (existing.filePath as NSString).pathExtension
        try fileStorage.delete(cassetteLocalId: cassetteLocalId, extension: ext)
        context.delete(existing)
        try context.save()
      } catch {
        caught = error
      }
    }
    if let caught { throw caught }
  }

  public func fetchOne(cassetteLocalId: String) throws -> DeviceOwnershipMO? {
    var result: DeviceOwnershipMO?
    var caught: Error?
    context.performAndWait {
      do { result = try fetchOneInternal(cassetteLocalId: cassetteLocalId) }
      catch { caught = error }
    }
    if let caught { throw caught }
    return result
  }

  public func fetchAll() throws -> [DeviceOwnershipMO] {
    var result: [DeviceOwnershipMO] = []
    var caught: Error?
    context.performAndWait {
      let request: NSFetchRequest<DeviceOwnershipMO> = DeviceOwnershipMO.fetchRequest()
      request.sortDescriptors = [
        NSSortDescriptor(key: "downloadedAt", ascending: false),
      ]
      do { result = try context.fetch(request) }
      catch { caught = error }
    }
    if let caught { throw caught }
    return result
  }

  /// Plain-value snapshot of every owned item — safe to hand to the sync layer
  /// off the Core Data queue (no managed objects escape the context). This is
  /// the device's COMPLETE owned-set, the basis of the full-state inventory
  /// report. `downloadedAt` is carried so a full report preserves the real
  /// download time instead of letting the server default it to "now".
  /// `cassetteLocalId` is coerced through String? so this compiles whatever
  /// nullability Core Data codegen gives the (model-non-optional) attribute.
  public func fetchAllInventory() throws
    -> [(cassetteLocalId: String, mbid: String?, downloadedAt: Date)] {
    var result: [(cassetteLocalId: String, mbid: String?, downloadedAt: Date)] = []
    var caught: Error?
    context.performAndWait {
      let request: NSFetchRequest<DeviceOwnershipMO> = DeviceOwnershipMO.fetchRequest()
      do {
        result = try context.fetch(request).compactMap {
          mo -> (cassetteLocalId: String, mbid: String?, downloadedAt: Date)? in
          let lid: String? = mo.cassetteLocalId
          guard let lid, !lid.isEmpty else { return nil }
          let mbid: String? = mo.mbid
          let downloadedAt: Date? = mo.downloadedAt
          return (cassetteLocalId: lid, mbid: mbid, downloadedAt: downloadedAt ?? Date())
        }
      } catch { caught = error }
    }
    if let caught { throw caught }
    return result
  }

  public func exists(cassetteLocalId: String) -> Bool {
    ((try? fetchOne(cassetteLocalId: cassetteLocalId)) ?? nil) != nil
  }

  /// Fast, tight-predicate lookup by Subsonic track id. The `subsonicTrackId`
  /// attribute is fetch-indexed (v51), so this is cheap enough for the
  /// playback-dispatch hot path. Returns nil if no row matches.
  public func fetchOne(subsonicTrackId: String) throws -> DeviceOwnershipMO? {
    var result: DeviceOwnershipMO?
    var caught: Error?
    context.performAndWait {
      let request: NSFetchRequest<DeviceOwnershipMO> = DeviceOwnershipMO.fetchRequest()
      request.predicate = NSPredicate(format: "subsonicTrackId == %@", subsonicTrackId)
      request.fetchLimit = 1
      do { result = try context.fetch(request).first }
      catch { caught = error }
    }
    if let caught { throw caught }
    return result
  }

  /// Resolve the on-disk owned-file URL for a Subsonic track id, or nil if the
  /// track isn't owned (or the row is stale). Fully defensive — never throws —
  /// so it is safe to call inline at playback dispatch: any failure simply
  /// falls back to Amperfy's existing cache/stream behavior.
  public func localFileURL(forSubsonicTrackId id: String) -> URL? {
    guard !id.isEmpty, let row = try? fetchOne(subsonicTrackId: id) else { return nil }
    let url = fileStorage.musicDirectory().appendingPathComponent(row.filePath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      // Stale ownership row: recorded but the backing file is gone. Fall back
      // to streaming rather than handing the player a missing file.
      os_log(
        "owned row for %{public}@ has no file on disk (%{public}@) — falling back",
        log: self.log,
        type: .error,
        id,
        row.filePath
      )
      return nil
    }
    return url
  }

  // MARK: - Library-filter id sets (Phase 3.2)

  /// All owned Subsonic track ids — the predicate set for on-device-only Song
  /// surfaces. `SongMO.id` equals `DeviceOwnership.subsonicTrackId`.
  public func fetchAllSubsonicTrackIds() -> Set<String> {
    var result = Set<String>()
    context.performAndWait { result = ownedSubsonicTrackIdsInternal() }
    return result
  }

  /// Ids of albums that have at least one owned track (for the Albums list /
  /// Artist-detail album list filter).
  public func fetchOwnedAlbumIds() -> Set<String> {
    var result = Set<String>()
    context.performAndWait {
      for song in ownedSongsInternal() {
        if let id = song.album?.id, !id.isEmpty { result.insert(id) }
      }
    }
    return result
  }

  /// Ids of artists that have at least one owned track (for the Artists list).
  public func fetchOwnedArtistIds() -> Set<String> {
    var result = Set<String>()
    context.performAndWait {
      for song in ownedSongsInternal() {
        if let id = song.artist?.id, !id.isEmpty { result.insert(id) }
      }
    }
    return result
  }

  // MARK: - Internal (must be called inside context.perform*)

  private func ownedSubsonicTrackIdsInternal() -> Set<String> {
    let request: NSFetchRequest<DeviceOwnershipMO> = DeviceOwnershipMO.fetchRequest()
    request.predicate = NSPredicate(format: "subsonicTrackId != nil")
    var ids = Set<String>()
    if let rows = try? context.fetch(request) {
      for row in rows {
        if let sid = row.subsonicTrackId, !sid.isEmpty { ids.insert(sid) }
      }
    }
    return ids
  }

  private func ownedSongsInternal() -> [SongMO] {
    let ids = ownedSubsonicTrackIdsInternal()
    guard !ids.isEmpty else { return [] }
    let request: NSFetchRequest<SongMO> = SongMO.fetchRequest()
    request.predicate = NSPredicate(format: "id IN %@", ids)
    request.relationshipKeyPathsForPrefetching = [
      #keyPath(SongMO.album),
      #keyPath(SongMO.artist),
    ]
    request.returnsObjectsAsFaults = false
    return (try? context.fetch(request)) ?? []
  }

  private func fetchOneInternal(cassetteLocalId: String) throws -> DeviceOwnershipMO? {
    let request: NSFetchRequest<DeviceOwnershipMO> = DeviceOwnershipMO.fetchRequest()
    request.predicate = NSPredicate(format: "cassetteLocalId == %@", cassetteLocalId)
    request.fetchLimit = 1
    return try context.fetch(request).first
  }
}
