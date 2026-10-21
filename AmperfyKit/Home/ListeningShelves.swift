//
//  ListeningShelves.swift
//  AmperfyKit
//
//  Cassette: two Home rows built from the phone's own play log (UX review 2026-10-20).
//  The phone keeps a timestamp for every song played to the end (ScrobbleEntry), which
//  Home never used: it only read each song's last-played date and running count.
//
//   On Repeat         what you are into right now: albums ranked by how often you have
//                     played them in the last two weeks, recent plays counting more.
//   Around This Time  what you tend to play now: albums you play in this part of the day,
//                     on this kind of day (weekday or weekend), over the last two months.
//
//   More Like Lately  albums on the phone you have not played this month whose mood and
//                     energy tags match what you have been playing (replaces the Albums
//                     row, which ignored your current mood).
//   Lately mix        a fresh mix of songs on the phone matching the same profile.
//
//  The mood rows need the catalog's per-song tags (GET /api/sync/library-moods, cached by
//  LibraryMoods). Matching own music is done by comparing tags directly: the catalog's
//  "sounds like" links almost never land inside one person's library (2026-10-20 check:
//  0 to 1 candidates from 20 recent albums), while tag matching gave 22 strong ones.
//
//  Pure ranking, so it is testable without Core Data.
//  Never reads the retired albums.time_of_day concept: habits come only from real plays.
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

public struct ListeningPlay: Sendable, Equatable {
  public let date: Date
  public let albumID: String

  public init(date: Date, albumID: String) {
    self.date = date
    self.albumID = albumID
  }
}

public enum ListeningShelves {
  /// How far back the play log is read for either row.
  public static let lookbackDays = 60

  // On Repeat
  static let onRepeatWindowDays = 14
  static let onRepeatHalfLifeDays = 5.0
  static let onRepeatMinPlays = 3

  // Around This Time
  static let aroundNowHalfLifeDays = 21.0
  static let aroundNowMinPlays = 2

  public enum Daypart: Int, Sendable, CaseIterable {
    case morning, afternoon, evening, late

    public init(hour: Int) {
      switch hour {
      case 5 ... 10: self = .morning
      case 11 ... 16: self = .afternoon
      case 17 ... 21: self = .evening
      default: self = .late
      }
    }

    var name: String {
      switch self {
      case .morning: return "Mornings"
      case .afternoon: return "Afternoons"
      case .evening: return "Evenings"
      case .late: return "Late Nights"
      }
    }
  }

  /// Albums you have played at least three times in the last two weeks, by plays with
  /// recent ones weighted up (a five-day half-life), so a run of listening outranks one
  /// busy afternoon a fortnight ago.
  public static func onRepeat(_ plays: [ListeningPlay], now: Date) -> [String] {
    let since = now.addingTimeInterval(-Double(onRepeatWindowDays) * 86400)
    let recent = plays.filter { $0.date >= since && $0.date <= now }
    return rank(recent, now: now, halfLifeDays: onRepeatHalfLifeDays, minPlays: onRepeatMinPlays)
  }

  /// Albums you play in this part of the day on this kind of day, at least twice in the
  /// last two months, recent habits weighted up (a three-week half-life).
  public static func aroundNow(
    _ plays: [ListeningPlay],
    now: Date,
    calendar: Calendar = .current
  )
    -> [String] {
    let slot = slot(of: now, calendar: calendar)
    let since = now.addingTimeInterval(-Double(lookbackDays) * 86400)
    let matching = plays.filter {
      $0.date >= since && $0.date <= now && Self.slot(of: $0.date, calendar: calendar) == slot
    }
    return rank(matching, now: now, halfLifeDays: aroundNowHalfLifeDays, minPlays: aroundNowMinPlays)
  }

  /// The row's title for this moment: "Weekday Mornings", "Weekend Evenings", ...
  public static func aroundNowTitle(now: Date, calendar: Calendar = .current) -> String {
    let slot = slot(of: now, calendar: calendar)
    return "\(slot.weekend ? "Weekend" : "Weekday") \(slot.daypart.name)"
  }

  // MARK: - Internals

  struct Slot: Equatable {
    let weekend: Bool
    let daypart: Daypart
  }

  static func slot(of date: Date, calendar: Calendar) -> Slot {
    Slot(
      weekend: calendar.isDateInWeekend(date),
      daypart: Daypart(hour: calendar.component(.hour, from: date))
    )
  }

  /// Albums with at least `minPlays` plays, by decayed weight, ties by plain count, then id
  /// so the order is stable.
  static func rank(
    _ plays: [ListeningPlay],
    now: Date,
    halfLifeDays: Double,
    minPlays: Int
  )
    -> [String] {
    var weight: [String: Double] = [:]
    var count: [String: Int] = [:]
    for play in plays {
      let ageDays = max(0, now.timeIntervalSince(play.date) / 86400)
      weight[play.albumID, default: 0] += pow(0.5, ageDays / halfLifeDays)
      count[play.albumID, default: 0] += 1
    }
    return count
      .filter { $0.value >= minPlays }
      .keys
      .sorted { lhs, rhs in
        let lw = weight[lhs] ?? 0, rw = weight[rhs] ?? 0
        if lw != rw { return lw > rw }
        let lc = count[lhs] ?? 0, rc = count[rhs] ?? 0
        if lc != rc { return lc > rc }
        return lhs < rhs
      }
  }

  // MARK: - Mood matching

  /// A song's tags as weighted tokens: each mood counts 1, energy and valence a half.
  public typealias TagVector = [String: Double]

  static let latelyWindowDays = 30
  static let latelyHalfLifeDays = 10.0
  static let moreLikeLatelyMinMatch = 0.6
  static let moreLikeLatelyPerArtist = 2
  static let mixRecentlyPlayedDays = 3
  static let mixPoolSize = 120
  static let mixPerAlbum = 3

  public static func tagVector(moods: [String], energy: String?, valence: String?) -> TagVector {
    var v = TagVector()
    for m in moods { v["mood:\(m)", default: 0] += 1 }
    if let energy, !energy.isEmpty { v["energy:\(energy)", default: 0] += 0.5 }
    if let valence, !valence.isEmpty { v["valence:\(valence)", default: 0] += 0.5 }
    return v
  }

  static func add(_ v: TagVector, into acc: inout TagVector, weight: Double = 1) {
    for (k, x) in v { acc[k, default: 0] += x * weight }
  }

  static func cosine(_ a: TagVector, _ b: TagVector) -> Double {
    var dot = 0.0
    for (k, x) in a { dot += x * (b[k] ?? 0) }
    let na = a.values.reduce(0) { $0 + $1 * $1 }.squareRoot()
    let nb = b.values.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return na > 0 && nb > 0 ? dot / (na * nb) : 0
  }

  /// What you have been playing lately as one weighted tag profile: the last 30 days of
  /// plays, a ten-day half-life. `tagsForSong` returns nil for untagged songs.
  public static func latelyProfile(
    plays: [(date: Date, songID: String)],
    tagsForSong: (String) -> TagVector?,
    now: Date
  )
    -> TagVector {
    let since = now.addingTimeInterval(-Double(latelyWindowDays) * 86400)
    var profile = TagVector()
    for play in plays where play.date >= since && play.date <= now {
      guard let tags = tagsForSong(play.songID) else { continue }
      let ageDays = max(0, now.timeIntervalSince(play.date) / 86400)
      add(tags, into: &profile, weight: pow(0.5, ageDays / latelyHalfLifeDays))
    }
    return profile
  }

  /// The profile's leading moods, for a tile's subtitle: "Wistful · Contemplative".
  public static func describe(_ profile: TagVector, count: Int = 2) -> String {
    profile
      .filter { $0.key.hasPrefix("mood:") }
      .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
      .prefix(count)
      .map { String($0.key.dropFirst(5)).capitalized }
      .joined(separator: " · ")
  }

  public struct AlbumCandidate {
    public let albumID: String
    public let artistID: String
    public let songTags: [TagVector]

    public init(albumID: String, artistID: String, songTags: [TagVector]) {
      self.albumID = albumID
      self.artistID = artistID
      self.songTags = songTags
    }
  }

  /// Albums whose combined song tags match the profile closely (0.6 or better), best first,
  /// at most two per artist, leaving out albums played in the last 30 days.
  public static func moreLikeLately(
    _ albums: [AlbumCandidate],
    profile: TagVector,
    playedRecently: Set<String>
  )
    -> [String] {
    guard !profile.isEmpty else { return [] }
    let scored: [(String, String, Double)] = albums.compactMap { album in
      guard !playedRecently.contains(album.albumID), !album.songTags.isEmpty else { return nil }
      var vector = TagVector()
      for tags in album.songTags { add(tags, into: &vector) }
      let match = cosine(vector, profile)
      return match >= moreLikeLatelyMinMatch ? (album.albumID, album.artistID, match) : nil
    }
    var perArtist = [String: Int]()
    return scored
      .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
      .filter { item in
        perArtist[item.1, default: 0] += 1
        return perArtist[item.1]! <= moreLikeLatelyPerArtist
      }
      .map(\.0)
  }

  public struct SongCandidate {
    public let songID: String
    public let albumID: String
    public let tags: TagVector

    public init(songID: String, albumID: String, tags: TagVector) {
      self.songID = songID
      self.albumID = albumID
      self.tags = tags
    }
  }

  /// A mix of `count` songs drawn from the 120 closest to the profile, skipping songs played
  /// in the last three days and taking at most three from one album, in shuffled order.
  public static func latelyMix<R: RandomNumberGenerator>(
    _ songs: [SongCandidate],
    profile: TagVector,
    playedRecently: Set<String>,
    count: Int,
    using rng: inout R
  )
    -> [String] {
    guard !profile.isEmpty else { return [] }
    var scored: [(song: SongCandidate, match: Double)] = []
    for song in songs where !playedRecently.contains(song.songID) {
      let match = cosine(song.tags, profile)
      if match >= moreLikeLatelyMinMatch { scored.append((song, match)) }
    }
    scored.sort { lhs, rhs in
      if lhs.match != rhs.match { return lhs.match > rhs.match }
      return lhs.song.songID < rhs.song.songID
    }
    let pool: [SongCandidate] = scored.prefix(mixPoolSize).map(\.song)
    var perAlbum = [String: Int]()
    var picked = [String]()
    for song in pool.shuffled(using: &rng) where picked.count < count {
      perAlbum[song.albumID, default: 0] += 1
      if perAlbum[song.albumID]! <= mixPerAlbum { picked.append(song.songID) }
    }
    return picked
  }
}
