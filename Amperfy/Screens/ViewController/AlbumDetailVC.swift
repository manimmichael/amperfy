//
//  AlbumDetailVC.swift
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
import UIKit

// MARK: - AlbumDetailDiffableDataSource

class AlbumDetailDiffableDataSource: BasicUITableViewDiffableDataSource {
  override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
    false
  }

  override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
    // Return true to be enable swipe
    true
  }
}

// MARK: - AlbumDetailVC

class AlbumDetailVC: SingleSnapshotFetchedResultsTableViewController<SongMO> {
  override var sceneTitle: String? { album.name }

  var songToScrollTo: Song?
  private var fetchedResultsController: AlbumSongsFetchedResultsController!
  private var optionsButton: UIBarButtonItem!
  private var collapsedPlayButton: UIBarButtonItem!
  private var detailOperationsView: GenericDetailTableHeader?
  private let stickyHeader = DetailStickyHeaderView()
  private var hideUniformArtistSubtitle = false
  // Cassette fork — Layer 3 Phase 3.2 (library filtering). Owned track ids used
  // to dim non-owned rows; the detail list itself is never filtered. Empty when
  // nothing is on the phone (then every row dims, which is correct).
  private var cassetteOwnedTrackIds: Set<String> = []
  let album: Album

  init(account: Account, album: Album) {
    self.album = album
    super.init(style: .grouped, account: account)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func createDiffableDataSource() -> BasicUITableViewDiffableDataSource {
    let source =
      AlbumDetailDiffableDataSource(tableView: tableView) { tableView, indexPath, objectID -> UITableViewCell? in
        guard let object = try? self.appDelegate.storage.main.context
          .existingObject(with: objectID),
          let songMO = object as? SongMO
        else {
          fatalError("Managed object should be available")
        }
        let song = Song(managedObject: songMO)
        return self.createCell(tableView, forRowAt: indexPath, song: song)
      }
    return source
  }

  override func viewDidLoad() {
    // cassette Patch 037: see ArtistDetailVC for context — pin
    // inline title before super so the parent's large title
    // doesn't flash through the push transition.
    navigationItem.largeTitleDisplayMode = .never
    super.viewDidLoad()
    appDelegate.userStatistics.visited(.albumDetail)

    // cassette redesign (Surface 1): overflow returns to the navigation bar
    // (native glass circle on iOS 26); a play bar-button joins it when the
    // hero collapses under the bar.
    optionsButton = UIBarButtonItem.createOptionsBarButton()
    optionsButton.menu = UIMenu.lazyMenu { [weak self] in
      guard let self else { return [] }
      return EntityPreviewActionBuilder(container: album, on: self).createMenuActions()
    }
    collapsedPlayButton = UIBarButtonItem(
      image: UIImage(systemName: "play.fill"),
      primaryAction: UIAction { [weak self] _ in
        guard let self else { return }
        appDelegate.player.play(context: PlayContext(
          containable: album,
          playables: fetchedResultsController
            .getContextSongs(onlyCachedSongs: appDelegate.storage.settings.user.isOfflineMode) ?? []
        ))
      }
    )
    collapsedPlayButton.accessibilityLabel = "Play"

    cassetteOwnedTrackIds = DeviceOwnershipManager(
      context: appDelegate.storage.main.context
    ).fetchAllSubsonicTrackIds()

    fetchedResultsController = AlbumSongsFetchedResultsController(
      forAlbum: album,
      coreDataCompanion: appDelegate.storage.main,
      isGroupedInAlphabeticSections: false
    )
    singleFetchedResultsController = fetchedResultsController
    singleFetchedResultsController?.delegate = self
    singleFetchedResultsController?.fetch()

    // cassette Patch 045: in-view search removed from album detail.
    // Library / Songs / Playlists category lists keep search; the
    // detail view presents a fixed track list instead.
    tableView.register(nibName: PlayableTableCell.typeName)
    tableView.rowHeight = PlayableTableCell.rowHeight
    // Catalyst also need an estimate to calculate the correct height before scrolling
    tableView.estimatedRowHeight = PlayableTableCell.rowHeight
    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    tableView.sectionHeaderHeight = 0.0
    tableView.estimatedSectionHeaderHeight = 0.0
    tableView.backgroundColor = .backgroundColor

    // cassette Patch 104 (Root 2): artwork is the first content of the
    // scroll. The table extends under the navigation bar (insets mirrored
    // manually in viewDidLayoutSubviews) and the bar is transparent at the
    // scroll edge so back/overflow float over the artwork; the system
    // restores the standard bar surface once content scrolls under it.
    tableView.contentInsetAdjustmentBehavior = .never
    let transparentBar = UINavigationBarAppearance()
    transparentBar.configureWithTransparentBackground()
    navigationItem.scrollEdgeAppearance = transparentBar
    navigationItem.compactScrollEdgeAppearance = transparentBar

    let playShuffleInfoConfig = PlayShuffleInfoConfiguration(
      infoCB: { "\(self.album.songCount) Song\(self.album.songCount == 1 ? "" : "s")" },
      playContextCb: { () in PlayContext(
        containable: self.album,
        playables: self.fetchedResultsController
          .getContextSongs(onlyCachedSongs: self.appDelegate.storage.settings.user.isOfflineMode) ??
          []
      ) },
      player: appDelegate.player,
      isInfoAlwaysHidden: true,
      usesProminentPlayButton: true
    )
    let detailHeaderConfig = DetailHeaderConfiguration(
      entityContainer: album,
      rootView: self,
      tableView: tableView,
      playShuffleInfoConfig: playShuffleInfoConfig,
      extendsUnderNavigationBar: true
    )
    detailOperationsView = GenericDetailTableHeader
      .createTableHeader(configuration: detailHeaderConfig)
    refreshAlbumMetadataLine()
    DetailStickyHeaderSupport.install(
      stickyHeader: stickyHeader,
      in: self,
      overflowItem: optionsButton,
      collapsedPlayItem: collapsedPlayButton
    )
    stickyHeader.configure(title: album.name, subtitle: album.subtitle)
    tableView.layoutIfNeeded()
    DispatchQueue.main.async { [weak self] in
      self?.stickyHeader.alpha = 0
    }
    updateHideUniformArtistSubtitle()
    snapshotDidChange = { [weak self] in
      self?.updateHideUniformArtistSubtitle()
    }

    containableAtIndexPathCallback = { indexPath in
      self.fetchedResultsController.getWrappedEntity(at: indexPath)
    }
    playContextAtIndexPathCallback = convertIndexPathToPlayContext
    swipeCallback = { indexPath, completionHandler in
      let song = self.fetchedResultsController.getWrappedEntity(at: indexPath)
      let playContext = self.convertIndexPathToPlayContext(songIndexPath: indexPath)
      completionHandler(SwipeActionContext(containable: song, playContext: playContext))
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = false
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // Patch 104 (Root 2): with contentInsetAdjustmentBehavior == .never the
    // safe areas are mirrored manually (bottom = tab bar + mini player).
    tableView.contentInset.bottom = view.safeAreaInsets.bottom
    tableView.verticalScrollIndicatorInsets.top = view.safeAreaInsets.top
    tableView.verticalScrollIndicatorInsets.bottom = view.safeAreaInsets.bottom
    detailOperationsView?.resizeToFit()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    stickyHeader.alpha = 0
  }

  override func scrollViewDidScroll(_ scrollView: UIScrollView) {
    updateStickyHeaderAlpha()
  }

  private func updateStickyHeaderAlpha() {
    DetailStickyHeaderSupport.updateAlpha(
      stickyHeader: stickyHeader,
      scrollView: tableView,
      tableHeaderView: tableView.tableHeaderView,
      in: self,
      collapsedPlayItem: collapsedPlayButton
    )
  }

  private func updateHideUniformArtistSubtitle() {
    let songs = fetchedResultsController?
      .getContextSongs(onlyCachedSongs: false) ?? []
    let names = Set(songs.compactMap(\.creatorName))
    hideUniformArtistSubtitle = names.count == 1
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()

    Task { @MainActor in
      do {
        try await album.fetch(
          storage: self.appDelegate.storage,
          librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
          playableDownloadManager: self.appDelegate.getMeta(self.account.info)
            .playableDownloadManager
        )
      } catch {
        // cassette Patch 040: detail-appear background sync.
        self.appDelegate.eventLogger.report(
          topic: "Album Sync",
          error: error,
          isBackground: true
        )
      }
      self.refreshAlbumMetadataLine()
      self.detailOperationsView?.refresh()
    }
  }

  // Patch 026: build the Spotify-style "Type · Year · Duration" metadata
  // line. Type comes from OpenSubsonic releaseTypes (defaults to "Album"
  // when the server didn't surface one). Year and duration are skipped
  // when missing rather than rendered as zeros.
  private func refreshAlbumMetadataLine() {
    var parts: [String] = [album.albumType]
    if album.year > 0 {
      parts.append("\(album.year)")
    }
    if album.duration > 0 {
      parts.append(album.duration.asDurationShortString)
    }
    detailOperationsView?.metadataOverride = parts.joined(separator: " · ")
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    defer { songToScrollTo = nil }
    guard let songToScrollTo = songToScrollTo,
          let indexPath = fetchedResultsController.fetchResultsController
          .indexPath(forObject: songToScrollTo.managedObject)
    else { return }
    tableView.scrollToRow(at: indexPath, at: .top, animated: true)
  }

  func convertIndexPathToPlayContext(songIndexPath: IndexPath) -> PlayContext? {
    guard let songs = fetchedResultsController
      .getContextSongs(onlyCachedSongs: appDelegate.storage.settings.user.isOfflineMode)
    else { return nil }
    let selectedSong = fetchedResultsController.getWrappedEntity(at: songIndexPath)
    guard let playContextIndex = songs.firstIndex(of: selectedSong) else { return nil }
    return PlayContext(containable: album, index: playContextIndex, playables: songs)
  }

  func convertCellViewToPlayContext(cell: UITableViewCell) -> PlayContext? {
    guard let indexPath = tableView.indexPath(for: cell) else { return nil }
    return convertIndexPathToPlayContext(songIndexPath: indexPath)
  }

  func createCell(
    _ tableView: UITableView,
    forRowAt indexPath: IndexPath,
    song: Song
  )
    -> UITableViewCell {
    let cell: PlayableTableCell = dequeueCell(for: tableView, at: indexPath)
    cell.display(
      playable: song,
      playContextCb: convertCellViewToPlayContext,
      rootView: self,
      isDislayAlbumTrackNumberStyle: true,
      hideArtistSubtitle: hideUniformArtistSubtitle,
      cassetteIsOwned: cassetteOwnedTrackIds.contains(song.id)
    )
    return cell
  }

  // cassette Patch 045: `updateSearchResults` override removed
  // alongside the search controller. The base no-op
  // `BasicTableViewController.updateSearchResults` runs harmlessly
  // when scrolled-into-view callbacks fire.
}
