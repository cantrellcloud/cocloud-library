# Picture scripts report

> DEPRECATED: This report is kept for historical reference only. Use
> [scripts/pictures/RenameMoveFileToDateFolder.ps1](scripts/pictures/RenameMoveFileToDateFolder.ps1)
> for the current, supported workflow.

This report covers the following PowerShell scripts:

- [scripts/pictures/Get-FileMetaDataReturnObject.ps1](scripts/pictures/Get-FileMetaDataReturnObject.ps1)
- [scripts/pictures/RenameMoveFileToDateFolder.ps1](scripts/pictures/RenameMoveFileToDateFolder.ps1)
- [scripts/pictures/RenameMoveFileToDateFolder - Copy.ps1](scripts/pictures/RenameMoveFileToDateFolder%20-%20Copy.ps1)
- [scripts/pictures/RenameMoveFileToDateFolder - Copy (2).ps1](scripts/pictures/RenameMoveFileToDateFolder%20-%20Copy%20(2).ps1)

## 1) Get-FileMetaDataReturnObject.ps1

### What it does
Defines a single function, `Get-FileMetaData`, which:

- Accepts one or more **folder paths** (`-folder` parameter).
- For each folder, uses the Windows Shell COM API (`Shell.Application`) to enumerate items in the folder.
- For each file item, iterates metadata indices `0..266` and calls `Folder.GetDetailsOf(file, index)`.
- Builds and outputs one `PSObject` per file, adding a NoteProperty for each metadata field that has a non-empty value.

In practical terms: it returns “Explorer-style” metadata (Title, Authors, Date taken, Dimensions, etc.) as an object you can filter/sort.

### Key implementation notes / caveats
- **Slow by design**: loops through 267 possible metadata fields for every file.
- **Folder-only input**: the comment is correct; it expects a folder path, not a file path.
- Uses `Add-Member` with a hashtable argument (intended for `-NotePropertyMembers`). The code relies on positional binding and repeated calls.
- The `$hash` variable is used without an explicit initialization in the function body. In many PowerShell versions this can lead to brittle behavior; safest would be `$hash = @{}` before the `for` loop (this report does not change code; just noting the risk).

## 2) RenameMoveFileToDateFolder.ps1

### What it appears intended to do
This script looks like a **work-in-progress / diagnostic** version of a “rename-and-sort photos by date taken” script:

- Includes a copy of the same `Get-FileMetaData` function.
- Sets hard-coded paths:
  - Source: `F:\WorkingTemp\_Unsorted\`
  - Destination: `F:\WorkingTemp\_Sorted\`
- Attempts to read metadata recursively via:
  - `Get-FileMetaData -folder (Get-ChildItem $SourceDir -Recurse -Directory -Force).FullName`
- Loops through the returned metadata objects and tries to parse the `Date taken` field using multiple acceptable date/time formats.
- Prints a verbose block of diagnostics (`Write-Host`), and the actual rename/move block is commented out.

### Why it likely does not run successfully (current state)
There are several issues that would prevent this script from working as-is:

- Uses `continue` in path “workaround” blocks that are **not inside a loop**. `continue` is only valid inside loops/switch; used at top-level it throws an error.
- Both `$SourceDir` and `$DestDir` are already defined with a trailing `\`, so the `EndsWith('\\')` check is true, meaning the script hits the invalid `continue` path immediately.
- Contains an invalid standalone assignment line: `$ImgDateTaken =` (assignment with no value) which is a syntax error.
- Sets `$Img.Name = ""` and `$Img.'Date taken' = ""` before `$Img` exists (would error if reached).
- The “action” block (`Rename-Item` / `Move-Item`) is commented out, so even if parsing worked it only prints diagnostics.

## 3) RenameMoveFileToDateFolder - Copy.ps1

### What it does
This is the most “complete” and runnable version of the rename/sort script.

High level flow:

1. Defines `Get-FileMetaData` (same as above). (In this script, the metadata output is gathered but not actually used for the rename logic.)
2. Configures:
   - Source: `F:\WorkingTemp\_Unsorted\`
   - Destination: `F:\WorkingTemp\_Sorted\`
3. Finds image files recursively:
   - `Get-ChildItem $SourceDir -Include *.jpeg, *.png, *.gif, *.jpg, *.bmp, *.png -Recurse -Force`
   - Projects properties: `FullName, Name, BaseName, Extension`
4. For each image file:
   - Loads the image via `System.Drawing.Bitmap`.
   - Reads EXIF tag **36867** (`DateTimeOriginal`) via `GetPropertyItem(36867)`.
   - Converts bytes to an ASCII string like `yyyy:MM:dd HH:mm:ss\0`.
   - Parses and formats to `yyyyMMdd_HHmmss`.
   - Creates a destination subfolder `yyyy-MM-dd`.
   - Renames the file to `<yyyyMMdd_HHmmss><ext>` and moves it into that date folder.
5. Errors (e.g., missing EXIF DateTimeOriginal) are appended to an in-memory log and written to `<SourceDir>_errors.log` at the end.

### Key implementation notes / caveats
- Depends on **EXIF DateTimeOriginal**. Files without that tag (screenshots, edited images, many PNGs, etc.) will fall into the catch path.
- Uses `System.Drawing.Bitmap`. On Windows PowerShell 5.1 this often works; on PowerShell 7+, `System.Drawing` may require additional considerations (and is not fully supported cross-platform).
- Uses `Rename-Item` then `Move-Item`. If the destination already contains the renamed file, `Rename-Item` can fail.
- `Get-FileMetaData` and `$picMetadata` are present but unused in the rename pipeline.

## 4) RenameMoveFileToDateFolder - Copy (2).ps1

### What it appears intended to do
This version tries to do the same rename/sort operation but using **Shell metadata** (the `Date taken` field from `Get-FileMetaData`) instead of EXIF parsing via `System.Drawing`.

### Why it likely does not run successfully (current state)
Multiple logic/type issues prevent it from working as-is:

- `$ImgMetaData` is a collection of metadata PSObjects, not file objects. Later code assumes `$Img.Extension`, `$Img.FullName`, `$Img.Name` exist; in practice those properties are not guaranteed by `Get-FileMetaData`.
- `$ImgDateTaken = $Img | Select 'Date taken'` returns a wrapper object, not the raw string. It should access the property directly (e.g., `$Img.'Date taken'`).
- `DateTime.ParseExact($ImgDateTaken, "mm/dd/yyyy HH:mm:ss\0", $Null)`:
  - Uses `mm` (minutes) instead of `MM` (month) in the format string.
  - Includes a `\0` terminator that is not necessarily present in the Shell metadata string.
- `$NewFileName` is never assigned (commented out), but is used by `Rename-Item`, so rename will fail.

## Differences between scripts with similar names

### `RenameMoveFileToDateFolder.ps1` vs `RenameMoveFileToDateFolder - Copy.ps1`

- **Date source**:
  - `RenameMoveFileToDateFolder.ps1` tries to use Windows Shell “Date taken” metadata and parse it (multiple formats).
  - `RenameMoveFileToDateFolder - Copy.ps1` reads EXIF tag 36867 (DateTimeOriginal) directly from image bytes.
- **Action**:
  - `RenameMoveFileToDateFolder.ps1` has the rename/move code commented out and primarily prints debug info.
  - `RenameMoveFileToDateFolder - Copy.ps1` actually renames and moves files.
- **Reliability**:
  - `RenameMoveFileToDateFolder.ps1` currently contains syntax and control-flow errors (invalid `continue`, invalid assignment), so it likely won’t run.
  - `RenameMoveFileToDateFolder - Copy.ps1` is structurally runnable; main expected failures are missing EXIF tag or name collisions.

### `RenameMoveFileToDateFolder - Copy.ps1` vs `RenameMoveFileToDateFolder - Copy (2).ps1`

- **Implementation approach**:
  - `Copy.ps1` uses `System.Drawing.Bitmap` EXIF reading; generally consistent and locale-independent if tag exists.
  - `Copy (2).ps1` tries to use Shell metadata via `Get-FileMetaData`; this is more dependent on Explorer metadata providers and localized/variable date formats.
- **Current correctness**:
  - `Copy.ps1` is cohesive end-to-end.
  - `Copy (2).ps1` has several type/format issues (wrong `Select` usage, wrong date format string, missing `$NewFileName`, wrong object model for `$Img`).

### Common shared code
All three `RenameMoveFileToDateFolder*` scripts embed a copy of `Get-FileMetaData`. Only `RenameMoveFileToDateFolder.ps1` and `Copy (2)` attempt to use Shell metadata as the main signal; `Copy.ps1` uses EXIF and leaves the Shell metadata code unused.

## Quick “which should I use?” summary (based on current code)

- If you want something closest to working today: **`RenameMoveFileToDateFolder - Copy.ps1`**.
- If you want a Shell-metadata-based approach: **`RenameMoveFileToDateFolder.ps1`** is closer in intent but currently looks like a debug draft and needs fixes; **`Copy (2)`** is also draft-like and incomplete.

