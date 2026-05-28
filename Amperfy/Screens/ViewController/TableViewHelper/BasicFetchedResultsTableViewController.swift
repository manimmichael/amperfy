//
//  BasicFetchedResultsTableViewController.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 23.02.24.
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

class BasicFetchedResultsTableViewController<ResultType>: BasicTableViewController
  where ResultType: NSFetchRequestResult {
  var isIndexTitelsHidden = false
  /// cassette Patch 063: fade section index in while scrolling, hide when idle.
  var usesFadingSectionIndex = false

  private var singleFetchController: BasicFetchedResultsController<ResultType>?
  var singleFetchedResultsController: BasicFetchedResultsController<ResultType>? {
    set { singleFetchController = newValue }
    get { singleFetchController }
  }

  override func numberOfSections(in tableView: UITableView) -> Int {
    singleFetchController?.numberOfSections ?? 0
  }

  override func tableView(
    _ tableView: UITableView,
    titleForHeaderInSection section: Int
  )
    -> String? {
    singleFetchController?.titleForHeader(inSection: section)
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    singleFetchController?.numberOfRows(inSection: section) ?? 0
  }

  override func sectionIndexTitles(for tableView: UITableView) -> [String]? {
    isIndexTitelsHidden ? nil : singleFetchController?.sectionIndexTitles
  }

  override func tableView(
    _ tableView: UITableView,
    sectionForSectionIndexTitle title: String,
    at index: Int
  )
    -> Int {
    singleFetchController?.section(forSectionIndexTitle: title, at: index) ?? 0
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if usesFadingSectionIndex {
      setSectionIndexHidden(true, animated: false)
    }
  }

  override func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    if usesFadingSectionIndex {
      setSectionIndexHidden(false, animated: true)
    }
  }

  override func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    if usesFadingSectionIndex {
      setSectionIndexHidden(true, animated: true)
    }
  }

  override func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if usesFadingSectionIndex, !decelerate {
      setSectionIndexHidden(true, animated: true)
    }
  }

  override func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
    if usesFadingSectionIndex {
      setSectionIndexHidden(true, animated: true)
    }
  }

  func setSectionIndexHidden(_ hidden: Bool, animated: Bool) {
    guard usesFadingSectionIndex, let indexView = tableSectionIndexView else { return }
    let targetAlpha: CGFloat = hidden ? 0 : 1
    let apply = { indexView.alpha = targetAlpha }
    if animated {
      UIView.animate(withDuration: 0.2, animations: apply)
    } else {
      apply()
    }
  }

  private var tableSectionIndexView: UIView? {
    tableView.subviews.first {
      String(describing: type(of: $0)).contains("UITableViewIndex")
    }
  }
}
