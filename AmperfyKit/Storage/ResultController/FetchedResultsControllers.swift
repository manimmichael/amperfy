//
//  FetchedResultsControllers.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 16.04.21.
//  Copyright (c) 2021 Maximilian Bauer. All rights reserved.
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

// MARK: - CassetteOwnedScope

/// Which owned-id set a library FRC should constrain itself to in
/// on-device-only mode. `id` on Song/Album/Artist managed objects is the
/// Subsonic id, so each predicate is a simple `id IN <ownedSet>`.
enum CassetteOwnedScope {
  case song
  case album
  case artist
  case genre
}

/// Returns the ownership predicate to AND into a library FRC, or nil when the
/// library filter is Server Mode (everything). An empty owned set yields a
/// predicate that matches nothing, which is the correct on-device-only result
/// when nothing has been transferred yet.
func makeCassetteOwnershipPredicate(
  _ scope: CassetteOwnedScope,
  coreDataCompanion: CoreDataCompanion
)
  -> NSPredicate? {
  guard CassetteLibraryFilterProvider.shared.isOnDeviceOnly else { return nil }
  let manager = DeviceOwnershipManager(context: coreDataCompanion.context)
  let ids: Set<String>
  switch scope {
  case .song:
    ids = manager.fetchAllSubsonicTrackIds()
  case .album:
    ids = manager.fetchOwnedAlbumIds()
  case .artist:
    ids = manager.fetchOwnedArtistIds()
  case .genre:
    ids = manager.fetchOwnedGenreIds()
  }
  return NSPredicate(format: "id IN %@", ids)
}

// MARK: - CassetteOnPhoneIds

/// What is on this phone, as the Subsonic ids of its songs and of their albums and artists,
/// read in one pass (phone-taste: a genre page's three lists share one read instead of each
/// fetching every owned song with its relationships on the main thread).
public struct CassetteOnPhoneIds: Sendable {
  public let songs: Set<String>
  public let albums: Set<String>
  public let artists: Set<String>

  /// The ids of what is on this phone, or nil in Server Mode (no narrowing). One fetch of
  /// the ownership rows, then one fetch of the distinct album and artist ids of those songs
  /// (dictionary results, so no song is materialised). Falls back to the ownership
  /// manager's own reads if that fetch fails.
  public static func read(coreDataCompanion: CoreDataCompanion) -> CassetteOnPhoneIds? {
    guard CassetteLibraryFilterProvider.shared.isOnDeviceOnly else { return nil }
    let context = coreDataCompanion.context
    let manager = DeviceOwnershipManager(context: context)
    let songs = manager.fetchAllSubsonicTrackIds()
    guard !songs.isEmpty else { return CassetteOnPhoneIds(songs: [], albums: [], artists: []) }
    var rows: [NSDictionary]?
    context.performAndWait {
      let request = NSFetchRequest<NSDictionary>(entityName: "Song")
      request.resultType = .dictionaryResultType
      request.predicate = NSPredicate(format: "id IN %@", songs)
      request.propertiesToFetch = [
        Self.keyPathDescription("albumId", keyPath: "album.id"),
        Self.keyPathDescription("artistId", keyPath: "artist.id"),
      ]
      request.returnsDistinctResults = true
      rows = try? context.fetch(request)
    }
    guard let rows else {
      return CassetteOnPhoneIds(
        songs: songs,
        albums: manager.fetchOwnedAlbumIds(),
        artists: manager.fetchOwnedArtistIds()
      )
    }
    var albums = Set<String>()
    var artists = Set<String>()
    for row in rows {
      if let id = row["albumId"] as? String, !id.isEmpty { albums.insert(id) }
      if let id = row["artistId"] as? String, !id.isEmpty { artists.insert(id) }
    }
    return CassetteOnPhoneIds(songs: songs, albums: albums, artists: artists)
  }

  private static func keyPathDescription(_ name: String, keyPath: String) -> NSExpressionDescription {
    let description = NSExpressionDescription()
    description.name = name
    description.expression = NSExpression(forKeyPath: keyPath)
    description.expressionResultType = .stringAttributeType
    return description
  }

  func predicate(_ scope: CassetteOwnedScope) -> NSPredicate {
    switch scope {
    case .song: return NSPredicate(format: "id IN %@", songs)
    case .album: return NSPredicate(format: "id IN %@", albums)
    case .artist: return NSPredicate(format: "id IN %@", artists)
    case .genre: return NSPredicate(value: false)
    }
  }
}

// MARK: - CassetteOnPhoneSource

/// How a genre-page list learns what is on the phone (phone-taste).
public enum CassetteOnPhoneSource: Sendable {
  /// Read it when the list is built (the default, for a list on its own).
  case readNow
  /// Ids the page already read once for all of its lists; nil in Server Mode.
  case shared(CassetteOnPhoneIds?)

  /// The predicate to AND into the list, or nil in Server Mode.
  func predicate(_ scope: CassetteOwnedScope, coreDataCompanion: CoreDataCompanion) -> NSPredicate? {
    switch self {
    case .readNow:
      // Songs need only the ownership rows; albums and artists take the one-pass read.
      if scope == .song || scope == .genre {
        return makeCassetteOwnershipPredicate(scope, coreDataCompanion: coreDataCompanion)
      }
      return CassetteOnPhoneIds.read(coreDataCompanion: coreDataCompanion)?.predicate(scope)
    case let .shared(ids):
      return ids?.predicate(scope)
    }
  }
}

// MARK: - ArtistElementSortType

public enum ArtistElementSortType: Int, Sendable, Codable {
  case name = 0
  case rating = 1
  case newest = 2
  case duration = 3

  public static let defaultValue: ArtistElementSortType = .name

  public var asSectionIndexType: SectionIndexType {
    switch self {
    case .name:
      return .alphabet
    case .rating:
      return .rating
    case .newest:
      return .newestOrRecent
    case .duration:
      return .durationArtist
    }
  }
}

// MARK: - AlbumElementSortType

public enum AlbumElementSortType: Int, Sendable, Codable {
  case name = 0
  case rating = 1
  case newest = 2
  case artist = 3
  case duration = 4
  case year = 5
  case recent = 6

  public static let defaultValue: AlbumElementSortType = .name

  public var asSectionIndexType: SectionIndexType {
    switch self {
    case .name:
      return .alphabet
    case .rating:
      return .rating
    case .newest:
      return .newestOrRecent
    case .artist:
      return .alphabet
    case .duration:
      return .durationAlbum
    case .year:
      return .year
    case .recent:
      return .newestOrRecent
    }
  }
}

// MARK: - PlaylistSortType

public enum PlaylistSortType: Int, Sendable, Codable {
  case name = 0
  case lastPlayed = 1
  case lastChanged = 2
  case duration = 3

  static let defaultValue: PlaylistSortType = .name

  public var asSectionIndexType: SectionIndexType {
    switch self {
    case .name:
      return .alphabet
    case .lastPlayed:
      return .none
    case .lastChanged:
      return .none
    case .duration:
      return .none
    }
  }
}

// MARK: - SongElementSortType

public enum SongElementSortType: Int, Sendable, Codable {
  case name = 0
  case rating = 1
  case addedDate = 2
  case duration = 3
  case starredDate = 4
  // cassette Patch 038: feeds the Home "Artists" shelf via
  // SongsFetchedResultsController + a bounded fetchLimit. New case
  // appended to keep existing Codable persistence stable.
  case lastPlayedDate = 5
  // cassette Home Shelves v1: most-played songs first. Drives the
  // affinity / all-time ordering and the backfill source for the Home
  // album & artist shelves (deduped by container in HomeManager). New
  // case appended to keep existing Codable persistence stable.
  case playCount = 6

  public static let defaultValue: SongElementSortType = .name
  public static let defaultValueForFavorite: SongElementSortType = .starredDate

  public var asSectionIndexType: SectionIndexType {
    switch self {
    case .name:
      return .alphabet
    case .rating:
      return .rating
    case .addedDate:
      return .newestOrRecent
    case .duration:
      return .durationSong
    case .starredDate:
      return .none
    case .lastPlayedDate:
      return .none
    case .playCount:
      return .none
    }
  }

  public var hasSectionTitles: Bool {
    switch self {
    case .name:
      return true
    case .rating:
      return true
    case .addedDate:
      return false
    case .duration:
      return true
    case .starredDate:
      return false
    case .lastPlayedDate:
      return false
    case .playCount:
      return false
    }
  }
}

// MARK: - DisplayCategoryFilter

public enum DisplayCategoryFilter: Codable {
  case all
  case newest
  case recent
  case favorites
}

// MARK: - ArtistCategoryFilter

public enum ArtistCategoryFilter: Int, Sendable, Codable {
  case all = 0
  case favorites = 1
  case albumArtists = 2

  public static let defaultValue: ArtistCategoryFilter = .albumArtists
}

// MARK: - AlbumsDisplayStyle

public enum AlbumsDisplayStyle: Int, Sendable, Codable {
  case table = 0
  case grid = 1

  public static let defaultValue: AlbumsDisplayStyle = .grid
}

// MARK: - PodcastFetchedResultsController

public class PodcastFetchedResultsController: CachedFetchedResultsController<PodcastMO> {
  public init(
    coreDataCompanion: CoreDataCompanion,
    account: Account,
    isGroupedInAlphabeticSections: Bool
  ) {
    let fetchRequest = PodcastMO.alphabeticSortedFetchRequest
    fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      coreDataCompanion.library.getFetchPredicate(forAccount: account),
      NSCompoundPredicate(orPredicateWithSubpredicates: [
        AbstractLibraryEntityMO.excludeRemoteDeleteFetchPredicate,
        coreDataCompanion.library.getFetchPredicate(onlyCachedPodcasts: true),
      ]),
    ])
    fetchRequest.relationshipKeyPathsForPrefetching = PodcastMO.relationshipKeyPathsForPrefetching
    fetchRequest.returnsObjectsAsFaults = false
    super.init(
      coreDataCompanion: coreDataCompanion,
      fetchRequest: fetchRequest, account: account,
      isGroupedInAlphabeticSections: isGroupedInAlphabeticSections
    )
  }

  public func search(searchText: String, onlyCached: Bool) {
    if !searchText.isEmpty || onlyCached {
      let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        coreDataCompanion.library.getFetchPredicate(forAccount: account),
        NSCompoundPredicate(orPredicateWithSubpredicates: [
          AbstractLibraryEntityMO.excludeRemoteDeleteFetchPredicate,
          coreDataCompanion.library.getFetchPredicate(onlyCachedPodcasts: true),
        ]),
        PodcastMO.getIdentifierBasedSearchPredicate(searchText: searchText),
        coreDataCompanion.library.getFetchPredicate(onlyCachedPodcasts: onlyCached),
      ])
      search(predicate: predicate)
    } else {
      showAllResults()
    }
  }
}

// MARK: - PodcastEpisodesReleaseDateFetchedResultsController

public class PodcastEpisodesReleaseDateFetchedResultsController: BasicFetchedResultsController<
  PodcastEpisodeMO
> {
  let account: Account

  public init(
    coreDataCompanion: CoreDataCompanion,
    account: Account,
    isGroupedInAlphabeticSections: Bool,
    fetchLimit: Int? = nil
  ) {
    self.account = account
    let fetchRequest = PodcastEpisodeMO.publishedDateSortedFetchRequest
    fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      coreDataCompanion.library.getFetchPredicate(forAccount: account),
      coreDataCompanion.library.getFetchPredicateForUserAvailableEpisodes(),
    ])
    fetchRequest.relationshipKeyPathsForPrefetching = PodcastEpisodeMO
      .relationshipKeyPathsForPrefetching
    fetchRequest.returnsObjectsAsFaults = false
    fetchRequest.fetchLimit = fetchLimit ?? 0
    super.init(
      coreDataCompanion: coreDataCompanion,
      fetchRequest: fetchRequest,
      isGroupedInAlphabeticSections: isGroupedInAlphabeticSections
    )
  }

  public func search(searchText: String, onlyCachedSongs: Bool) {
    if !searchText.isEmpty || onlyCachedSongs {
      let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        coreDataCompanion.library.getFetchPredicate(forAccount: account),
        coreDataCompanion.library.getFetchPredicateForUserAvailableEpisodes(),
        PodcastEpisodeMO.getIdentifierBasedSearchPredicate(searchText: searchText),
        coreDataCompanion.library.getFetchPredicate(onlyCachedPodcastEpisodes: onlyCachedSongs),
      ])
      search(predicate: predicate)
    } else {
      showAllResults()
    }
  }
}

// MARK: - PodcastEpisodesFetchedResultsController

public class PodcastEpisodesFetchedResultsController: BasicFetchedResultsController<
  PodcastEpisodeMO
> {
  public let podcast: Podcast

  public init(
    forPodcast podcast: Podcast,
    coreDataCompanion: CoreDataCompanion,
    isGroupedInAlphabeticSections: Bool
  ) {
    self.podcast = podcast
    let fetchRequest = PodcastEpisodeMO.publishedDateSortedFetchRequest
    fetchRequest.predicate = coreDataCompanion.library
      .getFetchPredicateForUserAvailableEpisodes(forPodcast: podcast)
    fetchRequest.relationshipKeyPathsForPrefetching = PodcastEpisodeMO
      .relationshipKeyPathsForPrefetching
    fetchRequest.returnsObjectsAsFaults = false
    super.init(
      coreDataCompanion: coreDataCompanion,
      fetchRequest: fetchRequest,
      isGroupedInAlphabeticSections: isGroupedInAlphabeticSections
    )
  }

  public func search(searchText: String, onlyCachedSongs: Bool) {
    if !searchText.isEmpty || onlyCachedSongs {
      let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        coreDataCompanion.library.getFetchPredicateForUserAvailableEpisodes(forPodcast: podcast),
        PodcastEpisodeMO.getIdentifierBasedSearchPredicate(searchText: searchText),
        coreDataCompanion.library.getFetchPredicate(onlyCachedPodcastEpisodes: onlyCachedSongs),
      ])
      search(predicate: predicate)
    } else {
      showAllResults()
    }
  }
}

// MARK: - GenreFetchedResultsController

public class GenreFetchedResultsController: CachedFetchedResultsController<GenreMO> {
  public init(
    coreDataCompanion: CoreDataCompanion,
    account: Account,
    isGroupedInAlphabeticSections: Bool
  ) {
    let fetchRequest = GenreMO.alphabeticSortedFetchRequest
    fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      coreDataCompanion.library.getFetchPredicate(forAccount: account),
    ])
    // Cassette fork — Layer 3 Phase 3.2: constrain to owned genres in
    // on-device-only mode (nil/no-op in Server Mode).
    let cassetteOwned = makeCassetteOwnershipPredicate(.genre, coreDataCompanion: coreDataCompanion)
    if let cassetteOwned, let base = fetchRequest.predicate {
      fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        base,
        cassetteOwned,
      ])
    }
    fetchRequest.relationshipKeyPathsForPrefetching = GenreMO.relationshipKeyPathsForPrefetching
    fetchRequest.returnsObjectsAsFaults = false
    super.init(
      coreDataCompanion: coreDataCompanion,
      fetchRequest: fetchRequest, account: account,
      isGroupedInAlphabeticSections: isGroupedInAlphabeticSections
    )
    cassetteOwnershipPredicate = cassetteOwned
  }

  public func search(searchText: String, onlyCached: Bool) {
    if !searchText.isEmpty || onlyCached {
      let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        coreDataCompanion.library.getFetchPredicate(forAccount: account),
        GenreMO.getIdentifierBasedSearchPredicate(searchText: searchText),
        NSCompoundPredicate(orPredicateWithSubpredicates: [
          coreDataCompanion.library.getFetchPredicate(onlyCachedGenreArtists: onlyCached),
          coreDataCompanion.library.getFetchPredicate(onlyCachedGenreAlbums: onlyCached),
          coreDataCompanion.library.getFetchPredicate(onlyCachedGenreSongs: onlyCached),
        ]),
      ])
      search(predicate: predicate)
    } else {
      showAllResults()
    }
  }
}

// MARK: - GenreArtistsFetchedResultsController

public class GenreArtistsFetchedResultsController: BasicFetchedResultsController<ArtistMO> {
  let genre: Genre
  /// The on-phone ownership predicate (phone-taste), ANDed into the init and search
  /// predicates; nil in Server Mode.
  private let onPhonePredicate: NSPredicate?

  /// `onPhone`: what is on the phone, read here by default; a page that builds all three
  /// genre lists reads it once and shares it (`.shared`).
  public init(
    for genre: Genre,
    coreDataCompanion: CoreDataCompanion,
    isGroupedInAlphabeticSections: Bool,
    onPhone onPhoneSource: CassetteOnPhoneSource = .readNow
  ) {
    self.genre = genre
    // phone-taste: on the phone, only the artists on it (nil, so no change, in Server Mode).
    let onPhone = onPhoneSource.predicate(.artist, coreDataCompanion: coreDataCompanion)
    self.onPhonePredicate = onPhone
    let fetchRequest = ArtistMO.alphabeticSortedFetchRequest
    fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      NSCompoundPredicate(orPredicateWithSubpredicates: [
        AbstractLibraryEntityMO.excludeRemoteDeleteFetchPredicate,
        coreDataCompanion.library.getFetchPredicate(onlyCachedArtists: true),
      ]),
      coreDataCompanion.library.getFetchPredicate(forGenre: genre),
    ] + [onPhone].compactMap { $0 })
    fetchRequest.relationshipKeyPathsForPrefetching = ArtistMO.relationshipKeyPathsForPrefetching
    fetchRequest.returnsObjectsAsFaults = false
    super.init(
      coreDataCompanion: coreDataCompanion,
      fetchRequest: fetchRequest,
      isGroupedInAlphabeticSections: isGroupedInAlphabeticSections
    )
  }

  public func search(searchText: String, onlyCached: Bool) {
    if !searchText.isEmpty || onlyCached {
      let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        NSCompoundPredicate(orPredicateWithSubpredicates: [
          AbstractLibraryEntityMO.excludeRemoteDeleteFetchPredicate,
          coreDataCompanion.library.getFetchPredicate(onlyCachedArtists: true),
        ]),
        coreDataCompanion.library.getFetchPredicate(forGenre: genre),
        coreDataCompanion.library.getFetchPredicate(onlyCachedArtists: onlyCached),
        ArtistMO.getIdentifierBasedSearchPredicate(searchText: searchText),
      ] + [onPhonePredicate].compactMap { $0 })
      search(predicate: predicate)
    } else {
      showAllResults()
    }
  }
}

// MARK: - GenreAlbumsFetchedResultsController

public class GenreAlbumsFetchedResultsController: BasicFetchedResultsController<AlbumMO> {
  let genre: Genre
  /// The on-phone ownership predicate (phone-taste), ANDed into the init and search
  /// predicates; nil in Server Mode.
  private let onPhonePredicate: NSPredicate?

  /// `onPhone`: what is on the phone, read here by default; a page that builds all three
  /// genre lists reads it once and shares it (`.shared`).
  public init(
    for genre: Genre,
    coreDataCompanion: CoreDataCompanion,
    isGroupedInAlphabeticSections: Bool,
    onPhone onPhoneSource: CassetteOnPhoneSource = .readNow
  ) {
    self.genre = genre
    // phone-taste: on the phone, only the albums on it (nil, so no change, in Server Mode).
    let onPhone = onPhoneSource.predicate(.album, coreDataCompanion: coreDataCompanion)
    self.onPhonePredicate = onPhone
    let fetchRequest = AlbumMO.alphabeticSortedFetchRequest
    fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      NSCompoundPredicate(orPredicateWithSubpredicates: [
        AbstractLibraryEntityMO.excludeRemoteDeleteFetchPredicate,
        coreDataCompanion.library.getFetchPredicate(onlyCachedAlbums: true),
      ]),
      coreDataCompanion.library.getFetchPredicate(forGenre: genre),
    ] + [onPhone].compactMap { $0 })
    fetchRequest.relationshipKeyPathsForPrefetching = AlbumMO.relationshipKeyPathsForPrefetching
    fetchRequest.returnsObjectsAsFaults = false
    super.init(
      coreDataCompanion: coreDataCompanion,
      fetchRequest: fetchRequest,
      isGroupedInAlphabeticSections: isGroupedInAlphabeticSections
    )
  }

  public func search(searchText: String, onlyCached: Bool) {
    if !searchText.isEmpty || onlyCached {
      let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        NSCompoundPredicate(orPredicateWithSubpredicates: [
          AbstractLibraryEntityMO.excludeRemoteDeleteFetchPredicate,
          coreDataCompanion.library.getFetchPredicate(onlyCachedAlbums: true),
        ]),
        coreDataCompanion.library.getFetchPredicate(forGenre: genre),
        coreDataCompanion.library.getFetchPredicate(onlyCachedAlbums: onlyCached),
        ArtistMO.getIdentifierBasedSearchPredicate(searchText: searchText),
      ] + [onPhonePredicate].compactMap { $0 })
      search(predicate: predicate)
    } else {
      showAllResults()
    }
  }
}

// MARK: - GenreSongsFetchedResultsController

public class GenreSongsFetchedResultsController: BasicFetchedResultsController<SongMO> {
  let genre: Genre
  /// The on-phone ownership predicate (phone-taste), ANDed into the init and search
  /// predicates; nil in Server Mode.
  private let onPhonePredicate: NSPredicate?

  /// `onPhone`: what is on the phone, read here by default; a page that builds all three
  /// genre lists reads it once and shares it (`.shared`).
  public init(
    for genre: Genre,
    coreDataCompanion: CoreDataCompanion,
    isGroupedInAlphabeticSections: Bool,
    onPhone onPhoneSource: CassetteOnPhoneSource = .readNow
  ) {
    self.genre = genre
    // phone-taste: on the phone, only the songs on it (nil, so no change, in Server Mode).
    // Play-all and song-row playback follow, since getContextSongs reads this predicate.
    let onPhone = onPhoneSource.predicate(.song, coreDataCompanion: coreDataCompanion)
    self.onPhonePredicate = onPhone
    let fetchRequest = SongMO.alphabeticSortedFetchRequest
    fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      SongMO.excludeServerDeleteUncachedSongsFetchPredicate,
      coreDataCompanion.library.getFetchPredicate(forGenre: genre),
    ] + [onPhone].compactMap { $0 })
    fetchRequest.relationshipKeyPathsForPrefetching = SongMO.relationshipKeyPathsForPrefetching
    fetchRequest.returnsObjectsAsFaults = false
    super.init(
      coreDataCompanion: coreDataCompanion,
      fetchRequest: fetchRequest,
      isGroupedInAlphabeticSections: isGroupedInAlphabeticSections
    )
  }

  public func search(searchText: String, onlyCachedSongs: Bool) {
    if !searchText.isEmpty || onlyCachedSongs {
      let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        SongMO.excludeServerDeleteUncachedSongsFetchPredicate,
        coreDataCompanion.library.getFetchPredicate(forGenre: genre),
        SongMO.getIdentifierBasedSearchPredicate(searchText: searchText),
        coreDataCompanion.library.getFetchPredicate(onlyCachedSongs: onlyCachedSongs),
      ] + [onPhonePredicate].compactMap { $0 })
      search(predicate: predicate)
    } else {
      showAllResults()
    }
  }
}

// MARK: - ArtistFetchedResultsController

public class ArtistFetchedResultsController: CachedFetchedResultsController<ArtistMO> {
  public private(set) var sortType: ArtistElementSortType

  public init(
    coreDataCompanion: CoreDataCompanion,
    account: Account,
    sortType: ArtistElementSortType,
    isGroupedInAlphabeticSections: Bool,
    fetchLimit: Int? = nil
  ) {
    self.sortType = sortType
    var fetchRequest = ArtistMO.alphabeticSortedFetchRequest
    switch sortType {
    case .name:
      fetchRequest = ArtistMO.alphabeticSortedFetchRequest
    case .rating:
      fetchRequest = ArtistMO.ratingSortedFetchRequest
    case .newest:
      // artist currently does not support recentlyAdded
      fetchRequest = ArtistMO.identifierSortedFetchRequest
    case .duration:
      fetchRequest = ArtistMO.durationSortedFetchRequest
    }
    fetchRequest.fetchLimit = fetchLimit ?? 0
    fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      coreDataCompanion.library.getFetchPredicate(forAccount: account),
      NSCompoundPredicate(orPredicateWithSubpredicates: [
        AbstractLibraryEntityMO.excludeRemoteDeleteFetchPredicate,
        coreDataCompanion.library.getFetchPredicate(onlyCachedArtists: true),
      ]),
    ])
    // Cassette fork — Layer 3 Phase 3.2: constrain to owned artists in
    // on-device-only mode (nil/no-op in Server Mode).
    let cassetteOwned = makeCassetteOwnershipPredicate(
      .artist,
      coreDataCompanion: coreDataCompanion
    )
    if let cassetteOwned, let base = fetchRequest.predicate {
      fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        base,
        cassetteOwned,
      ])
    }
    fetchRequest.relationshipKeyPathsForPrefetching = ArtistMO.relationshipKeyPathsForPrefetching
    fetchRequest.returnsObjectsAsFaults = false
    super.init(
      coreDataCompanion: coreDataCompanion,
      fetchRequest: fetchRequest,
      account: account,
      sectionIndexType: sortType.asSectionIndexType,
      isGroupedInAlphabeticSections: isGroupedInAlphabeticSections
    )
    cassetteOwnershipPredicate = cassetteOwned
  }

  public func search(searchText: String, onlyCached: Bool, displayFilter: ArtistCategoryFilter) {
    if !searchText.isEmpty || onlyCached || displayFilter != .all {
      let predicate = coreDataCompanion.library.getSearchArtistsPredicate(
        for: account,
        searchText: searchText,
        onlyCached: onlyCached,
        displayFilter: displayFilter
      )
      search(predicate: predicate)
    } else {
      showAllResults()
    }
  }
}

// MARK: - ArtistAlbumsItemsFetchedResultsController

public class ArtistAlbumsItemsFetchedResultsController: BasicFetchedResultsController<AlbumMO> {
  let artist: Artist

  public init(
    for artist: Artist,
    coreDataCompanion: CoreDataCompanion,
    isGroupedInAlphabeticSections: Bool
  ) {
    self.artist = artist
    let fetchRequest = AlbumMO.releaseYearSortedFetchRequest
    fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      NSCompoundPredicate(orPredicateWithSubpredicates: [
        AbstractLibraryEntityMO.excludeRemoteDeleteFetchPredicate,
        coreDataCompanion.library.getFetchPredicate(onlyCachedAlbums: true),
      ]),
      NSCompoundPredicate(orPredicateWithSubpredicates: [
        coreDataCompanion.library.getFetchPredicate(forArtist: artist),
        AlbumMO.getFetchPredicateForAlbumsWhoseSongsHave(artist: artist),
      ]),
    ])
    // Cassette fork — Layer 3 Phase 3.2: constrain the artist's album list to
    // owned albums in on-device-only mode (nil/no-op in Server Mode).
    let cassetteOwned = makeCassetteOwnershipPredicate(.album, coreDataCompanion: coreDataCompanion)
    if let cassetteOwned, let base = fetchRequest.predicate {
      fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        base,
        cassetteOwned,
      ])
    }
    fetchRequest.relationshipKeyPathsForPrefetching = AlbumMO.relationshipKeyPathsForPrefetching
    fetchRequest.returnsObjectsAsFaults = false
    super.init(
      coreDataCompanion: coreDataCompanion,
      fetchRequest: fetchRequest,
      isGroupedInAlphabeticSections: isGroupedInAlphabeticSections
    )
    cassetteOwnershipPredicate = cassetteOwned
  }

  public func search(searchText: String, onlyCached: Bool) {
    if !searchText.isEmpty || onlyCached {
      let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        NSCompoundPredicate(orPredicateWithSubpredicates: [
          AbstractLibraryEntityMO.excludeRemoteDeleteFetchPredicate,
          coreDataCompanion.library.getFetchPredicate(onlyCachedAlbums: true),
        ]),
        NSCompoundPredicate(orPredicateWithSubpredicates: [
          coreDataCompanion.library.getFetchPredicate(forArtist: artist),
          AlbumMO.getFetchPredicateForAlbumsWhoseSongsHave(artist: artist),
        ]),
        coreDataCompanion.library.getFetchPredicate(onlyCachedAlbums: onlyCached),
        ArtistMO.getIdentifierBasedSearchPredicate(searchText: searchText),
      ])
      search(predicate: predicate)
    } else {
      showAllResults()
    }
  }
}

// MARK: - ArtistSongsItemsFetchedResultsController

public class ArtistSongsItemsFetchedResultsController: BasicFetchedResultsController<SongMO> {
  let artist: Artist
  let displayFilter: ArtistCategoryFilter

  public init(
    for artist: Artist,
    displayFilter: ArtistCategoryFilter,
    coreDataCompanion: CoreDataCompanion,
    isGroupedInAlphabeticSections: Bool,
    sortByPlayCount: Bool = false
  ) {
    self.artist = artist
    self.displayFilter = displayFilter
    let fetchRequest = SongMO.alphabeticSortedFetchRequest
    // cassette Patch 104: the artist detail "Popular" section sorts by play
    // count (most played first) with the alphabetical descriptors kept as
    // the tie-break fallback. Other callers (e.g. playlist-add) keep the
    // plain alphabetical order.
    if sortByPlayCount {
      fetchRequest.sortDescriptors = [
        NSSortDescriptor(key: #keyPath(SongMO.playCount), ascending: false),
      ] + (fetchRequest.sortDescriptors ?? [])
    }
    switch self.displayFilter {
    case .all, .favorites:
      fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        SongMO.excludeServerDeleteUncachedSongsFetchPredicate,
        coreDataCompanion.library.getFetchPredicate(forArtist: artist),
      ])
    case .albumArtists:
      fetchRequest.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
        NSCompoundPredicate(andPredicateWithSubpredicates: [
          SongMO.excludeServerDeleteUncachedSongsFetchPredicate,
          coreDataCompanion.library.getFetchPredicate(forArtist: artist),
        ]),
        NSCompoundPredicate(andPredicateWithSubpredicates: [
          SongMO.excludeServerDeleteUncachedSongsFetchPredicate,
          coreDataCompanion.library.getFetchPredicate(forSongsOfArtistWithCommonAlbum: artist),
        ]),
      ])
    }
    // Cassette fork — Layer 3 Phase 3.2: constrain the artist-detail song list to
    // owned tracks in on-device-only mode (nil/no-op in Server Mode).
    let cassetteOwned = makeCassetteOwnershipPredicate(.song, coreDataCompanion: coreDataCompanion)
    if let cassetteOwned, let base = fetchRequest.predicate {
      fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        base,
        cassetteOwned,
      ])
    }
    fetchRequest.relationshipKeyPathsForPrefetching = SongMO.relationshipKeyPathsForPrefetching
    fetchRequest.returnsObjectsAsFaults = false

    super.init(
      coreDataCompanion: coreDataCompanion,
      fetchRequest: fetchRequest,
      isGroupedInAlphabeticSections: isGroupedInAlphabeticSections
    )
    cassetteOwnershipPredicate = cassetteOwned
  }

  public func search(searchText: String, onlyCachedSongs: Bool) {
    if !searchText.isEmpty || onlyCachedSongs {
      var predicate = NSCompoundPredicate()
      switch displayFilter {
      case .all, .favorites:
        predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
          SongMO.excludeServerDeleteUncachedSongsFetchPredicate,
          coreDataCompanion.library.getFetchPredicate(forArtist: artist),
          SongMO.getIdentifierBasedSearchPredicate(searchText: searchText),
          coreDataCompanion.library.getFetchPredicate(onlyCachedSongs: onlyCachedSongs),
        ])
      case .albumArtists:
        predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
          NSCompoundPredicate(andPredicateWithSubpredicates: [
            SongMO.excludeServerDeleteUncachedSongsFetchPredicate,
            coreDataCompanion.library.getFetchPredicate(forArtist: artist),
            SongMO.getIdentifierBasedSearchPredicate(searchText: searchText),
            coreDataCompanion.library.getFetchPredicate(onlyCachedSongs: onlyCachedSongs),
          ]),
          NSCompoundPredicate(andPredicateWithSubpredicates: [
            SongMO.excludeServerDeleteUncachedSongsFetchPredicate,
            coreDataCompanion.library.getFetchPredicate(forSongsOfArtistWithCommonAlbum: artist),
            SongMO.getIdentifierBasedSearchPredicate(searchText: searchText),
            coreDataCompanion.library.getFetchPredicate(onlyCachedSongs: onlyCachedSongs),
          ]),
        ])
      }
      search(predicate: predicate)
    } else {
      showAllResults()
    }
  }
}

// MARK: - AlbumFetchedResultsController

public class AlbumFetchedResultsController: CachedFetchedResultsController<AlbumMO> {
  public private(set) var sortType: AlbumElementSortType

  public init(
    coreDataCompanion: CoreDataCompanion,
    account: Account,
    sortType: AlbumElementSortType,
    isGroupedInAlphabeticSections: Bool,
    fetchLimit: Int? = nil
  ) {
    self.sortType = sortType
    var fetchRequest = AlbumMO.alphabeticSortedFetchRequest
    switch sortType {
    case .name:
      fetchRequest = AlbumMO.alphabeticSortedFetchRequest
    case .rating:
      fetchRequest = AlbumMO.ratingSortedFetchRequest
    case .newest:
      fetchRequest = AlbumMO.newestSortedFetchRequest
    case .recent:
      fetchRequest = AlbumMO.recentSortedFetchRequest
    case .artist:
      fetchRequest = AlbumMO.artistNameSortedFetchRequest
    case .duration:
      fetchRequest = AlbumMO.durationSortedFetchRequest
    case .year:
      fetchRequest = AlbumMO.yearSortedFetchRequest
    }
    fetchRequest.fetchLimit = fetchLimit ?? 0
    fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      coreDataCompanion.library.getFetchPredicate(forAccount: account),
      NSCompoundPredicate(orPredicateWithSubpredicates: [
        AbstractLibraryEntityMO.excludeRemoteDeleteFetchPredicate,
        coreDataCompanion.library.getFetchPredicate(onlyCachedAlbums: true),
      ]),
    ])
    // Cassette fork — Layer 3 Phase 3.2: constrain to owned albums in
    // on-device-only mode (nil/no-op in Server Mode).
    let cassetteOwned = makeCassetteOwnershipPredicate(.album, coreDataCompanion: coreDataCompanion)
    if let cassetteOwned, let base = fetchRequest.predicate {
      fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        base,
        cassetteOwned,
      ])
    }
    fetchRequest.relationshipKeyPathsForPrefetching = AlbumMO.relationshipKeyPathsForPrefetching
    fetchRequest.returnsObjectsAsFaults = false
    super.init(
      coreDataCompanion: coreDataCompanion,
      fetchRequest: fetchRequest, account: account,
      sectionIndexType: sortType.asSectionIndexType,
      isGroupedInAlphabeticSections: isGroupedInAlphabeticSections
    )
    cassetteOwnershipPredicate = cassetteOwned
  }

  public func search(searchText: String, onlyCached: Bool, displayFilter: DisplayCategoryFilter) {
    if !searchText.isEmpty || onlyCached || displayFilter != .all {
      let predicate = coreDataCompanion.library.getSearchAlbumsPredicate(
        for: account,
        searchText: searchText,
        onlyCached: onlyCached,
        displayFilter: displayFilter
      )
      search(predicate: predicate)
    } else {
      showAllResults()
    }
  }
}

// MARK: - SongsFetchedResultsController

public class SongsFetchedResultsController: CachedFetchedResultsController<SongMO> {
  public private(set) var sortType: SongElementSortType

  public init(
    coreDataCompanion: CoreDataCompanion,
    account: Account,
    sortType: SongElementSortType,
    isGroupedInAlphabeticSections: Bool,
    fetchLimit: Int? = nil
  ) {
    self.sortType = sortType
    var fetchRequest = SongMO.alphabeticSortedFetchRequest
    switch sortType {
    case .name:
      fetchRequest = SongMO.alphabeticSortedFetchRequest
    case .rating:
      fetchRequest = SongMO.ratingSortedFetchRequest
    case .addedDate:
      fetchRequest = SongMO.addedDateSortedFetchRequest
    case .duration:
      fetchRequest = SongMO.durationSortedFetchRequest
    case .starredDate:
      fetchRequest = SongMO.starredDateSortedFetchRequest
    case .lastPlayedDate:
      // cassette Patch 038: feeds the Home Artists shelf; see
      // SongMO.lastPlayedDateSortedFetchRequest.
      fetchRequest = SongMO.lastPlayedDateSortedFetchRequest
    case .playCount:
      // cassette Home Shelves v1: most-played-first affinity source.
      fetchRequest = SongMO.playCountSortedFetchRequest
    }
    fetchRequest.fetchLimit = fetchLimit ?? 0
    fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      coreDataCompanion.library.getFetchPredicate(forAccount: account),
      SongMO.excludeServerDeleteUncachedSongsFetchPredicate,
    ])
    // Cassette fork — Layer 3 Phase 3.2: constrain to owned tracks in
    // on-device-only mode (nil/no-op in Server Mode).
    let cassetteOwned = makeCassetteOwnershipPredicate(.song, coreDataCompanion: coreDataCompanion)
    if let cassetteOwned, let base = fetchRequest.predicate {
      fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        base,
        cassetteOwned,
      ])
    }
    fetchRequest.relationshipKeyPathsForPrefetching = SongMO.relationshipKeyPathsForPrefetching
    fetchRequest.returnsObjectsAsFaults = false
    super.init(
      coreDataCompanion: coreDataCompanion,
      fetchRequest: fetchRequest, account: account,
      sectionIndexType: sortType.asSectionIndexType,
      isGroupedInAlphabeticSections: isGroupedInAlphabeticSections
    )
    cassetteOwnershipPredicate = cassetteOwned
    // CPU load for song VCs is high when background sync is active
    // reduce the CPU load on song VCs by turning updates off for those VCs
    keepAllResultsUpdated = false
  }

  public func search(
    searchText: String,
    onlyCachedSongs: Bool,
    displayFilter: DisplayCategoryFilter
  ) {
    if !searchText.isEmpty || onlyCachedSongs || displayFilter != .all {
      let predicate = coreDataCompanion.library.getSearchSongsPredicate(
        for: account,
        searchText: searchText,
        onlyCached: onlyCachedSongs,
        displayFilter: displayFilter
      )
      search(predicate: predicate)
    } else {
      showAllResults()
    }
  }
}

// MARK: - RadiosFetchedResultsController

public class RadiosFetchedResultsController: CachedFetchedResultsController<RadioMO> {
  public init(
    coreDataCompanion: CoreDataCompanion,
    account: Account,
    isGroupedInAlphabeticSections: Bool,
    fetchLimit: Int? = nil
  ) {
    let fetchRequest = RadioMO.alphabeticSortedFetchRequest
    fetchRequest.fetchLimit = fetchLimit ?? 0
    fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      coreDataCompanion.library.getFetchPredicate(forAccount: account),
      RadioMO.excludeServerDeleteRadiosFetchPredicate,
    ])
    fetchRequest.relationshipKeyPathsForPrefetching = RadioMO.relationshipKeyPathsForPrefetching
    fetchRequest.returnsObjectsAsFaults = false
    super.init(
      coreDataCompanion: coreDataCompanion,
      fetchRequest: fetchRequest, account: account,
      sectionIndexType: .alphabet,
      isGroupedInAlphabeticSections: isGroupedInAlphabeticSections
    )
  }

  public func search(searchText: String) {
    if !searchText.isEmpty {
      let predicate = coreDataCompanion.library.getSearchRadiosPredicate(
        for: account,
        searchText: searchText
      )
      search(predicate: predicate)
    } else {
      showAllResults()
    }
  }
}

// MARK: - AlbumSongsFetchedResultsController

public class AlbumSongsFetchedResultsController: BasicFetchedResultsController<SongMO> {
  let album: Album
  // cassette (UX review 2026-10-20): on the phone an album lists only the songs that
  // are on it; the rest of the album is still on the hub. Nil in Server Mode.
  private let ownedPredicate: NSPredicate?
  /// Every song of the album, on this phone or not. Shown against the listed count
  /// ("8 of 12 songs on this phone") when the two differ.
  public let totalSongCount: Int

  public init(
    forAlbum album: Album,
    coreDataCompanion: CoreDataCompanion,
    isGroupedInAlphabeticSections: Bool
  ) {
    self.album = album
    let basePredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      SongMO.excludeServerDeleteUncachedSongsFetchPredicate,
      coreDataCompanion.library.getFetchPredicate(forAlbum: album),
    ])
    let countRequest = NSFetchRequest<SongMO>(entityName: "Song")
    countRequest.predicate = basePredicate
    self.totalSongCount = (try? coreDataCompanion.context.count(for: countRequest)) ?? 0
    self.ownedPredicate = makeCassetteOwnershipPredicate(.song, coreDataCompanion: coreDataCompanion)
    let fetchRequest = SongMO.trackNumberSortedFetchRequest
    fetchRequest.predicate = NSCompoundPredicate(
      andPredicateWithSubpredicates: [basePredicate] + [ownedPredicate].compactMap { $0 }
    )
    fetchRequest.relationshipKeyPathsForPrefetching = SongMO.relationshipKeyPathsForPrefetching
    fetchRequest.returnsObjectsAsFaults = false
    super.init(
      coreDataCompanion: coreDataCompanion,
      fetchRequest: fetchRequest,
      isGroupedInAlphabeticSections: isGroupedInAlphabeticSections
    )
  }

  public func search(searchText: String, onlyCachedSongs: Bool) {
    if !searchText.isEmpty || onlyCachedSongs {
      let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        SongMO.excludeServerDeleteUncachedSongsFetchPredicate,
        coreDataCompanion.library.getFetchPredicate(forAlbum: album),
        SongMO.getIdentifierBasedSearchPredicate(searchText: searchText),
        coreDataCompanion.library.getFetchPredicate(onlyCachedSongs: onlyCachedSongs),
      ] + [ownedPredicate].compactMap { $0 })
      search(predicate: predicate)
    } else {
      showAllResults()
    }
  }
}

// MARK: - PlaylistItemsFetchedResultsController

public class PlaylistItemsFetchedResultsController: BasicFetchedResultsController<PlaylistItemMO> {
  public let playlist: Playlist
  // cassette (UX review 2026-10-20): on the phone a playlist lists only the songs that
  // are on it. The playlist itself keeps every item. Nil in Server Mode.
  private let ownedPredicate: NSPredicate?
  /// Every item of the playlist, on this phone or not.
  public let totalItemCount: Int

  public init(
    forPlaylist playlist: Playlist,
    coreDataCompanion: CoreDataCompanion,
    isGroupedInAlphabeticSections: Bool
  ) {
    self.playlist = playlist
    let basePredicate = coreDataCompanion.library.getFetchPredicate(forPlaylist: playlist)
    let countRequest = NSFetchRequest<PlaylistItemMO>(entityName: "PlaylistItem")
    countRequest.predicate = basePredicate
    self.totalItemCount = (try? coreDataCompanion.context.count(for: countRequest)) ?? 0
    if CassetteLibraryFilterProvider.shared.isOnDeviceOnly {
      let owned = DeviceOwnershipManager(context: coreDataCompanion.context)
        .fetchAllSubsonicTrackIds()
      self.ownedPredicate = NSPredicate(format: "%K IN %@", #keyPath(PlaylistItemMO.playable.id), owned)
    } else {
      self.ownedPredicate = nil
    }
    let fetchRequest = PlaylistItemMO.playlistOrderSortedFetchRequest
    fetchRequest.predicate = NSCompoundPredicate(
      andPredicateWithSubpredicates: [basePredicate] + [ownedPredicate].compactMap { $0 }
    )
    fetchRequest.relationshipKeyPathsForPrefetching = PlaylistItemMO
      .relationshipKeyPathsForPrefetching
    fetchRequest.returnsObjectsAsFaults = false
    super.init(
      coreDataCompanion: coreDataCompanion,
      fetchRequest: fetchRequest,
      isGroupedInAlphabeticSections: isGroupedInAlphabeticSections
    )
  }

  public func search(onlyCachedSongs: Bool) {
    if onlyCachedSongs {
      let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        coreDataCompanion.library.getFetchPredicate(forPlaylist: playlist),
        coreDataCompanion.library.getFetchPredicate(onlyCachedPlaylistItems: onlyCachedSongs),
      ] + [ownedPredicate].compactMap { $0 })
      search(predicate: predicate)
    } else {
      showAllResults()
    }
  }
}

// MARK: - PlaylistFetchedResultsController

public class PlaylistFetchedResultsController: BasicFetchedResultsController<PlaylistMO> {
  public private(set) var sortType: PlaylistSortType
  private let account: Account

  public init(
    coreDataCompanion: CoreDataCompanion,
    account: Account,
    sortType: PlaylistSortType,
    isGroupedInAlphabeticSections: Bool,
    fetchLimit: Int? = nil
  ) {
    self.account = account
    self.sortType = sortType
    var fetchRequest = PlaylistMO.alphabeticSortedFetchRequest
    switch sortType {
    case .name:
      fetchRequest = PlaylistMO.alphabeticSortedFetchRequest
    case .lastPlayed:
      fetchRequest = PlaylistMO.lastPlayedDateFetchRequest
    case .lastChanged:
      fetchRequest = PlaylistMO.lastChangedDateFetchRequest
    case .duration:
      fetchRequest = PlaylistMO.durationFetchRequest
    }
    fetchRequest.fetchLimit = fetchLimit ?? 0
    fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      coreDataCompanion.library.getFetchPredicate(forAccount: account),
      PlaylistMO.excludeSystemPlaylistsFetchPredicate,
    ])
    fetchRequest.relationshipKeyPathsForPrefetching = PlaylistMO.relationshipKeyPathsForPrefetching
    fetchRequest.returnsObjectsAsFaults = false
    super.init(
      coreDataCompanion: coreDataCompanion,
      fetchRequest: fetchRequest,
      isGroupedInAlphabeticSections: isGroupedInAlphabeticSections
    )
  }

  public func search(searchText: String, playlistSearchCategory: PlaylistSearchCategory) {
    if !searchText.isEmpty || playlistSearchCategory != .defaultValue {
      let predicate = coreDataCompanion.library.getSearchPlaylistsPredicate(
        for: account,
        searchText: searchText,
        playlistSearchCategory: playlistSearchCategory
      )
      search(predicate: predicate)
    } else {
      showAllResults()
    }
  }
}

// MARK: - PlaylistSelectorFetchedResultsController

public class PlaylistSelectorFetchedResultsController: CachedFetchedResultsController<PlaylistMO> {
  var sortType: PlaylistSortType

  public init(
    coreDataCompanion: CoreDataCompanion,
    account: Account,
    sortType: PlaylistSortType,
    isGroupedInAlphabeticSections: Bool
  ) {
    self.sortType = sortType
    var fetchRequest = PlaylistMO.alphabeticSortedFetchRequest
    switch sortType {
    case .name:
      fetchRequest = PlaylistMO.alphabeticSortedFetchRequest
    case .lastPlayed:
      fetchRequest = PlaylistMO.lastPlayedDateFetchRequest
    case .lastChanged:
      fetchRequest = PlaylistMO.lastChangedDateFetchRequest
    case .duration:
      fetchRequest = PlaylistMO.durationFetchRequest
    }
    fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      coreDataCompanion.library.getFetchPredicate(forAccount: account),
      PlaylistMO.excludeSystemPlaylistsFetchPredicate,
      coreDataCompanion.library.getFetchPredicate(forPlaylistSearchCategory: .userOnly),
    ])
    fetchRequest.relationshipKeyPathsForPrefetching = PlaylistMO.relationshipKeyPathsForPrefetching
    fetchRequest.returnsObjectsAsFaults = false
    super.init(
      coreDataCompanion: coreDataCompanion,
      fetchRequest: fetchRequest, account: account,
      isGroupedInAlphabeticSections: isGroupedInAlphabeticSections
    )
  }

  public func search(searchText: String) {
    if !searchText.isEmpty {
      let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        coreDataCompanion.library.getFetchPredicate(forAccount: account),
        PlaylistMO.excludeSystemPlaylistsFetchPredicate,
        PlaylistMO.getIdentifierBasedSearchPredicate(searchText: searchText),
        coreDataCompanion.library.getFetchPredicate(forPlaylistSearchCategory: .userOnly),
      ])
      search(predicate: predicate)
    } else {
      showAllResults()
    }
  }
}

// MARK: - ErrorLogFetchedResultsController

public class ErrorLogFetchedResultsController: BasicFetchedResultsController<LogEntryMO> {
  public init(coreDataCompanion: CoreDataCompanion, isGroupedInAlphabeticSections: Bool) {
    let fetchRequest = LogEntryMO.creationDateSortedFetchRequest
    super.init(
      coreDataCompanion: coreDataCompanion,
      fetchRequest: fetchRequest,
      isGroupedInAlphabeticSections: isGroupedInAlphabeticSections
    )
  }
}

// MARK: - MusicFolderFetchedResultsController

public class MusicFolderFetchedResultsController: CachedFetchedResultsController<MusicFolderMO> {
  public init(
    coreDataCompanion: CoreDataCompanion,
    account: Account,
    isGroupedInAlphabeticSections: Bool
  ) {
    let fetchRequest = MusicFolderMO.idSortedFetchRequest
    fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      coreDataCompanion.library.getFetchPredicate(forAccount: account),
    ])
    fetchRequest.relationshipKeyPathsForPrefetching = MusicFolderMO
      .relationshipKeyPathsForPrefetching
    fetchRequest.returnsObjectsAsFaults = false
    super.init(
      coreDataCompanion: coreDataCompanion,
      fetchRequest: fetchRequest, account: account,
      isGroupedInAlphabeticSections: isGroupedInAlphabeticSections
    )
  }

  public func search(searchText: String) {
    if !searchText.isEmpty {
      let searchPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        coreDataCompanion.library.getFetchPredicate(forAccount: account),
        MusicFolderMO.getSearchPredicate(searchText: searchText),
      ])
      search(predicate: searchPredicate)
    } else {
      showAllResults()
    }
  }
}

// MARK: - MusicFolderDirectoriesFetchedResultsController

public class MusicFolderDirectoriesFetchedResultsController: BasicFetchedResultsController<
  DirectoryMO
> {
  let musicFolder: MusicFolder

  public init(
    for musicFolder: MusicFolder,
    coreDataCompanion: CoreDataCompanion,
    isGroupedInAlphabeticSections: Bool
  ) {
    self.musicFolder = musicFolder
    let fetchRequest = DirectoryMO.alphabeticSortedFetchRequest
    fetchRequest.predicate = coreDataCompanion.library
      .getFetchPredicate(forMusicFolder: musicFolder)
    fetchRequest.relationshipKeyPathsForPrefetching = DirectoryMO.relationshipKeyPathsForPrefetching
    fetchRequest.returnsObjectsAsFaults = false
    super.init(
      coreDataCompanion: coreDataCompanion,
      fetchRequest: fetchRequest,
      isGroupedInAlphabeticSections: isGroupedInAlphabeticSections
    )
  }

  public func search(searchText: String) {
    if !searchText.isEmpty {
      let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        coreDataCompanion.library.getFetchPredicate(forMusicFolder: musicFolder),
        DirectoryMO.getIdentifierBasedSearchPredicate(searchText: searchText),
      ])
      search(predicate: predicate)
    } else {
      showAllResults()
    }
  }
}

// MARK: - DirectorySubdirectoriesFetchedResultsController

public class DirectorySubdirectoriesFetchedResultsController: BasicFetchedResultsController<
  DirectoryMO
> {
  let directory: Directory

  public init(
    for directory: Directory,
    coreDataCompanion: CoreDataCompanion,
    isGroupedInAlphabeticSections: Bool
  ) {
    self.directory = directory
    let fetchRequest = DirectoryMO.alphabeticSortedFetchRequest
    fetchRequest.predicate = coreDataCompanion.library
      .getDirectoryFetchPredicate(forDirectory: directory)
    fetchRequest.relationshipKeyPathsForPrefetching = DirectoryMO.relationshipKeyPathsForPrefetching
    fetchRequest.returnsObjectsAsFaults = false
    super.init(
      coreDataCompanion: coreDataCompanion,
      fetchRequest: fetchRequest,
      isGroupedInAlphabeticSections: isGroupedInAlphabeticSections
    )
  }

  public func search(searchText: String) {
    if !searchText.isEmpty {
      let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        coreDataCompanion.library.getDirectoryFetchPredicate(forDirectory: directory),
        DirectoryMO.getIdentifierBasedSearchPredicate(searchText: searchText),
      ])
      search(predicate: predicate)
    } else {
      showAllResults()
    }
  }
}

// MARK: - DirectorySongsFetchedResultsController

public class DirectorySongsFetchedResultsController: BasicFetchedResultsController<SongMO> {
  let directory: Directory

  public init(
    for directory: Directory,
    coreDataCompanion: CoreDataCompanion,
    isGroupedInAlphabeticSections: Bool
  ) {
    self.directory = directory
    let fetchRequest = SongMO.trackNumberSortedFetchRequest
    fetchRequest.predicate = coreDataCompanion.library
      .getSongFetchPredicate(forDirectory: directory)
    fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      SongMO.excludeServerDeleteUncachedSongsFetchPredicate,
      coreDataCompanion.library.getSongFetchPredicate(forDirectory: directory),
    ])
    fetchRequest.relationshipKeyPathsForPrefetching = SongMO.relationshipKeyPathsForPrefetching
    fetchRequest.returnsObjectsAsFaults = false
    super.init(
      coreDataCompanion: coreDataCompanion,
      fetchRequest: fetchRequest,
      isGroupedInAlphabeticSections: isGroupedInAlphabeticSections
    )
  }

  public func search(searchText: String, onlyCachedSongs: Bool) {
    if !searchText.isEmpty || onlyCachedSongs {
      let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        SongMO.excludeServerDeleteUncachedSongsFetchPredicate,
        coreDataCompanion.library.getSongFetchPredicate(forDirectory: directory),
        SongMO.getIdentifierBasedSearchPredicate(searchText: searchText),
        coreDataCompanion.library.getFetchPredicate(onlyCachedSongs: onlyCachedSongs),
      ])
      search(predicate: predicate)
    } else {
      showAllResults()
    }
  }
}

// MARK: - DownloadsFetchedResultsController

public class DownloadsFetchedResultsController: BasicFetchedResultsController<DownloadMO> {
  let account: Account

  public init(
    coreDataCompanion: CoreDataCompanion,
    account: Account,
    isGroupedInAlphabeticSections: Bool
  ) {
    self.account = account
    let fetchRequest: NSFetchRequest<DownloadMO> = DownloadMO.creationDateSortedFetchRequest
    fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
      coreDataCompanion.library.getFetchPredicate(forAccount: account),
      DownloadMO.onlyPlayablesPredicate,
    ])
    fetchRequest.relationshipKeyPathsForPrefetching = DownloadMO.relationshipKeyPathsForPrefetching
    fetchRequest.returnsObjectsAsFaults = false
    super.init(
      coreDataCompanion: coreDataCompanion,
      fetchRequest: fetchRequest,
      isGroupedInAlphabeticSections: isGroupedInAlphabeticSections
    )
  }
}
