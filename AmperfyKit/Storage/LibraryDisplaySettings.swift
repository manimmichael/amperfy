//
//  LibraryDisplaySettings.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 14.09.22.
//  Copyright (c) 2022 Maximilian Bauer. All rights reserved.
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

import Foundation
import UIKit

// MARK: - LibraryDisplayType

// cassette Patch 039: Codable conformance added so AccountSetting
// can persist a `lastLibraryCategory: LibraryDisplayType` directly.
// Raw-value Int encoding is forward-compatible with new cases
// because LibraryDisplayType(rawValue:) returns nil for unknown
// values — `AccountSetting` then falls back to `.artists` via the
// stored-property default.
@MainActor
public enum LibraryDisplayType: Int, CaseIterable, Sendable, Codable {
  case artists = 0
  case albums = 1
  case songs = 2
  case genres = 3
  case directories = 4
  case playlists = 5
  case podcasts = 6
  case downloads = 7
  case favoriteSongs = 8
  case favoriteAlbums = 9
  case favoriteArtists = 10
  // case recentSongs = 11 not used anymore
  case newestAlbums = 12
  case recentAlbums = 13
  case radios = 14

  public static func createByDisplayName(name: String) -> LibraryDisplayType? {
    .allCases.first {
      $0.displayName == name
    }
  }

  public var displayName: String {
    switch self {
    case .artists:
      return "Artists"
    case .albums:
      return "Albums"
    case .songs:
      return "Songs"
    case .genres:
      return "Genres"
    case .directories:
      return "Directories"
    case .playlists:
      return "Playlists"
    case .podcasts:
      return "Podcasts"
    case .downloads:
      return "Downloads"
    case .favoriteSongs:
      return "Favorite Songs"
    case .favoriteAlbums:
      return "Favorite Albums"
    case .favoriteArtists:
      return "Favorite Artists"
    case .newestAlbums:
      return "Newest Albums"
    case .recentAlbums:
      return "Recently Played Albums"
    case .radios:
      return "Radios"
    }
  }

  public var image: UIImage {
    switch self {
    case .artists:
      return UIImage.artist
    case .albums:
      return UIImage.album
    case .songs:
      return UIImage.musicalNotes
    case .genres:
      return UIImage.genre
    case .directories:
      return UIImage.folder
    case .playlists:
      return UIImage.playlist
    case .podcasts:
      return UIImage.podcast
    case .downloads:
      return UIImage.download
    case .favoriteSongs:
      return UIImage.heartFill
    case .favoriteAlbums:
      return UIImage.heartFill
    case .favoriteArtists:
      return UIImage.heartFill
    case .newestAlbums:
      return UIImage.albumNewest
    case .recentAlbums:
      return UIImage.albumRecent
    case .radios:
      return UIImage.radio
    }
  }

  // cassette (CarPlay Lucide): the in-car counterpart of `image`. CarPlay renders
  // outline Lucide glyphs (matching the web) instead of the phone's SF Symbols;
  // any type without a Lucide glyph falls back to its SF symbol.
  public var carPlayGlyphImage: UIImage {
    switch self {
    case .albums, .newestAlbums, .recentAlbums:
      return UIImage.lucideAlbums
    case .artists:
      return UIImage.lucideArtists
    case .songs:
      return UIImage.lucideSongs
    case .playlists:
      return UIImage.lucidePlaylists
    case .genres:
      return UIImage.lucideGenres
    case .radios:
      return UIImage.lucideRadio
    case .directories, .downloads, .favoriteAlbums,
         .favoriteArtists, .favoriteSongs, .podcasts:
      return image
    }
  }

  // cassette Patch 053 (Phase H): outline counterpart for tab bar selection
  // state. Most LibraryDisplayType icons are already outline-only SF Symbols
  // or custom assets (square.stack, music.note, music.mic, dot.radiowaves,
  // music.note.list, podcast asset, album_newest/_recent assets), so they
  // serve as their own outlineImage. The ones with a real fill/outline
  // pair flip: heart.fill -> heart, folder.fill -> folder, guitars.fill ->
  // guitars, arrow.down.circle -> arrow.down.circle. Tab bar selected
  // tabs use `image` (filled where it exists), inactive use `outlineImage`.
  public var outlineImage: UIImage {
    switch self {
    case .favoriteAlbums, .favoriteArtists, .favoriteSongs:
      return UIImage.heartOutline
    case .directories:
      return UIImage.folderOutline
    case .genres:
      return UIImage.guitarsOutline
    case .downloads:
      return UIImage.downloadOutline
    case .albums, .artists, .newestAlbums, .playlists, .podcasts,
         .radios, .recentAlbums, .songs:
      return image
    }
  }
}

// MARK: - LibraryDisplaySettings

public struct LibraryDisplaySettings: Sendable, Codable {
  public var combined: [[LibraryDisplayType]]

  // cassette: Podcasts is hidden as a browse surface app-wide. Filtering it
  // out of BOTH `inUse` and `notUsed` (the only lists the iOS tab bar, the
  // Mac/iPad sidebar, and the Edit/reorder picker read from) hard-hides it
  // from the active library AND the picker, without touching the persisted
  // `combined` storage — so podcast playback/data stay intact and a future
  // re-enable is a one-line revert. `LibraryContainerVC.dropdownCategories`
  // (the mobile dropdown) is filtered separately since it's a fixed list.
  //
  // cassette (favorites rip-out): the three Favorite browse surfaces
  // (Favorite Songs / Albums / Artists) are hidden here too. The
  // LibraryDisplayType enum cases + segue factories are kept (Codable +
  // exhaustive switches); this hard-hides them from every non-CarPlay browse
  // surface. Re-enable is a one-line revert.
  private static let hiddenBrowseTypes: Set<LibraryDisplayType> = [
    .podcasts,
    .directories,
    .favoriteSongs,
    .favoriteAlbums,
    .favoriteArtists,
  ]

  public var inUse: [LibraryDisplayType] {
    combined[0].filter { !Self.hiddenBrowseTypes.contains($0) }
  }

  public var notUsed: [LibraryDisplayType] {
    combined[1].filter { !Self.hiddenBrowseTypes.contains($0) }
  }

  private enum CodingKeys: String, CodingKey {
    case combined
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    let encodedCombined = combined.map { $0.map { $0.rawValue } }
    try container.encode(encodedCombined, forKey: .combined)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedCombined = try container.decode([[Int]].self, forKey: .combined)

    let mapped: [[LibraryDisplayType]] = decodedCombined.map { group in
      group.compactMap { LibraryDisplayType(rawValue: $0) }
    }

    if mapped.count == 2 {
      self.combined = mapped
    } else if let first = mapped.first {
      // If only one group present, treat it as inUse and compute notUsed
      self = LibraryDisplaySettings(inUse: first)
    } else {
      // Fallback to defaults if decoding produced no valid entries
      self = LibraryDisplaySettings(inUse: [])
    }
  }

  public func isVisible(libraryType: LibraryDisplayType) -> Bool {
    inUse.contains(where: { $0 == libraryType })
  }

  public init(inUse: [LibraryDisplayType]) {
    let notUsedSet = Set(LibraryDisplayType.allCases).subtracting(Set(inUse))
    self.combined = [inUse, Array(notUsedSet).sorted(by: { $0.rawValue < $1.rawValue })]
  }

  public static var defaultSettings: LibraryDisplaySettings {
    LibraryDisplaySettings(
      inUse: [
        .artists,
        .albums,
        .newestAlbums,
        .recentAlbums,
        .songs,
        // cassette: favorites removed — Favorite Songs no longer seeded.
        .directories,
        .playlists,
        // cassette: Podcasts intentionally omitted — hidden as a browse
        // surface (also filtered out of inUse/notUsed accessors above).
        .radios,
      ]
    )
  }

  public static var addToPlaylistSettings: LibraryDisplaySettings {
    LibraryDisplaySettings(
      inUse: [
        .genres,
        .artists,
        .albums,
        .newestAlbums,
        .recentAlbums,
        .songs,
        // cassette: favorites removed — Favorite Artists/Albums/Songs no
        // longer seeded into the add-to-playlist picker.
        .directories,
        .playlists,
      ]
    )
  }
}
