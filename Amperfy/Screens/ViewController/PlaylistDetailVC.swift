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
    exectueAfterAnimation {
      self.playlist?.movePlaylistItem(fromIndex: sourceIndexPath.row, to: destinationIndexPath.row)

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
    exectueAfterAnimation {
      self.playlist?.remove(at: indexPath.row)
      guard self.appDelegate.storage.settings.user.isOnlineMode,
            let account = self.playlist.account else { return }
      Task { @MainActor in do {
        try await self.appDelegate.getMeta(account.info).librarySyncer.syncUpload(
          playlistToDeleteSong: self.playlist,
          index: indexPath.row
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
  // to dim non-owned rows; playlist contents are never filtered (mixed
  // playlists keep all items, non-owned ones skip silently on playback).
  private var cassetteOwnedTrackIds: Set<String> = []

  private var editButton: UIBarButtonItem!
  private var optionsButton: UIBarButtonItem!
  private var collapsedPlayButton: UIBarButtonItem!
  var detailOperationsView: GenericDetailTableHeader?
  private let stickyHeader = DetailStickyHeaderView()

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
    navigationItem.largeTitleDisplayMode = .never
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
    optionsButton = UIBarButtonItem.createOptionsBarButton()
    optionsButton.menu = UIMenu.lazyMenu {
      EntityPreviewActionBuilder(container: self.playlist, on: self).createMenuActions()
    }
    // cassette redesign (Surface 1): play bar-button revealed when the hero
    // collapses under the (native glass) navigation bar.
    collapsedPlayButton = UIBarButtonItem(
      image: UIImage(systemName: "play.fill"),
      primaryAction: UIAction { [weak self] _ in
        guard let self else { return }
        appDelegate.player.play(context: PlayContext(
          containable: playlist,
          playables: fetchedResultsController
            .getContextSongs(onlyCachedSongs: appDelegate.storage.settings.user.isOfflineMode) ?? []
        ))
      }
    )
    collapsedPlayButton.accessibilityLabel = "Play"
    collapsedPlayButton.isHidden = true

    let playShuffleInfoConfig = PlayShuffleInfoConfiguration(
      infoCB: { "\(self.playlist.songCount) Song\(self.playlist.songCount == 1 ? "" : "s")" },
      playContextCb: { () in PlayContext(
        containable: self.playlist,
        playables: self.fetchedResultsController
          .getContextSongs(onlyCachedSongs: self.appDelegate.storage.settings.user.isOfflineMode) ??
          []
      ) },
      player: appDelegate.player,
      isInfoAlwaysHidden: true,
      usesProminentPlayButton: true
    )
    let detailHeaderConfig = DetailHeaderConfiguration(
      entityContainer: playlist,
      rootView: self,
      tableView: tableView,
      playShuffleInfoConfig: playShuffleInfoConfig
    )
    detailOperationsView = GenericDetailTableHeader
      .createTableHeader(configuration: detailHeaderConfig)
    refreshPlaylistMetadataLine()
    DetailStickyHeaderSupport.install(stickyHeader: stickyHeader, in: self)
    stickyHeader.configure(title: playlist.name, subtitle: playlistStickySubtitle())
    tableView.layoutIfNeeded()
    DispatchQueue.main.async { [weak self] in
      self?.stickyHeader.alpha = 0
    }
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

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    // Reset the collapsed title only when PUSHING a child (this VC stays in the
    // stack, so the child's bar starts clean). On a POP — including the
    // interactive edge-swipe — `isMovingFromParent` is true; zeroing alpha here
    // would snap the bar title off mid-swipe ("header re-expands"). Leave it so
    // the title slides away continuously with the content. A cancelled swipe
    // self-heals: viewIsAppearing recomputes alpha from the scroll offset.
    if !isMovingFromParent {
      stickyHeader.alpha = 0
    } else {
      // cassette (header-pop fix, round 3): playlist detail does NOT extend
      // under the nav bar, so it's far less prone to the pop re-expand than
      // album/artist — but it shares GenericDetailTableHeader, so apply the same
      // whole-transition freeze for consistency and safety.
      HeaderPopDebug.snapshot(
        "viewWillDisappear(pop)",
        header: tableView.tableHeaderView,
        scrollView: tableView,
        in: self
      )
      freezeCollapsingHeaderForPopTransition { [weak self] in
        guard let self else { return }
        // round 6: defer the re-measure + alpha recompute one runloop so it reads
        // SETTLED layout. Synchronously in the completion the layout is still
        // restoring (the bar animates back from the destination's large-title
        // height), which measures the hero as collapsed and snaps the title to
        // full opacity. The re-attached titleView already carries its correct
        // pre-pop alpha; this pass just confirms it.
        DispatchQueue.main.async {
          self.detailOperationsView?.resizeToFit()
          self.updateStickyHeaderAlpha()
        }
      }
    }
  }

  override func scrollViewDidScroll(_ scrollView: UIScrollView) {
    HeaderPopDebug.snapshot(
      "scrollViewDidScroll",
      header: tableView.tableHeaderView,
      scrollView: scrollView,
      in: self
    )
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

  private func playlistStickySubtitle() -> String? {
    var parts = ["Playlist"]
    if playlist.songCount > 0 {
      parts.append("\(playlist.songCount) song\(playlist.songCount == 1 ? "" : "s")")
    }
    return parts.joined(separator: " · ")
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
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
  // so we surface scope: "Playlist · 14 songs · 56m". Counts and
  // duration are skipped when missing.
  private func refreshPlaylistMetadataLine() {
    var parts = ["Playlist"]
    if playlist.songCount > 0 {
      parts.append("\(playlist.songCount) song\(playlist.songCount == 1 ? "" : "s")")
    }
    if playlist.duration > 0 {
      parts.append(playlist.duration.asDurationShortString)
    }
    detailOperationsView?.metadataOverride = parts.joined(separator: " · ")
    stickyHeader.configure(title: playlist.name, subtitle: playlistStickySubtitle())
  }

  /// cassette Patch 020: Cassette-flavored "Empty playlist" state.
  /// Refreshed on appear and after the playlist sync completes.
  private func refreshEmptyState() {
    contentUnavailableConfiguration = playlist.songCount == 0
      ? Self.emptyPlaylistConfig
      : nil
  }

  private static let emptyPlaylistConfig: UIContentUnavailableConfiguration = {
    var config = UIContentUnavailableConfiguration.empty()
    config.image = UIImage(systemName: "music.note.list")
    config.text = "Empty playlist"
    config.secondaryText = "Add songs from any artist or album."
    config.textProperties.font = UIFont.cassette(.sectionTitle)
    config.textProperties.color = CassetteTheme.UIColors.ink
    config.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
    config.secondaryTextProperties.color = CassetteTheme.UIColors.ink2
    config.imageProperties.tintColor = CassetteTheme.UIColors.ink3
    return config
  }()

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

    // cassette redesign (Surface 1): overflow returns to the navigation bar
    // alongside Edit; the play bar-button sits between them and stays hidden
    // until the hero collapses (DetailStickyHeaderSupport toggles it).
    navigationItem.rightBarButtonItems = [optionsButton, collapsedPlayButton, edititingBarButton]
      .compactMap { $0 }
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
