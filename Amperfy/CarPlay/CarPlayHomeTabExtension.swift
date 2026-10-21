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
  private var carPlayHomeSections: [HomeSection] {
    [.recent, .onRepeat, .aroundNow, .radios, .yourPlaylists, .newestAlbums, .recentlyPlayedArtists]
  }

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
  private func playFromHome(_ containable: PlayableContainable) {
    let onlyCached = isOfflineMode
    if let album = containable as? Album {
      appDelegate.player.play(context: PlayContext(
        containable: album,
        playables: album.playables.filterCached(dependigOn: onlyCached)
      ))
    } else if let artist = containable as? Artist {
      appDelegate.player.playShuffled(context: PlayContext(
        containable: artist,
        playables: artist.playables.filterCached(dependigOn: onlyCached)
      ))
    } else {
      appDelegate.player.play(context: PlayContext(containable: containable))
    }
    displayNowPlaying {}
  }

  func updateHomeSections() {
    guard interfaceController != nil, let sharedHome else { return }
    // cassette: compare only the sections CarPlay actually renders. Comparing
    // the full `session.homeRowData` / `sharedHome.data` dicts would always differ on
    // the unrendered `.resume` key and permanently defeat this early-out.
    let renderedNow = carPlayHomeSections.map { session.homeRowData[$0] ?? [] }
    let requestedNow = carPlayHomeSections.map { carPlayItems($0) ?? [] }
    guard renderedNow != requestedNow else {
      return
    }
    let homeRows = createHomeImageRows()
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
        // LOCAL cover (bundled preset or materialized pick) so playlists show art.
        image = CassetteCloudPlaylistBridge.localCoverImage(for: playlist.id)
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
      } else {
        // Unreachable for the four CarPlay shelves today; exists so nothing is ever
        // silently skipped if a shelf of another kind is added.
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
