# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), with versions numbered
`<major>.<minor>` and a two-digit minor (v1.00, v1.01 ... v1.10) to match the release folder names.

## [Unreleased]

## [1.00] - 2026-11-25
First release.

### Added
- Checks videos (files or whole folders, dropped or added) with ffprobe and marks each Plays, Quick fix, Sound fix, Convert or Can't read, with the reasons.
- Targets: Sony BRAVIA XR-42A90K (from Sony's Help Guide list), Samsung TV, LG TV, any 4K smart TV, older HD TV, phones and tablets, Plex/Jellyfin/Emby direct play, and My own choice (file type, picture, sound, largest size).
- Converts only what's needed: the picture is copied untouched when it plays, MP4 or MKV is picked to keep it, otherwise H.264 (or HEVC for 4K and HDR); sound converted per track; every language, subtitle (where the file type can hold it) and chapter kept.
- Text subtitles saved as .srt files beside the video too (optional); subtitle files beside the original copied with it.
- HDR kept for HDR TVs, turned into normal colours for the rest; interlaced video de-interlaced; pictures bigger than the target plays made smaller.
- Preview: picture, streams, reasons, what converting will do, Play, Open folder and Try 20 seconds (with the whole file's estimated size).
- Batch converting with progress, time left, Pause/Resume, Stop, taskbar progress and no sleep while working. Each new file is checked before the original is touched.
- Graphics card encoding (NVIDIA NVENC, Intel Quick Sync, AMD AMF) when one works on the PC, test-run at start, with automatic fallback to the processor.
- Utilities for one video: keep or remove sound and subtitle tracks and pick the main sound, trim, GIF (shown first, then saved where you choose), small clip, sound out of step, split by time or chapters, shrink under a size, save the sound (as it is or MP3), save subtitles as .srt/.sup, save a picture and contact sheet (both shown first, then saved where you choose), old tape and DVD clean-up, cover and title, make it louder (EBU R128), turn it, remove tags.
- More menu: join videos, find duplicates, stats (with all-time space saved), report as CSV for Excel or HTML, save and open the list (kept between runs too), convert at a set time.
- When done: copy or move each finished video to a folder, notification and sound, sleep or shut down after the list (60 seconds to cancel).
- Choices: quality, file type, picture format, save next to the original or in a chosen folder, keep or recycle originals.
- FFmpeg found automatically (PATH, winget, scoop, Chocolatey), with Install FFmpeg (winget) and Choose ffmpeg.exe.
- Light, Dark or the same as Windows, Help and About.
