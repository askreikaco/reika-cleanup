# RAR Archiver

Turns every project folder into ONE `.rar` file (WinRAR), several folders at once, and removes the original files only after the archive has been tested. Built for large folder trees on Google Drive for desktop (`H:\Shared drives\...`) but works on any Windows folder tree.

**It deletes files.** Read "Safety rules" and run it on a COPY of one folder first. Provided as is, without warranty (see LICENSE).

## Requirements
- Windows 10/11, WinRAR (`Rar.exe`), PowerShell 7. `RUN.bat` installs missing pieces with winget when it can.

## Use
1. Put `RUN.bat` and `CLEANUP.ps1` in one folder and double-click `RUN.bat`.
2. `[1/2]` paste one or more folders (several: separate with `;`). A listed folder is either a folder that holds project folders, or a project folder itself.
3. `[2/2]` "Customize advanced config? Y/N" (default N = saved answers or defaults). Y asks: log folder, parallel jobs, CPU use, compression level, other archives, loose `.rar`, inner `.rar`, shortcuts, together/one by one.
4. Type `YES`. Output is one line per folder: `HH:mm:ss -- ADDED <folder> (4m57s) [n/N]`; a `reason:` line explains anything kept or skipped.

## What it does, per project folder `X`
- Builds `X\X.rar` (solid, recovery record, tested) or ADDS leftovers to an existing `X.rar`. WinRAR never deletes your files itself: the tool deletes a file only when the tested archive's own list has the same path and size, so a file that could only be read partly stays in the folder.
- Read errors (e.g. a cloud-only file Drive cannot read) never wait for a key press: retry twice, then ignore that file and continue; the archive must still pass its test.
- Never newly packs `.gdoc/.gsheet/.gslides/.lnk` (cloud pointers) and, by default, existing `.zip/.rar/.7z...` (they stay as they are).
- Cleans a file from the folder only when its relative path and size are in the archive's own file list.
- Duplicate archives `X (N).rar` are extracted into a temp folder, their files placed (missing: moved in; same size: dropped; different: kept as `name (dupN).ext`), then deleted once everything is placed.
- Duplicate folders `X (N)` beside `X` are merged into the OLDEST (by created date), also inside the merged folder; nothing is overwritten.
- Loose `X.rar` next to a folder `X` is moved into `X`. Stray `<sub>\<sub>.rar` archives left by older versions are removed only when the project `.rar` is proven to hold every file, or unpacked first and removed after the project `.rar` confirms them.
- Optional: a `.lnk` shortcut to a folder (e.g. Drive "shortcut to folder") becomes a real folder with a verified copy of its target; the shortcut is deleted only after every file is confirmed; the source is never touched.

## Safety rules
- Delete only when sure: test first, compare real file lists, delete after confirmation. A `.rar` is never deleted on a guess.
- The project `.rar` is tested (`rar t`) whenever a delete depends on it. `-Recheck` tests every project `.rar` (audit). `-Trust` skips tests (not recommended).
- The resume log (`logs\rar-archive-log.csv`) is for debugging only; no decision uses it.
- Several windows can run at once on DIFFERENT folders (per-folder lock files).

## Updates
On start the script reads a small `latest.txt` (version, download link, SHA-256), installs a newer `CLEANUP.ps1` after checking the hash, and keeps the old one in `old version\<version>\`. Set `UpdateUrl` in `RUN_settings.json` to point it elsewhere, or `UpdateUrl` to an unreachable address to disable checking.

## Files
`RUN.bat` launcher · `CLEANUP.ps1` the tool (`$ScriptVersion` semantic version) · `RUN_settings.json` your saved answers (created on first run) · `logs\` run logs and temp files.
