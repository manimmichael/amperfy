//
//  WelcomePopupPresenter.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 31.07.25.
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

import Foundation

@MainActor
class WelcomePopupPresenter: NSObject {
  /// cassette (BUG-416): the two upstream first-launch popups are gone.
  ///
  /// The "Synchronization" explainer told people to use search to sync, which
  /// the phone has not needed since the cloud sync landed, and the
  /// "Notifications" pre-prompt named Amperfy and podcast episodes. Local
  /// notifications only ever carried podcast episodes (see
  /// `LocalNotificationManager`), and podcasts are not a Cassette surface, so
  /// the notification authorization is not requested at all: no pre-prompt, no
  /// system prompt. The "sync info read" flag is still stamped so a phone that
  /// upgrades from a build that showed the popup looks the same as a fresh
  /// install to everything downstream.
  func displayInfoPopupsIfNeeded() {
    if !appDelegate.storage.settings.app.isLibrarySyncInfoReadByUser {
      appDelegate.storage.settings.app.isLibrarySyncInfoReadByUser = true
    }
  }
}
