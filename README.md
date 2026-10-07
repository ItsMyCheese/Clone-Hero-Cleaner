# Clone Hero Duplicate Cleaner

A small Windows utility that finds and helps remove duplicate songs and "Bad Songs" in Clone Hero.

## Installation

**Put the cleaner directly inside your main Clone Hero songs folder.** This is the folder that contains all your individual song folders, albums, or song packs—not the folder where Clone Hero itself is installed.

1. Download the latest `CloneHeroCleaner` script.
2. Move the `.bat` file into your **main songs folder**.
3. Double-click the `.bat` file to open the cleaner.

For example, if your song library is `F:\Clone Hero Songs`, it should look like this:

```text
F:\Clone Hero Songs\
├── CloneHeroCleaner.bat       ← Put the cleaner here
├── Artist - Song 1\
│   └── song.ini
├── Artist - Song 2\
│   └── song.ini
└── Song Packs\
    └── Album\
        └── Another Song\
            └── song.ini
```

**Do not** put the cleaner in an individual song folder, the Clone Hero installation folder, or your Downloads folder. You only need **one copy** of the cleaner for your whole library, including subfolders.

The cleaner automatically uses the folder containing the `.bat` file as your song library. You do not need to edit the script to enter a folder path.

## How to use it

Start with **Option 1 — Check songs (nothing changes)**. This scans your library and creates a report so you can review what the cleaner found before moving or deleting anything.

The menu also includes:

- **Option 2 — Move extra and bad songs:** Moves selected folders to quarantine instead of permanently deleting them.
- **Option 3 — Move extras + delete the certain ones:** Moves uncertain items and permanently deletes items classified as unplayed.
- **Option 4 — Delete all extra and bad songs:** Permanently deletes selected folders. **Use with caution.**
- **Option 5 — Undo quarantine:** Restores songs that were moved to quarantine, when their original destinations are available.
- **Option 6 — Open the newest saved report:** Appears after a run so you can review the results.

Reports and quarantined songs are stored **next to** your main songs folder, not inside it.

After cleaning up your library, open Clone Hero and use **Scan Songs** to refresh the game's song list.

## Important

**Back up your song library and saved data before using permanent-deletion options.** Permanently deleted songs do not go to the Recycle Bin, and Undo Quarantine cannot recover them. The cleaner attempts to protect saved scores and avoid unsafe removals, but this does not replace a backup.

Clone Hero's `badsongs.txt` may include duplicate-chart errors or warnings. The cleaner does not automatically delete every entry simply because it appears in that file; it applies additional checks before selecting folders.

**Windows only.** The script uses Windows Batch and PowerShell.
