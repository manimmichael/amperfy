//
//  SongMO+CoreDataClass.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 30.12.19.
//  Copyright (c) 2019 Maximilian Bauer. All rights reserved.
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

// MARK: - SongMO

@objc(SongMO)
public final class SongMO: AbstractPlayableMO {}

// MARK: CoreDataIdentifyable

extension SongMO: CoreDataIdentifyable {
  static var identifierKey: KeyPath<SongMO, String?> {
    \SongMO.title
  }

  static var excludeServerDeleteUncachedSongsFetchPredicate: NSPredicate {
    // see also Song Array extension [Song].filterServerDeleteUncachedSongs()
    NSCompoundPredicate(orPredicateWithSubpredicates: [
      NSCompoundPredicate(andPredicateWithSubpredicates: [
        NSPredicate(format: "%K > 0", #keyPath(SongMO.size)),
        NSPredicate(
          format: "%K == %i",
          #keyPath(SongMO.album.remoteStatus),
          RemoteStatus.available.rawValue
        ),
      ]),
      NSPredicate(format: "%K != nil", #keyPath(SongMO.relFilePath)),
    ])
  }

  static var alphabeticSortedFetchRequest: NSFetchRequest<SongMO> {
    let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
    fetchRequest.sortDescriptors = [
      NSSortDescriptor(
        key: #keyPath(SongMO.alphabeticSectionInitial),
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare)
      ),
      NSSortDescriptor(
        key: Self.identifierKeyString,
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare)
      ),
      NSSortDescriptor(
        key: "id",
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare)
      ),
    ]
    return fetchRequest
  }

  static var trackNumberSortedFetchRequest: NSFetchRequest<SongMO> {
    let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
    fetchRequest.sortDescriptors = [
      NSSortDescriptor(
        key: #keyPath(SongMO.disk),
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare)
      ),
      NSSortDescriptor(key: #keyPath(SongMO.track), ascending: true),
      NSSortDescriptor(
        key: Self.identifierKeyString,
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare)
      ),
      NSSortDescriptor(
        key: #keyPath(SongMO.id),
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare)
      ),
    ]
    return fetchRequest
  }

  static var ratingSortedFetchRequest: NSFetchRequest<SongMO> {
    let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
    fetchRequest.sortDescriptors = [
      NSSortDescriptor(key: #keyPath(SongMO.rating), ascending: false),
      NSSortDescriptor(
        key: Self.identifierKeyString,
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare)
      ),
      NSSortDescriptor(
        key: #keyPath(SongMO.id),
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare)
      ),
    ]
    return fetchRequest
  }

  static var durationSortedFetchRequest: NSFetchRequest<SongMO> {
    let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
    fetchRequest.sortDescriptors = [
      NSSortDescriptor(key: #keyPath(SongMO.combinedDuration), ascending: true),
      NSSortDescriptor(
        key: Self.identifierKeyString,
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare)
      ),
      NSSortDescriptor(
        key: #keyPath(SongMO.id),
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare)
      ),
    ]
    return fetchRequest
  }

  static var starredDateSortedFetchRequest: NSFetchRequest<SongMO> {
    let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
    fetchRequest.sortDescriptors = [
      NSSortDescriptor(key: #keyPath(SongMO.starredDate), ascending: false),
      NSSortDescriptor(
        key: Self.identifierKeyString,
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare)
      ),
      NSSortDescriptor(
        key: #keyPath(SongMO.id),
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare)
      ),
    ]
    return fetchRequest
  }

  static var addedDateSortedFetchRequest: NSFetchRequest<SongMO> {
    let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
    fetchRequest.sortDescriptors = [
      NSSortDescriptor(key: #keyPath(SongMO.addedDate), ascending: false),
      NSSortDescriptor(
        key: Self.identifierKeyString,
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare)
      ),
      NSSortDescriptor(
        key: "id",
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare)
      ),
    ]
    return fetchRequest
  }

  // cassette Patch 038: most-recently-played songs first.
  // ArtistMO.lastPlayedDate isn't updated per-song-play in Amperfy
  // (only per-artist-context play), so the Artists shelf walks this
  // sorted song list and dedupes by song.artist. Bounded by
  // fetchLimit at the controller level so we don't pull the whole
  // library into memory.
  static var lastPlayedDateSortedFetchRequest: NSFetchRequest<SongMO> {
    let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
    fetchRequest.sortDescriptors = [
      NSSortDescriptor(key: #keyPath(SongMO.lastPlayedDate), ascending: false),
      NSSortDescriptor(
        key: Self.identifierKeyString,
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare)
      ),
      NSSortDescriptor(
        key: "id",
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare)
      ),
    ]
    return fetchRequest
  }

  // cassette Home Shelves v1: most-played songs first. Deduped by album /
  // artist in HomeManager to rank the Home shelves on maintained play data
  // (the per-song playCount is bumped on the play path; album/artist counts
  // are not). Bounded by fetchLimit at the controller level.
  static var playCountSortedFetchRequest: NSFetchRequest<SongMO> {
    let fetchRequest: NSFetchRequest<SongMO> = SongMO.fetchRequest()
    fetchRequest.sortDescriptors = [
      NSSortDescriptor(key: #keyPath(SongMO.playCount), ascending: false),
      NSSortDescriptor(
        key: Self.identifierKeyString,
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare)
      ),
      NSSortDescriptor(
        key: "id",
        ascending: true,
        selector: #selector(NSString.localizedStandardCompare)
      ),
    ]
    return fetchRequest
  }
}
