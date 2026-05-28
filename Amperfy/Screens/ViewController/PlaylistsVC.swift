//
//  PlaylistsVC.swift
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

// MARK: - PlaylistsDiffableDataSource

class PlaylistsDiffableDataSource: BasicUITableViewDiffableDataSource {
  override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
    // Return false if you do not want the item to be re-orderable.
    false
  }

  func playlistAt(indexPath: IndexPath) -> Playlist? {
    let objectID = itemIdentifier(for: indexPath)
    guard let objectID,
          let object = try? appDelegate.storage.main.context
          .existingObject(with: objectID),
          let playlistMO = object as? PlaylistMO
    else {
      return nil
    }

    let playlist = Playlist(
      library: appDelegate.storage.main.library,
      managedObject: playlistMO
    )
    return playlist
  }

  // Override to support editing the table view.
  override func tableView(
    _ tableView: UITableView,
    commit editingStyle: UITableViewCell.EditingStyle,
    forRowAt indexPath: IndexPath
  ) {
    guard editingStyle == .delete else { return }

    guard let playlist = playlistAt(indexPath: indexPath)
    else {
      return
    }

    let playlistId = playlist.id
    appDelegate.storage.main.library.deletePlaylist(playlist)
    appDelegate.storage.main.saveContext()

    guard let account = playlist.account else { return }
    Task { @MainActor in do {
      try await self.appDelegate.getMeta(account.info).librarySyncer
        .syncUpload(playlistIdToDelete: playlistId)
    } catch {
      self.appDelegate.eventLogger.report(topic: "Playlist Upload Deletion", error: error)
    }}
  }
}

// MARK: - PlaylistsVC

class PlaylistsVC: SingleSnapshotFetchedResultsTableViewController<PlaylistMO> {
  override var sceneTitle: String? { "Playlists" }

  private var fetchedResultsController: PlaylistFetchedResultsController!
  private var optionsButton: UIBarButtonItem!
  private var sortType: PlaylistSortType = .name
  // cassette Patch 044: pinned virtual "Liked Songs" entry. Sits as
  // `tableView.tableHeaderView` above the user-created playlists so
  // it's always visible at the top of the list. Tap routes into the
  // existing favorites-filtered SongsVC; count refreshes on appear.
  private var likedSongsHeader: LikedSongsHeaderRowView?

  init(account: Account) {
    super.init(style: .grouped, account: account)
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  override func createDiffableDataSource() -> BasicUITableViewDiffableDataSource {
    let source =
      PlaylistsDiffableDataSource(tableView: tableView) { tableView, indexPath, objectID -> UITableViewCell? in
        guard let object = try? self.appDelegate.storage.main.context
          .existingObject(with: objectID),
          let playlistMO = object as? PlaylistMO
        else {
          return UITableViewCell()
        }
        let playlist = Playlist(
          library: self.appDelegate.storage.main.library,
          managedObject: playlistMO
        )
        return self.createCell(tableView, forRowAt: indexPath, playlist: playlist)
      }
    return source
  }

  func playlistAt(indexPath: IndexPath) -> Playlist? {
    (diffableDataSource as? PlaylistsDiffableDataSource)?.playlistAt(indexPath: indexPath)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    appDelegate.userStatistics.visited(.playlists)

    optionsButton = UIBarButtonItem.createSortBarButton()

    change(sortType: appDelegate.storage.settings.user.playlistsSortSetting)

    // cassette Polish 2 (B1): per-category search removed; use the global Search tab.
    setNavBarTitle(title: "Playlists")
    tableView.register(nibName: PlaylistTableCell.typeName)
    tableView.rowHeight = PlaylistTableCell.rowHeight
    tableView.estimatedRowHeight = PlaylistTableCell.rowHeight
    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    tableView.sectionHeaderHeight = 0.0
    tableView.estimatedSectionHeaderHeight = 0.0
    tableView.backgroundColor = .backgroundColor

    setupLikedSongsHeader()

    #if !targetEnvironment(macCatalyst)
      refreshControl = UIRefreshControl()
    #endif
    refreshControl?.addTarget(
      self,
      action: #selector(Self.handleRefresh),
      for: UIControl.Event.valueChanged
    )

    containableAtIndexPathCallback = { indexPath in
      self.playlistAt(indexPath: indexPath)
    }
    playContextAtIndexPathCallback = { indexPath in
      guard let entity = self.playlistAt(indexPath: indexPath) else { return nil }
      return PlayContext(containable: entity)
    }
    swipeCallback = { indexPath, completionHandler in
      guard let playlist = self.playlistAt(indexPath: indexPath) else { return }
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
        completionHandler(SwipeActionContext(containable: playlist))
      }
    }
    snapshotDidChange = {
      self.updateContentUnavailable()
    }
  }

  func updateContentUnavailable() {
    if fetchedResultsController.fetchedObjects?.count ?? 0 == 0 {
      if fetchedResultsController.isSearchActive {
        contentUnavailableConfiguration = UIContentUnavailableConfiguration.search()
      } else {
        contentUnavailableConfiguration = emptyContentConfig
      }
    } else {
      contentUnavailableConfiguration = nil
    }
  }

  lazy var emptyContentConfig: UIContentUnavailableConfiguration = {
    var config = UIContentUnavailableConfiguration.empty()
    config.image = .playlist
    config.text = "No Playlists"
    config.secondaryText = "Your playlists will appear here."
    return config
  }()

  func change(sortType: PlaylistSortType) {
    self.sortType = sortType
    appDelegate.storage.settings.user.playlistsSortSetting = sortType
    singleFetchedResultsController?.clearResults()
    fetchedResultsController = PlaylistFetchedResultsController(
      coreDataCompanion: appDelegate.storage.main, account: account,
      sortType: sortType,
      isGroupedInAlphabeticSections: sortType.asSectionIndexType != .none
    )
    fetchedResultsController.fetchResultsController.sectionIndexType = sortType.asSectionIndexType
    singleFetchedResultsController = fetchedResultsController
    singleFetchedResultsController?.delegate = self
    singleFetchedResultsController?.fetch()
    tableView.reloadData()
    updateRightBarButtonItems()
    updateContentUnavailable()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = true
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    if appDelegate.storage.settings.user.isOfflineMode {
      isEditing = false
    }
    updateRightBarButtonItems()
    updateContentUnavailable()
    refreshLikedSongsCount()
    guard appDelegate.storage.settings.user.isOnlineMode else { return }
    Task { @MainActor in do {
      try await self.appDelegate.getMeta(self.account.info).librarySyncer
        .syncDownPlaylistsWithoutSongs()
    } catch {
      self.appDelegate.eventLogger.report(topic: "Playlists Sync", error: error)
    }}
  }

  func updateRightBarButtonItems() {
    var actions = [UIMenu]()
    actions.append(createSortButtonMenu())
    actions.append(createOptionsButtonMenu())
    optionsButton = UIBarButtonItem.createOptionsBarButton()
    optionsButton.menu = UIMenu(children: actions)
    var barButtons = [UIBarButtonItem]()
    barButtons.append(optionsButton)
    if appDelegate.storage.settings.user.isOnlineMode {
      barButtons.append(editButtonItem)
    }
    navigationItem.rightBarButtonItems = barButtons
  }

  func createCell(
    _ tableView: UITableView,
    forRowAt indexPath: IndexPath,
    playlist: Playlist
  )
    -> UITableViewCell {
    let cell: PlaylistTableCell = dequeueCell(for: tableView, at: indexPath)
    cell.display(playlist: playlist, rootView: self)
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    guard let playlist = playlistAt(indexPath: indexPath) else { return }
    navigationController?.pushViewController(
      AppStoryboard.Main.segueToPlaylistDetail(account: account, playlist: playlist),
      animated: true
    )
  }

  private func createSortButtonMenu() -> UIMenu {
    let sortByName = UIAction(
      title: "Name",
      image: sortType == .name ? .check : nil,
      handler: { _ in
        self.change(sortType: .name)
        self.updateSearchResults(for: self.searchController)
        self.appDelegate.notificationHandler.post(
          name: .fetchControllerSortChanged,
          object: nil,
          userInfo: nil
        )
      }
    )
    let sortByLastTimePlayed = UIAction(
      title: "Last time played",
      image: sortType == .lastPlayed ? .check : nil,
      handler: { _ in
        self.change(sortType: .lastPlayed)
        self.updateSearchResults(for: self.searchController)
        self.appDelegate.notificationHandler.post(
          name: .fetchControllerSortChanged,
          object: nil,
          userInfo: nil
        )
      }
    )
    let sortByChangeDate = UIAction(
      title: "Change date",
      image: sortType == .lastChanged ? .check : nil,
      handler: { _ in
        self.change(sortType: .lastChanged)
        self.updateSearchResults(for: self.searchController)
        self.appDelegate.notificationHandler.post(
          name: .fetchControllerSortChanged,
          object: nil,
          userInfo: nil
        )
      }
    )
    let sortByDuration = UIAction(
      title: "Duration",
      image: sortType == .duration ? .check : nil,
      handler: { _ in
        self.change(sortType: .duration)
        self.updateSearchResults(for: self.searchController)
        self.appDelegate.notificationHandler.post(
          name: .fetchControllerSortChanged,
          object: nil,
          userInfo: nil
        )
      }
    )
    return UIMenu(
      title: "Sort",
      image: .sort,
      options: [.displayInline],
      children: [sortByName, sortByLastTimePlayed, sortByChangeDate, sortByDuration]
    )
  }

  private func createOptionsButtonMenu() -> UIMenu {
    let fetchAllPlaylists = UIAction(title: "Sync All Playlists", image: .refresh, handler: { _ in
      Task { @MainActor in do {
        let accountObjectId = self.account.managedObject.objectID
        let playlistsIds = try await self.appDelegate.storage.async
          .performAndGet { asyncCompanion in
            let accoundAsync = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
            let playlists = asyncCompanion.library.getPlaylists(for: accoundAsync)
            return playlists.compactMap { $0.managedObject.objectID }
          }
        for moId in playlistsIds {
          let playlistMainMO = self.appDelegate.storage.main.context
            .object(with: moId) as! PlaylistMO
          let playlistMain = Playlist(
            library: self.appDelegate.storage.main.library,
            managedObject: playlistMainMO
          )
          try await playlistMain.fetch(
            storage: self.appDelegate.storage,
            librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
            playableDownloadManager: self.appDelegate.getMeta(self.account.info)
              .playableDownloadManager
          )
        }
        self.appDelegate.eventLogger.info(
          topic: "Sync All Playlists",
          message: "All playlists have been synced."
        )
      } catch {
        self.appDelegate.eventLogger.report(topic: "Sync All Playlists", error: error)
      }}
    })
    return UIMenu(
      title: "Options",
      image: .sort,
      options: [.displayInline],
      children: [fetchAllPlaylists]
    )
  }

  @objc
  func handleRefresh(refreshControl: UIRefreshControl) {
    Task { @MainActor in
      do {
        try await self.appDelegate.getMeta(self.account.info).librarySyncer
          .syncDownPlaylistsWithoutSongs()
      } catch {
        self.appDelegate.eventLogger.report(topic: "Playlists Sync", error: error)
      }
      self.refreshControl?.endRefreshing()
    }
  }

  override func updateSearchResults(for searchController: UISearchController) {
    let searchText = searchController.searchBar.text ?? ""
    let playlistSearchCategory = PlaylistSearchCategory(
      rawValue: searchController.searchBar
        .selectedScopeButtonIndex
    ) ?? PlaylistSearchCategory.defaultValue
    fetchedResultsController.search(
      searchText: searchText,
      playlistSearchCategory: playlistSearchCategory
    )
    tableView.reloadData()
    updateContentUnavailable()
  }

  // MARK: - Liked Songs header (cassette Patch 044)

  private func setupLikedSongsHeader() {
    let header = LikedSongsHeaderRowView()
    header.translatesAutoresizingMaskIntoConstraints = false
    header.onTap = { [weak self] in
      guard let self else { return }
      self.navigationController?.pushViewController(
        AppStoryboard.Main.segueToFavoriteSongs(account: self.account),
        animated: true
      )
    }
    likedSongsHeader = header

    // tableHeaderView needs an explicit frame width; sizing happens
    // via auto-layout inside `relayoutLikedSongsHeader`.
    let containerWidth = tableView.bounds.width > 0 ? tableView.bounds.width : view.bounds.width
    header.frame = CGRect(x: 0, y: 0, width: containerWidth, height: 64)
    tableView.tableHeaderView = header
    refreshLikedSongsCount()
  }

  private func refreshLikedSongsCount() {
    guard let header = likedSongsHeader else { return }
    let count = appDelegate.storage.main.library.getFavoriteSongs(for: account).count
    header.setCount(count)
    relayoutLikedSongsHeader()
  }

  private func relayoutLikedSongsHeader() {
    guard let header = likedSongsHeader else { return }
    let target = CGSize(width: tableView.bounds.width, height: UIView.layoutFittingCompressedSize.height)
    let size = header.systemLayoutSizeFitting(
      target,
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    )
    if header.frame.size.height != size.height || header.frame.size.width != tableView.bounds.width {
      header.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: size.height)
      tableView.tableHeaderView = header
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    relayoutLikedSongsHeader()
  }
}

// MARK: - LikedSongsHeaderRowView

/// cassette Patch 044: pinned row that surfaces the virtual "Liked
/// Songs" playlist at the top of PlaylistsVC. Visual rhythm matches
/// a PlaylistTableCell — a 44pt rounded artwork tile on the leading
/// edge with title + caption and a trailing chevron — so it reads
/// as part of the playlist list rather than a foreign banner.
private final class LikedSongsHeaderRowView: UIControl {
  private static let tileSize: CGFloat = 44
  private static let horizontalInset: CGFloat = 16
  private static let verticalInset: CGFloat = 10

  private let iconTile: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = CassetteTheme.UIColors.bg2
    view.layer.cornerRadius = 6
    view.layer.cornerCurve = .continuous
    return view
  }()

  private let iconImageView: UIImageView = {
    let iv = UIImageView()
    iv.translatesAutoresizingMaskIntoConstraints = false
    iv.image = UIImage(systemName: "heart.fill")
    // cassette Patch 049 (Phase D): Liked Songs heart drops to ink. Hearts
    // across the app (row favorites, popup player) all share ink as the
    // single "favorite" affordance; filled vs outline carries the state.
    iv.tintColor = CassetteTheme.UIColors.ink
    iv.contentMode = .scaleAspectFit
    return iv
  }()

  private let titleLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = UIFont.cassette(.rowTitle)
    label.textColor = CassetteTheme.UIColors.ink
    label.text = "Liked Songs"
    return label
  }()

  private let subtitleLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = UIFont.cassette(.caption)
    label.textColor = CassetteTheme.UIColors.ink2
    return label
  }()

  private let chevronImageView: UIImageView = {
    let iv = UIImageView()
    iv.translatesAutoresizingMaskIntoConstraints = false
    iv.image = UIImage(systemName: "chevron.right")
    iv.tintColor = CassetteTheme.UIColors.ink3
    iv.contentMode = .scaleAspectFit
    return iv
  }()

  private let separator: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = CassetteTheme.UIColors.ink4
    return view
  }()

  /// cassette Patch 044: PlaylistsVC sets this to push the
  /// favorites-filtered SongsVC.
  var onTap: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    backgroundColor = .backgroundColor
    accessibilityTraits = .button
    accessibilityLabel = "Liked Songs"
    addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)

    addSubview(iconTile)
    iconTile.addSubview(iconImageView)
    addSubview(titleLabel)
    addSubview(subtitleLabel)
    addSubview(chevronImageView)
    addSubview(separator)

    NSLayoutConstraint.activate([
      iconTile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
      iconTile.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconTile.widthAnchor.constraint(equalToConstant: Self.tileSize),
      iconTile.heightAnchor.constraint(equalToConstant: Self.tileSize),

      iconImageView.centerXAnchor.constraint(equalTo: iconTile.centerXAnchor),
      iconImageView.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),
      iconImageView.widthAnchor.constraint(equalToConstant: 22),
      iconImageView.heightAnchor.constraint(equalToConstant: 20),

      titleLabel.leadingAnchor.constraint(equalTo: iconTile.trailingAnchor, constant: 12),
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
      titleLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: chevronImageView.leadingAnchor,
        constant: -8
      ),

      subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
      subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
      subtitleLabel.bottomAnchor.constraint(
        equalTo: bottomAnchor,
        constant: -(Self.verticalInset + 1)
      ),

      chevronImageView.trailingAnchor.constraint(
        equalTo: trailingAnchor,
        constant: -Self.horizontalInset
      ),
      chevronImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
      chevronImageView.widthAnchor.constraint(equalToConstant: 10),
      chevronImageView.heightAnchor.constraint(equalToConstant: 14),

      separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
      separator.trailingAnchor.constraint(equalTo: trailingAnchor),
      separator.bottomAnchor.constraint(equalTo: bottomAnchor),
      // Half-point hairline; matches the visual weight of UITableView's
      // built-in separators without pulling on UIScreen.main (deprecated
      // in iOS 26).
      separator.heightAnchor.constraint(equalToConstant: 0.5),
    ])
  }

  func setCount(_ count: Int) {
    let suffix = count == 1 ? "song" : "songs"
    subtitleLabel.text = "\(count) \(suffix)"
    accessibilityValue = subtitleLabel.text
  }

  // Visual feedback on touch so the row reads as tappable, matching
  // UITableViewCell's selection style without inheriting it.
  override var isHighlighted: Bool {
    didSet {
      backgroundColor = isHighlighted
        ? CassetteTheme.UIColors.bg2
        : .backgroundColor
    }
  }
}
