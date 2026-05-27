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
      eventLogger: appDelegate.eventLogger
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
        userBarButtonItem: &userBarButtonItem
      )
    }

    navigationController?.navigationBar.prefersLargeTitles = true
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "Edit",
      style: .plain,
      target: self,
      action: #selector(editSectionsTapped)
    )
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
    navigationController?.navigationBar.prefersLargeTitles = true
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    sharedHome.updateFromRemote()
  }

  // MARK: - Layout

  private static func createLayout() -> UICollectionViewCompositionalLayout {
    let layout = UICollectionViewCompositionalLayout { sectionIndex, _ in
      guard let _ = HomeSection(rawValue: sectionIndex) else { return nil }

      // Item: square image with title below -> estimate height accommodates label
      let itemSize = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1.0),
        heightDimension: .fractionalHeight(1.0)
      )
      let item = NSCollectionLayoutItem(layoutSize: itemSize)

      // Group: fixed width to show large image; height estimated to fit image + label
      // We'll use a vertical group containing the cell's content; the cell itself handles layout.
      let groupSize = NSCollectionLayoutSize(
        widthDimension: .absolute(itemWidth),
        heightDimension: .estimated(210)
      )
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
    >(collectionView: collectionView) { collectionView, indexPath, item in
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

    dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
      guard kind == UICollectionView.elementKindSectionHeader,
            let header = collectionView.dequeueReusableSupplementaryView(
              ofKind: kind,
              withReuseIdentifier: SectionHeaderView.reuseID,
              for: indexPath
            ) as? SectionHeaderView,
            let section = self.sharedHome.orderedVisibleSections.element(at: indexPath.section)
      else {
        return nil
      }
      header.title = section.title
      if section == .randomAlbums {
        header.showsRefreshButton = true
        header.setRefreshHandler { [weak self] in self?.refreshRandomAlbumsSection() }
      } else if section == .randomArtists {
        header.showsRefreshButton = true
        header.setRefreshHandler { [weak self] in self?.refreshRandomArtistsSection() }
      } else if section == .randomGenres {
        header.showsRefreshButton = true
        header.setRefreshHandler { [weak self] in self?.refreshRandomGenresSection() }
      } else if section == .randomSongs {
        header.showsRefreshButton = true
        header.setRefreshHandler { [weak self] in self?.refreshRandomSongsSection() }
      } else {
        header.showsRefreshButton = false
        header.setRefreshHandler(nil)
      }
      return header
    }
  }

  private func applySnapshot(animated: Bool = true) {
    var snapshot = NSDiffableDataSourceSnapshot<HomeSection, HomeItem>()
    snapshot.appendSections(sharedHome.orderedVisibleSections)
    var totalItems = 0
    for section in sharedHome.orderedVisibleSections {
      let items = sharedHome.data[section] ?? []
      totalItems += items.count
      snapshot.appendItems(items, toSection: section)
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

  private static let emptyLibraryConfig: UIContentUnavailableConfiguration = {
    var config = UIContentUnavailableConfiguration.empty()
    config.image = UIImage(systemName: "music.note")
    config.text = "No music yet"
    config.secondaryText = "Add tracks to your Cassette Player to see them here."
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

  @objc
  private func editSectionsTapped() {
    presentSectionEditor()
  }

  private func presentSectionEditor() {
    // Build a simple editor using a temporary UIViewController with a table view
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

  @objc
  func refreshRandomAlbumsSection() {
    Task { @MainActor in
      await sharedHome.updateRandomAlbums(isOfflineMode: sharedHome.isOfflineMode)
    }
  }

  @objc
  func refreshRandomArtistsSection() {
    Task { @MainActor in
      await sharedHome.updateRandomArtists(isOfflineMode: sharedHome.isOfflineMode)
    }
  }

  @objc
  func refreshRandomGenresSection() {
    Task { @MainActor in
      await sharedHome.updateRandomGenres()
    }
  }

  @objc
  func refreshRandomSongsSection() {
    Task { @MainActor in
      await sharedHome.updateRandomSongs(isOfflineMode: sharedHome.isOfflineMode)
    }
  }

  // MARK: - Selection Handling

  override func collectionView(
    _ collectionView: UICollectionView,
    didSelectItemAt indexPath: IndexPath
  ) {
    guard let playableContainer = dataSource.itemIdentifier(for: indexPath)?.playableContainable
    else { return }

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

  var showsRefreshButton: Bool {
    get { !refreshButton.isHidden }
    set { refreshButton.isHidden = !newValue }
  }

  func setRefreshHandler(_ handler: (() -> ())?) {
    refreshButton.removeTarget(nil, action: nil, for: .allEvents)
    guard let handler else { return }
    refreshButton.addAction(UIAction { _ in handler() }, for: .touchUpInside)
  }

  var title: String? {
    didSet { titleLabel.text = title }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupSubviews()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupSubviews()
  }

  /// cassette Patch 025: give the section title room to breathe. The
  /// XIB previously pinned title flush top-to-bottom; now there's
  /// 16pt above it (separating it from the previous section's bottom
  /// inset / nav-bar zone) and 8pt below it (gap to the first cell
  /// row, replacing the section `contentInsets.top` that was zeroed).
  private func setupSubviews() {
    addSubview(titleLabel)
    addSubview(refreshButton)
    NSLayoutConstraint.activate([
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      titleLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: refreshButton.leadingAnchor,
        constant: -8
      ),
      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 16),
      titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
      refreshButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      refreshButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
    ])
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
