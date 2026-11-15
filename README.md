# Reaper Plugin Picker

**Version:** 1.0

A visual, screenshot-based plugin browser for REAPER. Build a curated FX library, organize plugins into groups, search, and add plugins to tracks or takes.

## Features

* Curated library populated from REAPER's installed effects.
* Grid and list views with a draggable tile-size slider. Hold **Ctrl** and scroll over the browser to zoom; the minimum size switches to List view.
* A dice button selects and scrolls to a random plugin from the currently visible results. It only highlights the plugin; it does not insert it.
* Search, quick category chips, and a filter popover for category and vendor filtering. Vendor names are inferred from REAPER's plugin names; effects without vendor metadata appear as **Unknown**, and JS effects as **JSFX**.
* Plugin cards show the vendor beneath the plugin name.
* Per-plugin display names, category overrides, and vendor overrides from the tile's right-click menu.
* Multi-group memberships. Ctrl-click to select multiple plugins, then right-click a selected plugin and toggle memberships in **Groups**.
* Double-click or press **Enter** to add the selected plugin. Drag tiles onto a track or an open track FX chain to add the effect; drops into a chain append it at the end.
* Target routing to selected tracks, the master track, or selected items' take FX.
* Manual or automated PNG screenshot capture, plus customizable colors, themes, fonts, and layout.
* Optional REAPER toolbar toggle-state integration.

## Requirements

* REAPER 6.0 or newer is recommended.
* **ReaImGui** is required. Install it through **Extensions > ReaPack > Browse packages**, then restart REAPER.
* **js_ReaScriptAPI** is optional. It enables screenshot capture, FX-chain drop targeting, and more reliable off-window mouse tracking during drag-and-drop.
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

1. Click **Add plugins** and choose installed effects to add to your library. Use the search, category chips, or filter popover, or **Add all shown** / **Remove all shown**.
2. Use the **All** and **Favorites** tabs or your group tabs to filter the library. Right-click a plugin and toggle **Groups > Favorites** to add or remove it from Favorites. Click the group-plus icon to create a group.
3. Drag the grid-size slider to resize tiles, or hold **Ctrl** and scroll over the browser. At the slider minimum, the browser switches to List view.
4. Click the dice button in the lower-right to highlight a random plugin from the current results.

### Groups and multi-selection

* Right-click a plugin and open **Groups** to toggle its group memberships or **Clear all groups**.
* Ctrl-click plugins to select or deselect multiple items. Right-click one of the selected plugins to apply group changes to the selection.
* Drag custom group tabs onto the left or right side of another group to rearrange them; **All** and **Favorites** stay pinned. Right-click a custom group tab to rename or delete it.

### Edit category and vendor

Right-click a plugin and choose **Edit category and vendor...**. Choose **Automatic** to restore its detected category; clear the vendor field or click **Use detected** to restore the detected vendor. Overrides are saved per plugin and update the browser filters.

### Rename a plugin

Right-click a plugin and choose **Rename plugin...** to change the name shown in the picker. Leave the field blank to restore the detected name. This does not rename the plugin in REAPER; the custom name is saved in `plugin-metadata.txt`.

### Add plugins to a project

Choose **Selected tracks**, **Master track**, or **Selected items (take FX)** from the target dropdown. Double-click a tile or press **Enter** to add the selected plugin. You can also drag a tile onto a track in Arrange/TCP or the Mixer, or into an open track FX-chain window. A drop into an FX chain appends the plugin to that chain. FX-chain drops require js_ReaScriptAPI; a single-click selects a tile.

### Screenshots

* In **Settings**, enable **Auto-capture when adding to library**, or use **Capture all missing** / **Re-capture all**.
* To capture manually, right-click a tile and choose **Capture screenshot**. With a Ctrl-selected batch, the menu offers a batch screenshot action.
* Capture methods are **Screen grab** and **Window copy**. Capturing briefly opens each plugin on a temporary track.
* You can also place your own PNG files in the screenshots folder. Filenames are based on the full FX name, with unsupported characters replaced by underscores.

## Controls

| Input | Action |
| :--- | :--- |
| Type in search | Filter plugins using space-separated terms |
| Category chips | Quickly filter by common categories; click the active chip to clear |
| Filter icon | Open all category/vendor filters and clear them |
| Grid-size slider | Resize tiles; minimum switches to List view |
| Ctrl + mouse wheel over browser | Zoom grid tiles in or out |
| Dice button | Highlight and scroll to a random visible plugin |
| Left / Right arrows | Move selection horizontally in Grid view when search is empty |
| Up / Down arrows | Move selection vertically |
| Enter | Add the selected plugin to the active target |
| Esc | Clear search, or close the picker when search is empty |
| Ctrl-click a tile | Add or remove it from the multi-selection |
| Right-click a tile | Open add, rename, metadata, screenshot, group, and remove actions |
| Right-click a group tab | Rename or delete the group |

## Settings and Data

Picker settings, including the selected theme and layout, are stored in REAPER's ExtState under `VisualPluginPicker`.

On Windows, the picker stores its accessible data in:

`%USERPROFILE%\Documents\REAPER Plugin Picker\`

* `library.txt` — plugin names and group memberships.
* `plugin-metadata.txt` — custom display names, category overrides, and vendor overrides.
* `groups.txt` — group definitions.
* `themes.txt` — saved color themes.
* `shots\*.png` — plugin screenshots.

On first run, existing data is moved from `<REAPER resource path>\Data\VisualPluginPicker\` when the corresponding destination file does not already exist. Existing files in Documents are preserved rather than overwritten. If the Windows user-profile path is unavailable, the picker uses the REAPER resource folder instead.
