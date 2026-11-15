# Reaper Plugin Picker

**Version:** 1.0

A visual, screenshot-based plugin browser for REAPER. Build a curated FX library, organize plugins into groups, search, and add plugins to tracks or takes.

## Features

* Curated library populated from REAPER's installed effects.
* Grid and list views with a draggable tile-size slider. Hold **Ctrl** and scroll over the browser to zoom; the minimum size switches to List view.
* A dice button selects and scrolls to a random plugin from the currently visible results. It only highlights the plugin; it does not insert it.
* Search and category filters for browsing the library.
* Multi-group memberships. Alt-click to select multiple plugins, then right-click a selected plugin and toggle memberships in **Groups**.
* Double-click or press **Enter** to add the selected plugin. Drag tiles to tracks for drag-and-drop insertion.
* Target routing to selected tracks, the master track, or selected items' take FX.
* Manual or automated PNG screenshot capture, plus customizable colors, themes, fonts, and layout.
* Optional REAPER toolbar toggle-state integration.

## Requirements

* REAPER 6.0 or newer is recommended.
* **ReaImGui** is required. Install it through **Extensions > ReaPack > Browse packages**, then restart REAPER.
* **js_ReaScriptAPI** is optional. It enables screenshot capture and improves off-window mouse tracking during drag-and-drop.
* ReaPack is recommended for installing the extensions and the script.

## Installation

### ReaPack

1. Add this repository in ReaPack using:
   `https://github.com/sonicwave03/reaper-plugin-picker/raw/main/index.xml`
2. Browse packages and install **reaper-plugin-picker.lua**.
3. Run **Reaper Plugin Picker** from REAPER's Action List, or bind it to a shortcut or toolbar button.

### Manual

1. Install ReaImGui, then copy `script/reaper-plugin-picker.lua` into REAPER's `Scripts` folder.
2. In REAPER, open the Action List (`?`), choose **New action... > Load ReaScript...**, and select the Lua file.
3. Run the action or bind it to a shortcut or toolbar button.

## Using the Picker

### Build and browse your library

1. Click **Add plugins** and choose installed effects to add to your library. Use the search, category filters, or **Add all shown** / **Remove all shown**.
2. Use the group tabs to filter the library. Click **+** to create a group.
3. Drag the grid-size slider to resize tiles, or hold **Ctrl** and scroll over the browser. At the slider minimum, the browser switches to List view.
4. Click the dice button in the lower-right to highlight a random plugin from the current results.

### Groups and multi-selection

* Right-click a plugin and open **Groups** to toggle its group memberships or **Clear all groups**.
* Alt-click plugins to select or deselect multiple items. Right-click one of the selected plugins to apply group changes to the selection.
* Right-click a group tab to rename or delete it.

### Add plugins to a project

Choose **Selected tracks**, **Master track**, or **Selected items (take FX)** from the target dropdown. Double-click a tile or press **Enter** to add the selected plugin. You can also drag a tile onto a track. A single-click selects a tile.

### Screenshots

* In **Settings**, enable **Auto-capture when adding to library**, or use **Capture all missing** / **Re-capture all**.
* To capture manually, right-click a tile and choose **Capture screenshot**. With an Alt-selected batch, the menu offers a batch screenshot action.
* Capture methods are **Screen grab** and **Window copy**. Capturing briefly opens each plugin on a temporary track.
* You can also place your own PNG files in the screenshots folder. Filenames are based on the full FX name, with unsupported characters replaced by underscores.

## Controls

| Input | Action |
| :--- | :--- |
| Type in search | Filter plugins using space-separated terms |
| Category dropdown | Filter by plugin category |
| Grid-size slider | Resize tiles; minimum switches to List view |
| Ctrl + mouse wheel over browser | Zoom grid tiles in or out |
| Dice button | Highlight and scroll to a random visible plugin |
| Left / Right arrows | Move selection horizontally in Grid view when search is empty |
| Up / Down arrows | Move selection vertically |
| Enter | Add the selected plugin to the active target |
| Esc | Clear search, or close the picker when search is empty |
| Alt-click a tile | Add or remove it from the multi-selection |
| Right-click a tile | Open add, screenshot, group, and remove actions |
| Right-click a group tab | Rename or delete the group |

## Settings and Data

Picker settings, including the selected theme and layout, are stored in REAPER's ExtState under `VisualPluginPicker`.

On Windows, the picker stores its accessible data in:

`%USERPROFILE%\Documents\REAPER Plugin Picker\`

* `library.txt` — plugin names and group memberships.
* `groups.txt` — group definitions.
* `themes.txt` — saved color themes.
* `shots\*.png` — plugin screenshots.

On first run, existing data is moved from `<REAPER resource path>\Data\VisualPluginPicker\` when the corresponding destination file does not already exist. Existing files in Documents are preserved rather than overwritten. If the Windows user-profile path is unavailable, the picker uses the REAPER resource folder instead.
