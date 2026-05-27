//
//  HomeSection.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 26.11.25.
//  Copyright (c) 2025 Maximilian Bauer. All rights reserved.
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

public enum HomeSection: Int, Sendable, CaseIterable, Codable {
  // add new section always at the end to keep the Int consitent
  case lastTimePlayedPlaylists
  case recentlyPlayedAlbums
  case newestAlbums
  case randomAlbums
  case newestPodcastEpisodes
  case podcasts
  case radios
  case randomArtists
  case randomGenres
  case randomSongs
  // cassette Patch 035: three-shelf IA. New cases appended so the
  // raw-Int ordinals of the legacy cases stay stable — any persisted
  // `accountSettings.homeSections` data continues to Codable-decode.
  // Only `editableSections` is surfaced to the editor going forward.
  case resume
  case yourPlaylists
  case recentlyAdded
  // cassette Patch 038: fourth shelf — artists ordered by recent
  // song play activity. Appended (ordinal 13) for Codable backwards-
  // compat; surfaced in defaultValue/editableSections between
  // resume and yourPlaylists.
  case recentlyPlayedArtists

  public static let defaultValue: [HomeSection] = [
    .resume,
    .recentlyPlayedArtists,
    .yourPlaylists,
    .recentlyAdded,
  ]

  /// cassette Patch 035: the sections the home-editor UI is allowed
  /// to surface. Keeps legacy enum cases reachable for Codable
  /// backwards-compat without letting users resurrect the old
  /// random/podcast/radio carousels.
  public static let editableSections: [HomeSection] = [
    .resume,
    .recentlyPlayedArtists,
    .yourPlaylists,
    .recentlyAdded,
  ]

  public var title: String {
    switch self {
    case .recentlyPlayedAlbums: return "Recently Played Albums"
    case .newestAlbums: return "Newest Albums"
    case .randomAlbums: return "Random Albums"
    case .lastTimePlayedPlaylists: return "Recently Played Playlists"
    case .newestPodcastEpisodes: return "Newest Podcast Episodes"
    case .podcasts: return "Podcasts"
    case .radios: return "Radios"
    case .randomArtists: return "Random Artists"
    case .randomGenres: return "Random Genres"
    case .randomSongs: return "Random Songs"
    case .resume: return "Resume"
    case .yourPlaylists: return "Your Playlists"
    case .recentlyAdded: return "Recently Added"
    case .recentlyPlayedArtists: return "Artists"
    }
  }

  public static func create(fromTitle: String) -> HomeSection? {
    allCases.first(where: { $0.title == fromTitle })
  }

  public var isRandomSection: Bool {
    switch self {
    case .recentlyPlayedAlbums: return false
    case .newestAlbums: return false
    case .randomAlbums: return true
    case .lastTimePlayedPlaylists: return false
    case .newestPodcastEpisodes: return false
    case .podcasts: return false
    case .radios: return false
    case .randomArtists: return true
    case .randomGenres: return true
    case .randomSongs: return true
    case .resume: return false
    case .yourPlaylists: return false
    case .recentlyAdded: return false
    case .recentlyPlayedArtists: return false
    }
  }
}
