# cocloud-library

## RenameMoveFileToDateFolder.ps1

The script at [scripts/pictures/RenameMoveFileToDateFolder.ps1](scripts/pictures/RenameMoveFileToDateFolder.ps1) renames and organizes images into date-based folders. It scans a source directory for image files, derives a timestamp using a configurable precedence order (EXIF `DateTimeOriginal`, Windows Shell metadata like `Date taken`, and finally file system timestamps), then moves each file into a destination subfolder named `yyyy-MM-dd` while renaming the file to `yyyyMMdd_HHmmss.ext`. If a name collision is detected, it appends a numeric suffix like `_001`. Any errors are recorded in an `_errors.log` file in the source directory (or a custom path via `-ErrorLogPath`). The script supports `-WhatIf` for safe dry runs. By default it processes: `*.jpg`, `*.jpeg`, `*.png`, `*.gif`, `*.bmp`, `*.tif`, `*.tiff`, `*.heic`, `*.heif`.

Usage examples:

```powershell
# Basic usage
./scripts/pictures/RenameMoveFileToDateFolder.ps1 -SourceDir "F:\WorkingTemp\_Unsorted" -DestDir "F:\WorkingTemp\_Sorted"

# Dry run (no changes)
./scripts/pictures/RenameMoveFileToDateFolder.ps1 -SourceDir "F:\Photos" -DestDir "F:\Photos\Sorted" -WhatIf

# Use only Shell metadata and file system dates
./scripts/pictures/RenameMoveFileToDateFolder.ps1 -SourceDir "F:\Photos" -DestDir "F:\Photos\Sorted" -DateSources Shell,FileSystem

# Customize file extensions and error log path
./scripts/pictures/RenameMoveFileToDateFolder.ps1 -SourceDir "F:\Photos" -DestDir "F:\Photos\Sorted" -Extensions *.jpg,*.jpeg,*.heic -ErrorLogPath "F:\Photos\photo-sort-errors.log"
```

