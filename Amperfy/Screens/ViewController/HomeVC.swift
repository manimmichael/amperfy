//
//  HomeVC.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 24.11.25.
//  Copyright (c) 2025 Maximilian Bauer. All rights reserved.
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
import OSLog
import UIKit

// MARK: - HomeVC

final class HomeVC: UICollectionViewController {
  // MARK: - Properties

  private var dataSource: UICollectionViewDiffableDataSource<HomeSection, HomeItem>!
  private let log = OSLog(subsystem: "Amperfy", category: "HomeVC")

  private static let itemWidth: CGFloat = 160.0
  private static let shelfEstimatedHeight: CGFloat = 210.0

  private var userButton: UIButton?
  private var userBarButtonItem: UIBarButtonItem?
  private let account: Account
  private var accountNotificationHandler: AccountNotificationHandler?
  private let sharedHome: HomeManager

  // MARK: - Init

  init(account: Account) {
    self.account = account
    let appDelegate = (UIApplication.shared.delegate as! AppDelegate)
    self.sharedHome = HomeManager(
      account: account,
      storage: appDelegate.storage,
      getMeta: appDelegate.getMeta,
      eventLogger: appDelegate.eventLogger,
      player: appDelegate.player,
      // cassette (Forgotten Albums): iOS Home builds the anti-recency shelf.
      buildsForgottenShelf: true
    )
    let layout = HomeVC.createLayout()
    super.init(collectionViewLayout: layout)
    sharedHome.applySnapshotCB = { [weak self] in
      guard let self else { return }
      applySnapshot(animated: true)
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    // ensures that the collection view stops placing items under the sidebar
    collectionView.contentInsetAdjustmentBehavior = .scrollableAxes

    // Pull-to-refresh on Home. This is what lets the passive poll back off to a long
    // idle interval without ever feeling stale: the gesture is the responsive path,
    // so the timer does not have to be.
    #if !targetEnvironment(macCatalyst)
      let refresh = UIRefreshControl()
      refresh.addTarget(self, action: #selector(handleCassetteRefresh(_:)), for: .valueChanged)
      collectionView.refreshControl = refresh
    #endif
    collectionView.backgroundColor = CassetteTheme.UIColors.bg
    title = "Home"

    accountNotificationHandler = AccountNotificationHandler(
      storage: appDelegate.storage,
      notificationHandler: appDelegate.notificationHandler
    )
    accountNotificationHandler?.registerCallbackForActiveAccountChange { [weak self] accountInfo in
      guard let self else { return }
      setupUserNavButton(
        currentAccount: account,
        userButton: &userButton,
        userBarButtonItem: &userBarButtonItem,
        extraLeadingMenuElements: makeHomeMenuExtras()
      )
    }

    configureHomeNavigationBar()
    // cassette Patch 035: the top-right Edit button is removed; the
    // "Edit Home" action lives in the account-button menu now (see
    // `setupUserNavButton` call above), and only the three Cassette
    // shelves remain visible/editable.
    configureCollectionView()
    configureDataSource()
    // cassette redesign (Surface 4): swap in the snapshot-aware layout so
    // the Resume section gets its full-width card geometry. Replaces the
    // raw-value section lookup (which broke once hidden-when-empty shelves
    // shifted the section indices).
    collectionView.setCollectionViewLayout(makeLayout(), animated: false)
    sharedHome.createFetchController()
    applySnapshot(animated: false)

    appDelegate.notificationHandler.register(
      self,
      selector: #selector(refreshOfflineMode),
      name: .offlineModeChanged,
      object: nil
    )

    // cassette Layer 3 Phase 3.2: rebuild the Home shelves when Server Mode
    // toggles. The shelves reuse the library FRCs, so recreating their fetch
    // controllers picks up the new ownership predicate.
    appDelegate.notificationHandler.register(
      self,
      selector: #selector(cassetteLibraryFilterChanged),
      name: CassetteLibraryFilterProvider.filterChangedNotification,
      object: nil
    )
  }

  // cassette (manual eager tab-bar reveal): drive minimize/expand from scroll
  // direction (see TabBarVC.cassetteUpdateMinimizeForScroll).
  override func scrollViewDidScroll(_ scrollView: UIScrollView) {
    (tabBarController as? TabBarVC)?.cassetteUpdateMinimizeForScroll(scrollView)
  }

  @objc
  private func cassetteLibraryFilterChanged() {
    sharedHome.createFetchController()
    applySnapshot(animated: false)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    configureHomeNavigationBar()
  }

  private func configureHomeNavigationBar() {
    title = "Home"
    // cassette: Home wears its name inline, the way Library wears "Albums".
    // The large title used to eat a full title-height band at the top and
    // then animate away on the first scroll — two different-looking Homes for
    // the same screen. Inline at `.sectionTitle` (the exact token the Library
    // dropdown uses) means the header never changes and the first shelf sits
    // that much higher.
    navigationItem.largeTitleDisplayMode = .never
    navigationController?.navigationBar.prefersLargeTitles = false
    let appearance = UINavigationBarAppearance()
    appearance.configureWithDefaultBackground()
    appearance.titleTextAttributes = [
      .font: UIFont.cassette(.sectionTitle),
      .foregroundColor: CassetteTheme.UIColors.ink,
    ]
    navigationItem.standardAppearance = appearance
    navigationItem.scrollEdgeAppearance = appearance
    if #available(iOS 15.0, *) {
      navigationItem.compactAppearance = appearance
    }
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    sharedHome.updateFromRemote()
    // cassette (Forgotten Albums): opportunistic roll-off of aged hot-log rows
    // into the durable cold counters, then stamp the shelf's current impressions
    // now that Home is on screen.
    appDelegate.storage.main.library.rollOffAgedHomeShelfEvents(for: account)
    recordForgottenShelfImpressionIfVisible()
  }

  /// cassette (Forgotten Albums): stamp `lastSurfacedOnHomeDate` + write a hot-log
  /// "surfaced" row for the albums currently on the shelf. Only when actually on
  /// screen; the storage layer is per-day idempotent, so this is safe to call on
  /// every appearance / snapshot.
  private func recordForgottenShelfImpressionIfVisible() {
    guard viewIfLoaded?.window != nil else { return }
    let ids = (sharedHome.data[.forgottenAlbums] ?? [])
      .compactMap { ($0.playableContainable as? Album)?.id }
    guard !ids.isEmpty else { return }
    appDelegate.storage.main.library.recordForgottenAlbumsSurfaced(albumIds: ids, for: account)
  }

  // MARK: - Layout

  /// Placeholder used between init and viewDidLoad (before the diffable
  /// data source exists). Resolves sections by raw value, which is good
  /// enough for the empty first pass; `makeLayout()` replaces it.
  private static func createLayout() -> UICollectionViewCompositionalLayout {
    UICollectionViewCompositionalLayout { sectionIndex, _ in
      Self.sectionLayout(for: HomeSection(rawValue: sectionIndex))
    }
  }

  /// cassette redesign (Surface 4): snapshot-aware layout. Resolves the
  /// section enum from the data source (hidden-when-empty shelves shift
  /// indices) so the Resume section can take a full-width card row while
  /// the shelves keep the 160pt orthogonal carousel rhythm.
  private func makeLayout() -> UICollectionViewCompositionalLayout {
    UICollectionViewCompositionalLayout { [weak self] sectionIndex, _ in
      let section = self?.dataSource.snapshot().sectionIdentifiers.element(at: sectionIndex)
      return Self.sectionLayout(for: section)
    }
  }

  private static func sectionLayout(for section: HomeSection?) -> NSCollectionLayoutSection? {
    guard let section else { return nil }

    // cassette Patch 025 / Polish 2 (A2): top inset is 0 (the SectionHeaderView
    // owns the vertical rhythm) and supplementariesFollowContentInsets is false
    // so the header's own 16pt leading lines up with the first card column.
    let contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 24, trailing: 16)

    // Patch 110 (3b): album/artist shelves use the shared carousel layout —
    // the same component the artist detail embeds (one carousel, two callers).
    guard section == .resume else {
      return AlbumCarousel.makeShelfSection(
        itemWidth: itemWidth,
        estimatedHeight: shelfEstimatedHeight,
        contentInsets: contentInsets,
        includeHeader: true
      )
    }

    // Resume: a single full-width glass card (no orthogonal scrolling).
    let itemSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .fractionalHeight(1.0)
    )
    let item = NSCollectionLayoutItem(layoutSize: itemSize)
    let groupSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .absolute(ResumeCardCell.cardHeight)
    )
    let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])

    let sectionLayout = NSCollectionLayoutSection(group: group)
    sectionLayout.contentInsets = contentInsets
    sectionLayout.supplementariesFollowContentInsets = false

    let headerSize = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1.0),
      heightDimension: .estimated(44)
    )
    let header = NSCollectionLayoutBoundarySupplementaryItem(
      layoutSize: headerSize,
      elementKind: UICollectionView.elementKindSectionHeader,
      alignment: .top
    )
    header.pinToVisibleBounds = false
    header.zIndex = 1
    sectionLayout.boundarySupplementaryItems = [header]

    return sectionLayout
  }

  // MARK: - CollectionView Setup

  private func configureCollectionView() {
    collectionView.backgroundColor = CassetteTheme.UIColors.bg
    collectionView.register(
      UINib(nibName: AlbumCollectionCell.typeName, bundle: .main),
      forCellWithReuseIdentifier: AlbumCollectionCell.typeName
    )
    // cassette Patch 038: ArtistCircleCollectionCell is purely
    // programmatic — register the class directly instead of a XIB.
    collectionView.register(
      ArtistCircleCollectionCell.self,
      forCellWithReuseIdentifier: ArtistCircleCollectionCell.typeName
    )
    // cassette redesign (Surface 4): full-width Resume glass card.
    collectionView.register(
      ResumeCardCell.self,
      forCellWithReuseIdentifier: ResumeCardCell.typeName
    )
    collectionView.register(
      SectionHeaderView.self,
      forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
      withReuseIdentifier: SectionHeaderView.reuseID
    )
  }

  // MARK: - Data Source

  private func configureDataSource() {
    dataSource = UICollectionViewDiffableDataSource<
      HomeSection,
      HomeItem
    >(collectionView: collectionView) { [unowned self] collectionView, indexPath, item in
      let section = dataSource.snapshot().sectionIdentifiers.element(at: indexPath.section)
      // cassette redesign (Surface 4): the Resume card is the screen's one
      // dedicated play surface — the shelf cards below navigate only, so
      // the old Recent[0] play overlay (Patch 069) is retired.
      if section == .resume {
        let cell = collectionView.dequeueReusableCell(
          withReuseIdentifier: ResumeCardCell.typeName,
          for: indexPath
        ) as! ResumeCardCell
        let containable = item.playableContainable
        cell.display(container: containable)
        cell.onPlayTapped = { [weak self] in
          guard let self else { return }
          // Patch 110 (2b): resume the persisted queue at its last position
          // instead of restarting the container from track 0. The player
          // restores its queue + musicIndex on launch; play() resumes that
          // current track and we seek it to its saved playProgress (the
          // backend defers the seek until the item is ready). The seek is done
          // explicitly here so ONLY the Resume card resumes mid-track — the
          // global isPlayerSongPlaybackResumeEnabled setting is left untouched.
          // Falls back to playing the container when nothing is queued to
          // resume.
          let player = appDelegate.player
          if let resumeTrack = player.currentMusicItem {
            player.play()
            if resumeTrack.playProgress > 0 {
              player.seek(toSecond: Double(resumeTrack.playProgress))
            }
          } else {
            player.play(context: PlayContext(containable: containable))
          }
        }
        return cell
      }
      if let artist = item.playableContainable as? Artist {
        let cell = collectionView.dequeueReusableCell(
          withReuseIdentifier: ArtistCircleCollectionCell.typeName,
          for: indexPath
        ) as! ArtistCircleCollectionCell
        cell.display(artist: artist)
        return cell
      }
      let cell = collectionView.dequeueReusableCell(
        withReuseIdentifier: AlbumCollectionCell.typeName,
        for: indexPath
      ) as! AlbumCollectionCell
      cell.display(
        container: item.playableContainable,
        rootView: self,
        itemWidth: Self.itemWidth,
        initialIndexPath: indexPath
      )
      return cell
    }

    dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
      guard kind == UICollectionView.elementKindSectionHeader,
            let header = collectionView.dequeueReusableSupplementaryView(
              ofKind: kind,
              withReuseIdentifier: SectionHeaderView.reuseID,
              for: indexPath
            ) as? SectionHeaderView,
            let snapshotSection = self?.dataSource.snapshot().sectionIdentifiers
            .element(at: indexPath.section)
      else {
        return nil
      }
      // cassette redesign (Surface 4): the Resume section's header is the
      // greeting line — quiet DM Mono, not a shelf title (and definitely
      // not Newsreader, which isn't bundled).
      if snapshotSection == .resume {
        header.style = .greeting
        header.title = Self.greetingText()
      } else {
        header.style = .shelf
        header.title = snapshotSection.title
      }
      // cassette Patch 035: every shelf is deterministic now; no
      // refresh button surfaces on any header.
      header.showsRefreshButton = false
      header.setRefreshHandler(nil)
      // cassette Patch 042: header tap navigates Playlists / Albums /
      // Artists into the matching Library category. Resume + Recent stay
      // presentational (handler nil → chevron hides).
      header.tapHandler = self?.tapHandler(for: snapshotSection)
      return header
    }
  }

  /// cassette redesign (Surface 4): time-of-day greeting above the Resume
  /// card, set in DM Mono caps like the app's other data labels.
  private static func greetingText() -> String {
    switch Calendar.current.component(.hour, from: Date()) {
    case 5 ..< 12: return "GOOD MORNING"
    case 12 ..< 18: return "GOOD AFTERNOON"
    default: return "GOOD EVENING"
    }
  }

  /// cassette Patch 042: returns the handler that fires when the
  /// shelf header is tapped, or nil if the header is presentational.
  private func tapHandler(for section: HomeSection) -> (() -> ())? {
    let category: LibraryDisplayType
    switch section {
    case .yourPlaylists: category = .playlists
    // cassette: the "Albums" shelf on Home is `.forgottenAlbums` (retitled),
    // not `.recentlyAdded` — that swap happened when the shelf was reworked
    // and this map was never updated, so the one shelf actually on screen
    // called "Albums" was the only typed shelf you couldn't tap into.
    // `.recentlyAdded` stays mapped for the legacy/editor path.
    case .forgottenAlbums, .recentlyAdded: category = .albums
    case .recentlyPlayedArtists: category = .artists
    // `.recent` is deliberately presentational: it mixes albums, playlists
    // and artists, so there is no single Library category to land on.
    default: return nil
    }
    return { [weak self] in
      AppDelegate.mainWindowHostVC?.switchToLibrary(category: category)
      _ = self
    }
  }

  /// cassette Patch 036: per-shelf hide-when-empty. We iterate the
  /// configured order but only append sections with content, so
  /// headers vanish for empty shelves (Resume, Your Playlists,
  /// Recently Added all hide independently). The full-screen empty
  /// state still kicks in when every shelf is empty.
  private func applySnapshot(animated: Bool = true) {
    var snapshot = NSDiffableDataSourceSnapshot<HomeSection, HomeItem>()
    var totalItems = 0
    // cassette: a diffable snapshot HARD-crashes (SIGTRAP) on a duplicate section
    // or item identifier. Shelf builders already dedup by stableID, but guard the
    // one render chokepoint too so a single missed dedup upstream degrades to a
    // dropped repeat instead of taking the whole app down. Belt to updatePlaylists'
    // suspenders after the applySnapshot crash cluster (build 2.1.1(3)).
    var seenSections = Set<HomeSection>()
    for section in sharedHome.orderedVisibleSections {
      guard seenSections.insert(section).inserted else { continue }
      var seenItemIDs = Set<String>()
      let items = (sharedHome.data[section] ?? []).filter {
        seenItemIDs.insert($0.stableID).inserted
      }
      guard !items.isEmpty else { continue }
      snapshot.appendSections([section])
      snapshot.appendItems(items, toSection: section)
      totalItems += items.count
    }
    dataSource.apply(snapshot, animatingDifferences: animated)
    refreshEmptyLibraryState(hasItems: totalItems > 0)
    // cassette (Forgotten Albums): the shelf may have just populated while Home
    // is visible — record the impression (per-day idempotent).
    recordForgottenShelfImpressionIfVisible()
  }

  /// cassette Patch 020: Cassette-flavored "no music yet" empty state on
  /// the Home tab. Triggered when the library has no playable items
  /// across all visible sections (the player still shows up either way).
  private func refreshEmptyLibraryState(hasItems: Bool) {
    contentUnavailableConfiguration = hasItems ? nil : Self.emptyLibraryConfig
  }

  /// cassette Patch 036: copy updated for the three-shelf IA — only
  /// shows when Resume, Your Playlists, and Recently Added are all
  /// empty (fresh install, no library, no listening history).
  private static let emptyLibraryConfig: UIContentUnavailableConfiguration = {
    var config = UIContentUnavailableConfiguration.empty()
    config.image = UIImage(systemName: "music.note")
    config.text = "Add music to your Cassette Player to start listening"
    config.secondaryText = "Once your Cassette Player syncs tracks, they'll show up here."
    config.textProperties.font = UIFont.cassette(.sectionTitle)
    config.textProperties.color = CassetteTheme.UIColors.ink
    config.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
    config.secondaryTextProperties.color = CassetteTheme.UIColors.ink2
    config.imageProperties.tintColor = CassetteTheme.UIColors.ink3
    return config
  }()

  @objc
  private func refreshOfflineMode() {
    os_log("HomeVC: OfflineModeChanged", log: self.log, type: .info)
    sharedHome.createFetchController()
  }

  /// cassette Patch 035: builds the screen-specific entries that
  /// get prepended to the account-button menu on the Home tab.
  /// Today: only "Edit Home." Other tabs pass no extras and see
  /// the unmodified account menu.
  private func makeHomeMenuExtras() -> [UIMenuElement] {
    let editHome = UIAction(
      title: "Edit Home",
      image: UIImage(systemName: "slider.horizontal.3"),
      handler: { [weak self] _ in
        self?.presentSectionEditor()
      }
    )
    return [editHome]
  }

  /// cassette Patch 035: wired from the account-button menu's
  /// "Edit Home" entry. The legacy `editSectionsTapped` `@objc`
  /// wrapper went away with the top-right bar button.
  func presentSectionEditor() {
    let editor = HomeEditorVC(current: sharedHome.orderedVisibleSections) { [weak self] newOrder in
      guard let self else { return }
      // cassette redesign (Surface 4): Resume isn't editable — the editor
      // only surfaces the shelves, so re-pin the Resume card to the top.
      sharedHome.orderedVisibleSections = [.resume] + newOrder.filter { $0 != .resume }
      if let accountInfo = appDelegate.storage.settings.accounts.active {
        appDelegate.storage.settings.accounts.updateSetting(accountInfo) { accountSettings in
          accountSettings.homeSections = newOrder
        }
      }
      applySnapshot(animated: true)

      sharedHome.createFetchController()
      sharedHome.updateFromRemote()
    }
    let nav = UINavigationController(rootViewController: editor)
    nav.modalPresentationStyle = .formSheet
    present(nav, animated: true)
  }

  // MARK: - Selection Handling

  override func collectionView(
    _ collectionView: UICollectionView,
    didSelectItemAt indexPath: IndexPath
  ) {
    guard let selectedItem = dataSource.itemIdentifier(for: indexPath) else { return }
    let playableContainer = selectedItem.playableContainable

    // cassette (Forgotten Albums): "opened from shelf" intent stamp (hot-log row
    // only; Home navigates on tap, so this is not a confirmed play — play-origin
    // attribution is deferred by design).
    if selectedItem.section == .forgottenAlbums, let album = playableContainer as? Album {
      appDelegate.storage.main.library.recordForgottenAlbumOpened(albumId: album.id)
    }

    // cassette Patch 042: every Home card navigates to detail. The
    // bottom-right play overlay (Patch 043) is the dedicated
    // play affordance, and the mini player still resumes the live
    // queue. The legacy "Resume[0] tap = play" branch is gone with
    // the Resume shelf itself.
    if let album = playableContainer as? Album {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToAlbumDetail(account: account, album: album),
        animated: true
      )
      navigationController?.navigationBar.prefersLargeTitles = false
    } else if let artist = playableContainer as? Artist {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToArtistDetail(account: account, artist: artist),
        animated: true
      )
      navigationController?.navigationBar.prefersLargeTitles = false
    } else if let playlist = playableContainer as? Playlist {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToPlaylistDetail(account: account, playlist: playlist),
        animated: true
      )
      navigationController?.navigationBar.prefersLargeTitles = false
    } else if let podcastEpisode = playableContainer as? PodcastEpisode,
              let podcast = podcastEpisode.podcast {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToPodcastDetail(
          account: account,
          podcast: podcast,
          episodeToScrollTo: podcastEpisode
        ),
        animated: true
      )
      navigationController?.navigationBar.prefersLargeTitles = false
    } else if let podcast = playableContainer as? Podcast {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToPodcastDetail(account: account, podcast: podcast),
        animated: true
      )
      navigationController?.navigationBar.prefersLargeTitles = false
    } else if let _ = playableContainer as? Radio {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToRadios(account: account),
        animated: true
      )
      navigationController?.navigationBar.prefersLargeTitles = false
    } else if let genre = playableContainer as? Genre {
      navigationController?.pushViewController(
        AppStoryboard.Main.segueToGenreDetail(account: account, genre: genre),
        animated: true
      )
      navigationController?.navigationBar.prefersLargeTitles = false
    }
  }

  /// Home pull-to-refresh: converge with the paired Mac, then run a full poll. Mirrors
  /// the library list's handleRefresh so both gestures mean the same thing.
  @objc
  private func handleCassetteRefresh(_ sender: UIRefreshControl) {
    Task { @MainActor in
      await IntentExecutor.shared.convergeAndRefresh()
      sender.endRefreshing()
    }
  }
}

extension HomeVC {
  override func collectionView(
    _ collectionView: UICollectionView,
    contextMenuConfigurationForItemAt indexPath: IndexPath,
    point: CGPoint
  )
    -> UIContextMenuConfiguration? {
    guard let containable = dataSource.itemIdentifier(for: indexPath)?.playableContainable
    else { return nil }

    let identifier = NSString(string: TableViewPreviewInfo(
      playableContainerIdentifier: containable.containerIdentifier,
      indexPath: indexPath
    ).asJSONString())
    return UIContextMenuConfiguration(identifier: identifier, previewProvider: {
      let vc = EntityPreviewVC()
      vc.display(container: containable, on: self)
      Task { @MainActor in
        do {
          try await containable.fetch(
            storage: self.appDelegate.storage,
            librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
            playableDownloadManager: self.appDelegate.getMeta(self.account.info)
              .playableDownloadManager
          )
        } catch {
          self.appDelegate.eventLogger.report(topic: "Preview Sync", error: error)
        }
        vc.refresh()
      }
      return vc
    }) { suggestedActions in
      var playIndexCB: (() -> PlayContext?)?
      playIndexCB = { PlayContext(containable: containable) }
      return EntityPreviewActionBuilder(
        container: containable,
        on: self,
        playContextCb: playIndexCB
      ).createMenu()
    }
  }

  override func collectionView(
    _ collectionView: UICollectionView,
    willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionCommitAnimating
  ) {
    animator.addCompletion {
      if let identifier = configuration.identifier as? String,
         let tvPreviewInfo = TableViewPreviewInfo.create(fromIdentifier: identifier),
         let containerIdentifier = tvPreviewInfo.playableContainerIdentifier,
         let container = self.appDelegate.storage.main.library
         .getContainer(identifier: containerIdentifier) {
        EntityPreviewActionBuilder(container: container, on: self).performPreviewTransition()
      }
    }
  }
}

// MARK: - SectionHeaderView

final class SectionHeaderView: UICollectionReusableView {
  static let reuseID = "SectionHeaderView"

  /// cassette redesign (Surface 4): the Resume section's header is the
  /// greeting line (Barlow, `.greeting` role); the shelves keep the Barlow
  /// section title.
  enum Style {
    case shelf
    case greeting
  }

  var style: Style = .shelf {
    didSet {
      switch style {
      case .shelf:
        titleLabel.font = UIFont.cassette(.sectionTitle)
        titleLabel.textColor = CassetteTheme.UIColors.ink
      case .greeting:
        // cassette Patch 104 (Root 4): the greeting used to render in 12pt
        // metadata mono — a fallback after Newsreader was dropped — which
        // read as a tiny caption. It now uses the dedicated `.greeting`
        // role (Barlow Condensed SemiBold 20pt, ink).
        titleLabel.font = UIFont.cassette(.greeting)
        titleLabel.textColor = CassetteTheme.UIColors.ink
      }
    }
  }

  private let refreshButton: UIButton = {
    let btn = UIButton(type: .system)
    btn.translatesAutoresizingMaskIntoConstraints = false
    btn.setImage(UIImage.refresh, for: .normal)
    // cassette Patch 048 (Phase C): refresh button in shelf headers pins
    // to ink2 explicitly. Previously inherited the window tint (orange);
    // now reads as a quiet secondary action consistent with the chevron
    // glyph on the other shelf headers.
    btn.tintColor = CassetteTheme.UIColors.ink2
    btn.isHidden = true
    btn.accessibilityLabel = "Refresh Randoms"
    return btn
  }()

  private let titleLabel: UILabel = {
    let lbl = UILabel()
    lbl.translatesAutoresizingMaskIntoConstraints = false
    // cassette Patch 032: section title routes through .sectionTitle
    // (22pt bold display) — consistent with empty-state titles and other
    // section headings.
    lbl.font = UIFont.cassette(.sectionTitle)
    lbl.textColor = CassetteTheme.UIColors.ink
    return lbl
  }()

  // cassette Patch 042: chevron-right indicator that surfaces only
  // when the header has a `tapHandler` (Playlists / Albums / Artists
  // navigate to the matching Library category). Hidden on Recent so
  // it stays a presentational shelf.
  private let chevronImageView: UIImageView = {
    let iv = UIImageView()
    iv.translatesAutoresizingMaskIntoConstraints = false
    // cassette: the chevron was a hairline — default (regular) weight scaled
    // into a 12x16 box next to 22pt Barlow Condensed Bold, so it read as a
    // stray tick rather than an affordance. Bold at 13pt matches the stroke
    // of the title it sits beside, and ink (not ink2) stops it looking
    // half-disabled. The Library dropdown chevron is semibold/12 for the same
    // reason.
    iv.image = UIImage(
      systemName: "chevron.right",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
    )
    iv.tintColor = CassetteTheme.UIColors.ink
    // `.center`, not `.scaleAspectFit`: aspect-fit would rescale the glyph to
    // the box and throw away the point size we just set.
    iv.contentMode = .center
    iv.isHidden = true
    return iv
  }()

  // cassette Patch 042: invisible UIControl spans title + chevron so
  // the entire trailing region is tappable, matching the Apple Music
  // / Files-style "tap whole header to see all" affordance.
  private lazy var tapButton: UIControl = {
    let ctl = UIControl()
    ctl.translatesAutoresizingMaskIntoConstraints = false
    ctl.addAction(UIAction { [weak self] _ in self?.tapHandler?() }, for: .touchUpInside)
    return ctl
  }()

  var showsRefreshButton: Bool {
    get { !refreshButton.isHidden }
    set { refreshButton.isHidden = !newValue }
  }

  func setRefreshHandler(_ handler: (() -> ())?) {
    refreshButton.removeTarget(nil, action: nil, for: .allEvents)
    guard let handler else { return }
    refreshButton.addAction(UIAction { _ in handler() }, for: .touchUpInside)
  }

  /// cassette Patch 042: per-shelf navigation hook. When non-nil,
  /// the chevron indicator surfaces, the header becomes a hit
  /// target, and tapping fires the handler (e.g. switch the Library
  /// tab to .albums).
  var tapHandler: (() -> ())? {
    didSet {
      let isTappable = tapHandler != nil
      chevronImageView.isHidden = !isTappable
      tapButton.isUserInteractionEnabled = isTappable
      tapButton.accessibilityTraits = isTappable ? .button : []
    }
  }

  var title: String? {
    didSet {
      titleLabel.text = title
      tapButton.accessibilityLabel = title
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupSubviews()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupSubviews()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    tapHandler = nil
    setRefreshHandler(nil)
    showsRefreshButton = false
    style = .shelf
  }

  /// cassette Patch 025: give the section title room to breathe. The
  /// XIB previously pinned title flush top-to-bottom; now there's
  /// 16pt above it (separating it from the previous section's bottom
  /// inset / nav-bar zone) and 8pt below it (gap to the first cell
  /// row, replacing the section `contentInsets.top` that was zeroed).
  ///
  /// cassette Patch 042: also hosts the optional chevron and the
  /// transparent tap target.
  private func setupSubviews() {
    addSubview(titleLabel)
    addSubview(chevronImageView)
    addSubview(refreshButton)
    addSubview(tapButton)
    // cassette Polish 2 (A2): the chevron now sits directly adjacent to the
    // title (6pt gap) instead of floating against the trailing edge. On Home
    // it reads "tap into this shelf"; in Library the same glyph (rotated to
    // chevron.down) reads "dropdown". The trailing region is intentionally
    // empty space.
    titleLabel.setContentHuggingPriority(.required, for: .horizontal)
    NSLayoutConstraint.activate([
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 16),
      titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

      chevronImageView.leadingAnchor.constraint(
        equalTo: titleLabel.trailingAnchor,
        constant: 6
      ),
      chevronImageView.trailingAnchor.constraint(
        lessThanOrEqualTo: trailingAnchor,
        constant: -16
      ),
      chevronImageView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
      chevronImageView.widthAnchor.constraint(equalToConstant: 14),
      chevronImageView.heightAnchor.constraint(equalToConstant: 18),

      refreshButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      refreshButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

      tapButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      tapButton.topAnchor.constraint(equalTo: titleLabel.topAnchor),
      tapButton.bottomAnchor.constraint(equalTo: titleLabel.bottomAnchor),
      tapButton.trailingAnchor.constraint(
        equalTo: chevronImageView.trailingAnchor,
        constant: 8
      ),
    ])
    // Default to non-tappable; supplementaryViewProvider sets a
    // handler per-shelf which flips this back on.
    tapButton.isUserInteractionEnabled = false
  }
}

extension UIFont {
  fileprivate func withWeight(_ weight: UIFont.Weight) -> UIFont {
    let descriptor = fontDescriptor.addingAttributes([
      UIFontDescriptor.AttributeName.traits: [UIFontDescriptor.TraitKey.weight: weight],
    ])
    return UIFont(descriptor: descriptor, size: pointSize)
  }
}
