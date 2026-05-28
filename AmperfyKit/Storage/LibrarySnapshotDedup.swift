//
//  LibrarySnapshotDedup.swift
//  AmperfyKit
//
//  cassette Patch 059: render-time guardrail for duplicate ArtistMO/AlbumMO ids.

import CoreData
import Foundation
import UIKit

public enum LibrarySnapshotDedup {
  public static func suppressingDuplicateServerIds(
    snapshot: NSDiffableDataSourceSnapshot<Int, NSManagedObjectID>,
    context: NSManagedObjectContext
  ) -> NSDiffableDataSourceSnapshot<Int, NSManagedObjectID> {
    var result = NSDiffableDataSourceSnapshot<Int, NSManagedObjectID>()
    for section in snapshot.sectionIdentifiers {
      result.appendSections([section])
      let items = snapshot.itemIdentifiers(inSection: section)
      result.appendItems(
        deduplicateObjectIDs(items, context: context),
        toSection: section
      )
    }
    return result
  }

  private static func deduplicateObjectIDs(
    _ items: [NSManagedObjectID],
    context: NSManagedObjectContext
  ) -> [NSManagedObjectID] {
    var winnersById = [String: NSManagedObjectID]()
    for objectID in items {
      guard let serverId = serverId(for: objectID, context: context), !serverId.isEmpty else {
        continue
      }
      if let existing = winnersById[serverId] {
        winnersById[serverId] = preferredObjectID(existing, objectID, context: context)
      } else {
        winnersById[serverId] = objectID
      }
    }

    var emitted = Set<NSManagedObjectID>()
    var result = [NSManagedObjectID]()
    for objectID in items {
      guard let serverId = serverId(for: objectID, context: context) else {
        if !emitted.contains(objectID) {
          result.append(objectID)
          emitted.insert(objectID)
        }
        continue
      }
      if serverId.isEmpty {
        if !emitted.contains(objectID) {
          result.append(objectID)
          emitted.insert(objectID)
        }
        continue
      }
      guard winnersById[serverId] == objectID, !emitted.contains(objectID) else { continue }
      result.append(objectID)
      emitted.insert(objectID)
    }
    return result
  }

  private static func serverId(
    for objectID: NSManagedObjectID,
    context: NSManagedObjectContext
  ) -> String? {
    guard let object = try? context.existingObject(with: objectID) else { return nil }
    if let artistMO = object as? ArtistMO { return artistMO.id }
    if let albumMO = object as? AlbumMO { return albumMO.id }
    return nil
  }

  private static func preferredObjectID(
    _ first: NSManagedObjectID,
    _ second: NSManagedObjectID,
    context: NSManagedObjectContext
  ) -> NSManagedObjectID {
    let firstScore = richnessScore(for: first, context: context)
    let secondScore = richnessScore(for: second, context: context)
    if firstScore == secondScore { return first }
    return firstScore > secondScore ? first : second
  }

  private static func richnessScore(
    for objectID: NSManagedObjectID,
    context: NSManagedObjectContext
  ) -> Int {
    guard let object = try? context.existingObject(with: objectID) else { return 0 }
    if let artistMO = object as? ArtistMO {
      let artist = Artist(managedObject: artistMO)
      var score = artist.songCount
      if artist.artwork != nil { score += 1_000 }
      return score
    }
    if let albumMO = object as? AlbumMO {
      let album = Album(managedObject: albumMO)
      var score = album.songs.count
      if album.isSongsMetaDataSynced { score += 1_000 }
      if album.artwork != nil { score += 100 }
      return score
    }
    return 0
  }
}
