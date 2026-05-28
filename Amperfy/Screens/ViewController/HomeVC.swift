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
      player: appDelegate.player
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
    sharedHome.createFetchController()
    applySnapshot(animated: false)

    appDelegate.notificationHandler.register(
      self,
      selector: #selector(refreshOfflineMode),
      name: .offlineModeChanged,
      object: nil
    )
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    configureHomeNavigationBar()
  }

  private func configureHomeNavigationBar() {
    title = "Home"
    navigationItem.largeTitleDisplayMode = .always
    navigationController?.navigationBar.prefersLargeTitles = true
    let appearance = UINavigationBarAppearance()
    appearance.configureWithDefaultBackground()
    appearance.largeTitleTextAttributes = [
      .font: UIFont.cassette(.heroTitle),
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
  }

  // MARK: - Layout

  private static func createLayout() -> UICollectionViewCompositionalLayout {
    // cassette Patch 038: section-aware layout. Captures the
    // section enum from the snapshot so the Artists shelf can swap
    // to a tighter ~110pt-wide group sized for the circular
    // ArtistCircleCollectionCell, while other shelves keep the
    // existing 160pt × 210pt rhythm.
    let layout = UICollectionViewCompositionalLayout { sectionIndex, environment in
      guard let section = HomeSection(rawValue: sectionIndex) else { return nil }

      let itemSize = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1.0),
        heightDimension: .fractionalHeight(1.0)
      )
      let item = NSCollectionLayoutItem(layoutSize: itemSize)

      let groupSize: NSCollectionLayoutSize
      switch section {
      default:
        groupSize = NSCollectionLayoutSize(
          widthDimension: .absolute(itemWidth),
          heightDimension: .estimated(shelfEstimatedHeight)
        )
      }
      _ = environment
      let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])

      let sectionLayout = NSCollectionLayoutSection(group: group)
      sectionLayout.orthogonalScrollingBehavior = .continuous
      sectionLayout.interGroupSpacing = 12
      // cassette Patch 025: drop the section top inset — vertical
      // rhythm above the carousel now comes from `SectionHeaderView`'s
      // own internal padding (16pt above title, 8pt below) so we
      // don't double-count the gap.
      sectionLayout.contentInsets = NSDirectionalEdgeInsets(
        top: 0,
        leading: 16,
        bottom: 24,
        trailing: 16
      )

      // Header
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
    return layout
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
      let section = self.dataSource.snapshot().sectionIdentifiers.element(at: indexPath.section)
      let showsPlayOverlay = section == .recent && indexPath.item == 0
      if let artist = item.playableContainable as? Artist {
        let cell = collectionView.dequeueReusableCell(
          withReuseIdentifier: ArtistCircleCollectionCell.typeName,
          for: indexPath
        ) as! ArtistCircleCollectionCell
        cell.display(artist: artist, showsPlayOverlay: showsPlayOverlay)
        // cassette Patch 043: tap-vs-play split. Body tap still
        // navigates to detail via didSelectItemAt; the overlay
        // starts playback for the artist's playable contents.
        cell.onPlayTapped = { [weak self] in
          guard let self else { return }
          self.appDelegate.player.play(
            context: PlayContext(containable: artist)
          )
        }
        return cell
      }
      let cell = collectionView.dequeueReusableCell(
        withReuseIdentifier: AlbumCollectionCell.typeName,
        for: indexPath
      ) as! AlbumCollectionCell
      let containable = item.playableContainable
      cell.showsPlayOverlay = showsPlayOverlay
      cell.display(
        container: containable,
        rootView: self,
        itemWidth: Self.itemWidth,
        initialIndexPath: indexPath
      )
      // cassette Patch 043: same tap-vs-play split as the artist
      // cell — overlay tap fires `player.play` for whatever
      // container this card represents (album, playlist, podcast).
      cell.onPlayTapped = { [weak self] in
        guard let self else { return }
        self.appDelegate.player.play(
          context: PlayContext(containable: containable)
        )
      }
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
      header.title = snapshotSection.title
      // cassette Patch 035: every shelf is deterministic now; no
      // refresh button surfaces on any header.
      header.showsRefreshButton = false
      header.setRefreshHandler(nil)
      // cassette Patch 042: header tap navigates Playlists / Albums /
      // Artists into the matching Library category. Recent stays
      // presentational (handler nil → chevron hides).
      header.tapHandler = self?.tapHandler(for: snapshotSection)
      return header
    }
  }

  /// cassette Patch 042: returns the handler that fires when the
  /// shelf header is tapped, or nil if the header is presentational.
  private func tapHandler(for section: HomeSection) -> (() -> Void)? {
    let category: LibraryDisplayType
    switch section {
    case .yourPlaylists: category = .playlists
    case .recentlyAdded: category = .albums
    case .recentlyPlayedArtists: category = .artists
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
    for section in sharedHome.orderedVisibleSections {
      let items = sharedHome.data[section] ?? []
      guard !items.isEmpty else { continue }
      snapshot.appendSections([section])
      snapshot.appendItems(items, toSection: section)
      totalItems += items.count
    }
    dataSource.apply(snapshot, animatingDifferences: animated)
    refreshEmptyLibraryState(hasItems: totalItems > 0)
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
      sharedHome.orderedVisibleSections = newOrder
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
    guard let playableContainer = dataSource.itemIdentifier(for: indexPath)?.playableContainable
    else { return }

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
    iv.image = UIImage(systemName: "chevron.right")
    iv.tintColor = CassetteTheme.UIColors.ink2
    iv.contentMode = .scaleAspectFit
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
  var tapHandler: (() -> Void)? {
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
    NSLayoutConstraint.activate([
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      titleLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: chevronImageView.leadingAnchor,
        constant: -6
      ),
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 16),
      titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

      chevronImageView.trailingAnchor.constraint(
        lessThanOrEqualTo: refreshButton.leadingAnchor,
        constant: -8
      ),
      chevronImageView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
      chevronImageView.widthAnchor.constraint(equalToConstant: 12),
      chevronImageView.heightAnchor.constraint(equalToConstant: 16),

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
