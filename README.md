# Squeeze Native

A simple Windows app that converts any video into a YouTube-ready **H.264 MP4** with a capped bitrate. It is made to be easy to use with just the mouse: add your videos, pick a folder, press **Start**.

It was built for old, low-end PCs (for example an Intel Core i5 4th gen with 4 GB RAM), so it processes one video at a time and runs at slightly lower priority to keep the computer usable while it works.

![Windows](https://img.shields.io/badge/Windows-10%20%2F%2011-blue) ![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE) ![FFmpeg](https://img.shields.io/badge/powered%20by-FFmpeg-green)

## Features

- **Any video format**: MTS, M2TS, TS, MOV, MKV, AVI, MP4, WMV, FLV, WEBM, MPG, VOB, 3GP, MXF and more
- **Batch conversion**: add many files, a whole folder, or drag and drop
- **Fixed bitrate cap**: 750 KBps (kilobytes per second, which is 6000 kbps) by default, and you can change it
- **Quality first**: uses the `libx264` software encoder with three speed settings
- **Resolution choice**: Automatic, Keep original, 2160p, 1440p, 1080p, 720p, 480p or 360p
- **Target file size**: type a size (for example 200 MB) and every video in the list is converted to about that size
- **Camcorder friendly**: interlaced footage (such as AVCHD `.MTS`) is deinterlaced automatically
- **Smart audio**: AAC audio is copied untouched, anything else is converted to AAC 192k
- **Safe**: your original files are never changed or overwritten
- **Update checker**: can check this GitHub repository for new versions

## Requirements

- Windows 10 or 11 (PowerShell 5.1 is already included)
- **FFmpeg**, installed once with winget. Open Command Prompt and run:

  ```
  winget install "FFmpeg (Essentials Build)"
  ```

  If the app says FFmpeg was not found right after installing, restart the PC once.

## Installation

1. Click **Code > Download ZIP** on this page and extract it, or download `VideoConverter.ps1` and `Start Converter.bat`.
2. Keep both files **in the same folder** (for example `C:\SqueezeNative` or your Desktop).
3. Double-click **Start Converter.bat**.

If Windows SmartScreen shows a warning the first time, click **More info** and then **Run anyway**.

## How to use

1. **Pick your videos** with *Add videos...* or *Add a folder...*, or drag and drop files into the list. You can also drop files onto `Start Converter.bat`.
2. **Choose the output folder** with *Change...*. The choice is remembered.
3. **Options** (all optional, the defaults are good):
   - **Max bitrate**: the video bitrate cap in KBps
   - **Speed**: Fast, Balanced (default) or Best quality
   - **Resolution**: see the table below
   - **Make every video about this size**: tick it and type a size in MB or GB
4. Press the green **START CONVERTING** button. Two progress bars show the current video and the whole batch, with the time left and conversion speed. **Cancel** stops it at any time.

When it finishes you get a summary and an option to open the output folder. Converted files are saved as `.mp4` with the same name as the original.

## Options in detail

### Speed

| Setting | x264 preset | Use it when |
| --- | --- | --- |
| Fast | `veryfast` | you are in a hurry |
| Balanced (default) | `faster` | you want a good mix of speed and quality |
| Best quality | `medium` | quality matters most and you can wait |

### Resolution

| Setting | What it does |
| --- | --- |
| Automatic (default) | Keeps the original size, but shrinks anything above 4K to 1080p |
| Keep original size | Never resizes |
| 2160p / 1440p / 1080p / 720p / 480p / 360p | Sets the shorter side of the video to that value (works for portrait videos too) |

Videos that are already smaller than the chosen resolution are **never enlarged**. When you choose a lower resolution, the bitrate cap is lowered to match (never below 600 kbps) so you do not get huge files at small sizes.

### Target file size

Tick **Make every video about this size** and enter a size. For each video, the app works out the bitrate needed from its length and audio. Things to know:

- The size is **approximate**. The app aims about 5% under what you typed, but short clips can still land a bit off.
- The max bitrate still applies, and a video is never padded beyond what its source needs. If the size you asked for is more than a video can use, the file ends up smaller.
- If the size is too small for the video's length, quality will be low and the file may come out bigger than asked. The log box at the bottom tells you when this happens.
- For very small sizes the audio is lowered to 96k to save space.
- The checkbox is switched off every time the app starts.

## How it converts

- **Video**: H.264 (High profile), 4:2:0, `libx264`, with `-b:v`, `-maxrate` and a matching buffer so the bitrate stays under the cap. Single pass, because two-pass would double the time on slow PCs.
- **Container**: MP4 with `faststart`, closed GOP.
- **Audio**: the first audio track only. AAC is copied as it is. Anything else (such as the Dolby Digital AC-3 in `.MTS` files) becomes AAC 192k, and 5.1 sound is mixed down to stereo.
- **Interlaced video**: detected with `ffprobe` and deinterlaced with `yadif` so motion does not show comb lines.
- **Low-bitrate sources**: a video that is already below the cap is not padded up. It gets about 1.25 times its own bitrate instead.
- **Safety**: output goes to a temporary `.part.mp4` file first, which is renamed only when the conversion succeeds. Failed or cancelled files leave nothing behind. If a file with the same name exists, a number is added, such as `clip (1).mp4`.

## Updates

The app checks this repository when it starts, and the **Check for updates** button does it on demand. If the version number in the repository is higher, it asks whether to update. Saying yes downloads the new `VideoConverter.ps1`, keeps the old one as `VideoConverter.ps1.bak`, and restarts the app. If you are offline, the automatic check does nothing.

### For the maintainer

Open `VideoConverter.ps1` in Notepad and set these lines near the top:

```powershell
$AppVersion = '1.1.2'
$UpdateRepo = 'YOUR-GITHUB-USERNAME/YOUR-REPO'
$UpdateBranch = 'main'
```

To release an update, raise `$AppVersion`, then upload the file to the repository. The repository must be **public**, because the app reads the raw file without signing in. If you rename `VideoConverter.ps1`, also change `$UpdateFile` and the file name inside `Start Converter.bat`.

## Where settings are stored

Your output folder, bitrate, speed and resolution choices are saved in `%APPDATA%\VideoConverter\settings.json`. Delete that file to reset everything.

## Troubleshooting

| Problem | What to do |
| --- | --- |
| "FFmpeg was not found" | Run the winget command above, then restart the PC once |
| A video shows **FAILED** | Check the log box at the bottom of the window for the reason. Damaged files and unusual formats are the usual cause |
| It is slow | Use the **Fast** speed setting, or lower the resolution. Software encoding on an old CPU is slow for 1080p60 |
| The window does not appear | Make sure `VideoConverter.ps1` and `Start Converter.bat` are in the same folder |

## Credits

Built with [FFmpeg](https://ffmpeg.org/) and Windows PowerShell.
