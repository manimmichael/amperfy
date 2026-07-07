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
  private var carPlayHomeSections: [HomeSection] {
    [.recentlyPlayedAlbums, .newestAlbums, .yourPlaylists, .recentlyPlayedArtists]
  }

  func updateHomeSections() {
    guard let sharedHome else { return }
    // cassette: compare only the sections CarPlay actually renders. Comparing
    // the full `homeRowData` / `sharedHome.data` dicts would always differ on
    // the unrendered `.resume` key and permanently defeat this early-out.
    let renderedNow = carPlayHomeSections.map { homeRowData[$0] ?? [] }
    let requestedNow = carPlayHomeSections.map { sharedHome.data[$0] ?? [] }
    guard renderedNow != requestedNow else {
      return
    }
    let homeRows = createHomeImageRows()
    let homeSection = CPListSection(items: homeRows, header: nil, sectionIndexTitle: nil)
    homeTab.updateSections([homeSection])
  }

  func createHomeImageRows() -> [CPListImageRowItem] {
    guard let sharedHome else { return [] }
    var imageRows = [CPListImageRowItem]()
    for section in carPlayHomeSections {
      // cassette: hide-when-empty on CarPlay (mirrors HomeVC Patch 036 at
      // HomeVC.swift:399). Skip shelves with no items and clear any stale
      // rendered snapshot so `updateHomeSections`' change-detection settles
      // rather than rebuilding on every callback while the shelf stays empty.
      guard let sectionItems = sharedHome.data[section], !sectionItems.isEmpty else {
        homeRowData[section] = []
        continue
      }
      if let row = homeImageRows[section] {
        let alreadyCreatedData = homeRowData[section]
        let requestedData = sharedHome.data[section]
        if alreadyCreatedData !=
          requestedData {
          let imageRowElements = createHomeRowImageElements(section: section, isDetail: false)
          row.elements = imageRowElements
        }
        imageRows.append(row)
      } else if let row = createHomeRow(section: section, isDetailTemplate: false) {
        homeImageRows[section] = row
        imageRows.append(row)
      }
    }
    return imageRows
  }

  func createHomeRow(section: HomeSection, isDetailTemplate: Bool) -> CPListImageRowItem? {
    guard let sharedHome else { return nil }
    let alreadyCreatedData = homeRowData[section]
    let requestedData = sharedHome.data[section]
    if !isDetailTemplate,
       alreadyCreatedData ==
       requestedData {
      return homeImageRows[section]
    }

    let imageRowElements = createHomeRowImageElements(section: section, isDetail: isDetailTemplate)
    let isRandomSection = section.isRandomSection

    var title: String?
    if !isDetailTemplate {
      title = section.title
    } else if isRandomSection {
      title = "Refresh"
    }

    let row = CPListImageRowItem(
      text: title,
      elements: imageRowElements,
      allowsMultipleLines: isDetailTemplate
    )
    // handler CB is called when user pressed the section title
    row.handler = { [weak self] selectedRow, completion in
      guard let self else { completion(); return }
      if !isDetailTemplate {
        Task { @MainActor in
          let detailSectionRow = createHomeRow(section: section, isDetailTemplate: true)
          let detailListTemplate = CPListTemplate(title: section.title, sections: [
            CPListSection(items: detailSectionRow != nil ? [detailSectionRow!] : []),
          ])
          self.pushTemplateIfAllowed(detailListTemplate, animated: true)
          completion()
        }
      } else {
        // cassette Patch 035: random/podcast/radio shelves are no
        // longer materialised by HomeManager, so CarPlay never has
        // a refresh action to dispatch — the three Cassette shelves
        // are all deterministic.
        completion()
      }
    }
    // listImageRowHandler CB is called when user pressed on a image inside the row
    row.listImageRowHandler = { [weak self] item, index, completion in
      guard let self else { completion(); return }
      // Resolve the tap against the snapshot that backs the *visible* elements,
      // not the live shelf data: recomputeAllShelves() rebuilds sharedHome.data
      // on every play/pause/stop and FRC change, so re-indexing it can hit nil
      // or the wrong item (the dead tap). For the home carousel that snapshot
      // is homeRowData[section] (kept in lockstep with row.elements); for a
      // pushed detail list it is homeDetailRowData[section], captured at build
      // time. Match by stableID, preferring the live item so playback uses a
      // current managed object when one still exists.
      let renderedItems = isDetailTemplate
        ? (homeDetailRowData[section] ?? [])
        : (homeRowData[section] ?? [])
      guard index >= 0, index < renderedItems.count else { completion(); return }
      let tappedID = renderedItems[index].stableID
      let liveItem = sharedHome.data[section]?.first { $0.stableID == tappedID }
      let selectedPlayable = (liveItem ?? renderedItems[index]).playableContainable
      Task { @MainActor in
        // cassette (CarPlay open-a-view): a Home tile tap OPENS the item's detail
        // view (album track list / artist / playlist) — same as the library rows —
        // instead of auto-playing. Playback happens when the user taps a track or
        // Shuffle inside. Anything without a detail view falls back to play().
        if let album = selectedPlayable as? Album {
          self.pushTemplateIfAllowed(
            self.makeAlbumDetailTemplate(for: album, onlyCached: isOfflineMode),
            animated: true
          )
        } else if let artist = selectedPlayable as? Artist,
                  let template = self.makeArtistDetailTemplate(for: artist, onlyCached: isOfflineMode) {
          self.pushTemplateIfAllowed(template, animated: true)
        } else if let playlist = selectedPlayable as? Playlist {
          self.pushPlaylistDetail(playlist)
        } else {
          self.appDelegate.player.play(context: PlayContext(containable: selectedPlayable))
          self.displayNowPlaying {}
        }
        completion()
      }
    }
    return row
  }

  func createHomeRowImageElements(
    section: HomeSection,
    isDetail: Bool
  )
    -> [CPListImageRowItemRowElement] {
    guard let sharedHome else { return [] }

    let alreadyCreatedData = homeRowData[section]
    let requestedData = sharedHome.data[section]
    if !isDetail,
       alreadyCreatedData ==
       requestedData {
      return homeImageRows[section]?.elements as? [CPListImageRowItemRowElement] ?? []
    }
    if !isDetail {
      homeRowData[section] = requestedData
    } else {
      homeDetailRowData[section] = requestedData
      for var container in homeArtworkUpdate {
        container.value.detailRow.removeAll()
      }
    }

    var imageRowElements = [CPListImageRowItemRowElement]()
    let items = requestedData ?? []
    for item in items {
      var image: UIImage?
      var artwork: Artwork?
      var entity: AbstractLibraryEntity?
      if let libEntity = item.playableContainable as? AbstractLibraryEntity {
        image = LibraryEntityImage.getImageToDisplayImmediately(
          libraryEntity: libEntity,
          themePreference: getPreference(activeAccountInfo).theme,
          artworkDisplayPreference: getPreference(activeAccountInfo).artworkDisplayPreference,
          useCache: false
        )
        if let entityArtwork = libEntity.artwork, let accountInfo = entityArtwork.account?.info {
          artwork = entityArtwork
          entity = libEntity
          // trigger download only once
          if homeArtworkUpdate[entityArtwork.uniqueID] == nil {
            appDelegate.getMeta(accountInfo).artworkDownloadManager.download(object: entityArtwork)
          }
        }
      }
      let displayImage = image?.carPlayImage(carTraitCollection: traits) ?? UIImage
        .getGeneratedArtwork(
          theme: getPreference(activeAccountInfo).theme,
          artworkType: item.playableContainable
            .getArtworkCollection(theme: getPreference(activeAccountInfo).theme).defaultArtworkType,
          name: nil
        )

      let element = CPListImageRowItemRowElement(
        image: displayImage,
        title: item.playableContainable.name,
        subtitle: item.playableContainable.subtitle
      )
      if let artwork, let entity {
        if homeArtworkUpdate[artwork.uniqueID] == nil {
          homeArtworkUpdate[artwork.uniqueID] = EntityImageRowContainer(
            entity: entity,
            item: item,
            homeRow: isDetail ? [] : [element],
            detailRow: isDetail ? [element] : []
          )
        } else if isDetail {
          homeArtworkUpdate[artwork.uniqueID]?.detailRow.append(element)
        } else {
          homeArtworkUpdate[artwork.uniqueID]?.homeRow.append(element)
        }
      }
      imageRowElements.append(element)
    }
    return imageRowElements
  }
}
