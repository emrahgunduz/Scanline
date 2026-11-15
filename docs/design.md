# Scanline — UI/UX design (Phase 2)

Fresh native macOS look (no external design system), SwiftUI.

## Requirements (from the user)

- Black and white output only.
- **Select Folder…** (file picker) and **Open in Finder**.
- Last scan shown fitted; zoom/pan with mouse and **− / + / Fit** (plus 1:1).
- Live list of files in the folder: preview, rename, delete.
- Progress of what the scanner is doing; countdown for auto-scan.
- Auto-scan on/off. Off: scanning starts with the scanner's top button (or Scan Now).
- Freely resizable window (no min/max limits beyond a sensible minimum).
- Modern, colorful, appealing; slick icon.

## Decisions (2026-11-15)

| Topic | Decision |
|---|---|
| Icon | **A · Beam**: white receipt crossed by a glowing yellow scan line on a violet → magenta → coral squircle. |
| Scanner button | Short press = scan now. **Long press = toggle Auto-scan.** |
| Appearance | **Light / Dark / Match system** segmented control in the toolbar. |
| File list order | **Newest first.** |
| Orientation | Receipts fed bottom-first or sideways are **turned upright automatically** (on-device text check: prices, dates, times, receipt words; quarter turns are tried only when a scan is wider than tall). Existing files: **Rotate Left / Right / 180°** (viewer header, right-click › Rotate). |

## Layout

- **Toolbar:** app mark + name · folder name and path (centre) · appearance segment · Auto-scan switch · **Scan Now** (accent).
- **Sidebar (300 pt):** "Saving to" folder tile, Select Folder… / Open in Finder, "Next file" name, live scan list (thumbnail, name, time · length · size). Selected row: Rename, Move to Trash (toast with Undo).
- **Activity card:** colored tile + plain-language title + detail, progress bar while busy, five-step track Paper → Feed → Scan → Clean up → Saved, button hint ("press to scan now · hold to turn Auto-scan on/off").
- **Viewer:** receipt on a dotted canvas, scroll/drag to pan, floating zoom pill (− · % · + · Fit · 1:1); coral scan line sweeps while scanning.

## Color roles

| Role | Light | Dark |
|---|---|---|
| Accent (buttons, selection) | `#5B4CF5` | `#5B4CF5`, text `#B4ABFF` |
| Ready / countdown | `#5B4CF5` on `#EEECFF` | tile on 18% tint |
| Scanning | `#FF5D3A` on `#FFEDE8` | tile on 18% tint |
| Cleaning up | `#F08C00` on `#FFF4DB` | tile on 18% tint |
| Saved | `#12B886` on `#E3F8F0` | tile on 18% tint |
| Stopped early | `#E8590C` on `#FFF4DB` | tile on 18% tint |
| Disconnected | `#868B9C` on `#F1F2F6` | tile on 18% tint |
| Window / sidebar | `#FFFFFF` / `#F3F4F9` | `#1B1C24` / `#20212B` |

Type: SF Pro (system), SF Mono / JetBrains Mono for file names. The receipt itself is always shown on white.
