# Layout Editor Usage Guide

## Overview
The Layout Editor allows you to visually drag UI elements around and export the layout as JSON, which can then be used to generate permanent code changes.

## How to Use

### 1. Enable Edit Mode
- Press **Cmd+Shift+E** to toggle layout edit mode
- A blue indicator will appear in the top-left showing "Layout Edit Mode"

### 2. Drag Elements
- When edit mode is active, draggable views will show:
  - Blue outline around the view
  - Corner handles (blue circles)
  - Center drag handle
  - View ID label above the view
- Click and drag any view to reposition it
- Changes are saved automatically when you exit edit mode

### 3. Export Layout
- Press **Cmd+Option+E** to export the current layout to your Desktop
- The file will be named `mediadash_layout_YYYY-MM-DD_HH-mm-ss.json`
- Share this JSON file with the AI assistant to generate permanent code changes

### 4. Exit Edit Mode
- Press **Cmd+Shift+E** again to exit edit mode
- Layout changes are automatically saved

## Currently Draggable Views

- `sidebar` - The sidebar view in compact mode
- `stagingArea` - The staging area view in compact mode
- `dashboardButton` - The dashboard toggle button
- `dashboardView` - The entire dashboard view in dashboard mode

## Adding More Draggable Views

To make any view draggable, simply add `.draggableLayout(id: "yourViewId")` to it:

```swift
YourView()
    .draggableLayout(id: "yourViewId")
```

## Layout JSON Format

The exported JSON contains:
- `viewOffsets`: Dictionary of view IDs to their offset (x, y) values
- `viewPositions`: Dictionary of view IDs to their absolute positions (currently unused)
- `viewFrames`: Dictionary of view IDs to their frame rectangles (currently unused)

Example:
```json
{
  "viewOffsets": {
    "sidebar": {
      "width": 10,
      "height": -20
    },
    "stagingArea": {
      "width": 0,
      "height": 0
    }
  }
}
```

## Notes

- Layout changes are stored in UserDefaults and persist across app launches
- To reset all layout changes, you can clear the UserDefaults key `mediadash_layout_config`
- The layout editor only affects visual positioning via `.offset()` modifiers
- When sharing the JSON with the AI, ask it to "update ContentView.swift to match this layout"

