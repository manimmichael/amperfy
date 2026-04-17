# Fonts

This directory holds the Cassette typography TTFs. They are loaded via the
`UIAppFonts` key in `Amperfy/Info.plist` and resolved at runtime by
`AmperfyKit/CassetteFont.swift`.

## Expected files

- `BarlowCondensed-Regular.ttf`
- `BarlowCondensed-SemiBold.ttf`
- `BarlowCondensed-Bold.ttf`
- `BarlowCondensed-ExtraBold.ttf`
- `DMMono-Regular.ttf`
- `DMMono-Medium.ttf`

## How to populate

From the wrapper directory (`apps/cassette-player-ios/`) run:

```bash
bash scripts/fetch-fonts.sh
```

The script downloads the TTFs from the Google Fonts GitHub repos (both
fonts are released under the SIL Open Font License 1.1, which is
compatible with GPL v3) and drops them into this folder.

## Xcode integration (one-time, manual)

After the files exist locally:

1. Open `Amperfy.xcodeproj` in Xcode.
2. Right-click `Amperfy/Resources/` in the Project Navigator → **Add Files to "Amperfy"…**.
3. Select the `Fonts/` folder. Check **"Copy items if needed"** is off (files already live there), check **"Create folder references"**, and tick the **Amperfy** target.
4. Confirm the files appear under **Build Phases → Copy Bundle Resources** for the Amperfy target.
5. Build. The `UIAppFonts` entries in `Info.plist` will pick them up at launch.

Until that manual step is done, `UIFont.cassetteDisplay(size:)` and friends
will fall back to the system font (SF Pro). The app will still run fine.
