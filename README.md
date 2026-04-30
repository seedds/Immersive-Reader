# ImmersiveReader

ImmersiveReader is an iOS/iPadOS EPUB reader built with SwiftUI, SwiftData, and Readium.

It focuses on EPUB3 reading with synced read-aloud playback, active text highlighting, upload/import workflows, custom font support, reading progress restore, chapter navigation, reader appearance controls, and resume-aware playback.

## Screenshots

| Reader | Library | Upload | Settings |
| --- | --- | --- | --- |
| <img src="docs/images/reader.png" width="220" alt="Reader view with active text highlighting and playback controls"> | <img src="docs/images/library.png" width="220" alt="Library tab showing imported books"> | <img src="docs/images/upload.png" width="220" alt="Upload tab with local server status and recent uploads"> | <img src="docs/images/settings.png" width="220" alt="Settings tab with reader appearance and playback controls"> |

## Features

- Local network upload server for `.epub`, `.ttf`, and `.otf` files
- Read-aloud playback with active text highlighting
- Tap-to-play on spoken text
- Auto scroll with continuous reading
- Custom font import and family-based font management

## App Structure

The app has three tabs:

- `Books`: browse, import, refresh, delete, and open books
- `Upload`: run a local upload server and upload EPUB or custom font files
- `Settings`: reader typography, custom fonts, theme, and highlight color settings

## Reader Behavior

- Reader opens in scroll mode by default
- Playback bar appears only for books with parsed media overlays
- Active spoken text is highlighted in the EPUB view
- The highlight color can be customized from Settings
- Custom fonts can be imported from Settings and selected as one font-family choice even when they include multiple files such as regular and italic
- Imported custom font families are available after reopening the current book
- Chapter selection can jump playback to the first matching clip
- Manual scroll-and-stop can retarget playback to the first visible playable fragment
- Reopening a book with a saved last-played segment navigates to that segment and highlights it without autoplay
- Reopening a book with no saved played segment does not pre-highlight any text

## Storage Layout

- Imported EPUB files are stored in the app `Documents` directory
- Temporary uploads are stored in `tmp/Immersive Reader/Uploads/`
- Extracted EPUB contents are stored in `Library/Application Support/Immersive Reader/Extracted/<book-id>/`
- Imported custom fonts are stored in `Library/Application Support/Immersive Reader/CustomFonts/`
- Custom font metadata is stored in `Library/Application Support/Immersive Reader/custom-fonts.json`

Imported EPUBs are intended to appear in the Files app under `On My iPhone/ImmersiveReader`.

Custom fonts are app-managed assets and do not appear in the Files app library view.

## Tech Stack

- SwiftUI
- SwiftData
- Readium Swift Toolkit
- AVFoundation
- Network.framework

## Build

Open the Xcode project:

- `Immersive Reader.xcodeproj`

Or build from the command line:

```bash
xcodebuild -project "Immersive Reader.xcodeproj" -scheme "Immersive Reader" -destination 'generic/platform=iOS Simulator' build
```

## Notes

- The upload server is intended for devices on the same local network.
- HTTP upload accepts `.epub`, `.ttf`, and `.otf` files.
- Uploaded `.ttf` and `.otf` files are auto-imported into `Settings > Reader > Custom Fonts` using the same code path as the in-app custom font importer.
- Read-aloud features depend on EPUB media overlays being present and parsed successfully.
- Readium scroll mode in this setup is per-resource rather than a fully stitched whole-book vertical scroll.
