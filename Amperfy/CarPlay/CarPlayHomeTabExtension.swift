//
//  CarPlayHomeTabExtension.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 02.01.26.
//  Copyright (c) 2026 Maximilian Bauer. All rights reserved.
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
import CarPlay
import CoreData
import Foundation

// MARK: - CarMoodTile

/// phone-taste: one tile of the car's Made for You row (was Mood). A tap resolves to one of
/// these (stored in the session when the row is drawn), never to live data.
enum CarMoodTile: Equatable {
  /// The Lately mix (HomeManager.latelyMix): songs on this phone that match recent listening.
  case lately
  /// A mood door: POST /api/mixtape/door, cut to the songs on this phone. No longer offered
  /// (founder, 2026-10-21: the phone's own mood mixes replace the doors); kept so a door
  /// load in flight still resolves.
  case door(key: String, label: String, hexColor: String)
  /// One of Home's other made-for-you playlists (HomeManager.otherMixes), by id: this part
  /// of the day, Been a While or a mood mix, all built on the phone.
  case mix(id: String, title: String, hexColor: String?)
}

// MARK: - CarPlaySceneDelegate + Home

extension CarPlaySceneDelegate {
  /// cassette (CarPlay feel-good, Jobs 1.2/1.3): CarPlay Home is album-forward —
  /// two album shelves lead, then Playlists, then Artists. Resume is omitted (an
  /// iOS-only full-width hero card) and the heterogeneous "Recent" shelf is
  /// dropped in favor of the explicit album shelves. This is a CarPlay-LOCAL
  /// section list; it never mutates `HomeSection.defaultValue`, so iOS Home (a
  /// separate `HomeManager` instance with its own render loop) is unaffected. The
  /// two album shelves have data only because the CarPlay `HomeManager` was
  /// created with `buildsAlbumShelves: true`. Empty shelves (e.g. Recently Played
  /// Albums before any album play) are hidden by the guard in `createHomeImageRows`.
  ///
  /// cassette 2026-10-20 (driving pass): Recent leads (the row people actually use, with
  /// the Resume item at its head, since CarPlay has no Resume card), then Radio, the most
  /// natural thing to play while driving, then Playlists, Newest Albums and Artists.
  /// On Repeat and Around This Time follow Recent (the phone's own play log).
  ///
  /// phone-taste: Mood sits between On Repeat and the time-of-day row, as in the car mock.
  private var carPlayHomeSections: [HomeSection] {
    [
      .recent,
      .onRepeat,
      .moodDoors,
      .aroundNow,
      .radios,
      .yourPlaylists,
      .newestAlbums,
      .recentlyPlayedArtists,
    ]
  }

  /// The Lately tile needs four covers for its picture (the mock shows it at four or more).
  private static let latelyCoverCount = 4
  /// A mood mix's drawn cover is decoded this large for the car (its biggest slot at 3x).
  private static let drawnCoverPixels = 480

  /// The items a CarPlay Home row shows. Recent carries the Resume item first.
  private func carPlayItems(_ section: HomeSection) -> [HomeItem]? {
    guard let sharedHome else { return nil }
    guard section == .recent else { return sharedHome.data[section] }
    let items = (sharedHome.data[.resume] ?? []) + (sharedHome.data[.recent] ?? [])
    return items
  }

  private func carPlayTitle(_ section: HomeSection) -> String {
    switch section {
    case .radios: return "Radio"
    case .yourPlaylists: return "Playlists"
    case .recentlyPlayedArtists: return "Artists"
    default: return section.title
    }
  }

  /// A Home tile plays straight away and shows Now Playing (founder, 2026-10-20: one tap
  /// to music behind the wheel). An album plays from the top, an artist shuffled. Browsing
  /// stays one tap away on the row's title.
  ///
  /// phone-taste: only what is on this phone is queued (the foundation's OneTapPlay rule). A
  /// station plays as itself. Nothing of it on the phone: nothing plays and Now Playing stays
  /// shut (Home rows hold only records on the phone, so this is the rare race with a removal).
  private func playFromHome(_ containable: PlayableContainable) {
    if containable is Radio {
      appDelegate.player.play(context: PlayContext(containable: containable))
      displayNowPlaying {}
      return
    }
    let playables = onPhonePlayables(of: containable)
    guard !playables.isEmpty else { return }
    let context = PlayContext(containable: containable, playables: playables)
    if containable is Artist {
      appDelegate.player.playShuffled(context: context)
    } else {
      appDelegate.player.play(context: context)
    }
    displayNowPlaying {}
  }

  func updateHomeSections() {
    guard interfaceController != nil, sharedHome != nil else { return }
    // cassette: compare only the sections CarPlay actually renders. Comparing
    // the full `session.homeRowData` / `sharedHome.data` dicts would always differ on
    // the unrendered `.resume` key and permanently defeat this early-out.
    let renderedNow = carPlayHomeSections.map { session.homeRowData[$0] ?? [] }
    let requestedNow = carPlayHomeSections.map { carPlayItems($0) ?? [] }
    // phone-taste: the Mood row is not made of HomeItems, so its signature is compared too;
    // and the time-of-day row can change its title while its albums stay the same.
    let aroundTitle = carPlayTitle(.aroundNow)
    guard renderedNow != requestedNow
      || moodSignature() != session.moodSignature
      || aroundTitle != session.aroundTitle
    else {
      return
    }
    let homeRows = createHomeImageRows()
    session.aroundTitle = aroundTitle
    let homeSection = CPListSection(items: homeRows, header: nil, sectionIndexTitle: nil)
    homeTab.updateSections([homeSection])
    pruneHomeArtworkIndex()
  }

  /// Drop tiles that are no longer on screen from the artwork index. A shelf rebuild replaces
  /// its elements, and the index used to keep every element ever built, so it grew on every
  /// track change for the life of the process (CPS-4).
  private func pruneHomeArtworkIndex() {
    let live = Set(
      session.homeImageRows.values
        .flatMap { ($0.elements as? [CPListImageRowItemRowElement]) ?? [] }
        .map { ObjectIdentifier($0) }
    )
    for (artworkID, var container) in session.homeArtworkUpdate {
      container.homeRow.removeAll { !live.contains(ObjectIdentifier($0)) }
      session.homeArtworkUpdate[artworkID] = container.homeRow.isEmpty ? nil : container
    }
  }

  func createHomeImageRows() -> [CPListImageRowItem] {
    guard sharedHome != nil else { return [] }
    var imageRows = [CPListImageRowItem]()
    for section in carPlayHomeSections {
      // phone-taste: the Mood row has no HomeItems by design (HomeSection.moodDoors), so it
      // is built before the empty-shelf guard below, which would always hide it.
      if section == .moodDoors {
        if let row = makeMoodRow() { imageRows.append(row) }
        continue
      }
      // cassette: hide-when-empty on CarPlay (mirrors HomeVC Patch 036 at
      // HomeVC.swift:399). Skip shelves with no items and clear any stale
      // rendered snapshot so `updateHomeSections`' change-detection settles
      // rather than rebuilding on every callback while the shelf stays empty.
      guard let sectionItems = carPlayItems(section), !sectionItems.isEmpty else {
        session.homeRowData[section] = []
        continue
      }
      if let row = session.homeImageRows[section] {
        let alreadyCreatedData = session.homeRowData[section]
        let requestedData = carPlayItems(section)
        if alreadyCreatedData !=
          requestedData {
          let imageRowElements = createHomeRowImageElements(section: section)
          row.elements = imageRowElements
        }
        // phone-taste: a reused row takes its current title (the time-of-day row turns
        // from Evenings to Nights mid-drive).
        row.text = carPlayTitle(section)
        imageRows.append(row)
      } else if let row = createHomeRow(section: section) {
        session.homeImageRows[section] = row
        imageRows.append(row)
      }
    }
    return imageRows
  }

  func createHomeRow(section: HomeSection) -> CPListImageRowItem? {
    guard sharedHome != nil else { return nil }
    let alreadyCreatedData = session.homeRowData[section]
    let requestedData = carPlayItems(section)
    if alreadyCreatedData ==
      requestedData {
      return session.homeImageRows[section]
    }

    let imageRowElements = createHomeRowImageElements(section: section)
    let row = CPListImageRowItem(
      text: carPlayTitle(section),
      elements: imageRowElements,
      allowsMultipleLines: false
    )
    // handler CB is called when user pressed the section title
    row.handler = { [weak self] selectedRow, completion in
      guard let self else { completion(); return }
      Task { @MainActor in
        // cassette (BUG-338): the shelf title opens a plain row list of the shelf's items,
        // never a wrapped tile grid (see makeHomeShelfListTemplate).
        self.pushTemplateIfAllowed(
          self.makeHomeShelfListTemplate(section: section),
          animated: true
        )
        completion()
      }
    }
    // listImageRowHandler CB is called when user pressed on a image inside the row
    row.listImageRowHandler = { [weak self] item, index, completion in
      guard let self else { completion(); return }
      // Resolve the tap against the snapshot that backs the *visible* elements,
      // not the live shelf data: recomputeAllShelves() rebuilds sharedHome.data
      // on every play/pause/stop and FRC change, so re-indexing it can hit nil
      // or the wrong item (the dead tap). That snapshot is session.homeRowData[section]
      // (kept in lockstep with row.elements). Match by stableID, preferring the
      // live item so playback uses a current managed object when one still exists.
      let renderedItems = session.homeRowData[section] ?? []
      guard index >= 0, index < renderedItems.count else { completion(); return }
      let tappedID = renderedItems[index].stableID
      let liveItem = carPlayItems(section)?.first { $0.stableID == tappedID }
      let selectedPlayable = (liveItem ?? renderedItems[index]).playableContainable
      Task { @MainActor in
        self.playFromHome(selectedPlayable)
        completion()
      }
    }
    return row
  }

  func createHomeRowImageElements(section: HomeSection) -> [CPListImageRowItemRowElement] {
    guard sharedHome != nil else { return [] }

    let alreadyCreatedData = session.homeRowData[section]
    let requestedData = carPlayItems(section)
    if alreadyCreatedData ==
      requestedData {
      return session.homeImageRows[section]?.elements as? [CPListImageRowItemRowElement] ?? []
    }
    session.homeRowData[section] = requestedData

    var imageRowElements = [CPListImageRowItemRowElement]()
    let items = requestedData ?? []
    for item in items {
      // phone-taste: a station is dressed from the radio catalog (its own name, its network
      // or "Live", its logo or a word picture in its colour). Checked before the library
      // entity cast, which a Radio also passes, and never registered for artwork updates.
      if let radio = item.playableContainable as? Radio {
        imageRowElements.append(makeRadioElement(radio))
        continue
      }
      var image: UIImage?
      var artwork: Artwork?
      var entity: AbstractLibraryEntity?
      if let libEntity = item.playableContainable as? AbstractLibraryEntity {
        image = LibraryEntityImage.coverImage(
          libraryEntity: libEntity,
          artworkDisplayPreference: getPreference(activeAccountInfo).artworkDisplayPreference,
          useCache: false
        )
        if let entityArtwork = libEntity.artwork, let accountInfo = entityArtwork.account?.info {
          artwork = entityArtwork
          entity = libEntity
          // trigger download only once
          if session.homeArtworkUpdate[entityArtwork.uniqueID] == nil {
            appDelegate.getMeta(accountInfo).artworkDownloadManager.download(object: entityArtwork)
          }
        }
      } else if let playlist = item.playableContainable as? Playlist {
        // cassette (Wave 2b): a Playlist is NOT an AbstractLibraryEntity, so the
        // cast above missed and the Home tile fell to a placeholder. Resolve its
        // LOCAL cover (bundled preset or materialized pick) so playlists show art; a pick
        // not downloaded yet shows the preset (phone-taste: the shared fallback).
        image = CassetteCloudPlaylistBridge.displayCoverImage(for: playlist.id)
      }
      // cassette: artist tiles render as circles on CarPlay to match iOS (albums, playlists,
      // etc. stay square), real art and placeholder alike. A tile without art gets the
      // placeholder with the item's initial (BUG-421), like the library rows.
      let displayImage = style.artwork(
        image,
        kind: style.artworkKind(of: item.playableContainable),
        name: item.playableContainable.name,
        circle: item.playableContainable is Artist,
        slot: .shelf
      )

      let element = CPListImageRowItemRowElement(
        image: displayImage,
        title: item.playableContainable.name,
        subtitle: item.playableContainable.subtitle
      )
      if let artwork, let entity {
        if session.homeArtworkUpdate[artwork.uniqueID] == nil {
          session.homeArtworkUpdate[artwork.uniqueID] = EntityImageRowContainer(
            entity: entity,
            item: item,
            homeRow: [element]
          )
        } else {
          session.homeArtworkUpdate[artwork.uniqueID]?.homeRow.append(element)
        }
      }
      imageRowElements.append(element)
    }
    return imageRowElements
  }

  /// cassette (BUG-338): the shelf detail is a plain row list, never a wrapped tile grid, because the
  /// phone cannot learn the head unit's column count. Rows are the library's own detail rows, so a
  /// tap opens the same view a Home tile tap opens, and artwork lands through the "refresh List items"
  /// walk in downloadFinishedSuccessful because the rows carry userInfo. Built at push time as a
  /// snapshot of the shelf, like the grid was.
  func makeHomeShelfListTemplate(section: HomeSection) -> CPListTemplate {
    let items = (carPlayItems(section) ?? []).prefix(carPlayLeafItemLimit(reserved: 0))
    var rows = [CPListItem]()
    for item in items {
      let containable = item.playableContainable
      if let album = containable as? Album {
        rows.append(createDetailTemplate(for: album, onlyCached: isOfflineMode))
      } else if let artist = containable as? Artist {
        rows.append(createDetailTemplate(for: artist, onlyCached: isOfflineMode))
      } else if let playlist = containable as? Playlist {
        rows.append(createPlaylistRow(playlist))
      } else if let radio = containable as? Radio {
        rows.append(makeRadioRow(radio))
      } else {
        // Reached by no CarPlay shelf today (albums, artists, playlists and stations have
        // their own rows); exists so nothing is ever silently skipped if a shelf of another
        // kind is added.
        rows.append(makePlayContainableRow(containable))
      }
    }
    let template = CPListTemplate(title: carPlayTitle(section), sections: [CPListSection(items: rows)])
    template.emptyViewTitleVariants = ["Nothing here yet"]
    return template
  }

  /// cassette (BUG-338): the fallback row for a shelf item without a detail view: the old
  /// tile behaviour, play the item then show Now Playing. Generated artwork only.
  private func makePlayContainableRow(_ containable: PlayableContainable) -> CPListItem {
    let row = CPListItem(
      text: containable.name,
      detailText: containable.subtitle,
      image: style.artwork(nil, kind: style.artworkKind(of: containable), name: containable.name),
      accessoryImage: nil,
      accessoryType: .none
    )
    row.handler = { [weak self] _, completion in
      guard let self = self else { completion(); return }
      appDelegate.player.play(context: PlayContext(containable: containable))
      displayNowPlaying { completion() }
    }
    return row
  }
}

// MARK: - Mood row (phone-taste)

extension CarPlaySceneDelegate {
  /// What decides the Made for You row's tiles and art: the Lately mix's lead albums (when
  /// it has songs), and each other playlist's id, title and lead albums. Cheap: no image is
  /// decoded here.
  func moodSignature() -> String {
    var parts = [String]()
    if let mix = sharedHome?.latelyMix, !mix.songs.isEmpty {
      parts.append("lately:" + mix.leadAlbums.map(\.id).joined(separator: ","))
    }
    for mix in sharedHome?.otherMixes ?? [] {
      parts.append("\(mix.id)=\(mix.title):" + mix.leadAlbums.map(\.id).joined(separator: ","))
      // A mood mix's drawn cover, and whether it has landed (the tile swaps it in).
      if let address = MixCoverCache.address(for: mix) {
        parts.append("\(address.absoluteString)=\(MixCoverCache.isOnDisk(address))")
      }
    }
    return parts.joined(separator: "|")
  }

  /// The Mood row, rebuilt (tiles, covers, art) only when its signature changed, or nil when
  /// it has no tiles. The row object is kept for the session, so a tile list that empties
  /// and fills again reuses it.
  fileprivate func makeMoodRow() -> CPListImageRowItem? {
    let signature = moodSignature()
    if signature != session.moodSignature {
      session.moodSignature = signature
      rebuildMoodTiles()
      let elements = session.moodTiles.map { makeMoodElement($0) }
      if let row = session.moodRow {
        row.elements = elements
      } else if !elements.isEmpty {
        session.moodRow = createMoodRow(elements: elements)
      }
    }
    return session.moodTiles.isEmpty ? nil : session.moodRow
  }

  /// The Lately tile when the mix has songs and four of its lead albums have a cover on disk
  /// (decoded here, once per signature), then Home's other made-for-you playlists: a mood
  /// mix as its drawn cover once that is on disk (its colour and name until then), the others
  /// as their records with the name across them (shown only with four covers on disk, like
  /// Lately). The server's mood doors are no longer offered (founder, 2026-10-21): the
  /// phone's mood mixes replace them, with no beta.
  private func rebuildMoodTiles() {
    var tiles = [CarMoodTile]()
    var coversByTile = [String: [UIImage]]()
    let preference = getPreference(activeAccountInfo).artworkDisplayPreference
    func fourCovers(_ albums: [Album]) -> [UIImage]? {
      let covers = albums.compactMap {
        LibraryEntityImage.coverImage(
          libraryEntity: $0,
          artworkDisplayPreference: preference,
          useCache: false
        )
      }
      return covers.count >= Self.latelyCoverCount ? Array(covers.prefix(Self.latelyCoverCount)) : nil
    }
    if let mix = sharedHome?.latelyMix, !mix.songs.isEmpty, let covers = fourCovers(mix.leadAlbums) {
      tiles.append(.lately)
      coversByTile["lately"] = covers
    }
    for mix in sharedHome?.otherMixes ?? [] {
      if case let .mood(_, hexColor) = mix.kind {
        tiles.append(.mix(id: mix.id, title: mix.title, hexColor: hexColor))
        // Its drawn cover when it is on disk (never fetched here); its colour and name until then.
        if let address = MixCoverCache.address(for: mix),
           let cover = MixCoverCache.diskImage(address, maxPixelSize: Self.drawnCoverPixels) {
          coversByTile[mix.id] = [cover]
        }
      } else if let covers = fourCovers(mix.leadAlbums) {
        tiles.append(.mix(id: mix.id, title: mix.title, hexColor: nil))
        coversByTile[mix.id] = covers
      }
    }
    session.moodTiles = tiles
    session.moodCovers = coversByTile
  }

  /// A tile's picture and title. Lately and the other record playlists: their records in a
  /// square with the name across them. A mood mix: its drawn cover, else (or a door) its
  /// colour and its name.
  private func moodArt(_ tile: CarMoodTile, slot: CarPlayStyle.Slot) -> (image: UIImage, title: String) {
    switch tile {
    case .lately:
      return (style.mosaicArt(covers: session.moodCovers["lately"] ?? [], word: "Lately", slot: slot), "Lately")
    case let .door(_, label, hexColor):
      let color = UIColor(cassetteHexString: hexColor) ?? UIColor.cassette(.surfaceElevated)
      return (style.wordArt(word: label, color: color, slot: slot), label)
    case let .mix(id, title, hexColor):
      if let hexColor {
        if let cover = session.moodCovers[id]?.first {
          return (style.drawnCover(cover, slot: slot), title)
        }
        let color = UIColor(cassetteHexString: hexColor) ?? UIColor.cassette(.surfaceElevated)
        return (style.wordArt(word: title, color: color, slot: slot), title)
      }
      return (style.mosaicArt(covers: session.moodCovers[id] ?? [], word: title, slot: slot), title)
    }
  }

  private func makeMoodElement(_ tile: CarMoodTile) -> CPListImageRowItemRowElement {
    let art = moodArt(tile, slot: .shelf)
    return CPListImageRowItemRowElement(image: art.image, title: art.title, subtitle: "Mix")
  }

  private func createMoodRow(elements: [CPListImageRowItemRowElement]) -> CPListImageRowItem {
    let row = CPListImageRowItem(text: "Made for You", elements: elements, allowsMultipleLines: false)
    // The title opens the tiles as a plain list (the same art at row size).
    row.handler = { [weak self] _, completion in
      guard let self else { completion(); return }
      Task { @MainActor in
        self.pushTemplateIfAllowed(self.makeMoodListTemplate(), animated: true)
        completion()
      }
    }
    // A tile plays at once. The tap resolves against the tiles the row was drawn from.
    row.listImageRowHandler = { [weak self] _, index, completion in
      guard let self else { completion(); return }
      Task { @MainActor in
        let tiles = self.session.moodTiles
        guard index >= 0, index < tiles.count else { completion(); return }
        self.playMoodTile(tiles[index], completion: completion)
      }
    }
    return row
  }

  /// The Mood row's title tap: one row per tile, detail "Mix". A row plays, as the tile does.
  private func makeMoodListTemplate() -> CPListTemplate {
    let rows: [CPListItem] = session.moodTiles.map { tile in
      let art = moodArt(tile, slot: .row)
      let item = CPListItem(
        text: art.title,
        detailText: "Mix",
        image: art.image,
        accessoryImage: nil,
        accessoryType: .none
      )
      item.handler = { [weak self] _, completion in
        guard let self else { completion(); return }
        Task { @MainActor in
          self.playMoodTile(tile, completion: completion)
        }
      }
      return item
    }
    let template = CPListTemplate(title: "Made for You", sections: [CPListSection(items: rows)])
    template.emptyViewTitleVariants = ["Nothing here yet"]
    return template
  }

  private func playMoodTile(_ tile: CarMoodTile, completion: @escaping () -> ()) {
    switch tile {
    case .lately:
      playLately(completion: completion)
    case let .door(key, label, _):
      playDoor(key: key, label: label, completion: completion)
    case let .mix(id, title, _):
      playMix(id: id, title: title, completion: completion)
    }
  }

  /// One of Home's other made-for-you playlists, played at once from the songs still on the
  /// phone.
  private func playMix(id: String, title: String, completion: @escaping () -> ()) {
    let mix = sharedHome?.otherMixes.first(where: { $0.id == id })
    let songs = OneTapPlay.playables(mix?.songs ?? [])
    guard !songs.isEmpty else {
      presentCarAlert("\(title) has nothing on this phone right now", completion: completion)
      return
    }
    appDelegate.player.play(context: PlayContext(name: title, playables: songs))
    displayNowPlaying { completion() }
  }

  /// The Lately mix Home built with the tile (songs on this phone matching recent listening),
  /// played at once.
  private func playLately(completion: @escaping () -> ()) {
    let songs = OneTapPlay.playables(sharedHome?.latelyMix?.songs ?? [])
    guard !songs.isEmpty else {
      presentCarAlert("Not enough music on this phone matches lately yet", completion: completion)
      return
    }
    appDelegate.player.play(context: PlayContext(name: "Lately", playables: songs))
    displayNowPlaying { completion() }
  }

  /// A door's mix, fetched and played at once (the car has no preview sheet). One door loads
  /// at a time; a result that arrives after something else started playing is dropped, so a
  /// slow network never yanks away what the driver chose since. `completion` runs on every
  /// path.
  private func playDoor(key: String, label: String, completion: @escaping () -> ()) {
    guard session.doorLoad == nil else { completion(); return }
    let token = UUID()
    session.doorLoad = token
    session.doorLoadOvertaken = false
    Task { @MainActor [weak self] in
      let outcome = await MixtapePlayback.makeDoorMix(doorKey: key)
      // A disconnect or an account change replaced the session: drop it.
      guard let self, self.session.doorLoad == token else { completion(); return }
      let overtaken = self.session.doorLoadOvertaken
      self.session.doorLoad = nil
      self.session.doorLoadOvertaken = false
      guard !overtaken else { completion(); return }
      switch outcome {
      case let .ok(name, songs):
        self.appDelegate.player.play(context: PlayContext(name: name, playables: songs))
        self.displayNowPlaying { completion() }
      case .notEnough:
        self.presentCarAlert("Not enough of your music fits \(label) yet", completion: completion)
      case .nothingOnPhone:
        self.presentCarAlert("None of \(label) is on this phone yet", completion: completion)
      case .unavailable:
        self.presentCarAlert("Can't make \(label) right now", completion: completion)
      }
    }
  }

  /// The player's queue changed (anything played, from the car or the phone): a door mix
  /// still loading must not take over when it lands. Called from the player notifier.
  func noteQueueChangedForDoorLoad() {
    if session.doorLoad != nil { session.doorLoadOvertaken = true }
  }

  /// A one-line car alert with a single OK that dismisses it. Always presented with a
  /// completion, so a refused present is reported rather than raised.
  func presentCarAlert(_ message: String, completion: @escaping () -> ()) {
    guard let interfaceController else { completion(); return }
    let ok = CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in
      self?.interfaceController?.dismissTemplate(animated: true) { _, _ in }
    }
    let alert = CPAlertTemplate(titleVariants: [message], actions: [ok])
    interfaceController.presentTemplate(alert, animated: true) { _, _ in }
    completion()
  }
}

// MARK: - Radio tiles and rows (phone-taste)

extension CarPlaySceneDelegate {
  /// A station's words from the bundled radio catalog: its own name (else the hub's), and its
  /// network, or "Live" when the network is the station itself (nil for a station the catalog
  /// does not know).
  private func radioWords(_ radio: Radio) -> (name: String, line: String?, info: RadioCatalogStation?) {
    let info = RadioCatalog.shared.station(forStreamUrl: radio.url)
    let name = info?.name ?? radio.title
    let line = info.map { $0.sourceLabel != $0.name ? $0.sourceLabel : "Live" }
    return (name, line, info)
  }

  /// The station's logo when it is already in memory, else a word picture in its colour.
  private func radioArt(info: RadioCatalogStation?, name: String, slot: CarPlayStyle.Slot) -> UIImage {
    if let url = info?.image, !url.isEmpty, let logo = RadioArtLoader.shared.cachedImage(for: url) {
      return style.artwork(logo, kind: .radio, name: name, slot: slot)
    }
    let color = info.flatMap { UIColor(cassetteHexString: $0.accent) }
      ?? UIColor.cassette(.surfaceElevated)
    return style.wordArt(word: name, color: color, slot: slot)
  }

  /// Fetches the station's logo when it has one that is not in memory yet, and hands it over
  /// drawn for `slot`. Offline the word picture simply stays.
  private func loadRadioLogo(
    info: RadioCatalogStation?,
    name: String,
    slot: CarPlayStyle.Slot,
    apply: @escaping (UIImage) -> ()
  ) {
    guard let url = info?.image, !url.isEmpty, RadioArtLoader.shared.cachedImage(for: url) == nil
    else { return }
    Task { @MainActor [weak self] in
      guard let logo = await RadioArtLoader.shared.image(for: url), let self else { return }
      apply(self.style.artwork(logo, kind: .radio, name: name, slot: slot))
    }
  }

  fileprivate func makeRadioElement(_ radio: Radio) -> CPListImageRowItemRowElement {
    let words = radioWords(radio)
    let element = CPListImageRowItemRowElement(
      image: radioArt(info: words.info, name: words.name, slot: .shelf),
      title: words.name,
      subtitle: words.line
    )
    loadRadioLogo(info: words.info, name: words.name, slot: .shelf) { [weak element] logo in
      element?.image = logo
    }
    return element
  }

  /// The Radio row's list: the same name, line and picture at row size. A tap plays the
  /// station and shows Now Playing, as the tile does.
  fileprivate func makeRadioRow(_ radio: Radio) -> CPListItem {
    let words = radioWords(radio)
    let item = CPListItem(
      text: words.name,
      detailText: words.line,
      image: radioArt(info: words.info, name: words.name, slot: .row),
      accessoryImage: nil,
      accessoryType: .none
    )
    loadRadioLogo(info: words.info, name: words.name, slot: .row) { [weak item] logo in
      item?.setImage(logo)
    }
    item.handler = { [weak self] _, completion in
      guard let self else { completion(); return }
      appDelegate.player.play(context: PlayContext(containable: radio))
      displayNowPlaying { completion() }
    }
    return item
  }
}
