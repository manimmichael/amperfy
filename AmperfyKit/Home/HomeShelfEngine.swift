//
//  HomeShelfEngine.swift
//  AmperfyKit
//
//  The home-shelf algorithm (Recent / Albums / Artists), ported 1:1 from the
//  TypeScript reference engine at apps/cassette/src/lib/home-shelves/. This is the
//  SAME algorithm the web runs; the two are kept genuinely in sync by the shared
//  golden fixtures (home-shelves-fixtures.json) — HomeShelfConformanceTests feeds
//  each fixture's input here and asserts the output matches web's exactly.
//
//  Pure: same input -> same output, no clock, no I/O. `HomeManager` builds a
//  `ShelfInput` from Core Data and calls `buildHomeShelves`.
//
//  If you change this, change the TS engine too (or vice versa), regenerate the
//  fixtures, and keep every platform's conformance test green. See the spec at
//  apps/cassette/src/lib/home-shelves/README.md.
//

import Foundation

// MARK: - Contract types (Codable so the fixtures decode into them)

public struct ShelfAlbum: Codable {
  public let key: String
  public let title: String
  public let artist: String
  public let genre: String?
  public let trackCount: Int
  public let playedTrackCount: Int
  public let totalPlays: Int
  public let lastPlayedAt: Int64?
  public let addedAt: Int64?

  public init(key: String, title: String, artist: String, genre: String?, trackCount: Int,
              playedTrackCount: Int, totalPlays: Int, lastPlayedAt: Int64?, addedAt: Int64?) {
    self.key = key; self.title = title; self.artist = artist; self.genre = genre
    self.trackCount = trackCount; self.playedTrackCount = playedTrackCount
    self.totalPlays = totalPlays; self.lastPlayedAt = lastPlayedAt; self.addedAt = addedAt
  }
}

public struct ShelfArtist: Codable {
  public let key: String
  public let name: String
  public let genre: String?
  public let trackCount: Int
  public let albumCount: Int
  public let totalPlays: Int
  public let lastPlayedAt: Int64?
  public let addedAt: Int64?

  public init(key: String, name: String, genre: String?, trackCount: Int, albumCount: Int,
              totalPlays: Int, lastPlayedAt: Int64?, addedAt: Int64?) {
    self.key = key; self.name = name; self.genre = genre; self.trackCount = trackCount
    self.albumCount = albumCount; self.totalPlays = totalPlays
    self.lastPlayedAt = lastPlayedAt; self.addedAt = addedAt
  }
}

public struct ShelfPlaylist: Codable {
  public let key: String
  public let name: String
  public let lastPlayedAt: Int64?

  public init(key: String, name: String, lastPlayedAt: Int64?) {
    self.key = key; self.name = name; self.lastPlayedAt = lastPlayedAt
  }
}

public struct ShelfInput: Codable {
  public let albums: [ShelfAlbum]
  public let artists: [ShelfArtist]
  public let playlists: [ShelfPlaylist]
  public let recentArtistKeys: [String]?
  public let now: Int64
  public let seed: String

  public init(albums: [ShelfAlbum], artists: [ShelfArtist], playlists: [ShelfPlaylist],
              recentArtistKeys: [String]?, now: Int64, seed: String) {
    self.albums = albums; self.artists = artists; self.playlists = playlists
    self.recentArtistKeys = recentArtistKeys; self.now = now; self.seed = seed
  }
}

public enum RecentKind: String, Codable { case album, artist, playlist }
public enum AlbumReason: String, Codable { case forgotten, deepcut, rekindle, fill }
public enum ArtistReason: String, Codable { case added, cold, affinity, recency, fill }

public struct RecentPick: Codable, Equatable { public let kind: RecentKind; public let key: String }
public struct AlbumPick: Codable, Equatable { public let key: String; public let reason: AlbumReason }
public struct ArtistPick: Codable, Equatable { public let key: String; public let reason: ArtistReason }

public struct HomeShelves: Codable, Equatable {
  public let resume: RecentPick?
  public let recent: [RecentPick]
  public let albums: [AlbumPick]
  public let artists: [ArtistPick]
}

// MARK: - Configuration (mirrors config.ts; the one place to tune)

public struct ShelfConfig {
  public struct Albums {
    public let deepCutMinTracks: Int
    public let deepCutPlayedMin: Int
    public let deepCutPlayedMax: Int
    public let rekindleMinPlays: Int
    public let coldDays: Int
    public let turnoverDays: Int
    public let forgottenPerSecondary: Int
  }
  public struct Artists {
    public let coldDays: Int
    public let turnoverDays: Int
    public let affinityRecentDays: Int
    public let blendCycle: [String]
  }
  public struct Recent {
    public let max: Int
    public let splitResume: Bool
  }
  public let targetCount: Int
  public let carouselCap: Int
  public let albums: Albums
  public let artists: Artists
  public let recent: Recent
}

public let HOME_SHELF_CONFIG = ShelfConfig(
  targetCount: 10,
  carouselCap: 12,
  albums: .init(deepCutMinTracks: 3, deepCutPlayedMin: 1, deepCutPlayedMax: 2,
                rekindleMinPlays: 5, coldDays: 60, turnoverDays: 7, forgottenPerSecondary: 3),
  artists: .init(coldDays: 60, turnoverDays: 7, affinityRecentDays: 30,
                 blendCycle: ["added", "cold", "affinity"]),
  recent: .init(max: 12, splitResume: true)
)

private let DAY_MS: Int64 = 86_400_000

// MARK: - Shared scoring primitives (must match scoring.ts exactly)

private func dayNumber(_ nowMs: Int64) -> Int64 { nowMs / DAY_MS }

/// FNV-1a, 32-bit — the daily-rotation hash. Iterates UTF-16 code units to match
/// JS `charCodeAt`; `&*` is the 32-bit wrapping multiply (JS `Math.imul`).
private func hashString(_ s: String) -> UInt32 {
  var h: UInt32 = 0x811c_9dc5
  for c in s.utf16 {
    h ^= UInt32(c)
    h = h &* 0x0100_0193
  }
  return h
}

/// Left-rotate by a per-(seed, day) offset — turnover while preserving priority order.
private func rotatedDaily<T>(_ items: [T], _ seed: String, _ nowMs: Int64) -> [T] {
  if items.count <= 1 { return items }
  let off = Int(hashString("\(seed):\(dayNumber(nowMs))") % UInt32(items.count))
  return Array(items[off...] + items[..<off])
}

private func isOlderThanDays(_ then: Int64?, _ nowMs: Int64, _ days: Int) -> Bool {
  guard let t = then else { return true }
  return nowMs - t >= Int64(days) * DAY_MS
}

private func isWithinDays(_ then: Int64?, _ nowMs: Int64, _ days: Int) -> Bool {
  guard let t = then else { return false }
  let diff = nowMs - t
  return diff < Int64(days) * DAY_MS && diff >= 0
}

/// compareRanked as a strict "a before b" predicate (total, no ties): played-before-
/// unplayed -> most-recent lastPlayed -> higher totalPlays -> newer added -> key asc.
private func rankedBefore(_ a: ShelfArtist, _ b: ShelfArtist) -> Bool {
  let ap = a.lastPlayedAt != nil, bp = b.lastPlayedAt != nil
  if ap != bp { return ap }
  if ap, bp, a.lastPlayedAt! != b.lastPlayedAt! { return a.lastPlayedAt! > b.lastPlayedAt! }
  if a.totalPlays != b.totalPlays { return a.totalPlays > b.totalPlays }
  let aa = a.addedAt ?? 0, ba = b.addedAt ?? 0
  if aa != ba { return aa > ba }
  return a.key < b.key
}

// MARK: - Recent shelf (recent.ts)

private func buildRecent(_ input: ShelfInput, _ cfg: ShelfConfig) -> (resume: RecentPick?, recent: [RecentPick]) {
  let eligibleArtists = Set(input.recentArtistKeys ?? [])
  struct Dated { let kind: RecentKind; let key: String; let at: Int64 }
  var merged: [Dated] = []
  for a in input.albums where a.lastPlayedAt != nil {
    merged.append(Dated(kind: .album, key: a.key, at: a.lastPlayedAt!))
  }
  for ar in input.artists where ar.lastPlayedAt != nil && eligibleArtists.contains(ar.key) {
    merged.append(Dated(kind: .artist, key: ar.key, at: ar.lastPlayedAt!))
  }
  for p in input.playlists where p.lastPlayedAt != nil {
    merged.append(Dated(kind: .playlist, key: p.key, at: p.lastPlayedAt!))
  }
  merged.sort { x, y in
    if x.at != y.at { return x.at > y.at }
    return (x.kind.rawValue + x.key) < (y.kind.rawValue + y.key)
  }
  var seen = Set<String>()
  var ordered: [RecentPick] = []
  for m in merged {
    let id = "\(m.kind.rawValue):\(m.key)"
    if seen.contains(id) { continue }
    seen.insert(id)
    ordered.append(RecentPick(kind: m.kind, key: m.key))
  }
  if cfg.recent.splitResume, !ordered.isEmpty {
    let resume = ordered[0]
    return (resume, Array(ordered.dropFirst().prefix(cfg.recent.max)))
  }
  return (nil, Array(ordered.prefix(cfg.recent.max)))
}

// MARK: - Albums shelf (albums.ts)

private func buildAlbums(_ albums: [ShelfAlbum], _ cfg: ShelfConfig, _ now: Int64,
                         _ seed: String, _ exclude: Set<String>) -> [AlbumPick] {
  let c = cfg.albums
  let eligible = albums.filter { !exclude.contains($0.key) }

  func byOldestAdded(_ a: ShelfAlbum, _ b: ShelfAlbum) -> Bool {
    let ax = a.addedAt ?? 0, bx = b.addedAt ?? 0
    if ax != bx { return ax < bx }
    return a.key < b.key
  }

  let forgotten = rotatedDaily(
    eligible.filter { $0.lastPlayedAt == nil && $0.totalPlays == 0 }.sorted(by: byOldestAdded),
    seed, now)
  let deep = rotatedDaily(
    eligible.filter {
      $0.trackCount >= c.deepCutMinTracks &&
      $0.playedTrackCount >= c.deepCutPlayedMin &&
      $0.playedTrackCount <= c.deepCutPlayedMax
    }, seed, now)
  let rekindle = rotatedDaily(
    eligible.filter { $0.totalPlays >= c.rekindleMinPlays && isOlderThanDays($0.lastPlayedAt, now, c.coldDays) }
      .sorted { $0.totalPlays > $1.totalPlays },
    seed, now)

  var picked: [AlbumPick] = []
  var used = Set<String>()
  var fi = 0, di = 0, ri = 0
  var preferDeep = true

  func push(_ a: ShelfAlbum?, _ reason: AlbumReason) -> Bool {
    guard let a = a, !used.contains(a.key) else { return false }
    used.insert(a.key)
    picked.append(AlbumPick(key: a.key, reason: reason))
    return true
  }
  func nextUnused(_ pool: [ShelfAlbum], _ from: Int) -> Int {
    var i = from
    while i < pool.count && used.contains(pool[i].key) { i += 1 }
    return i
  }

  while picked.count < cfg.carouselCap {
    var progressed = false
    var n = 0
    while n < c.forgottenPerSecondary && picked.count < cfg.carouselCap {
      fi = nextUnused(forgotten, fi)
      if push(fi < forgotten.count ? forgotten[fi] : nil, .forgotten) {
        fi += 1; progressed = true
      } else { break }
      n += 1
    }
    if picked.count >= cfg.carouselCap { break }
    func tryDeep() -> Bool {
      di = nextUnused(deep, di)
      if push(di < deep.count ? deep[di] : nil, .deepcut) { di += 1; return true }
      return false
    }
    func tryRekindle() -> Bool {
      ri = nextUnused(rekindle, ri)
      if push(ri < rekindle.count ? rekindle[ri] : nil, .rekindle) { ri += 1; return true }
      return false
    }
    let secondary = preferDeep ? (tryDeep() || tryRekindle()) : (tryRekindle() || tryDeep())
    preferDeep.toggle()
    if secondary { progressed = true }
    if !progressed { break }
  }

  if picked.count < cfg.targetCount {
    for a in eligible.sorted(by: byOldestAdded) {
      if picked.count >= cfg.targetCount { break }
      if used.contains(a.key) { continue }
      used.insert(a.key)
      picked.append(AlbumPick(key: a.key, reason: .fill))
    }
  }
  return Array(picked.prefix(cfg.carouselCap))
}

// MARK: - Artists shelf (artists.ts)

private func buildArtists(_ input: ShelfInput, _ cfg: ShelfConfig, _ exclude: Set<String>) -> [ArtistPick] {
  let c = cfg.artists
  let now = input.now
  let eligible = input.artists.filter { !exclude.contains($0.key) }

  func normGenre(_ g: String?) -> String? {
    guard let g = g else { return nil }
    let t = g.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return t.isEmpty ? nil : t
  }

  let windowMs = Double(c.affinityRecentDays) * Double(DAY_MS)
  var weights: [String: Double] = [:]
  func addWeight(_ genre: String?, _ lastPlayedAt: Int64?) {
    guard let g = normGenre(genre), let t = lastPlayedAt else { return }
    if !isWithinDays(t, now, c.affinityRecentDays) { return }
    let w = max(0, 1 - Double(now - t) / windowMs)
    weights[g, default: 0] += w
  }
  for a in input.albums { addWeight(a.genre, a.lastPlayedAt) }
  for ar in input.artists { addWeight(ar.genre, ar.lastPlayedAt) }

  func artistGenreWeight(_ a: ShelfArtist) -> Double {
    guard let g = normGenre(a.genre) else { return 0 }
    return weights[g] ?? 0
  }
  func playedRecently(_ a: ShelfArtist) -> Bool {
    a.lastPlayedAt != nil && !isOlderThanDays(a.lastPlayedAt, now, c.coldDays)
  }
  func notInRotation(_ a: ShelfArtist) -> Bool { !playedRecently(a) }
  func matchesTaste(_ a: ShelfArtist) -> Bool { artistGenreWeight(a) > 0 }

  let affinity = rotatedDaily(
    eligible.filter { notInRotation($0) && matchesTaste($0) }.sorted { a, b in
      let wa = artistGenreWeight(a), wb = artistGenreWeight(b)
      if wa != wb { return wa > wb }
      let aa = a.addedAt ?? 0, ba = b.addedAt ?? 0
      if aa != ba { return aa > ba }
      return a.key < b.key
    }, input.seed, now)

  let added = rotatedDaily(
    eligible.filter { $0.lastPlayedAt == nil && !matchesTaste($0) }.sorted { a, b in
      let aa = a.addedAt ?? 0, ba = b.addedAt ?? 0
      if aa != ba { return aa > ba }
      return a.key < b.key
    }, input.seed, now)

  let cold = rotatedDaily(
    eligible.filter {
      $0.lastPlayedAt != nil && isOlderThanDays($0.lastPlayedAt, now, c.coldDays) && !matchesTaste($0)
    }.sorted { a, b in
      if a.totalPlays != b.totalPlays { return a.totalPlays > b.totalPlays }
      return a.key < b.key
    }, input.seed, now)

  let pools: [String: [ShelfArtist]] = ["added": added, "cold": cold, "affinity": affinity]
  var ptr: [String: Int] = ["added": 0, "cold": 0, "affinity": 0]
  var picked: [ArtistPick] = []
  var used = Set<String>()

  func takeFrom(_ reason: String) -> Bool {
    let pool = pools[reason] ?? []
    var i = ptr[reason] ?? 0
    while i < pool.count && used.contains(pool[i].key) { i += 1 }
    ptr[reason] = i + 1
    guard i < pool.count else { return false }
    let a = pool[i]
    used.insert(a.key)
    picked.append(ArtistPick(key: a.key, reason: ArtistReason(rawValue: reason) ?? .fill))
    return true
  }

  var guardN = 0
  while picked.count < cfg.carouselCap && guardN < 10_000 {
    guardN += 1
    var progressed = false
    for reason in c.blendCycle {
      if picked.count >= cfg.carouselCap { break }
      if takeFrom(reason) { progressed = true }
    }
    if !progressed { break }
  }

  if picked.count < cfg.targetCount {
    for a in eligible.filter({ !used.contains($0.key) }).sorted(by: rankedBefore) {
      if picked.count >= cfg.targetCount { break }
      used.insert(a.key)
      picked.append(ArtistPick(key: a.key, reason: .fill))
    }
  }
  return Array(picked.prefix(cfg.carouselCap))
}

// MARK: - Orchestrator (index.ts)

public func buildHomeShelves(_ input: ShelfInput, config cfg: ShelfConfig = HOME_SHELF_CONFIG) -> HomeShelves {
  let (resume, recent) = buildRecent(input, cfg)
  var excludeAlbums = Set<String>()
  var excludeArtists = Set<String>()
  for pick in ([resume].compactMap { $0 } + recent) {
    if pick.kind == .album { excludeAlbums.insert(pick.key) }
    else if pick.kind == .artist { excludeArtists.insert(pick.key) }
  }
  let albums = buildAlbums(input.albums, cfg, input.now, input.seed, excludeAlbums)
  let artists = buildArtists(input, cfg, excludeArtists)
  return HomeShelves(resume: resume, recent: recent, albums: albums, artists: artists)
}
