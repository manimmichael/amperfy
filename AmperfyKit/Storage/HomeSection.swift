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
  // cassette Patch 042: heterogeneous "Recent" shelf merging recently-
  // played albums, playlists, artists, and freshly-added albums into
  // one row sorted by interaction date. Appended (ordinal 14) so
  // legacy `accountSettings.homeSections` Codable payloads keep
  // decoding; .resume left in the enum but no longer rendered.
  case recent
  // cassette (Forgotten Albums): owned albums the user has drifted from — the
  // anti-recency shelf. Appended (ordinal 15) so legacy Codable `homeSections`
  // payloads keep decoding.
  case forgottenAlbums

  // cassette: the six Mood tiles (Get Pumped, Focus, ...) — a HEADER-ONLY
  // section (zero HomeItems; see HomeVC's supplementary-view handling for
  // .moodDoors). A mood door isn't a PlayableContainable — it's a static
  // preset that generates a mixtape on tap, not a real library entity — so
  // it deliberately does NOT flow through the HomeItem/diffable-snapshot
  // pipeline the way every other shelf does. Appended (ordinal 16) per this
  // enum's own append-only Codable-compat rule.
  case moodDoors

  // cassette 2026-10-20: two rows from the phone's own play log (AmperfyKit/Home/
  // ListeningShelves.swift). Appended (ordinals 17, 18) per the append-only rule.
  case onRepeat
  case aroundNow
  // cassette 2026-10-20: albums on the phone matching the mood of recent listening.
  // Ordinal 19. Takes the Albums row's place on Home when it has anything to show.
  case moreLikeLately
  // cassette 2026-10-21: records you heard a song or two of lately (mostly from the
  // made-for-you playlists), a nudge to go deeper. Ordinal 20. Took over the one idea in
  // Recent that no other row carried.
  case fromYourMixes
  // cassette 2026-10-26: Put something on (founder: "its own row under Resume"). One tile per
  // thing a person might be doing, answered by their own playlist or a live station
  // (AmperfyKit/Cassette/PutSomethingOn.swift). Header-only like .moodDoors. Ordinal 21.
  case putSomethingOn

  // cassette redesign (Surface 4): Resume leads the Home IA again - a
  // single full-width card sourced from the lastPlayedDate FRCs.
  //
  // phone-taste (approved phone mock, 2026-10-20): the mock's rows come straight under
  // Resume, in the mock's order: ON REPEAT, the time-of-day row, MOOD, MORE LIKE. The
  // rows the mock does not draw stay below them until the founder decides on them.
  // CarPlay keeps its own list (CarPlayHomeTabExtension.carPlayHomeSections).
  public static let defaultValue: [HomeSection] = [
    .resume,
    // cassette 2026-10-26: one tap to something that fits what you are doing.
    .putSomethingOn,
    // cassette 2026-10-20: what you are into now, and what you play at this time.
    .onRepeat,
    .aroundNow,
    // phone-taste: the approved mock puts Mood right after the time-of-day row (it
    // used to sit below Playlists).
    .moodDoors,
    // cassette 2026-10-21: Recent left Home (founder): On Repeat is the way back to what
    // you have been playing, Resume holds the last thing, the Playlists and Artists rows
    // carry the playlists and artists you played. Its one new idea, records you heard a
    // song or two of, is this row. CarPlay keeps its Recent list.
    .fromYourMixes,
    .moreLikeLately,
    // cassette: "Albums" is the from-your-collection shelf (`.forgottenAlbums`,
    // retitled). It sits right after More Like Lately so it fills that slot whenever
    // More Like is empty (HomeManager clears Albums while More Like has rows). The old
    // played->newest "Albums" row (`.recentlyAdded`) is retired from Home.
    .forgottenAlbums,
    // cassette 2026-10-13: the dial on Home - stations ranked by what you
    // listen to and what you own (HomeManager.updateRadios).
    .radios,
    .yourPlaylists,
    .recentlyPlayedArtists,
  ]

  /// cassette Patch 035: the sections the home-editor UI is allowed
  /// to surface. Keeps legacy enum cases reachable for Codable
  /// backwards-compat without letting users resurrect the old
  /// random/podcast/radio carousels.
  public static let editableSections: [HomeSection] = [
    .recent,
    .yourPlaylists,
    .forgottenAlbums,
    .recentlyPlayedArtists,
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
    // cassette Patch 042: shelf retitle. Enum case names stay so
    // Codable decoding of legacy AccountSetting payloads doesn't
    // break; only the user-facing title changes.
    case .yourPlaylists: return "Playlists"
    case .recentlyAdded: return "Recently Added Albums" // retired from Home; retitled to avoid a duplicate "Albums"
    case .recentlyPlayedArtists: return "Artists"
    case .recent: return "Recent"
    case .forgottenAlbums: return "Albums" // the from-your-collection / anti-recency shelf, surfaced as "Albums"
    case .moodDoors: return "Mood" // accessibility fallback only — MoodDoorsHeaderView owns the visible header
    case .onRepeat: return "On Repeat"
    case .aroundNow: return ListeningShelves.aroundNowTitle(now: Date())
    case .moreLikeLately: return "More Like Lately"
    case .fromYourMixes: return "From Your Mixes"
    case .putSomethingOn: return "Put Something On"
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
    case .recent: return false
    case .forgottenAlbums: return false
    case .moodDoors: return false
    case .onRepeat: return false
    case .aroundNow: return false
    case .moreLikeLately: return false
    case .fromYourMixes: return false
    case .putSomethingOn: return false
    }
  }
}
