//
//  PlaylistDetailVC.swift
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

// MARK: - PlaylistDetailDiffableDataSource

class PlaylistDetailDiffableDataSource: BasicUITableViewDiffableDataSource {
  var playlist: Playlist!
  var isMoveAllowed = false
  var isEditAllowed = true

  /// The playlist position of a row. On the phone the list hides songs that are not on
  /// it, so a row number is not a position in the playlist (UX review 2026-10-20).
  private func playlistIndex(for indexPath: IndexPath) -> Int {
    guard let objectID = itemIdentifier(for: indexPath),
          let index = playlist.managedObject.items.firstIndex(where: { $0.objectID == objectID })
    else { return indexPath.row }
    return index
  }

  override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
    // Return false if you do not want the item to be re-orderable.
    isMoveAllowed
  }

  override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
    // Return true to be enable swipe
    isEditAllowed
  }

  override func tableView(
    _ tableView: UITableView,
    moveRowAt sourceIndexPath: IndexPath,
    to destinationIndexPath: IndexPath
  ) {
    let fromIndex = playlistIndex(for: sourceIndexPath)
    let toIndex = playlistIndex(for: destinationIndexPath)
    exectueAfterAnimation {
      self.playlist?.movePlaylistItem(fromIndex: fromIndex, to: toIndex)

      guard self.appDelegate.storage.settings.user.isOnlineMode,
            let account = self.playlist.account else { return }
      Task { @MainActor in do {
        try await self.appDelegate.getMeta(account.info).librarySyncer
          .syncUpload(playlistToUpdateOrder: self.playlist)
      } catch {
        self.appDelegate.eventLogger.report(topic: "Playlist Upload Order Update", error: error)
      }}
    }
    super.tableView(tableView, moveRowAt: sourceIndexPath, to: destinationIndexPath)
  }

  override func tableView(
    _ tableView: UITableView,
    commit editingStyle: UITableViewCell.EditingStyle,
    forRowAt indexPath: IndexPath
  ) {
    guard editingStyle == .delete else { return }
    let index = playlistIndex(for: indexPath)
    exectueAfterAnimation {
      self.playlist?.remove(at: index)
      guard self.appDelegate.storage.settings.user.isOnlineMode,
            let account = self.playlist.account else { return }
      Task { @MainActor in do {
        try await self.appDelegate.getMeta(account.info).librarySyncer.syncUpload(
          playlistToDeleteSong: self.playlist,
          index: index
        )
      } catch {
        self.appDelegate.eventLogger.report(topic: "Playlist Upload Entry Remove", error: error)
      }}
    }
    super.tableView(tableView, commit: editingStyle, forRowAt: indexPath)
  }
}

// MARK: - PlaylistDetailVC

class PlaylistDetailVC: SingleSnapshotFetchedResultsTableViewController<PlaylistItemMO> {
  override var sceneTitle: String? { playlist.name }

  private var fetchedResultsController: PlaylistItemsFetchedResultsController!
  let playlist: Playlist
  // Cassette fork — Layer 3 Phase 3.2 (library filtering). Owned track ids used
  // to dim non-owned rows in Server Mode. On the phone the list shows only songs
  // that are on it; the playlist itself keeps every item (UX review 2026-10-20).
  private var cassetteOwnedTrackIds: Set<String> = []

  private var editButton: UIBarButtonItem!
  var detailOperationsView: GenericDetailTableHeader?
  /// The shared detail-page frame (Wave 3). The hero stays below the bar: this screen has
  /// pull-to-refresh, whose spinner would sit under a transparent bar at the top edge.
  private lazy var chrome = DetailScreenChrome(
    host: self,
    placement: .belowBar,
    menu: { [weak self] in
      guard let self else { return [] }
      return EntityPreviewActionBuilder(container: playlist, on: self).createMenuActions()
    },
    playContext: { [weak self] in self?.playlistPlayContext() }
  )

  init(account: Account, playlist: Playlist) {
    self.playlist = playlist
    super.init(style: .grouped, account: account)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func createDiffableDataSource() -> BasicUITableViewDiffableDataSource {
    let source =
      PlaylistDetailDiffableDataSource(tableView: tableView) { tableView, indexPath, objectID -> UITableViewCell? in
        guard let object = try? self.appDelegate.storage.main.context
          .existingObject(with: objectID),
          let playlistItemMO = object as? PlaylistItemMO
        else {
          return UITableViewCell()
        }
        let playlistItem = PlaylistItem(
          library: self.appDelegate.storage.main.library,
          managedObject: playlistItemMO
        )
        return self.createCell(tableView, forRowAt: indexPath, playlistItem: playlistItem)
      }
    source.playlist = playlist
    return source
  }

  override func viewDidLoad() {
    // cassette Patch 037: see ArtistDetailVC for context — pin
    // inline title before super so the parent's large title
    // doesn't flash through the push transition.
    chrome.prepareBeforeLoad()
    super.viewDidLoad()

    #if !targetEnvironment(macCatalyst)
      refreshControl = UIRefreshControl()
    #endif

    appDelegate.userStatistics.visited(.playlistDetail)
    cassetteOwnedTrackIds = DeviceOwnershipManager(
      context: appDelegate.storage.main.context
    ).fetchAllSubsonicTrackIds()
    fetchedResultsController = PlaylistItemsFetchedResultsController(
      forPlaylist: playlist,
      coreDataCompanion: appDelegate.storage.main,
      isGroupedInAlphabeticSections: false
    )
    singleFetchedResultsController = fetchedResultsController
    singleFetchedResultsController?.delegate = self
    singleFetchedResultsController?.fetch()

    tableView.register(nibName: PlayableTableCell.typeName)
    tableView.rowHeight = PlayableTableCell.rowHeight
    tableView.estimatedRowHeight = PlayableTableCell.rowHeight
    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    tableView.sectionHeaderHeight = 0.0
    tableView.estimatedSectionHeaderHeight = 0.0
    tableView.backgroundColor = .backgroundColor

    // Use a single button, two buttons don't work on catalyst
    editButton = UIBarButtonItem(
      title: "Edit",
      style: .plain,
      target: self,
      action: #selector(openEditView)
    )
    let playShuffleInfoConfig = PlayShuffleInfoConfiguration(
      infoCB: {
        DetailScreenChrome.songCountText(
          onPhone: self.fetchedResultsController.fetchResultsController.fetchedObjects?.count ?? 0,
          total: max(self.playlist.songCount, self.fetchedResultsController.totalItemCount)
        )
      },
      playContextCb: { () in self.playlistPlayContext() },
      player: appDelegate.player,
      isInfoAlwaysHidden: true,
      usesProminentPlayButton: true
    )
    let detailHeaderConfig = DetailHeaderConfiguration(
      entityContainer: playlist,
      rootView: self,
      tableView: tableView,
      playShuffleInfoConfig: playShuffleInfoConfig,
      extendsUnderNavigationBar: chrome.extendsUnderNavigationBar
    )
    detailOperationsView = GenericDetailTableHeader
      .createTableHeader(configuration: detailHeaderConfig)
    refreshPlaylistMetadataLine()
    chrome.install(header: detailOperationsView, title: playlist.name)
    refreshControl?.addTarget(
      self,
      action: #selector(Self.handleRefresh),
      for: UIControl.Event.valueChanged
    )

    snapshotDidChange = { [weak self] in
      self?.refreshPlaylistMetadataLine()
      self?.detailOperationsView?.refresh()
    }

    containableAtIndexPathCallback = { indexPath in
      self.fetchedResultsController.getWrappedEntity(at: indexPath).playable
    }
    playContextAtIndexPathCallback = { indexPath in
      self.convertIndexPathToPlayContext(songIndexPath: indexPath)
    }
    swipeCallback = { indexPath, completionHandler in
      let playlistItem = self.fetchedResultsController.getWrappedEntity(at: indexPath)
      let playContext = self.convertIndexPathToPlayContext(songIndexPath: indexPath)
      completionHandler(SwipeActionContext(
        containable: playlistItem.playable,
        playContext: playContext
      ))
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = false
    refreshEmptyState()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // Playlist never re-measured its hero on layout, so a rotation or iPad resize that kept
    // the size class left it at the old width (DET-4).
    chrome.viewDidLayoutSubviews()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    chrome.viewWillDisappear(isMovingFromParent: isMovingFromParent)
  }

  override func scrollViewDidScroll(_ scrollView: UIScrollView) {
    chrome.scrollViewDidScroll()
  }

  override func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    super.scrollViewDidEndDecelerating(scrollView)
    chrome.scrollDidSettle()
  }

  override func scrollViewDidEndDragging(
    _ scrollView: UIScrollView,
    willDecelerate decelerate: Bool
  ) {
    super.scrollViewDidEndDragging(scrollView, willDecelerate: decelerate)
    if !decelerate {
      chrome.scrollDidSettle()
    }
  }

  /// What Play plays, for the hero button and the collapsed bar button alike.
  private func playlistPlayContext() -> PlayContext {
    PlayContext(
      containable: playlist,
      playables: fetchedResultsController
        .getContextSongs(onlyCachedSongs: appDelegate.storage.settings.user.isOfflineMode) ?? []
    )
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    chrome.viewIsAppearing()
    // cassette (UX review 2026-10-20): "8 of 12 songs on this phone" under the list.
    tableView.tableFooterView = DetailScreenChrome.onPhoneFooter(
      onPhone: fetchedResultsController.fetchResultsController.fetchedObjects?.count ?? 0,
      total: max(playlist.songCount, fetchedResultsController.totalItemCount)
    )
    if appDelegate.storage.settings.user.isOfflineMode {
      tableView.isEditing = false
    }
    refreshBarButtons()
    Task { @MainActor in
      do {
        try await playlist.fetch(
          storage: self.appDelegate.storage,
          librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
          playableDownloadManager: self.appDelegate.getMeta(self.account.info)
            .playableDownloadManager
        )
      } catch {
        self.appDelegate.eventLogger.report(topic: "Playlist Sync", error: error)
      }
      self.refreshPlaylistMetadataLine()
      self.detailOperationsView?.refresh()
      self.refreshEmptyState()
    }
  }

  // Patch 026: playlist metadata line. Year doesn't apply for playlists,
  // so we surface scope: "14 songs · 56m". Counts and duration are skipped
  // when missing. cassette: leading type noun dropped, matching the other
  // detail pages.
  private func refreshPlaylistMetadataLine() {
    var parts: [String] = []
    if playlist.songCount > 0 {
      parts.append("\(playlist.songCount) song\(playlist.songCount == 1 ? "" : "s")")
    }
    if playlist.duration > 0 {
      parts.append(playlist.duration.asDurationShortString)
    }
    detailOperationsView?.metadataOverride = parts.joined(separator: " · ")
    chrome.setTitle(playlist.name)
  }

  /// cassette Patch 020: Cassette-flavored "Empty playlist" state.
  /// Refreshed on appear and after the playlist sync completes.
  private func refreshEmptyState() {
    contentUnavailableConfiguration = playlist.songCount == 0
      ? Self.emptyPlaylistConfig
      : nil
  }

  private static let emptyPlaylistConfig: UIContentUnavailableConfiguration = .cassetteEmpty(
    image: CassetteIcon.playlist.uiImage,
    title: "Empty playlist",
    body: "Add songs from any artist or album."
  )

  func refreshBarButtons() {
    var edititingBarButton: UIBarButtonItem? = nil

    if appDelegate.storage.settings.user.isOnlineMode {
      edititingBarButton = editButton
      edititingBarButton?.title = "Edit"
      edititingBarButton?.style = .plain
      if playlist.isSmartPlaylist {
        edititingBarButton?.isEnabled = false
      }
    }

    // Overflow, then the collapsed play (hidden until the hero collapses), then Edit.
    chrome.setExtraTrailingItems([edititingBarButton].compactMap { $0 })
  }

  func convertIndexPathToPlayContext(songIndexPath: IndexPath) -> PlayContext? {
    guard let songs = fetchedResultsController
      .getContextSongs(onlyCachedSongs: appDelegate.storage.settings.user.isOfflineMode)
    else { return nil }
    return PlayContext(containable: playlist, index: songIndexPath.row, playables: songs)
  }

  func convertCellViewToPlayContext(cell: UITableViewCell) -> PlayContext? {
    guard let indexPath = tableView.indexPath(for: cell)
    else { return nil }
    return convertIndexPathToPlayContext(songIndexPath: IndexPath(row: indexPath.row, section: 0))
  }

  @objc
  private func openEditView(sender: UIBarButtonItem) {
    let playlistDetailVC = AppStoryboard.Main.segueToPlaylistEdit(
      account: account,
      playlist: playlist
    )
    let playlistDetailNav = UINavigationController(rootViewController: playlistDetailVC)
    playlistDetailVC.onDoneCB = {
      self.detailOperationsView?.refresh()
      self.tableView.reloadData()
      self.refreshEmptyState()
    }
    present(playlistDetailNav, animated: true, completion: nil)
  }

  func createCell(
    _ tableView: UITableView,
    forRowAt indexPath: IndexPath,
    playlistItem: PlaylistItem
  )
    -> UITableViewCell {
    let cell: PlayableTableCell = dequeueCell(for: tableView, at: indexPath)
    if let song = playlistItem.playable.asSong {
      cell.display(
        playable: song,
        playContextCb: convertCellViewToPlayContext,
        rootView: self,
        cassetteIsOwned: cassetteOwnedTrackIds.contains(song.id)
      )
    }
    return cell
  }

  // cassette Patch 045: vestigial `updateSearchResults` override
  // removed. PlaylistDetailVC never installed a search controller,
  // so this override only ran when ancestral lifecycle hooks
  // (e.g. BasicTableViewController.viewIsAppearing) called through.
  // The base no-op covers that path.

  @objc
  func handleRefresh(refreshControl: UIRefreshControl) {
    Task { @MainActor in
      do {
        try await self.appDelegate.getMeta(self.account.info).librarySyncer
          .syncDown(playlist: playlist)
      } catch {
        self.appDelegate.eventLogger.report(topic: "Playlist Sync", error: error)
      }
      self.detailOperationsView?.refresh()
      self.refreshControl?.endRefreshing()
    }
  }
}
