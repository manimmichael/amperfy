//
//  SpinnerViewController.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 25.02.21.
//  Copyright (c) 2021 Maximilian Bauer. All rights reserved.
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
import Foundation
import UIKit

class SpinnerViewController: UIViewController {
  private var spinner = UIActivityIndicatorView(style: .large)
  private var isDisplayed = false

  override func loadView() {
    view = UIView()

    // cassette Patch 033: drop UIColor.quaternarySystemFill (the iOS
    // dark-mode fill which composites to a cool blue-grey on top of the
    // warm Cassette palette). Use bg2 so the spinner overlay sits on the
    // same neutral grey family as the rest of the chrome.
    if #available(iOS 13.0, *) {
      view.backgroundColor = CassetteTheme.UIColors.bg2
      spinner.color = UIColor.placeholderText
    } else {
      view.backgroundColor = UIColor(white: 0.9, alpha: 1.0)
    }

    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.startAnimating()
    view.addSubview(spinner)

    spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true

    NSLayoutConstraint(
      item: view!,
      attribute: .centerY,
      relatedBy: .equal,
      toItem: spinner,
      attribute: .centerY,
      multiplier: 1.0,
      constant: 200
    ).isActive = true
  }

  func display(on hostVC: UIViewController) {
    if !isDisplayed {
      hostVC.addChild(self)
      view.frame = hostVC.view.frame
      hostVC.view.addSubview(view)
      didMove(toParent: hostVC)
      isDisplayed = true
    }
  }

  func hide() {
    if isDisplayed {
      willMove(toParent: nil)
      view.removeFromSuperview()
      removeFromParent()
      isDisplayed = false
    }
  }
}
