<#
.SYNOPSIS
  Renames and moves image files into date-based folders.

.DESCRIPTION
  Discovers images under a source directory, derives a timestamp from EXIF,
  Shell metadata, or file system timestamps (in that order by default), and
  moves each file into a yyyy-MM-dd folder under the destination while
  renaming to yyyyMMdd_HHmmss.ext.

.EXAMPLE
  .\RenameMoveFileToDateFolder.ps1 -SourceDir "F:\WorkingTemp\_Unsorted" -DestDir "F:\WorkingTemp\_Sorted"

.EXAMPLE
  .\RenameMoveFileToDateFolder.ps1 -SourceDir "F:\Photos" -DestDir "F:\Photos\Sorted" -DateSources Shell,FileSystem -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceDir,

    [Parameter(Mandatory = $true)]
    [string]$DestDir,

    [string[]]$Extensions = @(
        '*.jpg', '*.jpeg', '*.png', '*.gif', '*.bmp', '*.tif', '*.tiff', '*.heic', '*.heif'
    ),

    [bool]$Recurse = $true,

    [ValidateSet('Exif', 'Shell', 'FileSystem')]
    [string[]]$DateSources = @('Exif', 'Shell', 'FileSystem'),

    [string]$ErrorLogPath
)

Set-StrictMode -Version Latest

function Get-ExifDateTime {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        Add-Type -AssemblyName System.Drawing
        $image = [System.Drawing.Image]::FromFile($Path)
        try {
            $item = $image.GetPropertyItem(36867)
            if (-not $item) {
                return $null
            }

            $raw = [System.Text.Encoding]::ASCII.GetString($item.Value)
            $raw = $raw.Trim([char]0)
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParseExact($raw, 'yyyy:MM:dd HH:mm:ss', $null, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
                return $parsed
            }
        } finally {
            $image.Dispose()
        }
    } catch {
        return $null
    }

    return $null
}

function Get-ShellDateTime {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [hashtable]$IndexCache
    )

    try {
        $folderPath = Split-Path -Path $Path -Parent
        $fileName = Split-Path -Path $Path -Leaf
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.Namespace($folderPath)
        if (-not $folder) {
            return $null
        }

        if (-not $IndexCache.ContainsKey($folderPath)) {
            $dateColumns = @('Date taken', 'Media created', 'Date created')
            $index = $null
            for ($i = 0; $i -le 320; $i++) {
                $name = $folder.GetDetailsOf($null, $i)
                if ($name -and $dateColumns -contains $name) {
                    $index = $i
                    break
                }
            }

            $IndexCache[$folderPath] = $index
        }

        $indexValue = $IndexCache[$folderPath]
        if ($null -eq $indexValue) {
            return $null
        }

        $item = $folder.ParseName($fileName)
        if (-not $item) {
            return $null
        }

        $value = $folder.GetDetailsOf($item, $indexValue)
        if (-not $value) {
            return $null
        }

        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse($value, [System.Globalization.CultureInfo]::CurrentCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            return $parsed
        }

        if ([datetime]::TryParse($value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            return $parsed
        }
    } catch {
        return $null
    }

    return $null
}

function Get-FileSystemDateTime {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )

    if ($File.CreationTime -ne [datetime]::MinValue) {
        return $File.CreationTime
    }

    return $File.LastWriteTime
}

function Get-PreferredDateTime {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File,

        [Parameter(Mandatory = $true)]
        [string[]]$Sources,

        [hashtable]$IndexCache
    )

    foreach ($source in $Sources) {
        switch ($source) {
            'Exif' {
                $date = Get-ExifDateTime -Path $File.FullName
                if ($date) { return $date }
            }
            'Shell' {
                $date = Get-ShellDateTime -Path $File.FullName -IndexCache $IndexCache
                if ($date) { return $date }
            }
            'FileSystem' {
                $date = Get-FileSystemDateTime -File $File
                if ($date) { return $date }
            }
        }
    }

    return $null
}

function Get-UniqueTargetPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderPath,

        [Parameter(Mandatory = $true)]
        [string]$BaseName,

        [Parameter(Mandatory = $true)]
        [string]$Extension
    )

    $candidate = Join-Path -Path $FolderPath -ChildPath ($BaseName + $Extension)
    if (-not (Test-Path -LiteralPath $candidate)) {
        return $candidate
    }

    $counter = 1
    while ($true) {
        $suffix = "_{0:000}" -f $counter
        $candidate = Join-Path -Path $FolderPath -ChildPath ($BaseName + $suffix + $Extension)
        if (-not (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
        $counter++
    }
}

$resolvedSource = (Resolve-Path -LiteralPath $SourceDir).Path
$resolvedDest = (Resolve-Path -LiteralPath $DestDir -ErrorAction SilentlyContinue)
if (-not $resolvedDest) {
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    $resolvedDest = (Resolve-Path -LiteralPath $DestDir).Path
}

if (-not $ErrorLogPath) {
    $ErrorLogPath = Join-Path -Path $resolvedSource -ChildPath '_errors.log'
}

$indexCache = @{}
$errors = New-Object System.Collections.Generic.List[string]

$files = Get-ChildItem -LiteralPath $resolvedSource -File -Include $Extensions -Recurse:$Recurse -Force

foreach ($file in $files) {
    try {
        $date = Get-PreferredDateTime -File $file -Sources $DateSources -IndexCache $indexCache
        if (-not $date) {
            $errors.Add("{0} ERROR No usable date for {1}" -f (Get-Date -Format 'yyyyMMdd HH:mm:ss'), $file.FullName)
            continue
        }

        $folderName = $date.ToString('yyyy-MM-dd')
        $baseName = $date.ToString('yyyyMMdd_HHmmss')
        $destFolder = Join-Path -Path $resolvedDest -ChildPath $folderName
        if (-not (Test-Path -LiteralPath $destFolder)) {
            New-Item -ItemType Directory -Path $destFolder -Force | Out-Null
        }

        $extension = $file.Extension.ToLowerInvariant()
        $targetPath = Get-UniqueTargetPath -FolderPath $destFolder -BaseName $baseName -Extension $extension

        if ($PSCmdlet.ShouldProcess($file.FullName, "Move to $targetPath")) {
            Move-Item -LiteralPath $file.FullName -Destination $targetPath -Force
        }
    } catch {
        $errors.Add("{0} ERROR Did not move {1}. Reason: {2}" -f (Get-Date -Format 'yyyyMMdd HH:mm:ss'), $file.FullName, $_.Exception.Message)
        continue
    }
}

if ($errors.Count -gt 0) {
    $errors | Out-File -FilePath $ErrorLogPath -Encoding UTF8
    Write-Warning "Errors were found. Please check $ErrorLogPath"
}