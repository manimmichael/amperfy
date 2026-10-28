//
//  CloudHome.swift
//  Amperfy
//
//  Cassette: One Home on this phone (founder, 2026-10-28). The cloud's Home answer
//  (HomeStore) found among what the phone holds: each record by the first of its songs on the
//  phone (cassette_local_id -> DeviceOwnership -> the Subsonic song -> its album), each
//  playlist by its cloud id, each station by its slug on the hub's dial, each artist through
//  their songs. A row the phone can't fill comes out empty and is hidden. The phone's Home
//  (HomeManager, HomeVC) and CarPlay draw the same rows from the one instance, so the car can
//  never show a different Home from the phone.
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

import AmperfyKit
import CoreData
import Foundation

@MainActor
final class CloudHome: NSObject {
  /// One of the cloud's rows, with what the phone holds of it.
  struct Row {
    /// The cloud's row id ("on-repeat").
    let id: String
    /// The Home section it is drawn in (the phone and the car key their rows by it).
    let section: HomeSection
    let shout: String
    let answer: String
    /// Records, playlists, stations or artists on the phone, in the cloud's order.
    var items: [PlayableContainable] = []
    /// The made-for-you row's playlists, Lately first.
    var mixes: [HomeManager.MadeForYouMix] = []
    /// Resume: the song of the record played last, when it is on the phone.
    var song: Song?
    /// The reaching row's shelf.
    var shelf: Shelf?
    /// All shelves: how many of today's shelves the phone holds records of.
    var shelfCount = 0

    /// Whether the phone holds anything of the row.
    var isFilled: Bool {
      switch section {
      case .moodDoors: return !mixes.isEmpty
      case .reach: return shelf.map(CloudHome.isDrawable) ?? false
      case .allShelves: return shelfCount > 0
      default: return !items.isEmpty
      }
    }
  }

  /// A reaching shelf, with the records of it on the phone.
  struct Shelf {
    let id: String
    let kind: String
    let shout: String
    let answer: String
    let onHome: Bool
    let albums: [Album]
    /// Nostalgia's mix of songs from its years, when enough of it is on the phone.
    let mix: HomeManager.MadeForYouMix?

    var isDeepDive: Bool { kind == "deep-dive" }
  }

  /// Posted on the main actor when the rows change.
  static let didChange = Notification.Name("cassette.cloudHomeChanged")

  /// The rows the phone can draw, in the cloud's order (an empty row is left in, so a host
  /// can tell a row it can't fill from one the cloud did not send; `drawnRows` drops them).
  private(set) var rows: [Row] = []
  /// Every shelf made today that the phone holds a record of, the one on Home first.
  private(set) var shelves: [Shelf] = []
  /// Moves whenever the rows change.
  private(set) var generation = 0

  /// The rows the phone can fill, in order.
  var drawnRows: [Row] { rows.filter(\.isFilled) }

  /// Whether the cloud's Home is drawn: an answer is held and the phone holds something of
  /// it. Otherwise the phone's own Home stands in (a first launch offline, or music still on
  /// its way to the phone).
  var isDrawn: Bool { !drawnRows.isEmpty }

  func row(_ section: HomeSection) -> Row? {
    rows.first { $0.section == section }
  }

  private let account: Account
  private let storage: PersistentStorage
  private let player: PlayerFacade

  private init(account: Account, storage: PersistentStorage, player: PlayerFacade) {
    self.account = account
    self.storage = storage
    self.player = player
    super.init()
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(sourcesChanged), name: .cassetteHomeChanged, object: nil)
    center.addObserver(
      self,
      selector: #selector(sourcesChanged),
      name: CassetteLibraryFilterProvider.filterChangedNotification,
      object: nil
    )
    // Resume follows what is playing on the phone.
    for name in [Notification.Name.playerPlay, .playerPause, .playerStop] {
      center.addObserver(self, selector: #selector(sourcesChanged), name: name, object: nil)
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  private static var current: CloudHome?

  /// The one instance for the active account (the phone's Home and the car share it).
  static func shared(account: Account, storage: PersistentStorage, player: PlayerFacade) -> CloudHome {
    if let current, current.account.managedObject.objectID == account.managedObject.objectID {
      return current
    }
    let made = CloudHome(account: account, storage: storage, player: player)
    current = made
    return made
  }

  // MARK: - Refresh

  private var pendingRefresh: DispatchWorkItem?

  /// The answer, the music on the phone or what is playing changed: look again shortly (a
  /// burst of notifications is one look).
  @objc
  private func sourcesChanged() {
    pendingRefresh?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.refresh() }
    pendingRefresh = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
  }

  /// What the expensive part (records, mixes, artists, stations, shelves) was found from:
  /// the answer's revision, the songs on the phone and the hub's stations.
  private var foundFrom: String?
  private var found: (rows: [Row], shelves: [Shelf])?

  /// Find the answer among what the phone holds now. Records are looked up again only when
  /// the answer or the music on the phone changed; playlists and Resume every time (cheap).
  /// Posts `didChange` when the rows moved.
  func refresh() {
    let store = HomeStore.shared
    guard let answer = store.answer else {
      publish([], [])
      return
    }
    let isOnPhone = HomeManager.makeOnPhoneCheck(storage: storage)
    let radios = storage.main.library.getRadios(for: account)
    let signature = "\(store.revision)|\(isOnPhone.owned?.trackIds.count ?? -1)|\(isOnPhone.owned?.albumIds.count ?? -1)|\(radios.count)"
    if signature != foundFrom || found == nil {
      found = find(answer, isOnPhone: isOnPhone, radios: radios)
      foundFrom = signature
    }
    guard var rows = found?.rows else { return }
    for index in rows.indices {
      switch rows[index].section {
      case .yourPlaylists:
        rows[index].items = playlists(answer.rows.first { $0.id == rows[index].id }, isOnPhone: isOnPhone)
      case .resume:
        fillResume(&rows[index], answer: answer, isOnPhone: isOnPhone)
      default:
        break
      }
    }
    publish(rows, found?.shelves ?? [])
  }

  private func publish(_ rows: [Row], _ shelves: [Shelf]) {
    guard Self.signature(rows, shelves) != Self.signature(self.rows, self.shelves) else { return }
    self.rows = rows
    self.shelves = shelves
    generation += 1
    NotificationCenter.default.post(name: Self.didChange, object: self)
  }

  private static func signature(_ rows: [Row], _ shelves: [Shelf]) -> [String] {
    rows.map { row in
      ([row.id, row.shout, row.answer, row.song?.id ?? "", String(row.shelfCount)]
        + row.items.map(HomeManager.stableID(for:))
        + row.mixes.map { ([$0.id, $0.title, $0.coverVariant ?? ""] + $0.songs.map(\.id)).joined(separator: ",") }
        + (row.shelf.map { [$0.id] + $0.albums.map(\.id) } ?? []))
        .joined(separator: "|")
    } + shelves.map { ([$0.id, $0.mix?.id ?? ""] + $0.albums.map(\.id)).joined(separator: ",") }
  }

  // MARK: - Finding the answer on the phone

  /// Every record, mix and artist of the answer, found among the songs on the phone in one
  /// pass: one ownership read, one song fetch.
  private func find(
    _ answer: HomeAnswer,
    isOnPhone: HomeManager.OnPhoneCheck,
    radios: [Radio]
  )
    -> (rows: [Row], shelves: [Shelf]) {
    let songIDByLocalID = HomeManager.songIDsByLocalID(storage: storage)
    // The songs to fetch: each record's and artist's first song on the phone (one is enough
    // to find it), and every song of every mix.
    var wanted = Set<String>()
    func firstHeld(_ songs: [String]) -> String? {
      songs.lazy.compactMap { songIDByLocalID[$0] }.first
    }
    func want(_ record: HomeAnswer.Record) {
      // a record split across albums on the phone: any held song finds one of them
      for local in record.songs { if let id = songIDByLocalID[local] { wanted.insert(id) } }
    }
    func want(_ mix: HomeAnswer.Mix) {
      for local in mix.songs { if let id = songIDByLocalID[local] { wanted.insert(id) } }
    }
    for row in answer.rows {
      switch row.content {
      case let .resume(record, _, _):
        if let record { want(record) }
      case let .records(records): records.forEach(want)
      case let .mixes(mixes): mixes.forEach(want)
      case let .reach(shelf):
        shelf.records.forEach(want)
        if let mix = shelf.mix { want(mix) }
      case let .artists(artists):
        for artist in artists {
          if let id = firstHeld(artist.songs) { wanted.insert(id) }
        }
      default: break
      }
    }
    for shelf in answer.shelves {
      shelf.records.forEach(want)
      if let mix = shelf.mix { want(mix) }
    }
    let songsByID = storage.main.library.getSongsByID(for: account, ids: wanted)
    func song(_ local: String) -> Song? {
      songIDByLocalID[local].flatMap { songsByID[$0] }.flatMap { song in
        let mo = song.managedObject
        return mo.isDeleted || mo.managedObjectContext == nil ? nil : song
      }
    }
    func album(_ record: HomeAnswer.Record) -> Album? {
      for local in record.songs {
        if let album = song(local)?.album, !album.id.isEmpty, isOnPhone(album) { return album }
      }
      return nil
    }
    func albums(_ records: [HomeAnswer.Record]) -> [Album] {
      var seen = Set<String>()
      return records.compactMap(album).filter { seen.insert($0.id).inserted }
    }
    func mix(_ mix: HomeAnswer.Mix) -> HomeManager.MadeForYouMix? {
      let songs: [AbstractPlayable] = mix.songs.compactMap(song).filter { isOnPhone.contains($0) }
      let kind: HomeManager.MadeForYouMix.Kind
      switch mix.kind {
      case "lately": kind = .lately
      case "daypart": kind = .daypart
      case "been-a-while": kind = .beenAWhile
      case "mood": kind = .mood(key: String(mix.id.dropFirst("mood:".count)), hexColor: mix.color ?? "#6B5A44")
      case "nostalgia": kind = .years(id: mix.id)
      default: return nil
      }
      // Lately shows with any of its songs here; the rest need enough to be a playlist.
      guard !songs.isEmpty, kind == .lately || songs.count >= ListeningShelves.madeMixMinSongs
      else { return nil }
      return HomeManager.MadeForYouMix(
        kind: kind,
        title: mix.title,
        subtitle: mix.subtitle,
        songs: songs,
        leadAlbums: HomeManager.leadAlbums(for: songs, storage: storage, account: account),
        coverVariant: mix.cover?.variant
      )
    }
    func shelf(_ shelf: HomeAnswer.Shelf) -> Shelf {
      Shelf(
        id: shelf.id,
        kind: shelf.kind,
        shout: shelf.shout,
        answer: shelf.answer,
        onHome: shelf.onHome,
        albums: albums(shelf.records),
        mix: shelf.mix.flatMap(mix)
      )
    }
    func artists(_ artists: [HomeAnswer.Artist]) -> [Artist] {
      var seen = Set<String>()
      return artists.compactMap { artist -> Artist? in
        for local in artist.songs {
          guard let song = song(local) else { continue }
          if let found = song.album?.artist ?? song.artist, !found.id.isEmpty, isOnPhone(found) {
            return found
          }
        }
        return nil
      }.filter { seen.insert($0.id).inserted }
    }

    var rows = [Row]()
    for cloudRow in answer.rows {
      guard let section = Self.section(of: cloudRow) else { continue }
      var row = Row(id: cloudRow.id, section: section, shout: cloudRow.shout, answer: cloudRow.answer)
      switch cloudRow.content {
      case let .records(records): row.items = albums(records)
      case let .mixes(mixes): row.mixes = mixes.compactMap(mix)
      case let .stations(slugs): row.items = stations(slugs, radios: radios)
      case let .reach(cloudShelf): row.shelf = shelf(cloudShelf)
      case let .artists(cloudArtists): row.items = artists(cloudArtists)
      default: break
      }
      rows.append(row)
    }
    // All shelves: today's shelves the phone holds records of, the one on Home first.
    let shelves = answer.shelves.map(shelf)
      .filter { !$0.albums.isEmpty || $0.mix != nil }
      .sorted { $0.onHome && !$1.onHome }
    for index in rows.indices where rows[index].section == .allShelves {
      rows[index].shelfCount = shelves.count
    }
    return (rows, shelves)
  }

  /// The Home section a cloud row is drawn in. A row this build does not know is not drawn.
  private static func section(of row: HomeAnswer.Row) -> HomeSection? {
    switch row.content {
    case .resume: return .resume
    case .mixes: return .moodDoors
    case .playlists: return .yourPlaylists
    case .stations: return .radios
    case .reach: return .reach
    case .artists: return .recentlyPlayedArtists
    case .allShelves: return .allShelves
    case .records:
      switch row.id {
      case "on-repeat": return .onRepeat
      case "around-now": return .aroundNow
      case "from-your-mixes": return .fromYourMixes
      case "recently-added": return .recentlyAdded
      default: return nil
      }
    case .unknown: return nil
    }
  }

  /// A reaching shelf is drawn on Home with its Deep dive record, or with two records (or
  /// Nostalgia's mix and a record) to reach between.
  nonisolated static func isDrawable(_ shelf: Shelf) -> Bool {
    if shelf.isDeepDive { return !shelf.albums.isEmpty }
    return shelf.albums.count + (shelf.mix == nil ? 0 : 1) >= 2
  }

  /// The hub's stations for the cloud's slugs, in its order: each slug's stream on the dial
  /// (RadioCatalog), matched to the station the hub holds.
  private func stations(_ slugs: [String], radios: [Radio]) -> [Radio] {
    let byURL = Dictionary(
      radios.map { (RadioCatalog.normalize($0.url), $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var seen = Set<String>()
    return slugs.compactMap { slug in
      RadioCatalog.shared.station(slug: slug).flatMap { byURL[RadioCatalog.normalize($0.streamUrl)] }
    }.filter { seen.insert($0.id).inserted }
  }

  /// Your playlists on the phone, in the cloud's order (the one last played on any device
  /// first), each holding at least one song that is here.
  private func playlists(_ cloudRow: HomeAnswer.Row?, isOnPhone: HomeManager.OnPhoneCheck) -> [PlayableContainable] {
    guard case let .playlists(list)? = cloudRow?.content else { return [] }
    var seen = Set<String>()
    return list.compactMap { storage.main.library.getPlaylist(for: account, id: $0.id) }
      .filter { isOnPhone($0) && seen.insert($0.id).inserted }
  }

  /// Resume: what is playing on this phone right now; else what the cloud says was played
  /// last on any device (a record and its song, or a playlist) when the phone holds it; else
  /// the phone's paused queue. Nothing of it here: the card hides.
  private func fillResume(_ row: inout Row, answer: HomeAnswer, isOnPhone: HomeManager.OnPhoneCheck) {
    row.items = []
    row.song = nil
    let live = player.currentlyPlaying?.asSong
    if player.isPlaying, let album = live?.album, !album.id.isEmpty, isOnPhone(album) {
      row.items = [album]
      row.song = live
      return
    }
    if case let .resume(record, songID, playlistID)? = answer.rows.first(where: { $0.id == row.id })?.content {
      if let playlistID, let playlist = storage.main.library.getPlaylist(for: account, id: playlistID),
         isOnPhone(playlist) {
        row.items = [playlist]
        return
      }
      if let record, let found = resumeAlbum(record, songID: songID, isOnPhone: isOnPhone) {
        row.items = [found.album]
        row.song = found.song
        return
      }
    }
    if let album = live?.album, !album.id.isEmpty, isOnPhone(album) {
      row.items = [album]
      row.song = live
    }
  }

  private func resumeAlbum(
    _ record: HomeAnswer.Record,
    songID: String?,
    isOnPhone: HomeManager.OnPhoneCheck
  )
    -> (album: Album, song: Song?)? {
    guard let album = lookUpAlbum(record, isOnPhone: isOnPhone) else { return nil }
    var song: Song?
    if let songID,
       let id = (try? DeviceOwnershipManager(context: storage.main.context)
         .fetchOne(cassetteLocalId: songID))?.subsonicTrackId,
       let held = storage.main.library.getSong(for: account, id: id), held.album?.id == album.id,
       isOnPhone.contains(held) {
      song = held
    }
    return (album, song)
  }

  /// One record's album on the phone, looked up alone (Resume, which changes between finds).
  private func lookUpAlbum(_ record: HomeAnswer.Record, isOnPhone: HomeManager.OnPhoneCheck) -> Album? {
    let ownership = DeviceOwnershipManager(context: storage.main.context)
    for local in record.songs {
      guard let row = try? ownership.fetchOne(cassetteLocalId: local), let id = row.subsonicTrackId,
            let album = storage.main.library.getSong(for: account, id: id)?.album,
            !album.id.isEmpty, isOnPhone(album)
      else { continue }
      return album
    }
    return nil
  }
}
