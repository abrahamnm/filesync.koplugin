# FileSync - Wireless File Manager for KOReader

[English](README.md) | [Español](README.es.md) | [Português](README.pt_BR.md) | [中文](README.zh_CN.md) | [العربية](README.ar.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Русский](README.ru.md) | [日本語](README.ja.md) | [한국어](README.ko.md)

A KOReader plugin that launches a local web server on your e-reader and displays a QR code on screen. Scan the code with your phone to open a polished web interface for managing books and files wirelessly — no cables, no apps, just your browser.

Works on devices running KOReader (designed for **Kindle** and **Kobo**), including non-touch, keypad-only e-readers — the on-device screens are fully operable with the D-pad and physical keys.

<p align="center">
  <img src="screenshots/qr-screen.png" alt="QR code screen on e-reader" width="500">
</p>
<p align="center">
  <img src="screenshots/web-home.png" alt="QR code screen on e-reader" width="250">
  &nbsp;&nbsp;&nbsp;
  <img src="screenshots/web-directory.png" alt="Web interface - home" width="250">
  &nbsp;&nbsp;&nbsp;
  <img src="screenshots/web-file-detail.png" alt="Web interface - file detail" width="250">
</p>

## Features

- **QR Code Access** — Scan to connect instantly, no typing URLs
- **File Browser** — Navigate your library with breadcrumb navigation
- **Upload Files** — Drag-and-drop or tap to upload books from your phone
- **Download Files** — Save any file to your phone with one tap
- **Create Folders** — Organize your library into directories
- **Rename & Delete** — Limited file management with confirmation dialogs
- **Search & Sort** — Filter by name, sort by name/size/date/type
- **Dark & Light Themes** — Auto-detected or toggled manually
- **Multiple View Modes** — List, grid, and large grid views
- **Multi-Language Support** — Available in 10 languages (English, Spanish, Portuguese, Chinese, Arabic, French, German, Russian, Japanese, Korean)
- **RTL Layout Support** — Full right-to-left layout for Arabic
- **Sleep Prevention** — Keeps device awake and WiFi alive while the server runs
- **Safe Mode** — Show only books and images, hiding system files
- **Responsive UI** — Designed for smartphones, works on any screen
- **Touch and Key Navigation** — On-device screens work with taps or with the D-pad/physical keys on non-touch readers

## How It Works

1. Connect your e-reader to WiFi
2. Open the FileSync plugin from KOReader's Network Tools menu
3. A QR code appears on the e-reader screen
4. Scan it with your phone (connected to the same WiFi)
5. Manage your books from the web interface in your phone's browser

## Installation

### Prerequisites

- A device with [KOReader](https://github.com/koreader/koreader) installed
- Both your e-reader and phone on the same WiFi network

### Option 1: From Release Archive (Recommended)

1. Download the latest release `.zip` from the [Releases](../../releases) page
2. Extract the archive
3. Copy the `filesync.koplugin` folder to your device's KOReader plugins directory (see paths above)
4. Restart KOReader

### Option 2: Direct Copy

1. Connect your e-reader to your computer via USB

2. Locate the KOReader plugins directory:
   - **Kindle:** `/mnt/us/koreader/plugins/`
   - **Kobo:** `.adds/koreader/plugins/` (on the root of the SD card)

3. Copy the entire `filesync.koplugin` folder into the plugins directory:
   ```
   plugins/
   ├── filesync.koplugin/
   │   ├── _meta.lua
   │   ├── main.lua
   │   └── filesync/
   │       ├── filesyncmanager.lua
   │       ├── httpserver.lua
   │       ├── fileops.lua
   │       ├── filesync_i18n.lua
   │       ├── json.lua
   │       ├── mobi.lua
   │       ├── utils.lua
   │       ├── static/
   │       │   └── index.html
   │       └── i18n/
   │           ├── en.po
   │           ├── es.po
   │           ├── pt_BR.po
   │           ├── zh_CN.po
   │           ├── ar.po
   │           ├── fr.po
   │           └── ...
   ├── other.koplugin/
   └── ...
   ```

4. Safely eject and restart KOReader

### Verifying Installation

After restarting KOReader, open the top menu and navigate to:

**Network → FileSync**

If you see the menu entry, the plugin is installed correctly.

## Usage

### Starting the Server

0. Make sure your device is connected to WiFi
1. Open KOReader's top menu
2. Navigate to **Network → FileSync**
3. Tap **Start file server**
4. A QR code will appear on screen with the connection URL

<p align="center">
  <img src="screenshots/menu.png" alt="FileSync menu in KOReader" width="350">
  &nbsp;&nbsp;&nbsp;
  <img src="screenshots/qr-screen.png" alt="QR code screen" width="350">
</p>

### Connecting from Your Phone

1. Make sure your phone is on the **same WiFi network** as the e-reader
2. Open your phone's camera and scan the QR code
3. Tap the link to open the web interface in your browser
4. Alternatively, type the URL shown below the QR code manually

### Managing Files

Once connected, the web interface lets you:

- **Browse** — Tap folders to navigate your library. Use the breadcrumb bar at the top to jump back to any parent directory.
- **Upload** — Tap the **Upload** button in the header, then choose files or drag them into the drop zone. Multiple files can be uploaded at once.
- **File details** — Tap any file to open its detail view, where you can **download**, **rename**, or **delete** it.
- **Create folders** — Tap the **Folder** button in the header and enter a name.
- **Search** — Use the search bar to filter the current directory by filename.
- **Sort** — Use the dropdown to sort by name, date, size, or type in ascending or descending order.

<p align="center">
  <img src="screenshots/web-home.png" alt="File browser - home" width="250">
  &nbsp;&nbsp;
  <img src="screenshots/web-directory.png" alt="File browser - directory with upload" width="250">
  &nbsp;&nbsp;
  <img src="screenshots/web-file-detail.png" alt="File detail view" width="250">
</p>

### Sleep Prevention

While the file server is running, the plugin automatically prevents your device from going to sleep or suspending. This keeps the server accessible and WiFi connected without interruption. Specifically:

- **Standby** and **suspend** are blocked so the device stays awake
- **Auto-suspend** and **auto-standby** timers are temporarily disabled
- **WiFi keepalive** is enabled to maintain the network connection

All settings are restored to their previous values when the server is stopped. If the device somehow suspends (e.g., due to critically low battery), the server will automatically restart when the device wakes up.

### Stopping the Server

- Tap **Stop file server** from the plugin menu, or
- The server stops automatically when you exit KOReader

### Simple UI Quick Action

If you also use the [Simple UI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) plugin, FileSync publishes the server toggle as a quick action so it can be added to Simple UI's bottom bar or homescreen. Pick **File server** from Simple UI's quick action list — its label follows the server state (**Start file server** / **Stop file server**).

The toggle is also available as a gesture action: **Settings → Taps and gestures → Gesture manager → General → Toggle FileSync server**.

### Changing the Port

1. Open the plugin menu
2. Tap **Server port**
3. Enter a port number between 1 and 65535 (default: 80)
4. Restart the server for the change to take effect

> **Note:** The default port 80 lets you reach the server by typing just the device IP (`http://192.168.1.5`), with no `:port` suffix. Ports below 1024 are privileged and only work when KOReader runs as root (e.g. on Kobo and Kindle). On Android and desktop the bind fails and the server automatically falls back to port 8080, so the URL becomes `http://192.168.1.5:8080`.

### Safe Mode

Safe mode is **enabled by default** and limits the web interface to only show files relevant to your reading library. When enabled:

- Only **ebooks** (EPUB, PDF, MOBI, AZW3, FB2, DJVU, CBZ, etc.), **documents** (TXT, DOC, RTF, HTML, etc.), and **images** (JPG, PNG, GIF, WebP) are shown
- System files, configuration files, and other non-book files are hidden
- Hidden files and folders (names starting with `.`) are hidden
- KOReader metadata directories (`.sdr` folders) are hidden and automatically cleaned up when deleting a book

To toggle safe mode, open the plugin menu and tap **Safe mode**. Disabling it will show every file on the device, including hidden files and folders, which are dimmed in the listing to set them apart.

## Troubleshooting

**Plugin doesn't appear in the menu**
- Ensure the folder is named exactly `filesync.koplugin` (case-sensitive)
- Check that `_meta.lua` and `main.lua` are directly inside the folder (not nested)
- Restart KOReader completely

**"WiFi is not enabled" error**
- Connect your e-reader to a WiFi network before starting the server
- Some devices require WiFi to be explicitly enabled in KOReader's network settings

**Phone can't connect**
- Verify both devices are on the same WiFi network
- Try typing the URL manually instead of scanning the QR code
- Check if your router has client isolation enabled (prevents devices from seeing each other)
- On Kindle: the plugin manages firewall rules automatically, but a restart may help if rules are stuck

**Upload fails**
- Check available storage space on the device
- Very large files may time out — try uploading smaller batches
- Ensure the target directory is writable
- The maximum upload size is 1 GB per file

**Large file uploads slow the device**
- Uploading files over 100 MB may cause the e-reader UI to become temporarily unresponsive during the transfer. This is normal — the device has limited processing power. The UI will recover once the upload completes.

## Contributing

Contributions are welcome!

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run the test suite (see below)
5. Test on a real device if possible
6. Submit a pull request

### Running Tests

The project uses [busted](https://lunarmodules.github.io/busted/) for unit testing. Tests cover the pure-logic functions (JSON encode/decode, path validation, version parsing, etc.) and do not require a KOReader environment.

**Install busted** (if not already installed):

```bash
luarocks install busted
```

**Run all tests:**

```bash
busted
```

This runs 208+ tests across 6 spec files. You should see output like:

```
208 successes / 0 failures / 0 errors / 0 pending : 0.04 seconds
```

**Run a specific spec file:**

```bash
busted spec/json_spec.lua
```

**Test files:**

| File | Covers |
|------|--------|
| `spec/json_spec.lua` | JSON encode/decode round-trips, edge cases, error handling |
| `spec/fileops_spec.lua` | Path traversal prevention, filename validation, size formatting, MIME types |
| `spec/updater_spec.lua` | Version parsing, version comparison, changelog extraction |
| `spec/utils_spec.lua` | Plugin directory resolution, shell escaping |
| `spec/httpserver_spec.lua` | URL decoding, query string parsing |

When adding new features, please add corresponding tests for any pure-logic functions.

## License

This project is licensed under the [AGPLv3](https://www.gnu.org/licenses/agpl-3.0.html), consistent with the KOReader project.
