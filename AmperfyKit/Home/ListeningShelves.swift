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
      // phone-taste: the row reads "Weekday Nights" (CarPlay's row title follows).
      case .late: return "Nights"
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

  // Most played, lately (an artist page's MOST PLAYED): this phone's own plays of each
  // song over the lookback window, decayed so last week outweighs two months ago. Kept
  // apart from the all-time counts (Song.playCount, the cloud's popular-rank), never
  // blended with them (founder, 2026-10-21).
  static let mostPlayedLatelyHalfLifeDays = 14.0
  static let mostPlayedLatelyMinPlays = 2

  /// Song ids, most played lately first. Each play is a completed play's date and song id;
  /// a song needs two plays in the window to count.
  public static func mostPlayedLately(
    _ plays: [(date: Date, songID: String)],
    now: Date
  )
    -> [String] {
    // rank() only uses ListeningPlay's id as a key, so a song id works as well as an album's.
    rank(
      plays.map { ListeningPlay(date: $0.date, albumID: $0.songID) },
      now: now,
      halfLifeDays: mostPlayedLatelyHalfLifeDays,
      minPlays: mostPlayedLatelyMinPlays
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

  public static func add(_ v: TagVector, into acc: inout TagVector, weight: Double = 1) {
    for (k, x) in v { acc[k, default: 0] += x * weight }
  }

  public static func cosine(_ a: TagVector, _ b: TagVector) -> Double {
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

  // MARK: More like (artist and playlist pages)

  /// An artist name for matching: trimmed, lowercased, accents folded ("Björk" and
  /// "bjork " are one artist).
  public static func normalizedArtistName(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
      .lowercased()
  }

  /// MORE LIKE on an artist page: other artists on the phone whose music carries the same
  /// moods, one album each. Artists are grouped by normalised NAME (the phone can hold one
  /// artist under several ids). Each artist's tags are the sum over all their songs; each
  /// is shown by their album with the most tag weight; they rank by how closely their
  /// tags match the page artist's (cosine, `minMatch` or better), best first, ties by name.
  /// The page artist and "Various Artists" are left out. Returns album ids.
  public static func moreLikeArtist(
    pageArtistName: String,
    albums: [AlbumCandidate],
    artistNameByAlbum: [String: String],
    minMatch: Double = 0.75,
    limit: Int = 8
  )
    -> [String] {
    let page = normalizedArtistName(pageArtistName)
    guard !page.isEmpty else { return [] }
    var vectorByArtist = [String: TagVector]()
    var tileByArtist = [String: (albumID: String, weight: Double)]()
    for album in albums where !album.songTags.isEmpty {
      guard let rawName = artistNameByAlbum[album.albumID] else { continue }
      let name = normalizedArtistName(rawName)
      guard !name.isEmpty else { continue }
      var albumVector = TagVector()
      for tags in album.songTags { add(tags, into: &albumVector) }
      add(albumVector, into: &vectorByArtist[name, default: TagVector()])
      let weight = albumVector.values.reduce(0, +)
      if let tile = tileByArtist[name],
         tile.weight > weight || (tile.weight == weight && tile.albumID < album.albumID) {
        continue
      }
      tileByArtist[name] = (album.albumID, weight)
    }
    guard let pageVector = vectorByArtist[page], !pageVector.isEmpty else { return [] }
    let excluded: Set<String> = [page, "various artists"]
    let scored: [(name: String, albumID: String, match: Double)] = vectorByArtist.compactMap { name, vector in
      guard !excluded.contains(name), let tile = tileByArtist[name] else { return nil }
      let match = cosine(vector, pageVector)
      return match >= minMatch ? (name, tile.albumID, match) : nil
    }
    return scored
      .sorted { $0.match != $1.match ? $0.match > $1.match : $0.name < $1.name }
      .prefix(limit)
      .map(\.albumID)
  }

  /// MORE LIKE for any tag profile (a playlist's songs, say): albums on the phone whose
  /// combined song tags match `profile` (`minMatch` or better), best first (ties by id),
  /// at most `perArtist` per artist, leaving out `excluding`. The same scoring as
  /// `moreLikeLately`, with no played-recently filter. Returns album ids.
  public static func moreLike(
    profile: TagVector,
    albums: [AlbumCandidate],
    excluding: Set<String>,
    minMatch: Double = 0.7,
    perArtist: Int = 1,
    limit: Int = 8,
    artistKey: (AlbumCandidate) -> String = { $0.artistID }
  )
    -> [String] {
    guard !profile.isEmpty else { return [] }
    let scored: [(album: AlbumCandidate, match: Double)] = albums.compactMap { album in
      guard !excluding.contains(album.albumID), !album.songTags.isEmpty else { return nil }
      var vector = TagVector()
      for tags in album.songTags { add(tags, into: &vector) }
      let match = cosine(vector, profile)
      return match >= minMatch ? (album, match) : nil
    }
    var countByArtist = [String: Int]()
    var picked = [String]()
    for item in scored.sorted(by: {
      $0.match != $1.match ? $0.match > $1.match : $0.album.albumID < $1.album.albumID
    }) {
      guard picked.count < limit else { break }
      let key = artistKey(item.album)
      countByArtist[key, default: 0] += 1
      if countByArtist[key]! <= perArtist { picked.append(item.album.albumID) }
    }
    return picked
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

// MARK: - Made for you (founder, 2026-10-21)

/// The playlists Home makes for you, beside Lately: one for this part of the day, the
/// favourites you have not played in a while, and the mood mixes (Road Trip, Get Pumped,
/// Focus, Wind Down, Late Night, Feel Good). All of them are built on the phone, from songs
/// on the phone, by the same tag maths as Lately; none calls the server. The mood mixes
/// replace the server's mood doors on the phone, whose mixes drifted (the founder's road
/// trip, 2026-08: Olivia Rodrigo beside Brand New, Chumbawamba after Coldplay in Focus).
/// Here they read only song-level tags (never the album energy fallback behind BUG-354),
/// grow outward from one seed song so they hang together, and space artists out.
extension ListeningShelves {
  /// A song as the made-for-you mixes see it.
  public struct MixSong: Sendable {
    public let songID: String
    public let albumID: String
    /// The artist, normalised (`normalizedArtistName`), for spacing and caps.
    public let artistKey: String
    /// Lowercased genre, or nil.
    public let genre: String?
    /// The record's year, 0 when unknown.
    public let year: Int
    public let tags: TagVector

    public init(songID: String, albumID: String, artistKey: String, genre: String?, year: Int, tags: TagVector) {
      self.songID = songID
      self.albumID = albumID
      self.artistKey = artistKey
      self.genre = genre
      self.year = year
      self.tags = tags
    }

    var energy: String? { Self.value(of: "energy:", in: tags) }
    var valence: String? { Self.value(of: "valence:", in: tags) }
    var moods: Set<String> {
      Set(tags.keys.filter { $0.hasPrefix("mood:") }.map { String($0.dropFirst(5)) })
    }

    var moodVector: TagVector { tags.filter { $0.key.hasPrefix("mood:") } }

    private static func value(of prefix: String, in tags: TagVector) -> String? {
      tags.keys.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
  }

  /// A mood mix: which songs may join (energy, valence, moods that rule a song out) and the
  /// moods it is after. Keys and colours are the app's mood doors (MoodDoors.swift).
  public struct MoodMix: Sendable {
    public let key: String
    public let title: String
    public let hexColor: String
    let energies: Set<String>?
    let valences: Set<String>?
    let target: TagVector
    let avoid: Set<String>

    init(
      key: String,
      title: String,
      hexColor: String,
      energies: Set<String>?,
      valences: Set<String>?,
      moods: [String: Double],
      avoid: Set<String>
    ) {
      self.key = key
      self.title = title
      self.hexColor = hexColor
      self.energies = energies
      self.valences = valences
      var target = TagVector()
      for (mood, weight) in moods { target["mood:\(mood)"] = weight }
      self.target = target
      self.avoid = avoid
    }

    /// How well a song's moods fit, 0 to 1, or nil when the song may not join at all.
    func fit(_ song: MixSong) -> Double? {
      if let energies {
        guard let energy = song.energy, energies.contains(energy) else { return nil }
      }
      if let valences {
        guard let valence = song.valence, valences.contains(valence) else { return nil }
      }
      let moods = song.moods
      guard !moods.isEmpty, moods.isDisjoint(with: avoid) else { return nil }
      let fit = cosine(song.moodVector, target)
      return fit >= MoodMix.minFit ? fit : nil
    }

    /// One target mood among a song's one to three is enough (about 0.3 against a
    /// ten-mood target); the energy and valence gates do the rest.
    static let minFit = 0.28
  }

  /// The six mood mixes, keyed and coloured like the mood doors. Their moods are the
  /// catalog's song taxonomy (taxonomy.ts MOODS); energy is low / medium / high and valence
  /// dark / bittersweet / bright, read per song.
  public static let moodMixes: [MoodMix] = [
    MoodMix(
      key: "road-trip",
      title: "Road Trip",
      hexColor: "#D4A020",
      energies: ["medium", "high"],
      valences: ["bright", "bittersweet"],
      moods: [
        "hopeful": 1, "nostalgic": 1, "euphoric": 1, "triumphant": 1, "energetic": 0.9,
        "uplifting": 1, "joyful": 1, "playful": 0.8, "confident": 0.7, "defiant": 0.5,
        "romantic": 0.4, "wistful": 0.4,
      ],
      avoid: ["somber", "mournful", "despairing", "eerie", "lonely"]
    ),
    MoodMix(
      key: "get-pumped",
      title: "Get Pumped",
      hexColor: "#E8452C",
      energies: ["high"],
      valences: nil,
      moods: [
        "energetic": 1, "euphoric": 1, "triumphant": 1, "intense": 1, "defiant": 1,
        "confident": 1, "empowering": 1, "urgent": 0.8, "rebellious": 0.8, "aggressive": 0.7,
        "cathartic": 0.6, "playful": 0.5,
      ],
      avoid: ["tender", "peaceful", "serene", "somber", "mournful", "lonely", "melancholic"]
    ),
    MoodMix(
      key: "focus",
      title: "Focus",
      hexColor: "#3A7CA5",
      energies: ["low", "medium"],
      valences: nil,
      moods: [
        "contemplative": 1, "dreamy": 1, "peaceful": 1, "serene": 1, "mysterious": 0.6,
        "wistful": 0.5, "hopeful": 0.4,
      ],
      avoid: [
        "aggressive", "intense", "urgent", "anxious", "defiant", "rebellious", "tense",
        "euphoric", "playful", "cathartic", "despairing",
      ]
    ),
    MoodMix(
      key: "wind-down",
      title: "Wind Down",
      hexColor: "#4A9B8E",
      energies: ["low"],
      valences: nil,
      moods: [
        "peaceful": 1, "serene": 1, "tender": 1, "dreamy": 0.8, "contemplative": 0.8,
        "wistful": 0.6, "romantic": 0.5, "hopeful": 0.4, "soulful": 0.5,
      ],
      avoid: [
        "aggressive", "intense", "urgent", "anxious", "tense", "energetic", "euphoric",
        "defiant", "rebellious", "restless",
      ]
    ),
    MoodMix(
      key: "late-night",
      title: "Late Night",
      hexColor: "#6B4FA0",
      energies: ["low", "medium"],
      valences: ["dark", "bittersweet"],
      moods: [
        "brooding": 1, "haunting": 1, "mysterious": 1, "melancholic": 1, "dreamy": 0.8,
        "lonely": 0.8, "wistful": 0.6, "eerie": 0.6, "vulnerable": 0.6, "somber": 0.5,
      ],
      avoid: ["playful", "joyful", "euphoric", "triumphant", "uplifting", "empowering"]
    ),
    MoodMix(
      key: "feel-good",
      title: "Feel Good",
      hexColor: "#D64B8C",
      energies: ["medium", "high"],
      valences: ["bright"],
      moods: [
        "playful": 1, "hopeful": 1, "joyful": 1, "euphoric": 1, "uplifting": 1,
        "romantic": 0.6, "confident": 0.6, "triumphant": 0.6, "energetic": 0.5,
      ],
      avoid: ["somber", "melancholic", "mournful", "despairing", "brooding", "haunting", "eerie"]
    ),
  ]

  /// The mood mixes in the order this part of the day suits them: the quiet ones first at
  /// night, the lively ones first by day.
  public static func moodMixOrder(for daypart: Daypart) -> [String] {
    switch daypart {
    case .morning: return ["focus", "get-pumped", "feel-good", "road-trip", "wind-down", "late-night"]
    case .afternoon: return ["focus", "road-trip", "feel-good", "get-pumped", "wind-down", "late-night"]
    case .evening: return ["feel-good", "road-trip", "wind-down", "late-night", "get-pumped", "focus"]
    case .late: return ["late-night", "wind-down", "focus", "feel-good", "road-trip", "get-pumped"]
    }
  }

  public static func daypart(of date: Date, calendar: Calendar = .current) -> Daypart {
    Daypart(hour: calendar.component(.hour, from: date))
  }

  // Tuning: one mix's shape.
  public static let madeMixLength = 30
  public static let madeMixMinSongs = 15
  /// The founder's rule (2026-08-20): wait four or five songs before an artist comes back.
  public static let mixArtistGap = 4
  static let mixMaxPerAlbum = 2
  static let mixMaxPerArtist = 3

  /// A mood mix of up to `count` songs, or [] when fewer than `minSongs` songs fit.
  ///
  /// Grown from one seed: the best-fitting song among those played lately (`favored`),
  /// chosen at random from the top three, else the best fit overall. Each next song is one of
  /// the five best by fit to the mood (55%) and closeness to the songs already in (45%),
  /// with a small pull toward the seed's genre and away from records more than a dozen years
  /// from the seed's. No artist within `mixArtistGap` songs of itself (relaxed only when
  /// nothing else is left), at most two songs per album and three per artist.
  public static func moodMix<R: RandomNumberGenerator>(
    _ mood: MoodMix,
    songs: [MixSong],
    favored: Set<String>,
    count: Int = madeMixLength,
    minSongs: Int = madeMixMinSongs,
    using rng: inout R
  )
    -> [String] {
    var eligible: [(song: MixSong, fit: Double)] = []
    for song in songs {
      if let fit = mood.fit(song) { eligible.append((song, fit)) }
    }
    guard eligible.count >= minSongs else { return [] }
    eligible.sort { $0.fit != $1.fit ? $0.fit > $1.fit : $0.song.songID < $1.song.songID }

    let favoredFits = eligible.filter { favored.contains($0.song.songID) }
    let seedPool = favoredFits.isEmpty ? Array(eligible.prefix(1)) : Array(favoredFits.prefix(3))
    guard let seed = seedPool.randomElement(using: &rng) else { return [] }

    return grow(
      from: seed.song,
      candidates: eligible,
      count: count,
      score: { candidate, centroid in
        var score = 0.55 * candidate.fit + 0.45 * cosine(candidate.song.tags, centroid)
        if let genre = seed.song.genre, candidate.song.genre == genre { score += 0.08 }
        if seed.song.year > 0, candidate.song.year > 0, abs(candidate.song.year - seed.song.year) > 12 {
          score -= 0.08
        }
        return score
      },
      using: &rng
    )
  }

  /// A mix for this part of the day on this kind of day: songs whose moods match what you
  /// play in this slot (the last two months, recent habits weighted up), drawn like Lately
  /// and leaving out the songs already in it (`excluding`). [] with fewer than eight plays
  /// in the slot or fewer than `minSongs` songs.
  public static func daypartMix<R: RandomNumberGenerator>(
    plays: [(date: Date, songID: String)],
    songs: [MixSong],
    excluding: Set<String>,
    playedRecently: Set<String>,
    now: Date,
    calendar: Calendar = .current,
    count: Int = madeMixLength,
    minSongs: Int = madeMixMinSongs,
    using rng: inout R
  )
    -> [String] {
    let slot = slot(of: now, calendar: calendar)
    let since = now.addingTimeInterval(-Double(lookbackDays) * 86400)
    let tagsByID = Dictionary(songs.map { ($0.songID, $0.tags) }, uniquingKeysWith: { first, _ in first })
    var profile = TagVector()
    var slotPlays = 0
    for play in plays where play.date >= since && play.date <= now {
      guard Self.slot(of: play.date, calendar: calendar) == slot, let tags = tagsByID[play.songID]
      else { continue }
      let ageDays = max(0, now.timeIntervalSince(play.date) / 86400)
      add(tags, into: &profile, weight: pow(0.5, ageDays / aroundNowHalfLifeDays))
      slotPlays += 1
    }
    guard slotPlays >= 8, !profile.isEmpty else { return [] }
    let candidates = songs
      .filter { !excluding.contains($0.songID) }
      .map { SongCandidate(songID: $0.songID, albumID: $0.albumID, tags: $0.tags) }
    let picked = latelyMix(candidates, profile: profile, playedRecently: playedRecently, count: count, using: &rng)
    guard picked.count >= minSongs else { return [] }
    let artistByID = Dictionary(songs.map { ($0.songID, $0.artistKey) }, uniquingKeysWith: { first, _ in first })
    return spacedByArtist(picked, artistOf: { artistByID[$0] ?? $0 })
  }

  /// One song's history, for Been a While.
  public struct PlayedSong: Sendable {
    public let songID: String
    public let albumID: String
    public let artistKey: String
    public let playCount: Int
    public let lastPlayed: Date?

    public init(songID: String, albumID: String, artistKey: String, playCount: Int, lastPlayed: Date?) {
      self.songID = songID
      self.albumID = albumID
      self.artistKey = artistKey
      self.playCount = playCount
      self.lastPlayed = lastPlayed
    }
  }

  /// Favourites you have not played in a while: songs played at least four times, none of
  /// them in the last 45 days, drawn from the 80 most played, at most two per album and three
  /// per artist, artists spaced out. [] when fewer than `minSongs` qualify.
  public static func beenAWhile<R: RandomNumberGenerator>(
    _ songs: [PlayedSong],
    now: Date,
    count: Int = madeMixLength,
    minSongs: Int = madeMixMinSongs,
    using rng: inout R
  )
    -> [String] {
    let cutoff = now.addingTimeInterval(-45 * 86400)
    let pool = songs
      .filter { $0.playCount >= 4 && ($0.lastPlayed.map { $0 < cutoff } ?? false) }
      .sorted { $0.playCount != $1.playCount ? $0.playCount > $1.playCount : $0.songID < $1.songID }
      .prefix(80)
    guard pool.count >= minSongs else { return [] }
    var perAlbum = [String: Int]()
    var perArtist = [String: Int]()
    var picked = [String]()
    for song in pool.shuffled(using: &rng) where picked.count < count {
      guard perAlbum[song.albumID, default: 0] < mixMaxPerAlbum,
            perArtist[song.artistKey, default: 0] < mixMaxPerArtist
      else { continue }
      perAlbum[song.albumID, default: 0] += 1
      perArtist[song.artistKey, default: 0] += 1
      picked.append(song.songID)
    }
    guard picked.count >= minSongs else { return [] }
    let artistByID = Dictionary(pool.map { ($0.songID, $0.artistKey) }, uniquingKeysWith: { first, _ in first })
    return spacedByArtist(picked, artistOf: { artistByID[$0] ?? $0 })
  }

  /// The same songs, reordered so an artist does not come back within `gap` songs wherever
  /// the mix allows it (the founder's rule, 2026-08-20). Stable otherwise.
  public static func spacedByArtist(
    _ ids: [String],
    artistOf: (String) -> String,
    gap: Int = mixArtistGap
  )
    -> [String] {
    var remaining = ids
    var result = [String]()
    result.reserveCapacity(ids.count)
    while !remaining.isEmpty {
      let recent = Set(result.suffix(gap).map(artistOf))
      let index = remaining.firstIndex { !recent.contains(artistOf($0)) } ?? 0
      result.append(remaining.remove(at: index))
    }
    return result
  }

  /// Grows a mix from `seed`: each step scores every song still allowed against the songs
  /// already in (their summed tags) and takes one of the best five at random.
  static func grow<R: RandomNumberGenerator>(
    from seed: MixSong,
    candidates: [(song: MixSong, fit: Double)],
    count: Int,
    score: ((song: MixSong, fit: Double), TagVector) -> Double,
    using rng: inout R
  )
    -> [String] {
    var picked = [seed.songID]
    var pickedArtists = [seed.artistKey]
    var perAlbum = [seed.albumID: 1]
    var perArtist = [seed.artistKey: 1]
    var centroid = seed.tags
    var pool = candidates.filter { $0.song.songID != seed.songID }
    while picked.count < count, !pool.isEmpty {
      let recentArtists = Set(pickedArtists.suffix(mixArtistGap))
      let capped = pool.filter {
        perAlbum[$0.song.albumID, default: 0] < mixMaxPerAlbum
          && perArtist[$0.song.artistKey, default: 0] < mixMaxPerArtist
      }
      guard !capped.isEmpty else { break }
      let spaced = capped.filter { !recentArtists.contains($0.song.artistKey) }
      let options = spaced.isEmpty ? capped : spaced
      let best = options
        .map { (candidate: $0, score: score($0, centroid)) }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.candidate.song.songID < $1.candidate.song.songID }
        .prefix(5)
      guard let next = best.randomElement(using: &rng)?.candidate else { break }
      picked.append(next.song.songID)
      pickedArtists.append(next.song.artistKey)
      perAlbum[next.song.albumID, default: 0] += 1
      perArtist[next.song.artistKey, default: 0] += 1
      add(next.song.tags, into: &centroid)
      pool.removeAll { $0.song.songID == next.song.songID }
    }
    return picked
  }

  /// A small seeded generator, so a mix is the same all day and new the next (the founder,
  /// 2026-08-20: mood playlists build once a day instead of rerolling on every tap).
  public struct DailyGenerator: RandomNumberGenerator {
    private var state: UInt64

    /// Seeded from the day (in `calendar`'s time zone) and the mix's key.
    public init(day: Date, key: String, calendar: Calendar = .current) {
      let parts = calendar.dateComponents([.year, .month, .day], from: day)
      let text = "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)|\(key)"
      var hash: UInt64 = 0xCBF2_9CE4_8422_2325
      for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01B3
      }
      state = hash
    }

    public mutating func next() -> UInt64 {
      // SplitMix64.
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
  }
}
