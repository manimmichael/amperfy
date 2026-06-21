// The Swift Programming Language
// https://docs.swift.org/swift-book

import AmperfyKit
import SwiftUI

// MARK: - EqualizerView

public struct EqualizerView: View {
  private var frequency: Int
  public var sliderFrameHeight: CGFloat
  public var sliderTintColor: Color
  public var gradientColors: [Color]
  @Binding
  public var sliderValues: [CGFloat]
  @State
  private var viewWidth: CGFloat = 300
  @Binding
  private var sliderLabel: [String]

  public init(
    sliderLabels: Binding<[String]>,
    sliderValues: Binding<[CGFloat]>,
    sliderFrameHeight: CGFloat = 200,
    sliderTintColor: Color,
    gradientColors: [Color]
  ) {
    self._sliderValues = sliderValues
    self._sliderLabel = sliderLabels
    self.frequency = sliderValues.count - 1
    self.sliderFrameHeight = sliderFrameHeight
    self.sliderTintColor = sliderTintColor
    self.gradientColors = gradientColors
  }

  public var body: some View {
    GeometryReader { geometry in
      let sliderWidth: CGFloat = (geometry.size.width - 35) / CGFloat(frequency + 2)
      let spacing: CGFloat = 0
      HStack(alignment: .top, spacing: 0) {
        addScale(sliderWidth: sliderWidth)
          .frame(width: 35, height: 200)
        VStack {
          ZStack(alignment: .top) {
            addScaleLines(sliderWidth: sliderWidth)
            addEqPath(spacing: spacing, sliderWidth: sliderWidth)
            setSlider(sliderWidth: sliderWidth)
          }
          .frame(height: 200)
          setSliderLabel(sliderWidth: sliderWidth)
        }
      }
      .background(
        Color.clear
      )
    }
    .frame(height: 220)
  }
}

extension EqualizerView {
  func addEqPath(spacing: CGFloat, sliderWidth: CGFloat) -> some View {
    ZStack {
      EqualizerPathTopLine(
        sliderValues: sliderValues,
        sliderFrameH: sliderFrameHeight,
        sliderSpacing: spacing,
        sliderWidth: sliderWidth
      )
      .stroke(sliderTintColor, lineWidth: 2.5)
      // cassette §E polish: soft glow under the curve.
      .shadow(color: sliderTintColor.opacity(0.55), radius: 6)
      .animation(.easeInOut, value: sliderValues)

      EqualizerPath(
        sliderValues: sliderValues,
        sliderFrameH: sliderFrameHeight,
        sliderSpacing: spacing,
        sliderWidth: sliderWidth
      )
      .fill(
        LinearGradient(
          gradient: Gradient(colors: self.gradientColors),
          startPoint: .top,
          endPoint: .bottom
        )
      )
      .animation(.easeInOut, value: sliderValues)
    }
  }

  func setSlider(sliderWidth: CGFloat) -> some View {
    HStack(spacing: 0) {
      ForEach(0 ... frequency, id: \.self) { i in
        SliderView(
          sliderValue: $sliderValues[i],
          sliderFrameHeight: sliderFrameHeight,
          sliderTintColor: sliderTintColor
        )
        .frame(width: sliderWidth)
      }
    }
  }

  func setSliderLabel(sliderWidth: CGFloat) -> some View {
    HStack(spacing: 0) {
      ForEach(0 ... sliderLabel.count - 1, id: \.self) { i in
        Text(sliderLabel[i])
          .font(.system(size: 11, weight: .regular, design: .monospaced))
          .foregroundStyle(CassetteTheme.Colors.ink2)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .frame(width: sliderWidth)
      }
    }
  }

  func addScale(sliderWidth: CGFloat) -> some View {
    VStack {
      ForEach((-EqualizerSetting.rangeFromZero / 2) ... -1, id: \.self) { i in
        Text("\(i * -2) dB")
          .font(.system(size: 11, weight: .regular, design: .monospaced))
          .foregroundStyle(CassetteTheme.Colors.ink3)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .frame(maxHeight: .infinity)
      }

      Text("0 dB")
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(CassetteTheme.Colors.ink2)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxHeight: .infinity)

      ForEach(1 ... (EqualizerSetting.rangeFromZero / 2), id: \.self) { i in
        Text("\(i * -2) dB")
          .font(.system(size: 11, weight: .regular, design: .monospaced))
          .foregroundStyle(CassetteTheme.Colors.ink3)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .frame(maxHeight: .infinity)
      }
    }
  }

  func addScaleLines(sliderWidth: CGFloat) -> some View {
    VStack {
      ForEach((-EqualizerSetting.rangeFromZero / 2) ... -1, id: \.self) { i in
        VStack {
          Rectangle()
            .fill(CassetteTheme.Colors.ink3.opacity(0.18))
            .frame(height: 1.0)
            .edgesIgnoringSafeArea(.horizontal)
        }.frame(maxHeight: .infinity)
      }

      VStack {
        Rectangle()
          .fill(CassetteTheme.Colors.ink2.opacity(0.35))
          .frame(height: 1.0)
          .edgesIgnoringSafeArea(.horizontal)
      }.frame(maxHeight: .infinity)

      ForEach(1 ... (EqualizerSetting.rangeFromZero / 2), id: \.self) { i in
        VStack {
          Rectangle()
            .fill(CassetteTheme.Colors.ink3.opacity(0.18))
            .frame(height: 1.0)
            .edgesIgnoringSafeArea(.horizontal)
        }.frame(maxHeight: .infinity)
      }
    }.padding(.horizontal)
  }
}
