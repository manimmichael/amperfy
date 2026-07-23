//
//  AlbumsCommonVCInteractions.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 20.06.24.
//  Copyright (c) 2024 Maximilian Bauer. All rights reserved.
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

// MARK: - SliderMenuPopover

class SliderMenuPopover: UIViewController, UIPopoverPresentationControllerDelegate {
  var sliderMenuView: SliderMenuView {
    view as! SliderMenuView
  }

  override func loadView() {
    view = SliderMenuView()
  }

  func adaptivePresentationStyle(
    for controller: UIPresentationController,
    traitCollection: UITraitCollection
  )
    -> UIModalPresentationStyle {
    .none
  }
}

// MARK: - SliderMenuView

class SliderMenuView: UIView {
  let slider: UISlider = {
    let slider = UISlider()
    slider.translatesAutoresizingMaskIntoConstraints = false
    return slider
  }()

  var stepValue: Float = 1.0
  var sliderValueChangedCB: VoidFunctionCallback?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupView()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupView()
  }

  private func setupView() {
    addSubview(slider)
    slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10).isActive = true
    slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10).isActive = true
    #if targetEnvironment(macCatalyst)
      slider.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
    #else
      slider.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -6).isActive = true
    #endif
    slider.addTarget(self, action: #selector(sliderValueChanged(_:)), for: .valueChanged)
  }

  @objc
  private func sliderValueChanged(_ sender: UISlider) {
    let newStep = roundf(slider.value / stepValue)
    slider.value = newStep * stepValue
    sliderValueChangedCB?()
  }
}

// MARK: - CassetteAlbumGrouping

/// cassette: adaptive album-grid grouping. Small owned collections read better
/// as a flat grid (no A/B/C section headers, no alpha scrubber index); large
/// ones keep the sectioned + indexed layout. `auto` decides by album count
/// against `CassetteAlbumGroupingProvider.threshold`; `flat` / `sectioned` are
/// manual overrides surfaced in the Sort/Style menu. Persisted in raw
/// UserDefaults (kept out of the Codable Settings blob to avoid migration
/// churn) — mirrors how CassetteLibraryFilterProvider stores its flag.
enum CassetteAlbumGrouping: String, CaseIterable {
  case auto
  case flat
  case sectioned
}

// MARK: - CassetteAlbumGroupingProvider

enum CassetteAlbumGroupingProvider {
  /// Below this owned-album count, `auto` flattens the grid. Tunable.
  static let threshold = 60

  private static let key = "cassetteAlbumGroupingOverride"

  static var current: CassetteAlbumGrouping {
    get {
      guard let raw = UserDefaults.standard.string(forKey: key),
            let value = CassetteAlbumGrouping(rawValue: raw) else { return .auto }
      return value
    }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
  }
}

// MARK: - AlbumsCommonVCInteractions

@MainActor
class AlbumsCommonVCInteractions {
  var sceneTitle: String? {
    switch displayFilter {
    case .all: "Albums"
    case .newest: "Newest Albums"
    case .recent: "Recently Played Albums"
    case .favorites: "Favorite Albums"
    }
  }

  public var isIndexTitelsHiddenCB: VoidFunctionCallback?
  public var reloadListViewCB: VoidFunctionCallback?
  public var updateSearchResultsCB: VoidFunctionCallback?
  public var endRefreshCB: VoidFunctionCallback?
  public var updateFetchDataSourceCB: VoidFunctionCallback?

  private var appDelegate: AppDelegate = (UIApplication.shared.delegate as! AppDelegate)
  private var isSetNavbarButton = true

  public var rootVC: UIViewController?
  public var fetchedResultsController: AlbumFetchedResultsController!
  public var optionsButton: UIBarButtonItem = .createOptionsBarButton()
  public var displayFilter: DisplayCategoryFilter = .all
  public var sortType: AlbumElementSortType = .name
  public var filterTitle = "Albums"
  public var newestElementsOffsetsSynced = Set<Int>()
  public var isIndexTitelsHidden = false {
    didSet {
      isIndexTitelsHiddenCB?()
    }
  }

  /// cassette: whether the current fetch is grouped into alphabetic sections.
  /// Drives the collection grid's section-header suppression so a flattened
  /// small collection shows no letter headers (the FRC is a single section and
  /// would otherwise render the first album's letter as a lone header).
  public private(set) var isGroupedInAlphabeticSections = false

  private let account: Account

  init(account: Account, isSetNavbarButton: Bool = true) {
    self.account = account
    self.isSetNavbarButton = isSetNavbarButton
  }

  public var isContentUnavailable: Bool {
    fetchedResultsController.fetchedObjects?.count ?? 0 == 0
  }

  func updateContentUnavailable() {
    if isContentUnavailable {
      if fetchedResultsController.isSearchActive {
        rootVC?.contentUnavailableConfiguration = CassetteLibraryFilterProvider.shared
          .isOnDeviceOnly ? cassetteOnDeviceSearchEmptyConfig : UIContentUnavailableConfiguration
          .search()
      } else {
        rootVC?.contentUnavailableConfiguration = CassetteLibraryFilterProvider.shared
          .isOnDeviceOnly ? cassetteOnDeviceEmptyConfig : emptyContentConfig
      }
    } else {
      rootVC?.contentUnavailableConfiguration = nil
    }
  }

  // cassette Layer 3 Phase 3.2: on-device-only empty states.
  lazy var cassetteOnDeviceEmptyConfig: UIContentUnavailableConfiguration = {
    var config = UIContentUnavailableConfiguration.empty()
    config.image = .album
    config.text = "No music on this phone yet"
    config.secondaryText = "Send albums from cassette.digital, or turn on Server Mode in Settings."
    return config
  }()

  lazy var cassetteOnDeviceSearchEmptyConfig: UIContentUnavailableConfiguration = {
    var config = UIContentUnavailableConfiguration.search()
    config
      .secondaryText =
      "No results on this phone. Enable Server Mode in Settings to search your full catalog."
    return config
  }()

  lazy var emptyContentConfig: UIContentUnavailableConfiguration = {
    var config = UIContentUnavailableConfiguration.empty()
    config.image = .album
    config.text = "No " + filterTitle
    config.secondaryText = "Your " + filterTitle.lowercased() + " will appear here."
    return config
  }()

  func applyFilter() {
    switch displayFilter {
    case .all:
      filterTitle = "Albums"
      isIndexTitelsHidden = false
      change(sortType: appDelegate.storage.settings.user.albumsSortSetting)
    case .newest:
      filterTitle = "Newest Albums"
      isIndexTitelsHidden = true
      change(sortType: .newest)
    case .recent:
      filterTitle = "Recently Played Albums"
      isIndexTitelsHidden = true
      change(sortType: .recent)
    case .favorites:
      filterTitle = "Favorite Albums"
      isIndexTitelsHidden = false
      change(sortType: appDelegate.storage.settings.user.albumsSortSetting)
    }
    rootVC?.setNavBarTitle(title: filterTitle)
  }

  /// Albums currently in scope: the owned set in the default on-device mode,
  /// the full available catalog in Server Mode. Used to decide adaptive
  /// grouping. A cheap COUNT / id-set fetch — not the full object graph.
  private var inScopeAlbumCount: Int {
    if CassetteLibraryFilterProvider.shared.isOnDeviceOnly {
      return DeviceOwnershipManager(context: appDelegate.storage.main.context)
        .fetchOwnedAlbumIds().count
    }
    return appDelegate.storage.main.library.getAlbumCount(for: account)
  }

  /// cassette: resolve the adaptive-grouping decision. `baseEligible` is whether
  /// the sort type even supports alphabetic sections (newest/recent never do).
  /// Newest/Recent stay flat regardless. Otherwise the manual override wins;
  /// `auto` groups only once the in-scope album count reaches the threshold.
  private func shouldGroupInAlphabeticSections(baseEligible: Bool) -> Bool {
    guard baseEligible else { return false }
    switch CassetteAlbumGroupingProvider.current {
    case .flat:
      return false
    case .sectioned:
      return true
    case .auto:
      return inScopeAlbumCount >= CassetteAlbumGroupingProvider.threshold
    }
  }

  func change(sortType: AlbumElementSortType) {
    self.sortType = sortType
    fetchedResultsController?.clearResults()
    var baseEligible = false
    switch sortType {
    case .artist, .duration, .name, .rating, .year:
      baseEligible = true
    case .newest, .recent:
      baseEligible = false
    }
    // cassette: adaptive grouping — flatten small collections (no section
    // headers, no alpha index). For .all / .favorites filters applyFilter()
    // seeds isIndexTitelsHidden=false; here we refine it to match the actual
    // grouping decision so the scrubber index disappears when flat.
    let isGroupedInAlphabeticSections =
      shouldGroupInAlphabeticSections(baseEligible: baseEligible)
    self.isGroupedInAlphabeticSections = isGroupedInAlphabeticSections
    if baseEligible {
      isIndexTitelsHidden = !isGroupedInAlphabeticSections
    }

    fetchedResultsController = AlbumFetchedResultsController(
      coreDataCompanion: appDelegate.storage.main, account: account,
      sortType: sortType,
      isGroupedInAlphabeticSections: isGroupedInAlphabeticSections
    )
    fetchedResultsController.fetchResultsController.sectionIndexType = sortType.asSectionIndexType
    updateFetchDataSourceCB?()
    fetchedResultsController.fetch()
    updateRightBarButtonItems()
    updateContentUnavailable()
  }

  func listViewWillDisplayCell(at indexPath: IndexPath, searchBarText: String?) {
    guard let elementCount = fetchedResultsController.fetchResultsController.fetchedObjects?.count
    else { return }
    if sortType == .newest || sortType == .recent,
       (searchBarText ?? "").isEmpty,
       indexPath.row > 0,
       // fetch each 20th row or on last element
       indexPath.row == elementCount - 1 || (indexPath.row % 20 == 0),
       // this offset has not been synced yet
       !newestElementsOffsetsSynced.contains(indexPath.row) {
      newestElementsOffsetsSynced.insert(indexPath.row)
      updateFromRemote(offset: indexPath.row, count: AmperKit.newestElementsFetchCount)
    }
  }

  func updateFromRemote(offset: Int = 0, count: Int = AmperKit.newestElementsFetchCount) {
    guard appDelegate.storage.settings.user.isOnlineMode else { return }
    switch displayFilter {
    case .all:
      break
    case .newest:
      Task { @MainActor in
        do {
          try await AutoDownloadLibrarySyncer(
            storage: self.appDelegate.storage,
            account: account,
            librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
            playableDownloadManager: self.appDelegate.getMeta(self.account.info)
              .playableDownloadManager
          )
          .syncNewestLibraryElements(offset: offset, count: count)
        } catch {
          // cassette Patch 040: tab-appear / pagination background sync.
          self.appDelegate.eventLogger.report(
            topic: "Newest Albums Sync",
            error: error,
            isBackground: true
          )
        }
        self.updateSearchResultsCB?()
      }
    case .recent:
      Task { @MainActor in
        do {
          try await self.appDelegate.getMeta(self.account.info).librarySyncer
            .syncRecentAlbums(
              offset: offset,
              count: count
            )
        } catch {
          self.appDelegate.eventLogger.report(
            topic: "Recent Albums Sync",
            error: error,
            isBackground: true
          )
        }
        self.updateSearchResultsCB?()
      }
    case .favorites:
      Task { @MainActor in
        do {
          try await self.appDelegate.getMeta(self.account.info).librarySyncer
            .syncFavoriteLibraryElements()
        } catch {
          self.appDelegate.eventLogger.report(
            topic: "Favorite Albums Sync",
            error: error,
            isBackground: true
          )
        }
        self.updateSearchResultsCB?()
      }
    }
  }

  func updateRightBarButtonItems() {
    guard isSetNavbarButton else { return }
    var actions = [UIMenu]()

    switch sortType {
    case .artist, .duration, .name, .rating, .year:
      actions.append(createSortButtonMenu())
    case .newest, .recent:
      break
    }
    actions.append(createStyleButtonMenu())

    // cassette: "Download <filter>" is gated to Server Mode (the Navidrome
    // streaming experience). In the default on-device-only mode everything in
    // the library is already on the phone, so bulk-download is a no-op — hide
    // it. It returns in Server Mode (still also requiring online mode, since it
    // hits the download manager).
    if !CassetteLibraryFilterProvider.shared.isOnDeviceOnly,
       appDelegate.storage.settings.user.isOnlineMode {
      actions.append(createActionButtonMenu())
    }

    if !actions.isEmpty {
      optionsButton = UIBarButtonItem.createOptionsBarButton()
      optionsButton.menu = UIMenu(children: actions)
      rootVC?.navigationItem.rightBarButtonItems = [optionsButton]
    } else {
      rootVC?.navigationItem.rightBarButtonItems = []
    }
  }

  private func createSortButtonMenu() -> UIMenu {
    let sortByName = UIAction(
      title: "Name",
      image: sortType == .name ? .check : nil,
      handler: { _ in
        self.change(sortType: .name)
        self.appDelegate.storage.settings.user.albumsSortSetting = .name
        self.updateSearchResultsCB?()
        self.appDelegate.notificationHandler.post(
          name: .fetchControllerSortChanged,
          object: nil,
          userInfo: nil
        )
      }
    )
    let sortByRating = UIAction(
      title: "Rating",
      image: sortType == .rating ? .check : nil,
      handler: { _ in
        self.change(sortType: .rating)
        self.appDelegate.storage.settings.user.albumsSortSetting = .rating
        self.updateSearchResultsCB?()
        self.appDelegate.notificationHandler.post(
          name: .fetchControllerSortChanged,
          object: nil,
          userInfo: nil
        )
      }
    )
    let sortByArtist = UIAction(
      title: "Artist",
      image: sortType == .artist ? .check : nil,
      handler: { _ in
        self.change(sortType: .artist)
        self.appDelegate.storage.settings.user.albumsSortSetting = .artist
        self.updateSearchResultsCB?()
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
        self.appDelegate.storage.settings.user.albumsSortSetting = .duration
        self.updateSearchResultsCB?()
        self.appDelegate.notificationHandler.post(
          name: .fetchControllerSortChanged,
          object: nil,
          userInfo: nil
        )
      }
    )
    let sortByYear = UIAction(
      title: "Year",
      image: sortType == .year ? .check : nil,
      handler: { _ in
        self.change(sortType: .year)
        self.appDelegate.storage.settings.user.albumsSortSetting = .year
        self.updateSearchResultsCB?()
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
      options: [],
      children: [sortByName, sortByRating, sortByArtist, sortByDuration, sortByYear]
    )
  }

  func showSliderMenu() {
    guard let rootVC = rootVC else { return }

    let popoverContentController = SliderMenuPopover()
    let sliderMenuView = popoverContentController.sliderMenuView
    sliderMenuView.frame = CGRect(x: 0, y: 0, width: 250, height: 50)

    if UIDevice.current.userInterfaceIdiom == .mac {
      sliderMenuView.slider.minimumValue = 3
      sliderMenuView.slider.maximumValue = 11
    } else if UIDevice.current.userInterfaceIdiom == .pad {
      sliderMenuView.slider.minimumValue = 3
      sliderMenuView.slider.maximumValue = 7
    } else {
      sliderMenuView.slider.minimumValue = 2
      sliderMenuView.slider.maximumValue = 5
    }
    sliderMenuView.slider.value = min(
      max(
        sliderMenuView.slider.minimumValue,
        Float(appDelegate.storage.settings.user.albumsGridSizeSetting)
      ),
      sliderMenuView.slider.maximumValue
    )
    sliderMenuView.sliderValueChangedCB = {
      let newIntValue = Int(sliderMenuView.slider.value)
      if newIntValue != self.appDelegate.storage.settings.user.albumsGridSizeSetting {
        self.appDelegate.storage.settings.user.albumsGridSizeSetting = newIntValue
        if let collectionVC = rootVC as? AlbumsCollectionVC {
          collectionVC.collectionView.reloadData()
        }
      }
    }

    popoverContentController.modalPresentationStyle = .popover
    popoverContentController.preferredContentSize = sliderMenuView.frame.size

    if let popoverPresentationController = popoverContentController.popoverPresentationController {
      popoverPresentationController.permittedArrowDirections = .up
      popoverPresentationController.delegate = popoverContentController
      popoverPresentationController.barButtonItem = optionsButton
      rootVC.present(popoverContentController, animated: true, completion: nil)
    }
  }

  private func createStyleButtonMenu() -> UIMenu {
    let tableStyle = UIAction(
      title: "Table",
      image: appDelegate.storage.settings.user.albumsStyleSetting == .table ? .check : nil,
      handler: { _ in
        self.appDelegate.storage.settings.user.albumsStyleSetting = .table
        self.applyAlbumsStyleChange()
      }
    )
    let gridStyle = UIAction(
      title: "Grid",
      image: appDelegate.storage.settings.user.albumsStyleSetting == .grid ? .check : nil,
      handler: { _ in
        self.appDelegate.storage.settings.user.albumsStyleSetting = .grid
        self.applyAlbumsStyleChange()
      }
    )
    let changeGridSize = UIAction(title: "Change Grid Size", image: .resize, handler: { _ in
      self.showSliderMenu()
    })
    changeGridSize
      .attributes = (appDelegate.storage.settings.user.albumsStyleSetting != .grid) ? .disabled : []

    return UIMenu(
      title: "Style",
      image: .grid,
      options: [],
      children: [tableStyle, gridStyle, changeGridSize, createGroupingMenu()]
    )
  }

  /// cassette: apply a grid ⇄ list style change. In the Library tab the album
  /// VC is an embedded child of `LibraryContainerVC`, which owns the nav bar
  /// (dropdown title + right-bar controls), so we ask the container to swap
  /// the child in place — the header survives. The old path called
  /// `replaceCurrentlyActiveVC` on the shared nav stack, which dropped the
  /// container and left a bare album VC with no header ("the header randomly
  /// stops rendering when I change the view type"). When the album VC was
  /// pushed standalone (e.g. Newest/Recent deep links, where it *is* the top
  /// of the stack), fall back to the nav-stack replace.
  private func applyAlbumsStyleChange() {
    guard let rootVC else { return }
    let newVC = AppStoryboard.Main.createAlbumsVC(
      account: account,
      style: appDelegate.storage.settings.user.albumsStyleSetting,
      category: displayFilter
    )
    if let container = rootVC.parent as? LibraryContainerVC {
      container.replaceEmbeddedChild(with: newVC)
    } else {
      rootVC.navigationController?.replaceCurrentlyActiveVC(with: newVC, animated: false)
    }
  }

  /// cassette: adaptive-grouping override, surfaced inline in the Style menu.
  /// Auto = decide by album count (flat below the threshold); Grouped /
  /// Ungrouped force the layout regardless of count. Changing it rebuilds the
  /// fetch for the current sort and reloads the list.
  private func createGroupingMenu() -> UIMenu {
    let current = CassetteAlbumGroupingProvider.current
    func makeAction(_ title: String, _ value: CassetteAlbumGrouping) -> UIAction {
      UIAction(
        title: title,
        image: current == value ? .check : nil,
        handler: { _ in
          CassetteAlbumGroupingProvider.current = value
          // Rebuild the FRC for the active sort with the new grouping decision,
          // then reload the grid + refresh the menu check state.
          self.change(sortType: self.sortType)
          self.reloadListViewCB?()
        }
      )
    }
    return UIMenu(
      title: "Grouping",
      image: UIImage(systemName: "textformat.abc.dottedunderline"),
      options: [.displayInline],
      children: [
        makeAction("Auto", .auto),
        makeAction("Grouped", .sectioned),
        makeAction("Ungrouped", .flat),
      ]
    )
  }

  private func createActionButtonMenu() -> UIMenu {
    let action = UIAction(
      title: "Download \(filterTitle)",
      image: UIImage.startDownload,
      handler: { _ in
        var albums = [Album]()
        switch self.displayFilter {
        case .all:
          albums = self.appDelegate.storage.main.library.getAlbums(for: self.account)
        case .newest:
          albums = self.appDelegate.storage.main.library
            .getNewestAlbums(for: self.account)
        case .recent:
          albums = self.appDelegate.storage.main.library
            .getRecentAlbums(for: self.account)
        case .favorites:
          albums = self.appDelegate.storage.main.library
            .getFavoriteAlbums(for: self.account)
        }
        let albumSongs = Array(albums.compactMap { $0.playables }.joined())
        if albumSongs.count > AppDelegate.maxPlayablesDownloadsToAddAtOnceWithoutWarning {
          let alert = UIAlertController(
            title: "Many Songs",
            message: "Are you sure to add \(albumSongs.count) songs from \"\(self.filterTitle)\" to download queue?",
            preferredStyle: .alert
          )
          alert.addAction(UIAlertAction(title: "OK", style: .default, handler: { _ in
            self.appDelegate.getMeta(self.account.info).playableDownloadManager
              .download(objects: albumSongs)
          }))
          alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
          self.rootVC?.present(alert, animated: true, completion: nil)
        } else {
          self.appDelegate.getMeta(self.account.info).playableDownloadManager
            .download(objects: albumSongs)
        }
      }
    )
    return UIMenu(options: [.displayInline], children: [action])
  }

  private var displayedSongs: [AbstractPlayable] {
    guard let displayedAlbumsMO = fetchedResultsController.fetchedObjects else { return [] }
    let displayedAlbums = displayedAlbumsMO.compactMap { Album(managedObject: $0) }
    var songs = [AbstractPlayable]()
    displayedAlbums.forEach { songs.append(contentsOf: $0.playables) }
    return songs
  }

  public func handleHeaderPlay() -> PlayContext {
    guard let displayedAlbumsMO = fetchedResultsController.fetchedObjects else { return PlayContext(
      name: filterTitle,
      playables: []
    ) }
    let firstAlbums = displayedAlbumsMO.prefix(5).compactMap { Album(managedObject: $0) }
    var songs = [AbstractPlayable]()
    firstAlbums.forEach { songs.append(contentsOf: $0.playables) }
    return PlayContext(
      name: filterTitle,
      playables: Array(songs.prefix(appDelegate.player.maxSongsToAddOnce))
    )
  }

  public func handleHeaderShuffle() -> PlayContext {
    guard let displayedAlbumsMO = fetchedResultsController.fetchedObjects else { return PlayContext(
      name: filterTitle,
      playables: []
    ) }
    let randomAlbums = displayedAlbumsMO[randomPick: 5].compactMap { Album(managedObject: $0) }
    var songs = [AbstractPlayable]()
    randomAlbums.forEach { songs.append(contentsOf: $0.playables) }
    return PlayContext(
      name: filterTitle,
      playables: Array(songs.prefix(appDelegate.player.maxSongsToAddOnce))
    )
  }

  func updateSearchResults(for searchController: UISearchController) {
    let searchText = searchController.searchBar.text ?? ""
    if !searchText.isEmpty, searchController.searchBar.selectedScopeButtonIndex == 0,
       CassetteLibraryFilterProvider.shared.currentFilter == .everything {
      // Cassette fork — Layer 3 Phase 3.2 (library filtering). Remote Subsonic
      // search only runs in Server Mode; on-device-only searches the
      // ownership-filtered local FRC alone.
      Task { @MainActor in do {
        try await self.appDelegate.getMeta(self.account.info).librarySyncer
          .searchAlbums(searchText: searchText)
      } catch {
        self.appDelegate.eventLogger.report(topic: "Albums Search", error: error)
      }}
    }
    fetchedResultsController.search(
      searchText: searchText,
      onlyCached: searchController.searchBar.selectedScopeButtonIndex == 1,
      displayFilter: displayFilter
    )
    updateContentUnavailable()
  }

  func createPlayShuffleInfoConfig() -> PlayShuffleInfoConfiguration {
    PlayShuffleInfoConfiguration(
      infoCB: {
        "\(self.fetchedResultsController.fetchedObjects?.count ?? 0) Album\((self.fetchedResultsController.fetchedObjects?.count ?? 0) == 1 ? "" : "s")"
      },
      playContextCb: handleHeaderPlay,
      player: appDelegate.player,
      isInfoAlwaysHidden: false,
      isShuffleOnContextNeccessary: false,
      shuffleContextCb: handleHeaderShuffle
    )
  }

  @objc
  func handleRefresh(refreshControl: UIRefreshControl) {
    guard appDelegate.storage.settings.user.isOnlineMode else {
      endRefreshCB?()
      return
    }
    Task { @MainActor in
      do {
        if self.displayFilter == .recent {
          try await self.appDelegate.getMeta(self.account.info).librarySyncer
            .syncRecentAlbums(
              offset: 0,
              count: AmperKit.newestElementsFetchCount
            )
        } else {
          try await AutoDownloadLibrarySyncer(
            storage: self.appDelegate.storage,
            account: account,
            librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
            playableDownloadManager: self.appDelegate.getMeta(self.account.info)
              .playableDownloadManager
          )
          .syncNewestLibraryElements()
        }
      } catch {
        self.appDelegate.eventLogger.report(
          topic: "Albums Newest Elements Sync",
          error: error,
          isBackground: true
        )
      }
      // Cassette: also run the sync/cover drain so a pull-to-refresh re-checks owned
      // album covers. The stock syncer above only fetches newest library ELEMENTS;
      // changed cover art is reconciled by handlePendingIntents (backfillOwnedAlbumCovers,
      // content_version-gated), which otherwise runs only on app foreground. Bare
      // (non-throwing) with its own single-flight guard — safe to call here.
      await IntentExecutor.shared.handlePendingIntents()
      self.endRefreshCB?()
    }
  }
}
