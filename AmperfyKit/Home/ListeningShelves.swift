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

  /// A song's tags as weighted tokens: each mood counts 1, energy and valence a half, and each
  /// subgenre of its sound 1 (`sound:<subgenre>`, matched apart from the moods: `likeness`).
  public typealias TagVector = [String: Double]

  static let latelyWindowDays = 30
  static let latelyHalfLifeDays = 10.0
  static let moreLikeLatelyMinMatch = 0.6
  static let moreLikeLatelyPerArtist = 2
  static let mixRecentlyPlayedDays = 3
  static let mixPoolSize = 120
  static let mixPerAlbum = 3

  public static func tagVector(
    moods: [String],
    energy: String?,
    valence: String?,
    sound: [String] = [],
    scenarios: [String] = []
  )
    -> TagVector {
    var v = TagVector()
    for m in moods { v["mood:\(m)", default: 0] += 1 }
    if let energy, !energy.isEmpty { v["energy:\(energy)", default: 0] += 0.5 }
    if let valence, !valence.isEmpty { v["valence:\(valence)", default: 0] += 0.5 }
    for s in sound where !s.isEmpty { v["\(soundPrefix)\(s)"] = 1 }
    for s in scenarios where !s.isEmpty { v["\(scenarioPrefix)\(s)"] = 1 }
    return v
  }

  static let soundPrefix = "sound:"
  /// What a song is for (road_trip, workout, winding_down...): only the mood playlists read
  /// it (`MoodMix`); every likeness leaves it out.
  static let scenarioPrefix = "scenario:"

  public static func add(_ v: TagVector, into acc: inout TagVector, weight: Double = 1) {
    for (k, x) in v { acc[k, default: 0] += x * weight }
  }

  /// A tag set made ready to compare: its keys in order and its norms summed once, in that
  /// order. Every sum here runs in key order and every score is rounded, so the same tags
  /// score the same on every launch (BUG-494: a dictionary's order changes per launch, and
  /// ties that should fall to the song id fell to rounding noise instead).
  public struct Prepared {
    let tags: TagVector
    let keys: [String]
    let norm: Double
    let moodNorm: Double
    let soundNorm: Double
    /// The sound weights summed: what a share of the sound is out of.
    let soundTotal: Double

    public init(_ tags: TagVector) {
      self.tags = tags
      keys = tags.keys.sorted()
      var all = 0.0, mood = 0.0, sound = 0.0, total = 0.0
      for k in keys {
        let x = tags[k]!
        all += x * x
        if k.hasPrefix(ListeningShelves.soundPrefix) {
          sound += x * x
          total += x
        } else if !k.hasPrefix(ListeningShelves.scenarioPrefix) {
          mood += x * x
        }
      }
      norm = all.squareRoot()
      moodNorm = mood.squareRoot()
      soundNorm = sound.squareRoot()
      soundTotal = total
    }
  }

  /// How alike two tag sets are, as two numbers: mood (moods, energy, valence) and sound
  /// (subgenres). Mood words alone pair records that sound nothing alike (BUG-498: Modern
  /// Vampires of the City beside Tubthumper on "contemplative, wistful"), so where both sides
  /// carry sound it counts as much as the mood. `sound` is nil when either side has none (tags
  /// from a server before sound, a song with no subgenres), and matching falls back to mood.
  public struct Likeness: Sendable, Equatable {
    public let mood: Double
    public let sound: Double?
    /// Whether `sound` ranks as well as gates (record against record), or only gates (a song
    /// or record against the lately profile, where it is a share: see `likeness(_:toProfile:)`).
    let soundRanks: Bool

    /// One number to rank by: the mean of the two, or the mood alone.
    public var score: Double {
      guard soundRanks, let sound else { return mood }
      return ListeningShelves.rounded((mood + sound) / 2)
    }

    /// With sound: the mood and the sound each clear their floor and the score clears
    /// `bar.score`. Without: the mood clears `bar.moodOnly`, the bar this match used before
    /// sound.
    public func passes(_ bar: Bar) -> Bool {
      if let sound { return mood >= bar.mood && sound >= bar.sound && score >= bar.score }
      return mood >= bar.moodOnly
    }
  }

  public struct Bar: Sendable {
    public let mood: Double
    public let sound: Double
    /// What the ranking number (`Likeness.score`) must reach; 0 for none.
    public let score: Double
    public let moodOnly: Double

    public init(mood: Double, sound: Double, score: Double = 0, moodOnly: Double) {
      self.mood = mood
      self.sound = sound
      self.score = score
      self.moodOnly = moodOnly
    }
  }

  public static func likeness(_ a: Prepared, _ b: Prepared) -> Likeness {
    // Walk the smaller set; both orders give the same sums because each runs in key order.
    let (small, large) = a.keys.count <= b.keys.count ? (a, b) : (b, a)
    var moodDot = 0.0, soundDot = 0.0
    for k in small.keys {
      guard let y = large.tags[k] else { continue }
      if k.hasPrefix(soundPrefix) {
        soundDot += small.tags[k]! * y
      } else if !k.hasPrefix(scenarioPrefix) {
        moodDot += small.tags[k]! * y
      }
    }
    let mood = a.moodNorm > 0 && b.moodNorm > 0 ? rounded(moodDot / (a.moodNorm * b.moodNorm)) : 0
    let sound = a.soundNorm > 0 && b.soundNorm > 0 ? rounded(soundDot / (a.soundNorm * b.soundNorm)) : nil
    return Likeness(mood: mood, sound: sound, soundRanks: true)
  }

  public static func likeness(_ a: TagVector, _ b: TagVector) -> Likeness {
    likeness(Prepared(a), Prepared(b))
  }

  /// A song or a record against a listening profile. The mood is the cosine, as ever. The
  /// sound is how much of what was played carries the item's sound: each of the item's
  /// subgenres, as its share of the item, up to that subgenre's share of the profile, summed
  /// (0 to 1). Unlike a cosine it does not favour the profile's one biggest style: a person
  /// who plays mostly indie rock and some folk gets folk too, but never a style they have not
  /// played at all. So it only gates; the mood ranks.
  public static func likeness(_ item: Prepared, toProfile profile: Prepared) -> Likeness {
    let mood = likeness(item, profile).mood
    guard item.soundTotal > 0, profile.soundTotal > 0 else {
      return Likeness(mood: mood, sound: nil, soundRanks: false)
    }
    var overlap = 0.0
    for k in item.keys where k.hasPrefix(soundPrefix) {
      overlap += min(item.tags[k]! / item.soundTotal, (profile.tags[k] ?? 0) / profile.soundTotal)
    }
    return Likeness(mood: mood, sound: rounded(overlap), soundRanks: false)
  }

  /// The plain cosine over every token, in key order and rounded (see `Prepared`).
  public static func cosine(_ a: TagVector, _ b: TagVector) -> Double {
    let pa = Prepared(a), pb = Prepared(b)
    guard pa.norm > 0, pb.norm > 0 else { return 0 }
    let (small, large) = pa.keys.count <= pb.keys.count ? (pa, pb) : (pb, pa)
    var dot = 0.0
    for k in small.keys { dot += small.tags[k]! * (large.tags[k] ?? 0) }
    return rounded(dot / (pa.norm * pb.norm))
  }

  /// Nine places: far below any bar's meaning, far above summing noise.
  static func rounded(_ x: Double) -> Double { (x * 1e9).rounded() / 1e9 }

  // MARK: Songs that are not songs (BUG-496)

  /// Whether a track is an interlude, an intro or a sketch rather than a song: under a minute,
  /// or "interlude" / "skit" / "segue" in the title, or a short one (under two and a half
  /// minutes) titled intro, outro, reprise, instrumental, untitled, prelude and the like, or
  /// wholly in brackets ("(Vegas // Dad)", "[untitled]"). The tagger gives these pure
  /// atmosphere, so they used to be the best fit for a mood. A length of 0 is unknown.
  /// Kept out of every made-for-you playlist and every record's summed tags.
  public static func isInterlude(title: String?, duration: Int) -> Bool {
    if duration > 0, duration < 60 { return true }
    let text = (title ?? "").lowercased()
    let words = Set(text.split(whereSeparator: { !$0.isLetter }).map(String.init))
    if !words.isDisjoint(with: ["interlude", "skit", "segue"]) { return true }
    let short = duration > 0 && duration < 150
    guard short else { return false }
    if !words.isDisjoint(with: [
      "intro", "introduction", "outro", "reprise", "instrumental", "untitled", "prelude",
      "overture", "foreword",
    ]) { return true }
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard let first = trimmed.first, let last = trimmed.last else { return false }
    return ("([{".contains(first) && ")]}".contains(last))
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

    /// The record's songs' tags summed, in the order given (keep it stable: LatelyLibrary
    /// sorts by song id).
    public var summedTags: TagVector {
      var vector = TagVector()
      for tags in songTags { ListeningShelves.add(tags, into: &vector) }
      return vector
    }
  }

  /// How close a song or a record must be to the lately profile (Home's MORE LIKE, Lately and
  /// the time-of-day playlist): the old mood bar, and a sound that is at least a few percent
  /// of what was played (`likeness(_:toProfile:)`). Without sound, the mood alone.
  public static let latelyBar = Bar(mood: moreLikeLatelyMinMatch, sound: 0.03, moodOnly: moreLikeLatelyMinMatch)
  /// How close another record must be to a page's record, artist or playlist (MORE LIKE):
  /// mood and sound together at 0.55 or better, neither far off on its own. Two separate
  /// bars (0.6 and 0.3) turned away records that plainly belong, close on one side and
  /// just short on the other (A Fever You Can't Sweat Out beside nimrod.: sound 0.93,
  /// mood 0.57), leaving 13 of the founder's tagged records with no shelf.
  public static func recordBar(moodOnly: Double) -> Bar {
    Bar(mood: 0.45, sound: 0.25, score: 0.55, moodOnly: moodOnly)
  }

  /// Albums whose combined song tags match the profile closely (`latelyBar`), best first,
  /// at most two per artist, leaving out albums played in the last 30 days.
  public static func moreLikeLately(
    _ albums: [AlbumCandidate],
    profile: TagVector,
    playedRecently: Set<String>
  )
    -> [String] {
    guard !profile.isEmpty else { return [] }
    let prepared = Prepared(profile)
    let scored: [(String, String, Double)] = albums.compactMap { album in
      guard !playedRecently.contains(album.albumID), !album.songTags.isEmpty else { return nil }
      let match = likeness(Prepared(album.summedTags), toProfile: prepared)
      return match.passes(latelyBar) ? (album.albumID, album.artistID, match.score) : nil
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
  /// moods and sound, one album each. Artists are grouped by normalised NAME (the phone can
  /// hold one artist under several ids). Each artist's tags are the sum over all their songs;
  /// each is shown by their album with the most tag weight; they rank by how closely their
  /// tags match the page artist's (`recordBar`, `minMatch` when there is no sound), best
  /// first, ties by name. The page artist and "Various Artists" are left out. Returns album ids.
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
    // Album id order, so an artist's tags sum the same way on every launch.
    for album in albums.sorted(by: { $0.albumID < $1.albumID }) where !album.songTags.isEmpty {
      guard let rawName = artistNameByAlbum[album.albumID] else { continue }
      let name = normalizedArtistName(rawName)
      guard !name.isEmpty else { continue }
      let albumVector = album.summedTags
      add(albumVector, into: &vectorByArtist[name, default: TagVector()])
      let weight = rounded(albumVector.keys.sorted().reduce(0) { $0 + albumVector[$1]! })
      if let tile = tileByArtist[name],
         tile.weight > weight || (tile.weight == weight && tile.albumID < album.albumID) {
        continue
      }
      tileByArtist[name] = (album.albumID, weight)
    }
    guard let pageVector = vectorByArtist[page], !pageVector.isEmpty else { return [] }
    let excluded: Set<String> = [page, "various artists"]
    let prepared = Prepared(pageVector)
    let bar = recordBar(moodOnly: minMatch)
    let scored: [(name: String, albumID: String, match: Double)] = vectorByArtist.compactMap { name, vector in
      guard !excluded.contains(name), let tile = tileByArtist[name] else { return nil }
      let match = likeness(Prepared(vector), prepared)
      return match.passes(bar) ? (name, tile.albumID, match.score) : nil
    }
    return scored
      .sorted { $0.match != $1.match ? $0.match > $1.match : $0.name < $1.name }
      .prefix(limit)
      .map(\.albumID)
  }

  /// MORE LIKE for any tag profile (a playlist's songs, say): albums on the phone whose
  /// combined song tags match `profile` (`recordBar`; `minMatch` when either side has no
  /// sound), best first (ties by id),
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
    let prepared = Prepared(profile)
    let bar = recordBar(moodOnly: minMatch)
    let scored: [(album: AlbumCandidate, match: Double)] = albums.compactMap { album in
      guard !excluding.contains(album.albumID), !album.songTags.isEmpty else { return nil }
      let match = likeness(Prepared(album.summedTags), prepared)
      return match.passes(bar) ? (album, match.score) : nil
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
    /// The artist, normalised (`normalizedArtistName`), for the per-artist cap; "" when
    /// unknown (no cap).
    public let artistKey: String
    public let tags: TagVector

    public init(songID: String, albumID: String, artistKey: String = "", tags: TagVector) {
      self.songID = songID
      self.albumID = albumID
      self.artistKey = artistKey
      self.tags = tags
    }
  }

  /// A mix of `count` songs drawn from the 120 closest in mood to the profile, among songs
  /// whose sound it has been playing (`latelyBar`), skipping songs played in the last three
  /// days and taking at most three
  /// from one album and three from one artist (BUG-495), in shuffled order. Seed `rng` by
  /// the day (`DailyGenerator`) and the mix stays the same all day.
  public static func latelyMix<R: RandomNumberGenerator>(
    _ songs: [SongCandidate],
    profile: TagVector,
    playedRecently: Set<String>,
    count: Int,
    using rng: inout R
  )
    -> [String] {
    guard !profile.isEmpty else { return [] }
    let prepared = Prepared(profile)
    var scored: [(song: SongCandidate, match: Double)] = []
    for song in songs where !playedRecently.contains(song.songID) {
      let match = likeness(Prepared(song.tags), toProfile: prepared)
      if match.passes(latelyBar) { scored.append((song, match.score)) }
    }
    scored.sort { lhs, rhs in
      if lhs.match != rhs.match { return lhs.match > rhs.match }
      return lhs.song.songID < rhs.song.songID
    }
    let pool: [SongCandidate] = scored.prefix(mixPoolSize).map(\.song)
    var perAlbum = [String: Int]()
    var perArtist = [String: Int]()
    var picked = [String]()
    for song in pool.shuffled(using: &rng) where picked.count < count {
      guard perAlbum[song.albumID, default: 0] < mixPerAlbum,
            song.artistKey.isEmpty || perArtist[song.artistKey, default: 0] < mixMaxPerArtist
      else { continue }
      perAlbum[song.albumID, default: 0] += 1
      if !song.artistKey.isEmpty { perArtist[song.artistKey, default: 0] += 1 }
      picked.append(song.songID)
    }
    return picked
  }
}

// MARK: - Made for you (founder, 2026-10-21)

/// The playlists Home makes for you, beside Lately: one for this part of the day, the
/// favourites you have not played in a while, and the mood mixes (Get Pumped,
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
    var scenarios: Set<String> { Self.values(of: ListeningShelves.scenarioPrefix, in: tags) }
    var sounds: Set<String> { Self.values(of: ListeningShelves.soundPrefix, in: tags) }

    private static func values(of prefix: String, in tags: TagVector) -> Set<String> {
      Set(tags.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
    }

    private static func value(of prefix: String, in tags: TagVector) -> String? {
      tags.keys.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
  }

  /// A mood mix: which songs may join (energy, valence, moods that rule a song out), the
  /// moods it is after, and what sets it apart from the other five: the scenarios it is for
  /// and the sounds it lives in (the founder, 2026-10-21: six playlists on mood words alone
  /// came out as two groups of three, the bright ones sharing up to 92% of their songs).
  /// Keys and colours are the app's mood doors (MoodDoors.swift).
  public struct MoodMix: Sendable {
    public let key: String
    public let title: String
    public let hexColor: String
    let energies: Set<String>?
    let valences: Set<String>?
    let target: TagVector
    let avoid: Set<String>
    /// Scenarios (scenarios.ts SONG_SCENARIOS) a song can be for to belong here.
    let scenarios: Set<String>
    /// Subgenres (taxonomy.ts SUBGENRES, lowercased) a song can sound like to belong here.
    let sounds: Set<String>

    init(
      key: String,
      title: String,
      hexColor: String,
      energies: Set<String>?,
      valences: Set<String>?,
      moods: [String: Double],
      avoid: Set<String>,
      scenarios: Set<String>,
      sounds: Set<String>
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
      self.scenarios = scenarios
      self.sounds = sounds
    }

    /// How well a song belongs, or nil when it may not join at all. It must pass the energy,
    /// valence and avoid gates and fit the moods (0 to 1); then, when the song carries a
    /// scenario or a sound at all, one of them must be this mix's (its anchor), and each
    /// adds to the fit: a scenario 0.25, a sound 0.15. A song with neither (tags from a
    /// server before them) is judged on its moods, as before.
    func fit(_ song: MixSong) -> Double? {
      guard let moodFit = moodFit(song) else { return nil }
      let songScenarios = song.scenarios, songSounds = song.sounds
      if songScenarios.isEmpty, songSounds.isEmpty { return moodFit }
      let forThis = !songScenarios.isDisjoint(with: scenarios)
      let soundsLikeThis = !songSounds.isDisjoint(with: sounds)
      guard forThis || soundsLikeThis else { return nil }
      return ListeningShelves.rounded(moodFit + (forThis ? 0.25 : 0) + (soundsLikeThis ? 0.15 : 0))
    }

    /// The gates and the mood fit alone.
    func moodFit(_ song: MixSong) -> Double? {
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

  /// The five mood mixes, keyed and coloured like the mood doors. Their moods are the
  /// catalog's song taxonomy (taxonomy.ts MOODS); energy is low / medium / high and valence
  /// dark / bittersweet / bright, read per song.
  public static let moodMixes: [MoodMix] = [
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
      avoid: ["tender", "peaceful", "serene", "somber", "mournful", "lonely", "melancholic"],
      scenarios: [
        "workout", "hype_pump_up", "motivation", "empowerment", "confidence", "protest_defiance",
        "victory_lap", "pregame",
      ],
      sounds: [
        "pop punk", "punk rock", "emo", "post-punk", "garage rock", "hard rock", "post-hardcore",
        "hardcore punk", "grunge", "folk punk", "alternative metal",
      ]
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
        // Songs that pull at you are not focus music.
        "melancholic", "vulnerable", "bittersweet", "lonely", "mournful",
      ],
      scenarios: ["studying_focus", "chill_background", "meditation", "coding"],
      sounds: [
        "post-rock", "ambient techno", "downtempo", "modern classical", "neoclassical",
        "minimalism", "contemporary classical", "new age", "lo-fi hip-hop", "chamber folk",
        "idm", "electronica", "cool jazz",
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
        // A sad low-energy song is not winding down.
        "brooding", "haunting", "eerie", "melancholic", "despairing", "mournful",
      ],
      scenarios: ["winding_down", "sunday_morning", "falling_asleep", "rainy_day"],
      sounds: [
        "indie folk", "acoustic folk", "chamber folk", "chamber pop", "vocal jazz",
        "traditional pop", "soft rock", "bedroom pop", "slowcore",
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
      avoid: ["playful", "joyful", "euphoric", "triumphant", "uplifting", "empowering"],
      scenarios: ["driving_at_night", "crying_alone", "processing_grief", "comedown"],
      sounds: [
        "trip-hop", "dream pop", "synth-pop", "darkwave", "art pop", "downtempo", "shoegaze",
        "art rock", "electropop", "synthwave", "gothic rock", "slowcore",
      ]
    ),
    // Road Trip folded in (founder, 2026-10-21): on the founder's library the two kept most
    // of their songs in common even with their own purposes and sounds, so they are one
    // playlist that takes both: bright or bittersweet, party and singalong songs as well as
    // driving and summer ones, pop as well as guitar rock.
    MoodMix(
      key: "feel-good",
      title: "Feel Good",
      hexColor: "#D64B8C",
      energies: ["medium", "high"],
      valences: ["bright", "bittersweet"],
      moods: [
        "playful": 1, "hopeful": 1, "joyful": 1, "euphoric": 1, "uplifting": 1,
        "triumphant": 0.8, "energetic": 0.8, "nostalgic": 0.7, "romantic": 0.6,
        "confident": 0.6, "defiant": 0.4, "wistful": 0.3,
      ],
      avoid: [
        "somber", "melancholic", "mournful", "despairing", "brooding", "haunting", "eerie",
        "lonely",
      ],
      scenarios: [
        "party", "singalong_karaoke", "celebration", "getting_ready", "summer_anthem", "new_love",
        "first_dance", "pregame", "road_trip", "driving_at_night", "nostalgia_throwback",
      ],
      sounds: [
        "indie pop", "dance-pop", "funk", "disco", "power pop", "synth-pop", "electropop",
        "britpop", "neo-soul", "soul", "bedroom pop", "indie rock", "folk rock", "americana",
        "country rock", "alternative rock", "pop rock", "classic rock", "soft rock",
      ]
    ),
  ]

  /// The mood mixes in the order this part of the day suits them: the quiet ones first at
  /// night, the lively ones first by day.
  public static func moodMixOrder(for daypart: Daypart) -> [String] {
    switch daypart {
    case .morning: return ["focus", "get-pumped", "feel-good", "wind-down", "late-night"]
    case .afternoon: return ["focus", "feel-good", "get-pumped", "wind-down", "late-night"]
    case .evening: return ["feel-good", "wind-down", "late-night", "get-pumped", "focus"]
    case .late: return ["late-night", "wind-down", "focus", "feel-good", "get-pumped"]
    }
  }

  // MARK: Covers (founder, 2026-10-21)

  /// The versions of each mood mix's drawn cover (cassette.digital's /api/covers/mix), in the
  /// order the daily pick walks them. Road Trip only shows on the web.
  public static let moodCoverVariants: [String: [String]] = [
    "get-pumped": ["chrome", "aerobics"],
    "focus": ["head", "script"],
    "wind-down": ["window"],
    "late-night": ["show", "broadcast"],
    "feel-good": ["memphis", "smear"],
    "road-trip": ["red-rock", "teal-sky", "cloud"],
  ]

  /// The version of a mood mix's cover for `date`: one a day in turn, the same for everyone
  /// on a given day, turning over at the listener's own midnight. Get Pumped picks by its
  /// songs instead (`getPumpedCoverVariant`).
  public static func dailyCoverVariant(key: String, on date: Date, timeZone: TimeZone = .current) -> String? {
    guard let variants = moodCoverVariants[key], !variants.isEmpty else { return nil }
    let localMillis = (date.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: date))) * 1000
    let day = Int((localMillis / 86_400_000).rounded(.down))
    return variants[((day % variants.count) + variants.count) % variants.count]
  }

  /// Subgenre words that make a song heavy for Get Pumped's cover.
  static let heavySoundWords = [
    "metal", "punk", "hardcore", "deathcore", "grunge", "screamo", "thrash", "doom", "sludge",
    "stoner", "hard rock", "garage rock", "noise rock",
  ]
  /// Moods that make a song with no subgenres heavy.
  static let heavyMoods: Set<String> = ["aggressive", "intense", "rebellious"]

  /// Get Pumped's cover from its songs: chrome when at least 40% of the songs that say
  /// anything are heavy (by their subgenres, else their moods), the aerobics one when the mix
  /// is more fun than heavy. A mix none of whose songs say anything gets chrome.
  public static func getPumpedCoverVariant(_ songs: [MixSong]) -> String {
    var heavy = 0
    var counted = 0
    for song in songs {
      let sounds = song.sounds
      if !sounds.isEmpty {
        counted += 1
        if sounds.contains(where: isHeavySound) { heavy += 1 }
        continue
      }
      let moods = song.moods
      guard !moods.isEmpty else { continue }
      counted += 1
      if !moods.isDisjoint(with: heavyMoods) { heavy += 1 }
    }
    guard counted > 0 else { return "chrome" }
    return Double(heavy) / Double(counted) >= 0.4 ? "chrome" : "aerobics"
  }

  /// A subgenre that reads as heavy: one of `heavySoundWords` inside it, or the word emo.
  static func isHeavySound(_ sound: String) -> Bool {
    let lowered = sound.lowercased()
    if heavySoundWords.contains(where: { lowered.contains($0) }) { return true }
    return lowered.split(whereSeparator: { $0 == " " || $0 == "-" }).contains("emo")
  }

  /// Late Night's guest: the artist with the most songs in the mix, whoever appears first on
  /// a tie, as `names` (one per song, in mix order) spell it. Nil when no song has one.
  public static func headlineArtist(_ names: [String]) -> String? {
    var counts = [String: Int]()
    var first = [String: Int]()
    var shown = [String: String]()
    for (position, name) in names.enumerated() {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      let key = normalizedArtistName(trimmed)
      guard !key.isEmpty else { continue }
      counts[key, default: 0] += 1
      if first[key] == nil {
        first[key] = position
        shown[key] = trimmed
      }
    }
    let best = counts.max { a, b in
      a.value != b.value ? a.value < b.value : first[a.key, default: 0] > first[b.key, default: 0]
    }
    return best.flatMap { shown[$0.key] }
  }

  /// Each song's one mood playlist: of the mixes it may join, the one it fits best relative
  /// to how well that mix's songs fit in general (its median), so a playlist with a generous
  /// pool does not take every shared song. Ties go to the mix listed first in `moodMixes`.
  /// Replaces first come, first served in row order, which made what each playlist got
  /// depend on the time of day.
  public static func moodHomes(_ songs: [MixSong]) -> [String: String] {
    var fits = [String: [String: Double]]()
    var median = [String: Double]()
    for mood in moodMixes {
      var byID = [String: Double]()
      for song in songs {
        if let fit = mood.fit(song) { byID[song.songID] = fit }
      }
      fits[mood.key] = byID
      let sorted = byID.values.sorted()
      if !sorted.isEmpty { median[mood.key] = sorted[sorted.count / 2] }
    }
    var homes = [String: (key: String, ratio: Double)]()
    for mood in moodMixes {
      guard let middle = median[mood.key], middle > 0 else { continue }
      for (id, fit) in fits[mood.key] ?? [:] {
        let ratio = rounded(fit / middle)
        if let current = homes[id], current.ratio >= ratio { continue }
        homes[id] = (mood.key, ratio)
      }
    }
    return homes.mapValues(\.key)
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
  /// the five best by fit to the mood (55%) and closeness in mood and sound to the songs
  /// already in (45%), with a small pull toward the seed's genre and away from records more
  /// than a dozen years from the seed's. No artist within `mixArtistGap` songs of itself (the
  /// mix ends early rather than break that), at most two songs per album and three per
  /// artist. Songs in `excluding` (an earlier playlist's, BUG-497) never join.
  public static func moodMix<R: RandomNumberGenerator>(
    _ mood: MoodMix,
    songs: [MixSong],
    favored: Set<String>,
    excluding: Set<String> = [],
    count: Int = madeMixLength,
    minSongs: Int = madeMixMinSongs,
    using rng: inout R
  )
    -> [String] {
    var eligible: [(song: MixSong, fit: Double)] = []
    for song in songs where !excluding.contains(song.songID) {
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
      score: { candidate, closeness in
        var score = 0.55 * candidate.fit + 0.45 * closeness.score
        if let genre = seed.song.genre, candidate.song.genre == genre { score += 0.08 }
        if seed.song.year > 0, candidate.song.year > 0, abs(candidate.song.year - seed.song.year) > 12 {
          score -= 0.08
        }
        return rounded(score)
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
      .map { SongCandidate(songID: $0.songID, albumID: $0.albumID, artistKey: $0.artistKey, tags: $0.tags) }
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
  /// per artist, artists spaced out, never a song in `excluding` (an earlier playlist's,
  /// BUG-497). [] when fewer than `minSongs` qualify.
  public static func beenAWhile<R: RandomNumberGenerator>(
    _ songs: [PlayedSong],
    excluding: Set<String> = [],
    now: Date,
    count: Int = madeMixLength,
    minSongs: Int = madeMixMinSongs,
    using rng: inout R
  )
    -> [String] {
    let cutoff = now.addingTimeInterval(-45 * 86400)
    let pool = songs
      .filter { !excluding.contains($0.songID) }
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

  /// The songs reordered so an artist never comes back within `gap` songs (the founder's
  /// rule, 2026-08-20). Each step takes the first song that fits, unless an artist's songs
  /// still to place only just fit in what is left: then that artist's first, so it is not
  /// left to bunch up at the end. A song that still cannot fit is left out rather than played
  /// too soon (BUG-495: Weekday Evenings used to end on three Novo Amor songs in a row).
  public static func spacedByArtist(
    _ ids: [String],
    artistOf: (String) -> String,
    gap: Int = mixArtistGap
  )
    -> [String] {
    var remaining = ids
    var left = [String: Int]()
    for id in ids { left[artistOf(id), default: 0] += 1 }
    var result = [String]()
    result.reserveCapacity(ids.count)
    while !remaining.isEmpty {
      let recent = Set(result.suffix(gap).map(artistOf))
      // An artist with n songs left needs (n - 1) * (gap + 1) + 1 places.
      let fits = remaining.indices.filter { !recent.contains(artistOf(remaining[$0])) }
      let tight = fits.first { i in
        let n = left[artistOf(remaining[i]), default: 0]
        return n > 1 && (n - 1) * (gap + 1) + 1 >= remaining.count
      }
      guard let index = tight ?? fits.first else { break }
      let id = remaining.remove(at: index)
      left[artistOf(id), default: 0] -= 1
      result.append(id)
    }
    return result
  }

  /// Grows a mix from `seed`: each step scores every song still allowed against the songs
  /// already in (their summed tags: `likeness`) and takes one of the best five at random.
  /// Stops early rather than bring an artist back within `mixArtistGap` songs.
  static func grow<R: RandomNumberGenerator>(
    from seed: MixSong,
    candidates: [(song: MixSong, fit: Double)],
    count: Int,
    score: ((song: MixSong, fit: Double), Likeness) -> Double,
    using rng: inout R
  )
    -> [String] {
    var picked = [seed.songID]
    var pickedArtists = [seed.artistKey]
    var perAlbum = [seed.albumID: 1]
    var perArtist = [seed.artistKey: 1]
    var centroid = seed.tags
    var pool = candidates.filter { $0.song.songID != seed.songID }
    var preparedByID = [String: Prepared](minimumCapacity: pool.count)
    for candidate in pool { preparedByID[candidate.song.songID] = Prepared(candidate.song.tags) }
    while picked.count < count, !pool.isEmpty {
      let recentArtists = Set(pickedArtists.suffix(mixArtistGap))
      let options = pool.filter {
        perAlbum[$0.song.albumID, default: 0] < mixMaxPerAlbum
          && perArtist[$0.song.artistKey, default: 0] < mixMaxPerArtist
          && !recentArtists.contains($0.song.artistKey)
      }
      guard !options.isEmpty else { break }
      let preparedCentroid = Prepared(centroid)
      let best = options
        .map { (candidate: $0, score: score($0, likeness(preparedByID[$0.song.songID]!, preparedCentroid))) }
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
