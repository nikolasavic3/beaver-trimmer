# VLC Trimmer

A powerful VLC extension for trimming videos on the fly with smart filename handling and batch processing capabilities.

## What is this?

Ever found yourself needing to quickly trim multiple videos while reviewing footage? Beaver Trimmer turns VLC into a streamlined video editing workflow. Set your in/out points, click a folder button, and you're done. The extension handles the FFmpeg command and generates intelligent filenames based on your original video's timestamp.

Perfect for:
- Dashcam footage review
- Security camera clips
- Lecture recordings
- Stream archives
- Any situation where you're trimming timestamped videos in bulk

## Key Features

- **One-click trimming** - Set start/end times and save to predefined folders with a single button press
- **Smart timestamp handling** - Automatically adjusts timestamps in filenames (supports YYYYMMDDHHMMSS format and variations)
- **Batch workflow** - Trim, move originals to folders, and jump to the next video without leaving VLC
- **Five customizable output folders** - Configure your own folder structure
- **Precision controls** - Fine-tune trim points with ±1s and ±10s buttons
- **Complete history tracking** - See all your trims and moves with full file paths
- **Flexible filename patterns** - Custom regex support for different timestamp formats

## Installation

### Requirements
- VLC Media Player (3.0 or newer)
- FFmpeg installed and accessible from command line

### Install the extension

Find your VLC extensions folder:

**Windows:**
```
C:\Users\[YourName]\AppData\Roaming\vlc\lua\extensions\
```

**macOS:**
```
~/Library/Application Support/org.videolan.vlc/lua/extensions/
```

**Linux:**
```
~/.local/share/vlc/lua/extensions/
```

**Note:** If you have multiple VLC installations, you may need to check which one is active. On Linux/macOS, use `which vlc` or `whereis vlc` to find the running version, then look for the corresponding extensions folder. Common additional locations include `/usr/share/vlc/lua/extensions/` or `/usr/local/share/vlc/lua/extensions/`.

Create the folders if they don't exist, then copy `beaver_trimmer.lua` into the extensions folder.

### Restart VLC
Find Beaver Trimmer under `View → Video Trimmer`

## Quick Start

1. Open a video in VLC
2. Launch the extension from `View → Video Trimmer`
3. Play your video and click "⏺ Capture" at your desired start point
4. Continue playing and click "⏺ Capture" for the end point (or manually enter times)
5. Click one of the folder buttons to trim and save

The trimmed video appears in your chosen subfolder with an updated timestamp in the filename.

## Configuration

Edit the `FOLDER_CONFIG` table at the top of the script to customize your folders:
```lua
local FOLDER_CONFIG = {
    {name = "(current)", path = ""},
    {name = "clips", path = "clips"},
    {name = "trimmed", path = "trimmed"},
    {name = "processed", path = "processed"},
    {name = "archive", path = "archive"}
}
```

Change the `name` and `path` values to match your preferred folder structure. The first entry should remain as the current directory option.

## How Smart Naming Works

When enabled, Beaver Trimmer parses timestamps from your video filenames and adds the trim start time to create accurate new timestamps.

**Example:**
- Original file: `dashcam_20241031_143022.mp4`
- Trim starts at: 5 minutes 30 seconds into the video
- New filename: `dashcam_20241031_143352.mp4`

The extension automatically detects separators (`_` or `-`) and preserves your original filename structure.

## Regex Pattern Customization

Default pattern: `(%d%d%d%d%d%d%d%d)[_%-]?(%d%d%d%d%d%d)`

This matches:
- `YYYYMMDD_HHMMSS`
- `YYYYMMDD-HHMMSS`
- `YYYYMMDDHHMMSS`

Modify the regex pattern in the UI to match your specific filename format. The preview updates in real-time to show how files will be renamed.

## Workflow Tips

### Processing multiple videos:
1. Load several videos into your VLC playlist
2. Trim the current video
3. Use "Move Original & Play Next" buttons to file the original and automatically load the next video
4. Repeat

### Keyboard shortcuts:
- Space: Play/Pause
- Shift+Left/Right: Jump 3 seconds
- Alt+Left/Right: Jump 10 seconds
- Combine with the capture buttons for quick trimming

## Troubleshooting

### "Trim failed" error
- Verify FFmpeg is installed: run `ffmpeg -version` in terminal/command prompt
- On Windows, add FFmpeg to your system PATH
- On macOS/Linux, install via package manager (`brew install ffmpeg` or `apt install ffmpeg`)

### Extension doesn't appear
- Check the file is in the correct extensions folder
- Verify the filename is `beaver_trimmer.lua` (or any `.lua` extension)
- Restart VLC completely

### Move operations not working
- Ensure target folders exist (the extension doesn't create them automatically)
- Check file permissions on the source and destination folders

## Technical Details

- Uses FFmpeg with `-c copy` for fast, lossless trimming
- Preserves original video/audio codecs
- No re-encoding (instant processing)
- Cross-platform: Windows, macOS, and Linux

## Contributing

Found a bug? Have a feature request? Open an issue on GitHub. Pull requests welcome.

**Note:** This extension executes FFmpeg and file operations on your system. Always back up important footage before batch processing.
