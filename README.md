# Visual Plugin Picker (REAPER)

**Version:** 2.0  
A visual, screenshot-based plugin browser for REAPER built with ReaImGui. Curate a focused library of the plugins you actually use, organize them into custom group tabs, and insert them onto tracks or takes with a click or drag-and-drop.

---

## Features

* **Curated Plugin Library:** Pick only the plugins you want from your installed FX list (`Add plugins`) rather than scrolling through hundreds of unused effects.
* **Visual Tile Grid:** Displays plugins as customizable screenshot tiles with automatic thumbnail scaling and optional text labels.
* **Drag-and-Drop Insertion:** Drag any plugin tile directly onto a track in REAPER's Track Control Panel (TCP), Mixer, or Arrange view with a live cursor preview.
* **Flexible Target Routing:** Add plugins to **Selected tracks**, the **Master track**, or **Selected items (take FX)** via click or keyboard shortcuts.
* **Custom Group Tabs:** Organize your library into custom tabs (`+ Group`), move plugins between groups via right-click context menus, or view everything under `All`.
* **Instant Multi-Term Search:** Filter your library in real time by typing multiple space-separated keywords (e.g., `fab eq`).
* **Full Keyboard Navigation:** Navigate tiles with the arrow keys, press `Enter` to insert the selected plugin, and press `Esc` to clear search or close the window.
* **Automated Screenshot Capture:** Automatically opens plugins on a temporary track and captures their GUI to PNG files (requires `js_ReaScriptAPI`), or lets you supply your own PNGs.
* **Customizable Layout & Theme:** Adjust tile width, aspect ratio, behavior flags, and every UI color via hex codes or a built-in RGBA color picker.
* **Toolbar Toggle Integration:** Syncs toggle state with any REAPER toolbar button or menu item bound to the script action.

---

## Requirements

* **REAPER** (v6.0+ recommended)
* **[ReaPack](https://reapack.com/)** (recommended for installing dependencies)
* **ReaImGui** *(Required)* — Install via `Extensions > ReaPack > Browse packages > ReaImGui`, then restart REAPER.
* **js_ReaScriptAPI** *(Optional)* — Required for automated plugin screenshot capture and reliable off-window mouse tracking during drag-and-drop. Install via `Extensions > ReaPack > Browse packages > js_ReaScriptAPI`.

---

## Installation

1. Save the Lua script file (e.g., `Visual Plugin Picker.lua`) into your REAPER Scripts directory (`Options > Show REAPER resource path in explorer/finder`, then open the `Scripts` folder).
2. In REAPER, open the **Action List** (`?` key).
3. Click **New action... > Load ReaScript...** and select `Visual Plugin Picker.lua`.
4. Run the action from the Action List, or bind it to a keyboard shortcut or toolbar button.

---

## Usage

### 1. Building Your Library
1. Click **Add plugins** in the top-right bar.
2. Search or filter installed FX by format (`All`, `Instruments`, `VST`, `VST3`, `JS`, `CLAP`, etc.).
3. Click any plugin row to toggle it in (`[x]`) or out (`[ ]`) of your library, or use **Add all shown** / **Remove all shown** for batch changes.
4. Click **< Back** to return to the visual grid.

### 2. Capturing Screenshots
* **Automatic Capture:** Enable **Auto-capture when adding to library** under **Settings**, or click **Capture all missing** / **Re-capture all**. The script briefly loads each plugin on a temporary track, captures its floating window, and removes the track.
* **Single Plugin Capture:** Right-click any tile in the grid and select **Capture screenshot**.
* **Capture Methods:**
  * *Screen grab (Default):* Captures GPU-rendered plugin interfaces accurately; ensure the floating plugin window is unobstructed during capture.
  * *Window copy:* Captures the window device context directly without interference from overlapping windows (may produce black images on certain hardware-accelerated GUIs).
* **Manual PNGs:** Without `js_ReaScriptAPI`, you can manually place `.png` screenshots into `<REAPER Resource Path>/Data/VisualPluginPicker/shots/`. Filenames match the full FX name with unsupported characters replaced by `_`.

### 3. Organizing & Inserting Plugins
* **Insert via Click / Enter:** Select your destination in the bottom-left dropdown (**Selected tracks**, **Master track**, or **Selected items (take FX)**) and click a tile or press `Enter`.
* **Insert via Drag-and-Drop:** Click and drag any tile out of the picker window and drop it directly onto a track in REAPER.
* **Manage Groups:** Click **+ Group** to create a new tab. Right-click any tile and choose **Move to group** to assign it, or right-click a group tab to delete it.

---

## Controls & Shortcuts

| Input | Action |
| :--- | :--- |
| **Type in Search** | Filter plugins across all groups using space-separated terms |
| **Left / Right Arrows** | Move selection horizontally (when search bar is empty) |
| **Up / Down Arrows** | Move selection vertically across grid rows |
| **Enter** | Insert the currently highlighted plugin into the active target |
| **Esc** | Clear the active search query, or close the picker window |
| **Right-Click Tile** | Open context menu (Add, Capture screenshot, Move to group, Remove) |
| **Right-Click Tab** | Delete a custom group tab |

---

## Data & Configuration Storage

All user data and settings are stored locally and persist across sessions:

* **Settings & Theme Colors:** Saved in REAPER's `ExtState` under the `VisualPluginPicker` section.
* **Plugin Library:** `<REAPER Resource Path>/Data/VisualPluginPicker/library.txt` (tab-separated plugin name and assigned group).
* **Group Tabs:** `<REAPER Resource Path>/Data/VisualPluginPicker/groups.txt`
* **Screenshots:** `<REAPER Resource Path>/Data/VisualPluginPicker/shots/*.png`
