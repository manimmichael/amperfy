//
//  ArtistDetailVC.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 09.03.19.
//  Copyright (c) 2019 Maximilian Bauer. All rights reserved.
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
import UIKit

class ArtistDetailVC: MultiSourceTableViewController {
  override var sceneTitle: String? { artist.name }

  private let artist: Artist
  var albumToScrollTo: Album?
  private var albumsFetchedResultsController: ArtistAlbumsItemsFetchedResultsController!
  private var songsFetchedResultsController: ArtistSongsItemsFetchedResultsController!
  private var optionsButton: UIBarButtonItem!
  private var detailOperationsView: GenericDetailTableHeader?
  private let stickyHeader = DetailStickyHeaderView()

  init(account: Account, artist: Artist) {
    self.artist = artist
    super.init(style: .grouped, account: account)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    // cassette Patch 037: pin inline title for this VC before super
    // runs so the nav bar collapses the parent's large title in the
    // first frame of the push transition — otherwise "Artists"
    // briefly renders behind the detail title.
    navigationItem.largeTitleDisplayMode = .never
    super.viewDidLoad()
    appDelegate.userStatistics.visited(.artistDetail)

    optionsButton = UIBarButtonItem.createOptionsBarButton()

    albumsFetchedResultsController = ArtistAlbumsItemsFetchedResultsController(
      for: artist,
      coreDataCompanion: appDelegate.storage.main,
      isGroupedInAlphabeticSections: false
    )
    albumsFetchedResultsController.delegate = self
    songsFetchedResultsController = ArtistSongsItemsFetchedResultsController(
      for: artist,
      displayFilter: appDelegate.storage.settings.user.artistsFilterSetting,
      coreDataCompanion: appDelegate.storage.main,
      isGroupedInAlphabeticSections: false
    )
    songsFetchedResultsController.delegate = self
    tableView.register(nibName: GenericTableCell.typeName)
    tableView.register(nibName: PlayableTableCell.typeName)
    tableView.sectionHeaderHeight = 0.0
    tableView.estimatedSectionHeaderHeight = 0.0
    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    tableView.backgroundColor = .backgroundColor

    // cassette Patch 045: in-view search removed from artist detail.
    // Library category lists keep their search controllers; the
    // detail view shows the artist's full top-songs + albums set.
    let playShuffleInfoConfig = PlayShuffleInfoConfiguration(
      infoCB: {
        "\(self.artist.albumCount) Album\(self.artist.albumCount == 1 ? "" : "s") \(CommonString.oneMiddleDot) \(self.artist.songCount) Song\(self.artist.songCount == 1 ? "" : "s")"
      },
      playContextCb: { () in
        let songs = self.songsFetchedResultsController
          .getContextSongs(onlyCachedSongs: self.appDelegate.storage.settings.user.isOfflineMode) ??
          []
        let sortedSongs = songs.filterSongs().sortByAlbum()
        return PlayContext(containable: self.artist, playables: sortedSongs)
      },
      player: appDelegate.player,
      isInfoAlwaysHidden: true,
      usesProminentPlayButton: true
    )
    let detailHeaderConfig = DetailHeaderConfiguration(
      entityContainer: artist,
      rootView: self,
      tableView: tableView,
      playShuffleInfoConfig: playShuffleInfoConfig
    )
    detailOperationsView = GenericDetailTableHeader
      .createTableHeader(configuration: detailHeaderConfig)
    refreshArtistMetadataLine()
    DetailStickyHeaderSupport.install(stickyHeader: stickyHeader, in: self)
    refreshStickyHeaderText()
    tableView.layoutIfNeeded()
    DispatchQueue.main.async { [weak self] in
      self?.stickyHeader.alpha = 0
    }

    // cassette Polish 2 (D1/E2): overflow lives in the header action bar now,
    // not the nav bar. The nav bar shows only the back button at rest and fades
    // in the title on scroll.

    containableAtIndexPathCallback = { indexPath in
      switch indexPath.section + 1 {
      case LibraryElement.Album.rawValue:
        return self.albumsFetchedResultsController.getWrappedEntity(at: IndexPath(
          row: indexPath.row,
          section: 0
        ))
      case LibraryElement.Song.rawValue:
        return self.songsFetchedResultsController.getWrappedEntity(at: IndexPath(
          row: indexPath.row,
          section: 0
        ))
      default:
        return nil
      }
    }
    playContextAtIndexPathCallback = { indexPath in
      switch indexPath.section + 1 {
      case LibraryElement.Album.rawValue:
        let album = self.albumsFetchedResultsController.getWrappedEntity(at: IndexPath(
          row: indexPath.row,
          section: 0
        ))
        Task { @MainActor in do {
          try await album.fetch(
            storage: self.appDelegate.storage,
            librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
            playableDownloadManager: self.appDelegate.getMeta(self.account.info)
              .playableDownloadManager
          )
        } catch {
          // cassette Patch 040: tap-prefetch background sync.
          self.appDelegate.eventLogger.report(
            topic: "Album Sync",
            error: error,
            isBackground: true
          )
        }}
        return PlayContext(containable: album)
      case LibraryElement.Song.rawValue:
        let songIndexPath = IndexPath(row: indexPath.row, section: 0)
        return self.convertIndexPathToPlayContext(songIndexPath: songIndexPath)
      default:
        return nil
      }
    }
    swipeCallback = { indexPath, completionHandler in
      switch indexPath.section + 1 {
      case LibraryElement.Album.rawValue:
        let album = self.albumsFetchedResultsController.getWrappedEntity(at: IndexPath(
          row: indexPath.row,
          section: 0
        ))
        Task { @MainActor in
          do {
            try await album.fetch(
              storage: self.appDelegate.storage,
              librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
              playableDownloadManager: self.appDelegate.getMeta(self.account.info)
                .playableDownloadManager
            )
          } catch {
            self.appDelegate.eventLogger.report(
              topic: "Album Sync",
              error: error,
              isBackground: true
            )
          }
          completionHandler(SwipeActionContext(containable: album))
        }
      case LibraryElement.Song.rawValue:
        let songIndexPath = IndexPath(row: indexPath.row, section: 0)
        let song = self.songsFetchedResultsController.getWrappedEntity(at: songIndexPath)
        let playContext = self.convertIndexPathToPlayContext(songIndexPath: songIndexPath)
        completionHandler(SwipeActionContext(containable: song, playContext: playContext))
      default:
        completionHandler(nil)
      }
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = false
  }

  override func scrollViewDidScroll(_ scrollView: UIScrollView) {
    updateStickyHeaderAlpha()
  }

  private func updateStickyHeaderAlpha() {
    DetailStickyHeaderSupport.updateAlpha(
      stickyHeader: stickyHeader,
      scrollView: tableView,
      tableHeaderView: tableView.tableHeaderView,
      in: self
    )
  }

  private func refreshStickyHeaderText() {
    var parts: [String] = ["Artist"]
    if artist.albumCount > 0 {
      parts.append("\(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s")")
    }
    if artist.songCount > 0 {
      parts.append("\(artist.songCount) song\(artist.songCount == 1 ? "" : "s")")
    }
    let subtitle = parts.count > 1 ? parts.joined(separator: " · ") : nil
    stickyHeader.configure(title: artist.name, subtitle: subtitle)
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    albumsFetchedResultsController?.delegate = self
    songsFetchedResultsController?.delegate = self
    Task { @MainActor in
      do {
        try await artist.fetch(
          storage: self.appDelegate.storage,
          librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
          playableDownloadManager: self.appDelegate.getMeta(self.account.info)
            .playableDownloadManager
        )
      } catch {
        // cassette Patch 040: detail-appear background sync.
        self.appDelegate.eventLogger.report(
          topic: "Artist Sync",
          error: error,
          isBackground: true
        )
      }
      self.refreshArtistMetadataLine()
      self.detailOperationsView?.refresh()
    }
  }

  // Patch 026: artist metadata line. Year doesn't apply, so we surface
  // catalog scope instead: "Artist · 12 albums · 187 songs". Counts are
  // suppressed when missing rather than rendered as zeros.
  private func refreshArtistMetadataLine() {
    var parts: [String] = ["Artist"]
    if artist.albumCount > 0 {
      parts.append("\(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s")")
    }
    if artist.songCount > 0 {
      parts.append("\(artist.songCount) song\(artist.songCount == 1 ? "" : "s")")
    }
    detailOperationsView?.metadataOverride = parts.joined(separator: " · ")
    refreshStickyHeaderText()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    stickyHeader.alpha = 0
    albumsFetchedResultsController?.delegate = nil
    songsFetchedResultsController?.delegate = nil
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    defer { albumToScrollTo = nil }
    guard let albumToScrollTo = albumToScrollTo,
          let indexPath = albumsFetchedResultsController.fetchResultsController
          .indexPath(forObject: albumToScrollTo.managedObject)
    else { return }
    let adjustedIndexPath = IndexPath(row: indexPath.row, section: 1)
    tableView.scrollToRow(at: adjustedIndexPath, at: .top, animated: true)
  }

  func convertIndexPathToPlayContext(songIndexPath: IndexPath) -> PlayContext? {
    guard let songs = songsFetchedResultsController
      .getContextSongs(onlyCachedSongs: appDelegate.storage.settings.user.isOfflineMode)
    else { return nil }
    let selectedSong = songsFetchedResultsController.getWrappedEntity(at: songIndexPath)
    guard let playContextIndex = songs.firstIndex(of: selectedSong) else { return nil }
    return PlayContext(containable: artist, index: playContextIndex, playables: songs)
  }

  func convertCellViewToPlayContext(cell: UITableViewCell) -> PlayContext? {
    guard let indexPath = tableView.indexPath(for: cell),
          indexPath.section + 1 == LibraryElement.Song.rawValue
    else { return nil }
    return convertIndexPathToPlayContext(songIndexPath: IndexPath(row: indexPath.row, section: 0))
  }

  // MARK: - Table view data source

  override func numberOfSections(in tableView: UITableView) -> Int {
    // 2 section + 1 top section. The top section is needed due to display bugs
    3
  }

  override func tableView(
    _ tableView: UITableView,
    titleForHeaderInSection section: Int
  )
    -> String? {
    switch section + 1 {
    case LibraryElement.Album.rawValue:
      return "Albums"
    case LibraryElement.Song.rawValue:
      return "Songs"
    default:
      return ""
    }
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch section + 1 {
    case LibraryElement.Album.rawValue:
      return albumsFetchedResultsController.sections?[0].numberOfObjects ?? 0
    case LibraryElement.Song.rawValue:
      return songsFetchedResultsController.sections?[0].numberOfObjects ?? 0
    default:
      return 0
    }
  }

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  )
    -> UITableViewCell {
    switch indexPath.section + 1 {
    case LibraryElement.Album.rawValue:
      let cell: GenericTableCell = dequeueCell(for: tableView, at: indexPath)
      let album = albumsFetchedResultsController.getWrappedEntity(at: IndexPath(
        row: indexPath.row,
        section: 0
      ))
      cell.display(container: album, rootView: self)
      return cell
    case LibraryElement.Song.rawValue:
      let cell: PlayableTableCell = dequeueCell(for: tableView, at: indexPath)
      let song = songsFetchedResultsController.getWrappedEntity(at: IndexPath(
        row: indexPath.row,
        section: 0
      ))
      cell.display(playable: song, playContextCb: convertCellViewToPlayContext, rootView: self)
      return cell
    default:
      return UITableViewCell()
    }
  }

  override func tableView(
    _ tableView: UITableView,
    heightForHeaderInSection section: Int
  )
    -> CGFloat {
    switch section + 1 {
    case LibraryElement.Album.rawValue:
      return albumsFetchedResultsController.sections?[0]
        .numberOfObjects ?? 0 > 0 ? CommonScreenOperations.tableSectionHeightLarge : 0
    case LibraryElement.Song.rawValue:
      return songsFetchedResultsController.sections?[0]
        .numberOfObjects ?? 0 > 0 ? CommonScreenOperations.tableSectionHeightLarge : 0
    default:
      return 0.0
    }
  }

  override func tableView(
    _ tableView: UITableView,
    heightForRowAt indexPath: IndexPath
  )
    -> CGFloat {
    switch indexPath.section + 1 {
    case LibraryElement.Album.rawValue:
      return GenericTableCell.rowHeight
    case LibraryElement.Song.rawValue:
      return PlayableTableCell.rowHeight
    default:
      return 0.0
    }
  }

  override func tableView(
    _ tableView: UITableView,
    estimatedHeightForRowAt indexPath: IndexPath
  )
    -> CGFloat {
    switch indexPath.section + 1 {
    case LibraryElement.Album.rawValue:
      return GenericTableCell.rowHeight
    case LibraryElement.Song.rawValue:
      return PlayableTableCell.rowHeight
    default:
      return 0.0
    }
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    switch indexPath.section + 1 {
    case LibraryElement.Album.rawValue:
      let album = albumsFetchedResultsController.getWrappedEntity(at: IndexPath(
        row: indexPath.row,
        section: 0
      ))
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToAlbumDetail(account: account, album: album),
        animated: true
      )
    case LibraryElement.Song.rawValue: break
    default: break
    }
  }

  // cassette Patch 045: `updateSearchResults` override removed
  // alongside the search controller; the base no-op runs in its
  // place when a parent view fires `updateSearchResults(for:)`.

  override func controller(
    _ controller: NSFetchedResultsController<NSFetchRequestResult>,
    didChange anObject: Any,
    at indexPath: IndexPath?,
    for type: NSFetchedResultsChangeType,
    newIndexPath: IndexPath?
  ) {
    var section = 0
    switch controller {
    case albumsFetchedResultsController.fetchResultsController:
      section = LibraryElement.Album.rawValue - 1
    case songsFetchedResultsController.fetchResultsController:
      section = LibraryElement.Song.rawValue - 1
    default:
      return
    }

    resultUpdateHandler?.applyChangesOfMultiRowType(
      controller,
      didChange: anObject,
      determinedSection: section,
      at: indexPath,
      for: type,
      newIndexPath: newIndexPath
    )
  }

  override func controller(
    _ controller: NSFetchedResultsController<NSFetchRequestResult>,
    didChange sectionInfo: NSFetchedResultsSectionInfo,
    atSectionIndex sectionIndex: Int,
    for type: NSFetchedResultsChangeType
  ) {}
}
