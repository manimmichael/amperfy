//
//  SwiftUIView.swift
//
//
//  Created by Urvi Koladiya on 2025-04-14.
//

import AmperfyKit
import SwiftUI

// cassette §E polish: replaced the rotated UISlider (whose default white knob
// was the one obviously-unfinished element, and which crashed on macCatalyst —
// hence the old Stepper special-case) with a custom vertical drag slider. The
// thumb is a themed dot whose vertical position mirrors EqualizerPath.calcYPos,
// so it rides exactly at the curve's height for its band. One implementation
// for every platform (no rotation, no Stepper fallback).
struct SliderView: View {
  @Binding
  var sliderValue: CGFloat
  var sliderFrameHeight: CGFloat
  var sliderTintColor: Color

  private var range: CGFloat { CGFloat(EqualizerSetting.rangeFromZero) }

  /// Mirrors `EqualizerPath.calcYPos` (with rect.height == sliderFrameHeight)
  /// so the thumb sits at the same height as the curve for this band.
  private func y(for value: CGFloat) -> CGFloat {
    let f = sliderFrameHeight
    let k = (0.5 * (value / range)) + 0.5
    return (0.05 * f) + 0.90 * (f - (k * f))
  }

  /// Inverse of `y(for:)`, snapped to the 1 dB step and clamped to range.
  private func value(atY y: CGFloat) -> CGFloat {
    let f = sliderFrameHeight
    let k = (0.95 - (y / f)) / 0.90
    let v = ((k - 0.5) * 2.0) * range
    return min(range, max(-range, v.rounded()))
  }

  var body: some View {
    GeometryReader { geo in
      ZStack {
        Color.clear
        Circle()
          .fill(sliderTintColor)
          .frame(width: 13, height: 13)
          .overlay(Circle().stroke(CassetteTheme.Colors.bg.opacity(0.5), lineWidth: 1))
          .shadow(color: sliderTintColor.opacity(0.7), radius: 4)
          .position(x: geo.size.width / 2, y: y(for: sliderValue))
      }
      .frame(width: geo.size.width, height: sliderFrameHeight)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { gesture in
            sliderValue = value(atY: gesture.location.y)
          }
      )
    }
    .frame(height: sliderFrameHeight)
  }
}
