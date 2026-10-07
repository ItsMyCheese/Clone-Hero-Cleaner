@echo off
setlocal EnableExtensions
title Clone Hero Duplicate Cleaner v33 - Consistent Colors
set "CH_DEDUPE_SCRIPT=%~f0"
if not defined CH_DEDUPE_MENU_STAGE set "CH_DEDUPE_MENU_STAGE=0"
:MAIN_MENU
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText($env:CH_DEDUPE_SCRIPT); $m='#=== CH_DEDUPE_PS ==='; $i=$s.LastIndexOf($m); if($i -lt 0){throw 'Embedded script not found'}; & ([scriptblock]::Create($s.Substring($i+$m.Length)))"
set "RC=%errorlevel%"
if "%RC%"=="99" exit /b 0
if "%RC%"=="98" (
    echo.
    echo Press any key to close...
    pause >nul
    exit /b 0
)
if "%RC%"=="0" set "CH_DEDUPE_MENU_STAGE=1"
echo.
if not "%RC%"=="0" echo Script ended with error code %RC%.
echo ============================================================
echo.
goto MAIN_MENU
#=== CH_DEDUPE_PS ===
$ErrorActionPreference = 'Stop'

# Exact gold on ANSI/true-color terminals; warm gold on older Windows consoles.
function Write-CHGold([string] $Message) {
    if ($env:WT_SESSION -or $env:TERM_PROGRAM -or $env:ANSICON -or $env:ConEmuANSI -eq 'ON') {
        $esc = [char]27
        Write-Host ($esc + '[38;2;255;215;0m' + $Message + $esc + '[0m')
    } else {
        Write-Host $Message -ForegroundColor DarkYellow
    }
}

# The folder containing this .bat file IS the Clone Hero song library.
# Put this file directly inside your main Songs folder, then run it there.
$Root = [IO.Path]::GetDirectoryName($env:CH_DEDUPE_SCRIPT)
if ([string]::IsNullOrWhiteSpace($Root) -or !(Test-Path -LiteralPath $Root -PathType Container)) {
    throw 'Could not determine the song folder from the program location.'
}
$Root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
if ($Root -eq [IO.Path]::GetPathRoot($Root).TrimEnd('\')) {
    throw 'Put this tool inside a SONGS folder, not directly in the root of a drive.'
}
# Store reports next to (not inside) the main song library, just like quarantine.
$ReportDir = $Root.TrimEnd('\') + ' - Duplicate Cleaner Reports'
$QuarantineRoot = $Root.TrimEnd('\') + ' - Duplicate Quarantine'
$RunStamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'

function Normalize-Value([string] $Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $v = $Value.Normalize([Text.NormalizationForm]::FormKC).Trim()
    $v = [regex]::Replace($v, '\s+', ' ')
    return $v.ToLowerInvariant()
}

function Get-FolderKey([string] $Folder) {
    try {
        return [IO.Path]::GetFullPath($Folder.Replace('/', '\')).TrimEnd('\').ToLowerInvariant()
    } catch { return '' }
}

function Read-SongIni([string] $IniPath) {
    $fields = @{}
    $insideSong = $false
    # Decode Unicode titles and charter names correctly (UTF-8, BOM, ANSI fallback).
    try {
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $lines = [IO.File]::ReadAllLines($IniPath, $strictUtf8)
    } catch [Text.DecoderFallbackException] {
        $lines = [IO.File]::ReadAllLines($IniPath, [Text.Encoding]::Default)
    }
    foreach ($line in $lines) {
        $s = $line.Trim()
        if (!$s -or $s.StartsWith(';') -or $s.StartsWith('#')) { continue }
        if ($s.StartsWith('[')) {
            $insideSong = ($s -match '^\[song\]$')
            continue
        }
        if (!$insideSong) { continue }
        $eq = $s.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $s.Substring(0, $eq).Trim().ToLowerInvariant()
        $val = $s.Substring($eq + 1).Trim()
        if ($val.Length -ge 2 -and (($val[0] -eq '"' -and $val[$val.Length - 1] -eq '"') -or
                                      ($val[0] -eq "'" -and $val[$val.Length - 1] -eq "'"))) {
            $val = $val.Substring(1, $val.Length - 2)
        }
        $fields[$key] = $val
    }
    $charter = ''
    if ($fields.ContainsKey('charter')) { $charter = $fields['charter'] }
    if (!$charter -and $fields.ContainsKey('frets')) { $charter = $fields['frets'] }
    $name = ''
    if ($fields.ContainsKey('name')) { $name = $fields['name'] }
    $artist = ''
    if ($fields.ContainsKey('artist')) { $artist = $fields['artist'] }
    return @{ Name = $name; Artist = $artist; Charter = $charter }
}

# This reads the documented/community-researched 16-byte-hash scoredata format.
# It REFUSES to classify any score if the binary layout does not fully validate.
function Read-CHScores([string] $Path) {
    $scores = @{}
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = New-Object IO.BinaryReader($fs)
    try {
        if ($fs.Length -lt 8) { throw 'Score file is shorter than 8 bytes.' }
        $header = [BitConverter]::ToString($reader.ReadBytes(4)).Replace('-', '')
        $songCount = [uint32] $reader.ReadUInt32()
        if ($songCount -gt 2000000) { throw 'Implausible score record count.' }
        for ($n = 0; $n -lt $songCount; $n++) {
            if (($fs.Length - $fs.Position) -lt 20) { throw "Truncated score record $n" }
            $hash = [BitConverter]::ToString($reader.ReadBytes(16)).Replace('-', '').ToLowerInvariant()
            $instCount = [int] $reader.ReadByte()
            $b0 = [int] $reader.ReadByte()
            $b1 = [int] $reader.ReadByte()
            $b2 = [int] $reader.ReadByte()
            $plays = $b0 + ($b1 * 256) + ($b2 * 65536)
            $scored = 0
            $maxScore = [uint32] 0
            if (($fs.Length - $fs.Position) -lt ($instCount * 16)) {
                throw "Truncated instrument records for chart $hash"
            }
            for ($k = 0; $k -lt $instCount; $k++) {
                $null = $reader.ReadUInt16()  # instrument
                $null = $reader.ReadByte()    # difficulty
                $null = $reader.ReadUInt16()  # completion numerator
                $null = $reader.ReadUInt16()  # completion denominator
                $null = $reader.ReadByte()    # stars
                $null = $reader.ReadBytes(4)  # padding
                $points = $reader.ReadUInt32()
                if ($points -gt 0) { $scored++ }
                if ($points -gt $maxScore) { $maxScore = $points }
            }
            if ($scores.ContainsKey($hash)) {
                $prior = $scores[$hash]
                $plays = [Math]::Max($plays, $prior.PlayCount)
                $scored += $prior.ScoreRecords
                $maxScore = [Math]::Max($maxScore, $prior.MaxScore)
            }
            $scores[$hash] = [pscustomobject]@{
                PlayCount = $plays; ScoreRecords = $scored; MaxScore = $maxScore
            }
        }
        if ($fs.Position -ne $fs.Length) {
            throw "Unrecognized trailing bytes: $($fs.Length - $fs.Position)"
        }
        return @{ Map = $scores; SongCount = $songCount; Header = $header }
    } finally {
        $reader.Close()
        $fs.Dispose()
    }
}

# The cache holds a counted table of song records. Each record begins with a
# BinaryReader (7-bit length-prefixed) UTF-8 folder path, followed by two
# 8-byte timestamps and a length-prefixed chart filename. Its final 16 bytes
# are the chart hash. This is checked against the user's real cache layout.
# Fail CLOSED if the table cannot be validated; never infer unplayed status.
function Read-7BitUnsigned([byte[]] $Data, [int] $Start) {
    [long] $value = 0
    for ($i = 0; $i -lt 5; $i++) {
        if (($Start + $i) -ge $Data.Length) { throw 'Truncated 7-bit string length.' }
        $v = [int] $Data[$Start + $i]
        $value = $value -bor (([long]($v -band 127)) -shl (7 * $i))
        if (($v -band 128) -eq 0) {
            if ($value -gt [int]::MaxValue) { throw '7-bit string length exceeds Int32.' }
            return [pscustomobject]@{ Length = [int] $value; Width = $i + 1 }
        }
    }
    throw 'Invalid 7-bit encoded length.'
}

function Read-CHCache([string] $Path, [string] $LibraryRoot, [hashtable] $ScoreMap) {
    if ((Get-Item -LiteralPath $Path).Length -gt 536870912) {
        throw 'Song cache is over 512 MB; automatic parsing disabled.'
    }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64) { throw 'Cache too short.' }
    $latin = [Text.Encoding]::GetEncoding(28591)
    $raw = $latin.GetString($bytes)  # Latin-1 preserves byte offsets exactly.
    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $rootKey = Get-FolderKey $LibraryRoot
    $validEntries = New-Object 'System.Collections.Generic.List[object]'

    # The original file was incorrectly searched for the phrase 'Clone Hero'.
    # That phrase occurs in bundled-song METADATA, not before each chart hash.
    # Find plausible drive-rooted paths, then validate their BinaryReader fields.
    $candidates = [regex]::Matches($raw, '(?i)[a-z]:\\')
    foreach ($match in $candidates) {
        $at = $match.Index
        $entry = $null
        for ($prefixWidth = 1; $prefixWidth -le 5; $prefixWidth++) {
            $prefixStart = $at - $prefixWidth
            if ($prefixStart -lt 0) { continue }
            try {
                $prefix = Read-7BitUnsigned $bytes $prefixStart
                if ($prefix.Width -ne $prefixWidth) { continue }
                $len = $prefix.Length
                if ($len -lt 5 -or $len -gt 32767 -or ($at + $len + 17) -gt $bytes.Length) { continue }
                $folder = $utf8.GetString($bytes, $at, $len)
                if ($folder -notmatch '^[a-zA-Z]:\\' -or $folder -match '[\x00-\x1F<>"|?*]' -or
                    $folder.Substring(2).Contains(':')) { continue }

                $chartNameAt = $at + $len + 16  # two DateTime fields
                $namePrefix = Read-7BitUnsigned $bytes $chartNameAt
                if ($namePrefix.Length -lt 5 -or $namePrefix.Length -gt 255) { continue }
                $nameAt = $chartNameAt + $namePrefix.Width
                if (($nameAt + $namePrefix.Length) -gt $bytes.Length) { continue }
                $chartName = $utf8.GetString($bytes, $nameAt, $namePrefix.Length)
                if ($chartName -notmatch '(?i)^[^\\/:\x00-\x1F<>"|?*]+\.(?:chart|mid|midi)$') { continue }

                $entry = [pscustomobject]@{
                    PrefixStart = $prefixStart
                    ChartFieldEnd = $nameAt + $namePrefix.Length
                    Folder = $folder
                    ChartName = $chartName
                }
                break
            } catch {
                continue
            }
        }
        if ($null -ne $entry) { $validEntries.Add($entry) }
    }

    if ($validEntries.Count -eq 0) { throw 'No valid path/filename records found.' }
    $first = $validEntries[0].PrefixStart
    if ($first -lt 4) { throw 'Cannot read cache table count.' }
    [long] $expected = [BitConverter]::ToUInt32($bytes, $first - 4)
    if ($expected -lt 1 -or $expected -ne $validEntries.Count) {
        throw "Cache records failed integrity check: header says $expected; validated $($validEntries.Count)."
    }

    $folders = @{}
    $matchedEntries = 0
    $outOfLibrary = 0
    $missingFiles = 0
    $allHashes = @{}
    for ($i = 0; $i -lt $validEntries.Count; $i++) {
        $entry = $validEntries[$i]
        if ($i -lt ($validEntries.Count - 1)) {
            $recordEnd = $validEntries[$i + 1].PrefixStart
        } else {
            $recordEnd = $bytes.Length
        }
        $hashAt = $recordEnd - 16
        # The 16-byte hash must be within THIS record, after the file metadata.
        if ($hashAt -le $entry.ChartFieldEnd) {
            throw "Malformed song-cache record #$i. No scores will be trusted."
        }
        $hash = [BitConverter]::ToString($bytes, $hashAt, 16).Replace('-', '').ToLowerInvariant()
        if ($hash -eq ('00' * 16)) {
            throw "Empty song hash in cache record #$i. No scores will be trusted."
        }
        $allHashes[$hash] = $true

        $folderKey = Get-FolderKey $entry.Folder
        if (!$folderKey.StartsWith($rootKey + '\', [StringComparison]::OrdinalIgnoreCase)) {
            $outOfLibrary++
            continue
        }
        # A cache entry must point to an existing chart, not merely a string.
        $chartFile = Join-Path $entry.Folder $entry.ChartName
        if (!(Test-Path -LiteralPath $chartFile -PathType Leaf)) {
            $missingFiles++
            continue
        }
        if (!$folders.ContainsKey($folderKey)) {
            $folders[$folderKey] = New-Object 'System.Collections.Generic.List[string]'
        }
        if (!$folders[$folderKey].Contains($hash)) { $folders[$folderKey].Add($hash) }
        $matchedEntries++
    }
    if ($matchedEntries -eq 0) {
        throw "No cached chart files found inside $LibraryRoot."
    }

    $scoreHashMatches = 0
    $scoreHashMatchesLocal = 0
    $localHashes = @{}
    foreach ($list in $folders.Values) {
        foreach ($h in $list) { $localHashes[$h] = $true }
    }
    foreach ($scoreHash in $ScoreMap.Keys) {
        if ($allHashes.ContainsKey($scoreHash)) { $scoreHashMatches++ }
        if ($localHashes.ContainsKey($scoreHash)) { $scoreHashMatchesLocal++ }
    }
    # No overlap means the alleged cache hashes may NOT be score hashes for
    # this installed game version, or scores may belong to an older library.
    # In either case an absent score is NOT enough to delete a chart.
    if ($ScoreMap.Count -gt 0 -and $scoreHashMatchesLocal -eq 0) {
        throw "Cache parsed ($($validEntries.Count) records), but ZERO saved-score hashes match existing song charts in the library. Automatic unplayed classification disabled."
    }
    return @{
        Folders = $folders
        CacheEntries = $validEntries.Count
        MatchedEntries = $matchedEntries
        OtherLibraryEntries = $outOfLibrary
        MissingChartFiles = $missingFiles
        ScoreHashMatches = $scoreHashMatches
        ScoreHashMatchesLocal = $scoreHashMatchesLocal
    }
}

# Find standard Windows saves and common portable Clone Hero locations.
# Game files and saved scores do not have to be on the same drive.
function Add-CHDataCandidate {
    param(
        [hashtable] $Seen,
        [System.Collections.Generic.List[object]] $Results,
        [string] $Path,
        [string] $Description
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try {
        $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
        if (!(Test-Path -LiteralPath $full -PathType Container)) { return }
        $key = $full.ToLowerInvariant()
        if ($Seen.ContainsKey($key)) { return }
        $Seen[$key] = $true
        $Results.Add([pscustomobject]@{ Folder = $full; Description = $Description })
    } catch { }
}

function Find-CHDataCandidates([string] $SongRoot) {
    $found = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}

    # Official Windows score/cache location for typical installations.
    if ($env:USERPROFILE) {
        Add-CHDataCandidate $seen $found (Join-Path $env:USERPROFILE 'AppData\LocalLow\srylain Inc_\Clone Hero') 'Standard Windows save folder'
    }
    if ($env:LOCALAPPDATA) {
        Add-CHDataCandidate $seen $found (Join-Path $env:LOCALAPPDATA '..\LocalLow\srylain Inc_\Clone Hero') 'Standard Windows save folder'
    }

    # A portable install normally stores game data in a GameData folder.
    $installFolders = New-Object 'System.Collections.Generic.List[string]'
    if ($env:ProgramFiles) { $installFolders.Add((Join-Path $env:ProgramFiles 'Clone Hero')) }
    $x86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if ($x86) { $installFolders.Add((Join-Path $x86 'Clone Hero')) }
    $installFolders.Add('C:\Program Files\Clone Hero')

    # If their song folder is in/near a portable game install, also check there.
    $walk = Get-Item -LiteralPath $SongRoot -ErrorAction Stop
    for ($i = 0; $i -lt 4 -and $null -ne $walk; $i++) {
        $installFolders.Add($walk.FullName)
        $walk = $walk.Parent
    }
    foreach ($install in $installFolders) {
        Add-CHDataCandidate $seen $found (Join-Path $install 'GameData') 'Portable install save folder'
    }

    return $found.ToArray()
}

function Test-CHDataFolder {
    param([string] $Folder, [string] $SongRoot, [string] $Description)
    $scorePath = Join-Path $Folder 'scoredata.bin'
    $cachePath = Join-Path $Folder 'songcache.bin'
    if (!(Test-Path -LiteralPath $scorePath -PathType Leaf)) {
        throw 'scoredata.bin is missing.'
    }
    if (!(Test-Path -LiteralPath $cachePath -PathType Leaf)) {
        throw 'songcache.bin is missing.'
    }
    # Both parsers perform structural checks. The cache parser also checks
    # that chart paths actually exist inside THIS library and hashes agree.
    $scores = Read-CHScores $scorePath
    $songCache = Read-CHCache $cachePath $SongRoot $scores.Map
    if ($songCache.MatchedEntries -lt 1) {
        throw 'No song charts in this folder matched the game cache.'
    }
    return [pscustomobject]@{
        Folder = $Folder
        Description = $Description
        ScorePath = $scorePath
        CachePath = $cachePath
        Scores = $scores
        Cache = $songCache
        CacheLastScanUtc = (Get-Item -LiteralPath $cachePath).LastWriteTimeUtc
    }
}

# Read Clone Hero's OWN last song-scan failures instead of treating a missing
# guitar track as a bad song. Official badsongs.txt ERROR groups list song
# folders. Do not import warnings, duplicate-chart errors, or instrument-only
# errors. Broken songs may still be repairable, so unknown scores are protected.
function Find-CHBadSongLogs([string] $LibraryRoot) {
    $possible = New-Object 'System.Collections.Generic.List[string]'
    $docs = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    if ($docs) {
        $possible.Add((Join-Path (Join-Path $docs 'Clone Hero') 'badsongs.txt'))
        $possible.Add((Join-Path (Join-Path $docs 'Clone Hero\PlayerData') 'badsongs.txt'))
    }
    if ($env:USERPROFILE) {
        $possible.Add((Join-Path $env:USERPROFILE 'Documents\Clone Hero\badsongs.txt'))
    }
    $possible.Add((Join-Path $LibraryRoot 'badsongs.txt'))
    $installDirs = New-Object 'System.Collections.Generic.List[string]'
    if ($env:ProgramFiles) { $installDirs.Add((Join-Path $env:ProgramFiles 'Clone Hero')) }
    $x86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if ($x86) { $installDirs.Add((Join-Path $x86 'Clone Hero')) }
    $walk = Get-Item -LiteralPath $LibraryRoot -ErrorAction Stop
    for ($i = 0; $i -lt 5 -and $null -ne $walk; $i++) {
        $installDirs.Add($walk.FullName)
        $walk = $walk.Parent
    }
    foreach ($install in $installDirs) {
        $possible.Add((Join-Path $install 'PlayerData\badsongs.txt'))
        $possible.Add((Join-Path $install 'badsongs.txt'))
    }
    $seen = @{}
    $logs = New-Object 'System.Collections.Generic.List[object]'
    foreach ($candidate in $possible) {
        try {
            $full = [IO.Path]::GetFullPath($candidate)
            $key = $full.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            if (Test-Path -LiteralPath $full -PathType Leaf) {
                $logs.Add((Get-Item -LiteralPath $full -ErrorAction Stop))
            }
        } catch { }
    }
    return @($logs.ToArray() | Sort-Object LastWriteTimeUtc -Descending)
}

function Explain-CHScanError([string] $Heading) {
    if ($Heading -match '(?i)metadata|song\.ini|song name') {
        return 'Clone Hero could not read valid song information (song.ini or song name).'
    }
    if ($Heading -match '(?i)corrupt|broken') {
        return 'Clone Hero reported that this song has a corrupt or broken chart file.'
    }
    if ($Heading -match '(?i)audio|sound') {
        return 'Clone Hero could not find usable audio for this song.'
    }
    if ($Heading -match '(?i)notes\.chart|notes\.mid|chart files|no chart') {
        return 'Clone Hero could not find a usable notes.chart or notes.mid file.'
    }
    return 'Clone Hero rejected this song during its last scan: ' + $Heading
}

function Read-CHBadSongLog([string] $LogPath, [string] $LibraryRoot) {
    if ((Get-Item -LiteralPath $LogPath).Length -gt 16777216) {
        throw 'badsongs.txt is unusually large; skipped for safety.'
    }
    $rootKey = Get-FolderKey $LibraryRoot
    $found = @{}
    $activeError = $false
    $heading = ''
    $seenPathInSection = $false
    $skipHeading = $false
    foreach ($line in [IO.File]::ReadAllLines($LogPath)) {
        $t = $line.Trim()
        if (!$t) {
            if ($seenPathInSection) { $activeError = $false; $heading = '' }
            continue
        }
        if ($t -match '(?i)^\s*#*\s*(warning|warn)\s*:') {
            $activeError = $false
            $heading = ''
            continue
        }
        if ($t -match '(?i)^\s*#*\s*error\s*:') {
            $activeError = $true
            $seenPathInSection = $false
            $heading = ($t -replace '(?i)^\s*#*\s*error\s*:\s*', '').Trim()
            $skipHeading = ($heading -match '(?i)duplicate|another song has|supported instruments|no playable instruments|no guitar|no instrument')
            continue
        }
        if (!$activeError) { continue }
        $candidate = $t.Trim('"')
        if ($candidate -match '^[A-Za-z]:\\') {
            $seenPathInSection = $true
            if ($skipHeading) { continue }
            # Only touch absolute folders actually inside THIS user's library.
            $key = Get-FolderKey $candidate
            if (!$key.StartsWith($rootKey + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
            if (!(Test-Path -LiteralPath $candidate -PathType Container)) { continue }
            $reason = Explain-CHScanError $heading
            if (!$found.ContainsKey($key)) {
                $found[$key] = [pscustomobject]@{
                    Folder = $candidate
                    Reason = $reason
                    LogPath = $LogPath
                    LogTimeUtc = (Get-Item -LiteralPath $LogPath).LastWriteTimeUtc
                }
            } elseif (!$found[$key].Reason.Contains($reason)) {
                $found[$key].Reason += ' ' + $reason
            }
        } elseif (!$seenPathInSection) {
            # Some versions wrap long ERROR headings across multiple lines.
            $heading += ' ' + $t
            $skipHeading = ($heading -match '(?i)duplicate|another song has|supported instruments|no playable instruments|no guitar|no instrument')
        }
    }
    foreach ($entry in $found.Values) { Write-Output $entry }
}

# Clone Hero reports identical chart errors using a DISPLAY LABEL followed
# by the real on-disk song folder in final parentheses. These are NOT corrupt
# song reports, and are NOT sufficient by themselves to delete files.
# Capture them for a separate count and to explain existing duplicate choices.
function Read-CHDuplicateChartLog([string] $LogPath, [string] $LibraryRoot) {
    if ((Get-Item -LiteralPath $LogPath).Length -gt 16777216) {
        throw 'badsongs.txt exceeds the safe reading limit.'
    }
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $inDuplicateSection = $false
    $rootKey = Get-FolderKey $LibraryRoot
    foreach ($line in [IO.File]::ReadAllLines($LogPath)) {
        $t = $line.Trim()
        if ($t -match '(?i)^(warning|warn|error)\s*:') {
            $inDuplicateSection = ($t -match '(?i)^error\s*:.*(duplicate charts|another song has)')
            continue
        }
        if (!$t) { $inDuplicateSection = $false; continue }
        if (!$inDuplicateSection) { continue }
        # Avoid interpreting the chart's display name as a Windows path.
        # In e.g. 'Band - Title (Charter) (F:\Songs\Album (Deluxe))', the
        # final parenthesized value is the genuine chart folder.
        $folder = ''
        if ($t -match '\(([a-zA-Z]:\\.+)\)\s*$') {
            $folder = $Matches[1]
        }
        $inLibrary = $false
        $exists = $false
        if ($folder) {
            $key = Get-FolderKey $folder
            if ($key -and $key.StartsWith($rootKey + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $inLibrary = $true
                $exists = (Test-Path -LiteralPath $folder -PathType Container)
            }
        }
        $entries.Add([pscustomobject]@{
            RawEntry = $t
            Folder = $folder
            InLibrary = $inLibrary
            Exists = $exists
        })
    }
    return @($entries.ToArray())
}

# Avoid acting on an old badsongs.txt if the folder or its files were changed
# after the game generated that report. Run Scan Songs again in that case.
function Test-CHBadSongReportFresh([string] $Folder, [datetime] $ReportedUtc) {
    try {
        $cutoff = $ReportedUtc.AddSeconds(5)
        if ((Get-Item -LiteralPath $Folder -ErrorAction Stop).LastWriteTimeUtc -gt $cutoff) {
            return $false
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $Folder -File -Force -ErrorAction Stop)) {
            if ($file.LastWriteTimeUtc -gt $cutoff) { return $false }
        }
        return $true
    } catch { return $false }
}

# Never remove an album/pack folder, even if it accidentally appears in a log.
function Test-CHSingleSongFolder([string] $Folder) {
    try {
        $files = @(Get-ChildItem -LiteralPath $Folder -File -Force -ErrorAction Stop)
        $looksLikeSong = @($files | Where-Object {
            $_.Name -match '(?i)^song\.ini$|^notes\.(chart|mid|midi)$' -or
            $_.Extension.ToLowerInvariant() -in @('.ogg','.mp3','.wav','.opus')
        }).Count -gt 0
        if (!$looksLikeSong) { return $false }
        $nested = Get-ChildItem -LiteralPath $Folder -Recurse -File -Force -ErrorAction Stop |
            Where-Object {
                (Get-FolderKey $_.DirectoryName) -ne (Get-FolderKey $Folder) -and
                $_.Name -match '(?i)^song\.ini$|^notes\.(chart|mid|midi)$'
            } | Select-Object -First 1
        return ($null -eq $nested)
    } catch { return $false }
}

# Keep an exact record of where every new quarantined folder came from.
# Historical versions only mirrored the folder structure; option 5 also
# recognizes those older folders if their original path can be inferred safely.
$QuarantineHistoryFile = Join-Path $QuarantineRoot '_CloneHero_Move_History.jsonl'

function Write-CHQuarantineEntry {
    param(
        [string] $Original,
        [string] $HeldAt,
        [string] $SongName,
        [string] $SongArtist,
        [string] $Reason
    )
    $record = [pscustomobject][ordered]@{
        Original = $Original
        Quarantined = $HeldAt
        Song = $SongName
        Artist = $SongArtist
        Reason = $Reason
        MovedUtc = [DateTime]::UtcNow.ToString('o')
    }
    $line = ConvertTo-Json -InputObject $record -Compress -Depth 5
    Add-Content -LiteralPath $QuarantineHistoryFile -Value $line -Encoding UTF8 -ErrorAction Stop
}

function Test-CHSafeAncestors([string] $Path, [string] $Boundary) {
    # Refuse junctions/symlinks in the destination's existing parent chain or
    # quarantine's source path. They can otherwise escape the library root.
    $boundaryKey = Get-FolderKey $Boundary
    $current = $Path
    while ($true) {
        $key = Get-FolderKey $current
        if (!$key -or ($key -ne $boundaryKey -and
            !$key.StartsWith($boundaryKey + '\', [StringComparison]::OrdinalIgnoreCase))) {
            return $false
        }
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            if ($key -ne $boundaryKey -and !$item.PSIsContainer) { return $false }
        }
        if ($key -eq $boundaryKey) { return $true }
        $parent = Split-Path -Parent $current
        if (!$parent -or $parent -eq $current) { return $false }
        $current = $parent
    }
}

function Get-CHQuarantinedSongs {
    $results = New-Object 'System.Collections.Generic.List[object]'
    if (!(Test-Path -LiteralPath $QuarantineRoot -PathType Container)) { return @() }
    if (!(Test-CHSafeAncestors $QuarantineRoot $QuarantineRoot)) {
        throw 'Quarantine root is a symbolic link or junction; restore cancelled.'
    }
    $rootKey = Get-FolderKey $Root
    $heldKey = Get-FolderKey $QuarantineRoot
    $seen = @{}

    if (Test-Path -LiteralPath $QuarantineHistoryFile -PathType Leaf) {
        foreach ($line in [IO.File]::ReadLines($QuarantineHistoryFile)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $record = ConvertFrom-Json -InputObject $line -ErrorAction Stop
                if (!$record.Original -or !$record.Quarantined) { continue }
                $from = [string] $record.Quarantined
                $to = [string] $record.Original
                $fromKey = Get-FolderKey $from
                $toKey = Get-FolderKey $to
                if (!$fromKey.StartsWith($heldKey + '\', [StringComparison]::OrdinalIgnoreCase) -or
                    !$toKey.StartsWith($rootKey + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
                if ($seen.ContainsKey($fromKey) -or !(Test-Path -LiteralPath $from -PathType Container)) { continue }
                $seen[$fromKey] = $true
                $songName = if ($record.Song) { [string] $record.Song } else { Split-Path -Leaf $from }
                $songArtist = if ($record.Artist) { [string] $record.Artist } else { '' }
                $songReason = if ($record.Reason) { [string] $record.Reason } else { 'Moved by a previous cleanup.' }
                $results.Add([pscustomobject]@{
                    HeldAt = $from; Original = $to
                    Name = $songName
                    Artist = $songArtist
                    Reason = $songReason
                    Known = $true
                })
            } catch {
                # A damaged journal line never authorizes moving a folder.
                Write-Warning 'A quarantine history entry could not be read; it was skipped.'
            }
        }
    }

    # Backward compatibility: restore old v25-and-earlier quarantines by their
    # mirrored relative folder structure, but ONLY clearly marked song folders.
    # Suffixes appended to avoid collisions have ambiguous original paths and
    # require a history entry, so never guess a destination for them.
    $markers = Get-ChildItem -LiteralPath $QuarantineRoot -Recurse -File -Force -ErrorAction Stop |
        Where-Object { $_.Name -match '(?i)^song\.ini$|^notes\.(chart|mid|midi)$' }
    foreach ($marker in $markers) {
        $from = $marker.DirectoryName
        $fromKey = Get-FolderKey $from
        if ($seen.ContainsKey($fromKey) -or !$fromKey.StartsWith($heldKey + '\', [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $seen[$fromKey] = $true
        $relative = $from.Substring($QuarantineRoot.TrimEnd('\').Length).TrimStart('\')
        if (!$relative -or $relative -match '(?i)_CHDUPE_[0-9a-f]{8}(?:\\|$)') { continue }
        if (!(Test-CHSingleSongFolder $from)) { continue }
        $to = Join-Path $Root $relative
        $toKey = Get-FolderKey $to
        if (!$toKey.StartsWith($rootKey + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
        $results.Add([pscustomobject]@{
            HeldAt = $from; Original = $to
            Name = (Split-Path -Leaf $from)
            Artist = ''
            Reason = 'Moved before restore history was available; original location inferred from quarantine folders.'
            Known = $false
        })
    }
    return @($results.ToArray() | Sort-Object Original, HeldAt)
}

function Save-CHRestoreReport([string] $Path, [object[]] $Items) {
    $cards = New-Object Text.StringBuilder
    $restored = @($Items | Where-Object { $_.Status -eq 'RESTORED' }).Count
    $skipped = $Items.Count - $restored
    foreach ($entry in $Items) {
        $song = Escape-ReportText $entry.Name
        $from = Escape-ReportText $entry.HeldAt
        $to = Escape-ReportText $entry.Original
        $reason = Escape-ReportText $entry.Reason
        $problem = Escape-ReportText $entry.Detail
        $result = Escape-ReportText $entry.Status
        $cls = if ($entry.Status -eq 'RESTORED') { 'restored' } else { 'skipped' }
        $problemHtml = if ($problem) { "<p class='problem'><b>Why not restored:</b> $problem</p>" } else { '' }
        $oneCard = @"
<article class="card $cls"><div class="head"><strong>$song</strong><span class="pill">$result</span></div>
<p><b>Why it was quarantined:</b> $reason</p>
$problemHtml
<details><summary>Folder locations</summary><p><b>In quarantine:</b><br><code>$from</code></p><p><b>Restore location:</b><br><code>$to</code></p></details></article>
"@
        [void] $cards.AppendLine($oneCard)
    }
    $html = @'
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Quarantine restore results</title><style>
:root{font-family:Segoe UI,Arial,sans-serif;background:#f2f5f9;color:#182638}*{box-sizing:border-box}
body{margin:0}main{max-width:950px;margin:auto;padding:28px 18px 70px}h1{font-size:29px;margin-bottom:7px}
.summary{color:#506178;margin:0 0 24px}.stats{font-size:18px;font-weight:650;margin-bottom:24px}
.card{background:#fff;border:1px solid #dde5ef;border-left:4px solid #1d9979;border-radius:12px;margin:11px 0;padding:18px 20px}
.card.skipped{border-left-color:#c67e29}.head{display:flex;justify-content:space-between;gap:12px;align-items:center}
strong{font-size:17px;overflow-wrap:anywhere}.pill{padding:5px 11px;border-radius:18px;background:#e0f4eb;color:#176f57;font-size:12px;font-weight:700}
.skipped .pill{background:#fff1dc;color:#99601f}p{line-height:1.5;font-size:14px}.problem{color:#985722}
summary{cursor:pointer;color:#345987;font-weight:600}code{font-size:12px;overflow-wrap:anywhere;word-break:break-all;color:#52647a}
</style></head><body><main><h1>Quarantine restore results</h1>
<p class="summary">Moved songs were returned to their original locations. Existing files were never overwritten.</p>
<div class="stats">__RESTORED__ restored &bull; __SKIPPED__ not restored</div>
__CARDS__</main></body></html>
'@
    $html = $html.Replace('__RESTORED__',[string]$restored).Replace('__SKIPPED__',[string]$skipped).Replace('__CARDS__',$cards.ToString())
    [IO.File]::WriteAllText($Path,$html,(New-Object Text.UTF8Encoding($false)))
}

function Restore-CHQuarantine {
    Write-Host ''
    Write-Host '========== UNDO QUARANTINE ==========' -ForegroundColor Cyan
    if (!(Test-Path -LiteralPath $QuarantineRoot -PathType Container)) {
        Write-Host 'No quarantine folder found. Nothing to restore.' -ForegroundColor Yellow
        return
    }
    $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'Clone.*Hero' })
    if ($running.Count -gt 0) { throw 'Close Clone Hero before restoring quarantined songs.' }
    Write-Host 'Finding songs in quarantine...' -ForegroundColor DarkCyan
    $candidates = @(Get-CHQuarantinedSongs)
    if ($candidates.Count -eq 0) {
        Write-Host 'No restorable song folders found. Nothing changed.' -ForegroundColor Yellow
        return
    }
    $ready = New-Object 'System.Collections.Generic.List[object]'
    $blocked = New-Object 'System.Collections.Generic.List[object]'
    $destinations = @{}
    foreach ($candidate in $candidates) {
        $detail = ''
        $from = $candidate.HeldAt
        $to = $candidate.Original
        $destKey = Get-FolderKey $to
        if ($destinations.ContainsKey($destKey)) {
            $detail = 'More than one quarantined folder points to this original location.'
        } elseif (!(Test-Path -LiteralPath $from -PathType Container)) {
            $detail = 'Quarantined folder is missing.'
        } elseif (!(Test-CHSafeAncestors $from $QuarantineRoot)) {
            $detail = 'Quarantine contains a symbolic link, junction, or unsafe path.'
        } elseif (!(Test-CHSafeAncestors (Split-Path -Parent $to) $Root)) {
            $detail = 'Original location passes through a symbolic link, junction, or unsafe path.'
        } elseif (Test-Path -LiteralPath $to) {
            $detail = 'Original location already exists; would overwrite a song or folder.'
        }
        if ($detail) {
            $blocked.Add([pscustomobject]@{
                Name=$candidate.Name; HeldAt=$from; Original=$to; Reason=$candidate.Reason; Detail=$detail; Status='SKIPPED'
            })
        } else {
            $destinations[$destKey] = $true
            $ready.Add($candidate)
        }
    }
    Write-Host "Found $($candidates.Count) quarantined song folders." -ForegroundColor Cyan
    Write-Host "  Ready to restore: $($ready.Count)" -ForegroundColor Green
    Write-Host "  Will leave in quarantine for safety: $($blocked.Count)" -ForegroundColor Yellow
    Write-Host "Quarantine: $QuarantineRoot"
    Write-Host "Restoring to: $Root"
    if ($blocked.Count -gt 0) {
        Write-Host ''
        Write-Host 'Folders that would be skipped:' -ForegroundColor Yellow
        foreach ($b in $blocked) { Write-Host "  $($b.Name): $($b.Detail)" -ForegroundColor Yellow }
    }
    if ($ready.Count -eq 0) {
        Write-Host 'Nothing can be restored automatically; no changes made.' -ForegroundColor Yellow
        return
    }
    Write-Host ''
    Write-Host 'No existing song folders will be replaced, and permanently deleted songs cannot be restored.' -ForegroundColor Yellow
    $confirm = (Read-Host 'Type RESTORE to return these songs, or press Enter to cancel').Trim().ToUpperInvariant()
    if ($confirm -ne 'RESTORE') { Write-Host 'Cancelled. Nothing changed.'; return }
    New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
    $results = New-Object 'System.Collections.Generic.List[object]'
    foreach ($b in $blocked) { $results.Add($b) }
    $successes = 0
    foreach ($candidate in $ready) {
        $status = 'SKIPPED'
        $detail = ''
        try {
            # Repeat every safety check immediately before the move.
            if (!(Test-Path -LiteralPath $candidate.HeldAt -PathType Container)) {
                throw 'Quarantined folder no longer exists.'
            }
            if (Test-Path -LiteralPath $candidate.Original) {
                throw 'Original location now exists; no overwrite allowed.'
            }
            if (!(Test-CHSafeAncestors $candidate.HeldAt $QuarantineRoot) -or
                !(Test-CHSafeAncestors (Split-Path -Parent $candidate.Original) $Root)) {
                throw 'A folder in the restore path is unsafe or redirected.'
            }
            New-Item -ItemType Directory -Path (Split-Path -Parent $candidate.Original) -Force -ErrorAction Stop | Out-Null
            if (Test-Path -LiteralPath $candidate.Original) {
                throw 'Original location appeared during restore; no overwrite allowed.'
            }
            Move-Item -LiteralPath $candidate.HeldAt -Destination $candidate.Original -ErrorAction Stop
            $status = 'RESTORED'
            $successes++
            Write-Host "Restored: $($candidate.Original)" -ForegroundColor Green
        } catch {
            $detail = $_.Exception.Message
            Write-Warning "Could not restore $($candidate.Name): $detail"
        }
        $results.Add([pscustomobject]@{
            Name=$candidate.Name; HeldAt=$candidate.HeldAt; Original=$candidate.Original;
            Reason=$candidate.Reason; Detail=$detail; Status=$status
        })
    }
    $report = Join-Path $ReportDir ("Songs Restored From Quarantine - $RunStamp.html")
    Save-CHRestoreReport -Path $report -Items @($results.ToArray())
    Write-Host ''
    Write-Host "Restored $successes of $($candidates.Count) song folders." -ForegroundColor Cyan
    Write-Host "Restore results saved: $report"
    Write-CHGold 'Choose option 6 from the menu to open this report.'
    Write-Host 'Run Scan Songs in Clone Hero when ready.' -ForegroundColor DarkCyan
}

function Escape-ReportText([object] $Value) {
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string] $Value)
}

function Save-EasyHtmlReport {
    param(
        [string] $Path,
        [ValidateSet('Proposed', 'Completed')] [string] $ReportType,
        [object[]] $Items
    )
    $rows = New-Object System.Text.StringBuilder
    $moveCount = 0
    $deleteCount = 0
    $otherCount = 0

    foreach ($item in $Items) {
        $song = Escape-ReportText $item.Song
        $artist = Escape-ReportText $item.Artist
        if ([string]::IsNullOrWhiteSpace($song)) { $song = '(Song name missing)' }
        if ([string]::IsNullOrWhiteSpace($artist)) { $artist = '(Artist not listed)' }

        if ($ReportType -eq 'Proposed') {
            $charter = Escape-ReportText $item.'Charter of This Extra Copy'
            $chartCount = Escape-ReportText $item.'Total Charts by This Charter'
            $reason = Escape-ReportText $item.'Why This Copy Was Chosen'
            $original = Escape-ReportText $item.'Folder to Remove From Library'
            $action = [string] $item.'Suggested Action'
            if ($action -eq 'Move') {
                $moveCount++
                $badge = 'Move'
                $badgeType = 'move'
            } else {
                $deleteCount++
                $badge = 'Delete'
                $badgeType = 'delete'
            }
            $kind = [string] $item.'Reason Type'
            if ($kind -eq 'Bad song') {
                $extraInfo = "<span class='charter'><b>Issue:</b> Clone Hero reported a bad song. <b>Charter:</b> $charter</span>"
            } else {
                $extraInfo = "<span class='charter'><b>Duplicate song</b> | Charted by: $charter <span class='subtle'>($chartCount charts in your library)</span></span>"
            }
            $why = "<div class='why'><b>Why this copy was selected:</b><br>$reason</div>"
            $paths = "<details><summary>Show folder location</summary><div class='path'>$original</div></details>"
        } else {
            $charter = Escape-ReportText $item.Charter
            $original = Escape-ReportText $item.'Original Folder'
            $destination = Escape-ReportText $item.'Moved To (if applicable)'
            $problem = Escape-ReportText $item.'Problem (if any)'
            # Use the actual selection reason from this exact scan, not a
            # generic explanation of the move/quarantine operation.
            $moveReason = Escape-ReportText $item.'Reason For Action'
            $reasonType = Escape-ReportText $item.'Reason Type'
            $status = [string] $item.'What Happened'
            if ($status -eq 'Moved to safe holding folder') {
                $moveCount++
                $badge = 'Moved'
                $badgeType = 'move'
            } elseif ($status -eq 'Permanently deleted') {
                $deleteCount++
                $badge = 'Deleted'
                $badgeType = 'delete'
            } else {
                $otherCount++
                $badge = 'Not changed'
                $badgeType = 'other'
            }
            $extraInfo = "<span class='charter'><b>Issue:</b> $reasonType <span class='subtle'>| Charted by: $charter</span></span>"
            $reasonLabel = if ($status -eq 'Moved to safe holding folder') {
                'Why it was moved'
            } elseif ($status -eq 'Permanently deleted') {
                'Why it was deleted'
            } else {
                'Why it was selected'
            }
            if ([string]::IsNullOrWhiteSpace($moveReason)) {
                $moveReason = 'This copy was selected by the cleaner, but its specific selection reason was not recorded.'
            }
            $why = "<div class='why'><b>${reasonLabel}:</b><br>$moveReason</div>"
            if ($problem) {
                $why += "<div class='why issue'><b>Problem:</b> $problem</div>"
            }
            $paths = "<details><summary>Show folder location</summary><div class='path'><b>Original:</b><br>$original</div>"
            if ($destination) { $paths += "<div class='path'><b>Moved to:</b><br>$destination</div>" }
            $paths += '</details>'
        }

        $cardHtml = @"
<article class="song-card" data-action="$badgeType">
  <div class="card-top">
    <div class="song-title"><strong>$song</strong><span class="artist">$artist</span></div>
    <span class="badge $badgeType">$badge</span>
  </div>
  $extraInfo
  $why
  $paths
</article>
"@
        [void] $rows.AppendLine($cardHtml)
    }

    if ($ReportType -eq 'Proposed') {
        $title = 'Songs selected for removal'
        $subtitle = 'Only extra copies and problem songs selected to move or delete are shown.'
        $firstStatLabel = 'Move'
        $secondStatLabel = 'Delete'
        $thirdStat = ''
        $moveFilterLabel = 'Move'
        $deleteFilterLabel = 'Delete'
    } else {
        $title = 'Changes made to your songs'
        $subtitle = 'See what was moved or deleted and the exact reason each folder was selected.'
        $firstStatLabel = 'Moved'
        $secondStatLabel = 'Deleted'
        $thirdStat = "<span class='stat other-stat'><b>$otherCount</b> Not changed</span>"
        $moveFilterLabel = 'Moved'
        $deleteFilterLabel = 'Deleted'
    }
    $total = $Items.Count
    if ($total -eq 0) {
        [void] $rows.AppendLine('<p class="empty">No extra copies were selected.</p>')
    }

    $template = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__</title>
<style>
:root{color-scheme:light;font-family:Segoe UI,Arial,sans-serif;color:#182638;background:#f2f5f9}
*{box-sizing:border-box}body{margin:0;line-height:1.5}
main{max-width:1040px;margin:0 auto;padding:28px 20px 72px}
header{margin-bottom:21px}h1{font-size:clamp(24px,3vw,32px);line-height:1.2;margin:0 0 8px;font-weight:760;letter-spacing:-.03em}
.subtitle{margin:0;color:#536277;font-size:15px}
.stats{display:flex;flex-wrap:wrap;gap:11px;margin:22px 0}
.stat{display:flex;align-items:baseline;gap:9px;background:#fff;border:1px solid #dce4ee;border-radius:12px;padding:13px 18px;color:#394a61;font-size:14px}
.stat b{font-size:25px;line-height:1;font-weight:750;color:#1a293e}
.stat.move-stat{border-left:4px solid #1f8b70}.stat.delete-stat{border-left:4px solid #c44b55}
.stat.other-stat{border-left:4px solid #8893a2}
.toolbar{display:flex;flex-wrap:wrap;gap:10px;justify-content:space-between;align-items:center;margin:24px 0 14px}
.search{flex:1 1 280px;min-width:170px;padding:12px 14px;border:1px solid #cbd5e1;border-radius:11px;background:#fff;font:inherit;font-size:14px;outline-offset:3px}
.filters{display:flex;gap:7px;flex-wrap:wrap}.filter{cursor:pointer;border:1px solid #cbd5e1;border-radius:9px;background:white;color:#334155;font:inherit;font-size:14px;font-weight:600;padding:10px 15px}
.filter[aria-pressed="true"]{background:#243a56;color:#fff;border-color:#243a56}
#visible-count{font-size:13px;color:#536277;margin:0 0 14px}
.song-card{background:#fff;border:1px solid #dce4ee;border-radius:13px;padding:17px 20px;margin:0 0 12px;box-shadow:0 2px 5px rgba(19,39,68,.035)}
.card-top{display:flex;justify-content:space-between;gap:15px;align-items:flex-start;margin-bottom:8px}
.song-title strong{display:block;font-weight:740;font-size:18px;line-height:1.3;overflow-wrap:anywhere}
.artist{display:block;font-size:14px;color:#59677b;margin-top:2px}
.badge{flex:0 0 auto;display:inline-flex;align-items:center;justify-content:center;min-width:72px;border-radius:20px;padding:5px 12px;font-weight:750;font-size:13px;text-transform:uppercase;letter-spacing:.02em}
.badge.move{color:#146e57;background:#e0f4eb}.badge.delete{color:#a62b36;background:#fde8e9}.badge.other{color:#5e6977;background:#ebeff3}
.charter{display:block;margin:9px 0;font-size:14px;color:#334155;overflow-wrap:anywhere}.subtle{font-size:13px;color:#64748b}
.why{color:#28374b;font-size:14px;line-height:1.6;margin:10px 0 5px;padding-left:13px;border-left:3px solid #c2d1e4}
.why.issue{border-color:#b65d4d}
details{margin-top:12px;color:#55657b;font-size:13px}summary{cursor:pointer;color:#345987;font-weight:650;max-width:max-content}summary:hover{text-decoration:underline}
.path{font-family:Consolas,monospace;font-size:12px;overflow-wrap:anywhere;background:#f5f7fa;color:#4a586c;padding:10px;border-radius:7px;margin-top:6px}
.empty{background:white;border:1px solid #dce4ee;border-radius:12px;padding:25px;text-align:center;color:#66758a}
[hidden]{display:none!important}
@media(max-width:520px){main{padding:20px 12px 48px}.song-card{padding:15px}.stat{flex:1}.badge{min-width:65px}}
@media print{body{background:#fff}main{max-width:100%;padding:0}.toolbar,#visible-count,details{display:none!important}.song-card{break-inside:avoid;box-shadow:none}}
</style>
</head>
<body><main>
<header><h1>__TITLE__</h1><p class="subtitle">__SUBTITLE__</p></header>
<div class="stats">
  <span class="stat"><b>__TOTAL__</b> song folders</span>
  <span class="stat move-stat"><b>__MOVE_COUNT__</b> __MOVE_STAT_LABEL__</span>
  <span class="stat delete-stat"><b>__DELETE_COUNT__</b> __DELETE_STAT_LABEL__</span>
  __THIRD_STAT__
</div>
<div class="toolbar">
  <input class="search" id="search" type="search" placeholder="Find a song, artist, or charter..." aria-label="Search songs">
  <div class="filters" aria-label="Filter by action">
    <button class="filter" type="button" data-show="all" aria-pressed="true">All</button>
    <button class="filter" type="button" data-show="move" aria-pressed="false">__MOVE_FILTER_LABEL__</button>
    <button class="filter" type="button" data-show="delete" aria-pressed="false">__DELETE_FILTER_LABEL__</button>
  </div>
</div>
<p id="visible-count">Showing __TOTAL__ of __TOTAL__</p>
<section id="song-list">
__SONGS__
</section>
<script>
(function(){
  const items=Array.from(document.querySelectorAll('.song-card'));
  const search=document.getElementById('search');
  const buttons=Array.from(document.querySelectorAll('.filter'));
  const searchable=items.map(function(item){return item.textContent.toLocaleLowerCase();});
  let selected='all';
  function update(){
    const query=search.value.trim().toLocaleLowerCase();
    let visible=0;
    items.forEach(function(item,index){
      const matches=(selected==='all'||item.dataset.action===selected)&&searchable[index].includes(query);
      item.hidden=!matches;
      if(matches) visible++;
    });
    document.getElementById('visible-count').textContent='Showing '+visible+' of '+items.length;
  }
  search.addEventListener('input',update);
  buttons.forEach(function(button){
    button.addEventListener('click',function(){
      selected=button.dataset.show;
      buttons.forEach(function(b){b.setAttribute('aria-pressed',String(b===button));});
      update();
    });
  });
  update();
})();
</script>
</main></body></html>
'@
    $html = $template.Replace('__TITLE__', (Escape-ReportText $title)).Replace('__SUBTITLE__', (Escape-ReportText $subtitle))
    $html = $html.Replace('__TOTAL__', [string]$total).Replace('__MOVE_COUNT__', [string]$moveCount).Replace('__DELETE_COUNT__', [string]$deleteCount)
    $html = $html.Replace('__MOVE_STAT_LABEL__', $firstStatLabel).Replace('__DELETE_STAT_LABEL__', $secondStatLabel)
    $html = $html.Replace('__MOVE_FILTER_LABEL__', $moveFilterLabel).Replace('__DELETE_FILTER_LABEL__', $deleteFilterLabel)
    $html = $html.Replace('__THIRD_STAT__', $thirdStat).Replace('__SONGS__', $rows.ToString())
    [IO.File]::WriteAllText($Path, $html, (New-Object System.Text.UTF8Encoding($false)))
}

try {
    Write-Host ''
    Write-Host '========== CLONE HERO DUPLICATE CLEANER v33 ==========' -ForegroundColor Cyan
    Write-Host "Library: $Root"
    if (!(Test-Path -LiteralPath $Root -PathType Container)) { throw "Library not found: $Root" }

    Write-Host 'Song folder detected.' -ForegroundColor Green
    Write-Host ''
    $showReportOption = ($env:CH_DEDUPE_MENU_STAGE -eq '1')
    Write-Host '  1 - Check songs (nothing changes)'
    Write-Host '  2 - Move extra and bad songs'
    Write-Host '  3 - Move extras + delete the certain ones'
    Write-Host '  4 - Delete all extra and bad songs'
    Write-Host '  5 - Undo quarantine (restore moved songs)'
    if ($showReportOption) { Write-CHGold '  6 - Open the newest saved report' }
    Write-Host '  Q - Close this program'
    if ($showReportOption) {
        $mode = (Read-Host 'Choose 1, 2, 3, 4, 5, 6, or Q').Trim().ToUpperInvariant()
        if ($mode -notin @('1', '2', '3', '4', '5', '6', 'Q')) { throw 'Invalid menu choice.' }
    } else {
        $mode = (Read-Host 'Choose 1, 2, 3, 4, 5, or Q').Trim().ToUpperInvariant()
        if ($mode -notin @('1', '2', '3', '4', '5', 'Q')) { throw 'Invalid menu choice.' }
    }
    if ($mode -eq 'Q') { exit 99 }
    if ($mode -eq '5') {
        Restore-CHQuarantine
        exit 0
    }

    # Reports only open when explicitly requested. This does not rescan songs,
    # alter folders, or create a new report. Returns to menu after opening.
    if ($mode -eq '6') {
        if (!(Test-Path -LiteralPath $ReportDir -PathType Container)) {
            Write-Host 'No reports saved yet. Choose option 1 to check your songs first.' -ForegroundColor Yellow
            exit 0
        }
        $lastReport = Get-ChildItem -LiteralPath $ReportDir -File -Filter '*.html' -ErrorAction Stop |
            Where-Object { $_.Name -like 'Songs Selected for Removal - *.html' -or $_.Name -like 'Extra Songs Selected - *.html' -or
                           $_.Name -like 'Songs Moved or Deleted - *.html' -or $_.Name -like 'Songs Restored From Quarantine - *.html' } |
            Sort-Object -Property @{Expression="LastWriteTimeUtc";Descending=$true}, @{Expression="Name";Descending=$true} |
            Select-Object -First 1
        if ($null -eq $lastReport) {
            Write-Host 'No reports saved yet. Choose option 1 to check your songs first.' -ForegroundColor Yellow
        } else {
            Write-CHGold "Opening saved report: $($lastReport.Name)"
            Start-Process -FilePath $lastReport.FullName -ErrorAction Stop
        }
        exit 0
    }

    # Refuse to run from Downloads/Desktop/etc. The program must live inside
    # the actual song library. This check happens BEFORE reports are created.
    $firstSongIni = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter 'song.ini' -Force -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $firstSongIni) {
        Write-Host ''
        Write-Host 'WRONG FOLDER - NO CLONE HERO SONGS FOUND HERE.' -ForegroundColor Red
        Write-Host "This program is currently in: $Root" -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'Move this file into your MAIN Clone Hero song folder and run it again.' -ForegroundColor Cyan
        Write-Host 'It should be in the same folder that contains your song, album, or pack folders.'
        Write-Host ''
        Write-Host 'Nothing was scanned, moved, deleted, or saved.' -ForegroundColor Green
        exit 98
    }

    $apply = ($mode -ne '1')
    $moveOnly = ($mode -eq '2')
    $moveAndDelete = ($mode -eq '3')
    $deleteAll = ($mode -eq '4')
    $hasPermanentDelete = ($moveAndDelete -or $deleteAll)

    if ($apply) {
        $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'Clone.*Hero' })
        if ($running.Count -gt 0) { throw 'Close Clone Hero before moving or deleting song folders.' }
    }

    New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
    $planPath = Join-Path $ReportDir ("Songs Selected for Removal - $RunStamp.html")
    $actionsPath = Join-Path $ReportDir ("Songs Moved or Deleted - $RunStamp.html")
    $errorsPath = Join-Path $ReportDir ("Problems Scanning Songs - $RunStamp.txt")

    Write-Host ''
    Write-Host 'Checking this PC for Clone Hero saved scores...' -ForegroundColor Cyan
    $validSources = New-Object 'System.Collections.Generic.List[object]'
    $checkedFolders = @{}
    $locations = @(Find-CHDataCandidates $Root)
    foreach ($location in $locations) {
        $key = $location.Folder.ToLowerInvariant()
        $checkedFolders[$key] = $true
        try {
            $valid = Test-CHDataFolder $location.Folder $Root $location.Description
            $validSources.Add($valid)
            Write-Host "[OK] $($location.Description): $($location.Folder)" -ForegroundColor Green
        } catch {
            Write-Host "[CHECK] $($location.Folder): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    if ($validSources.Count -eq 0) {
        Write-Host 'No compatible score + song-cache pair was detected automatically.' -ForegroundColor Yellow
        Write-Host 'The game can be installed on any drive. Its scores are stored separately.'
        $manual = (Read-Host 'Enter the folder containing scoredata.bin and songcache.bin, or Enter to preview only').Trim().Trim('"')
        if ($manual) {
            try {
                if (Test-Path -LiteralPath $manual -PathType Leaf) {
                    $manual = Split-Path -Parent $manual
                }
                # Accept the portable game's install folder as well as GameData itself.
                if (!(Test-Path -LiteralPath (Join-Path $manual 'scoredata.bin') -PathType Leaf) -and
                    (Test-Path -LiteralPath (Join-Path $manual 'GameData') -PathType Container)) {
                    $manual = Join-Path $manual 'GameData'
                }
                $valid = Test-CHDataFolder $manual $Root 'Folder selected by user'
                $validSources.Add($valid)
                Write-Host "[OK] Compatible files found: $($valid.Folder)" -ForegroundColor Green
            } catch {
                Write-Warning "That folder could not be verified: $($_.Exception.Message)"
            }
        }
    }

    $scoreReady = $false
    $cacheReady = $false
    $scoreMap = @{}
    $cache = @{}
    $scoreCount = 0
    $cacheLastScanUtc = [datetime]::MinValue
    $scorePath = ''
    $cachePath = ''
    $multipleSources = ($validSources.Count -gt 1)
    $selected = $null
    if ($validSources.Count -eq 1) {
        $selected = $validSources[0]
    } elseif ($multipleSources) {
        Write-Host ''
        Write-Host 'More than one valid Clone Hero score folder was found.' -ForegroundColor Yellow
        Write-Host 'Choose which set of scores to use for this run:'
        for ($i = 0; $i -lt $validSources.Count; $i++) {
            $number = $i + 1
            $source = $validSources[$i]
            Write-Host "  $number - $($source.Folder) ($($source.Cache.ScoreHashMatchesLocal) scores matched)"
        }
        $choice = (Read-Host 'Enter a number, or press Enter to preview only').Trim()
        $numberSelected = 0
        if ([int]::TryParse($choice, [ref] $numberSelected) -and
            $numberSelected -ge 1 -and $numberSelected -le $validSources.Count) {
            $selected = $validSources[$numberSelected - 1]
        }
    }

    if ($null -ne $selected) {
        $scorePath = $selected.ScorePath
        $cachePath = $selected.CachePath
        $scoreMap = $selected.Scores.Map
        $scoreCount = $selected.Scores.SongCount
        $scoreReady = $true
        $cache = $selected.Cache.Folders
        $cacheReady = $true
        $cacheLastScanUtc = $selected.CacheLastScanUtc
        Write-Host ''
        Write-Host '[OK] Song folder detected.' -ForegroundColor Green
        Write-Host '[OK] Score and song-cache files validated.' -ForegroundColor Green
        Write-Host "[OK] $($selected.Cache.MatchedEntries) songs in this library linked to the game cache." -ForegroundColor Green
        Write-Host "[OK] $($selected.Cache.ScoreHashMatchesLocal) of $($scoreMap.Count) saved song scores linked to this library." -ForegroundColor Green
        if ($selected.Cache.MissingChartFiles -gt 0) {
            Write-Host "[CHECK] $($selected.Cache.MissingChartFiles) cached chart paths no longer exist. Some songs may have unknown history." -ForegroundColor Yellow
        }
        if ($selected.Cache.ScoreHashMatchesLocal -lt $scoreMap.Count) {
            Write-Host '[CHECK] Some saved scores are for songs not linked to this folder.' -ForegroundColor Yellow
        }
    } else {
        Write-Host ''
        Write-Host '[STOP] No verified score + cache pair. This run is preview-only.' -ForegroundColor Yellow
    }

    # If two installations have separate score histories, selecting one cannot
    # prove that songs have never been played in the other installation.
    if ($multipleSources) {
        Write-Host '[CHECK] Other detected installations may have different scores. Histories were not merged.' -ForegroundColor Yellow
    }
    if ($multipleSources -and $hasPermanentDelete) {
        Write-Host '[STOP] More than one score library was found, so permanent deletion is disabled for safety.' -ForegroundColor Yellow
        Write-Host 'This run will move the selected extra songs instead.' -ForegroundColor Yellow
        $moveOnly = $true
        $moveAndDelete = $false
        $deleteAll = $false
        $hasPermanentDelete = $false
    }
    if ($apply -and (!$scoreReady -or !$cacheReady)) {
        Write-Host '[STOP] Changes require verified scores AND a compatible song cache. Running preview only.' -ForegroundColor Yellow
        $apply = $false
        $moveOnly = $false
        $moveAndDelete = $false
        $deleteAll = $false
        $hasPermanentDelete = $false
    }

    Write-Host ''
    Write-Host 'Checking every song folder, including album and pack subfolders...' -ForegroundColor DarkCyan
    $songs = New-Object 'System.Collections.Generic.List[object]'
    $charterCounts = @{}
    $groups = @{}
    # Index chart sizes once: a byte-identical chart MUST be the same size.
    # Prevent a rejected game chart from hashing thousands of unrelated files.
    $chartsByByteSize = @{}
    $scanErrors = @()
    $readErrors = New-Object 'System.Collections.Generic.List[string]'
    $iniFiles = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter 'song.ini' -Force -ErrorAction SilentlyContinue -ErrorVariable +scanErrors
    foreach ($ini in $iniFiles) {
        try {
            $meta = Read-SongIni $ini.FullName
            $folder = $ini.DirectoryName
            $folderKey = Get-FolderKey $folder
            $chart = ''
            foreach ($fileName in @('notes.chart', 'notes.mid', 'notes.midi')) {
                $candidate = Join-Path $folder $fileName
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { $chart = $candidate; break }
            }
            if (!$chart) {
                $fallback = Get-ChildItem -LiteralPath $folder -File -ErrorAction Stop |
                    Where-Object { $_.Extension.ToLowerInvariant() -in @('.chart', '.mid', '.midi') } |
                    Sort-Object Name | Select-Object -First 1
                if ($fallback) { $chart = $fallback.FullName }
            }
            $chartBytes = [long]0
            if ($chart) { $chartBytes = (Get-Item -LiteralPath $chart -ErrorAction Stop).Length }
            $nameKey = Normalize-Value $meta.Name
            $artistKey = Normalize-Value $meta.Artist
            $charterKey = Normalize-Value $meta.Charter
            $dupKey = ''
            if ($nameKey -and $artistKey) { $dupKey = $artistKey + [char]31 + $nameKey }

            $status = 'UNKNOWN'
            $method = 'No verified cache link'
            $plays = 0
            $records = 0
            $maxScore = [uint32]0
            # A cache older than the chart or metadata is potentially stale.
            $cacheFresh = $false
            if ($scoreReady -and $cacheReady -and $cache.ContainsKey($folderKey) -and $chart) {
                $chartTimeUtc = (Get-Item -LiteralPath $chart).LastWriteTimeUtc
                $cacheFresh = ($cacheLastScanUtc -ge $chartTimeUtc -and
                               $cacheLastScanUtc -ge $ini.LastWriteTimeUtc)
            }
            if ($cacheFresh) {
                $status = 'UNPLAYED'
                $method = 'songcache.bin hash'
                foreach ($hash in $cache[$folderKey]) {
                    if ($scoreMap.ContainsKey($hash)) {
                        $saved = $scoreMap[$hash]
                        $plays = [Math]::Max($plays, $saved.PlayCount)
                        $records += $saved.ScoreRecords
                        $maxScore = [Math]::Max($maxScore, $saved.MaxScore)
                        # A record in scoredata.bin alone is reason to keep this chart,
                        # even if its play count or saved points happen to be zero.
                        $status = 'PLAYED'
                    }
                }
            } elseif ($scoreReady -and $chart -and $scoreMap.Count -gt 0) {
                # This can prove a PLAYED chart on older versions. A miss proves nothing.
                try {
                    $md5 = (Get-FileHash -LiteralPath $chart -Algorithm MD5 -ErrorAction Stop).Hash.ToLowerInvariant()
                    if ($scoreMap.ContainsKey($md5)) {
                        $saved = $scoreMap[$md5]
                        $status = 'PLAYED'
                        $method = 'legacy MD5 hash match'
                        $plays = $saved.PlayCount
                        $records = $saved.ScoreRecords
                        $maxScore = $saved.MaxScore
                    }
                } catch { }
            }

            $song = [pscustomobject]@{
                Name = $meta.Name; Artist = $meta.Artist; Charter = $meta.Charter
                Folder = $folder; ChartFile = $chart; ChartBytes = $chartBytes
                ScoreStatus = $status; PlayCount = $plays; ScoreRecords = $records
                MaxScore = $maxScore; ScoreMatchMethod = $method
                CharterLibraryCount = 0; DuplicateKey = $dupKey
            }
            $songs.Add($song)
            if ($chart -and $chartBytes -gt 0) {
                $sizeKey = [string]$chartBytes
                if (!$chartsByByteSize.ContainsKey($sizeKey)) {
                    $chartsByByteSize[$sizeKey] = New-Object 'System.Collections.Generic.List[object]'
                }
                $chartsByByteSize[$sizeKey].Add($song)
            }
            if ($charterKey) {
                if (!$charterCounts.ContainsKey($charterKey)) { $charterCounts[$charterKey] = 0 }
                $charterCounts[$charterKey]++
            }
            if ($dupKey) {
                if (!$groups.ContainsKey($dupKey)) {
                    $groups[$dupKey] = New-Object 'System.Collections.Generic.List[object]'
                }
                $groups[$dupKey].Add($song)
            }
            if (($songs.Count % 500) -eq 0) {
                Write-Host "Song folders checked so far: $($songs.Count)..." -ForegroundColor DarkCyan
            }
        } catch {
            $readErrors.Add("$($ini.FullName) -- $($_.Exception.Message)")
        }
    }

    foreach ($song in $songs) {
        $ck = Normalize-Value $song.Charter
        if ($ck -and $charterCounts.ContainsKey($ck)) {
            $song.CharterLibraryCount = $charterCounts[$ck]
        }
    }

    # Locate and timestamp scan reports once for both game-error categories.
    $availableCHLogs = @(Find-CHBadSongLogs $Root)

    # Collect Clone Hero's chart-duplication errors separately from actual
    # broken-song errors. Never use a log entry ALONE to select a deletion.
    $gameDuplicateErrors = @()
    $gameDuplicateLogPath = ''
    $gameDuplicateLogTimeUtc = [datetime]::MinValue
    $gameDuplicateFolderKeys = @{}
    foreach ($log in $availableCHLogs) {
        try {
            $entries = @(Read-CHDuplicateChartLog $log.FullName $Root)
            if ($entries.Count -lt 1) { continue }
            $gameDuplicateErrors = $entries
            $gameDuplicateLogPath = $log.FullName
            $gameDuplicateLogTimeUtc = $log.LastWriteTimeUtc
            foreach ($entry in $entries) {
                if ($entry.InLibrary -and $entry.Exists) {
                    $gameDuplicateFolderKeys[(Get-FolderKey $entry.Folder)] = $true
                }
            }
            break
        } catch {
            Write-Host "Could not read Clone Hero duplicate-chart errors: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # Read Clone Hero's latest bad-song scan before deciding the duplicate winners.
    $badSongsSkippedOldScan = 0
    $badSongsSkippedSafety = 0
    $badLogUsed = ''
    $badCandidates = New-Object 'System.Collections.Generic.List[object]'
    $badFolderKeys = @{}
    foreach ($log in $availableCHLogs) {
        try {
            $maybe = @(Read-CHBadSongLog $log.FullName $Root)
            if ($maybe.Count -lt 1) { continue }
            $badLogUsed = $log.FullName
            foreach ($bad in $maybe) {
                if (!(Test-CHBadSongReportFresh $bad.Folder $bad.LogTimeUtc)) {
                    $badSongsSkippedOldScan++
                    continue
                }
                if (!(Test-CHSingleSongFolder $bad.Folder)) {
                    $badSongsSkippedSafety++
                    continue
                }
                $badCandidates.Add($bad)
                $badFolderKeys[(Get-FolderKey $bad.Folder)] = $true
            }
            break  # Newest applicable log wins; never merge obsolete scan results.
        } catch {
            Write-Host "Could not read $($log.FullName): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    $plan = New-Object 'System.Collections.Generic.List[object]'
    $remove = New-Object 'System.Collections.Generic.List[object]'
    $deleteCandidates = New-Object 'System.Collections.Generic.List[object]'
    $quarantineOnly = New-Object 'System.Collections.Generic.List[object]'
    $duplicateGroups = 0
    $blockedGroups = 0
    $unknownGroupsRanked = 0
    # Unknown-score fallback is permitted ONLY when scores and the song cache
    # were both successfully validated. Unknown-song removals are quarantine-only.
    $canRankUnknown = ($scoreReady -and $cacheReady)
    foreach ($key in $groups.Keys) {
        $members = @($groups[$key].ToArray())
        if ($members.Count -lt 2) { continue }
        $duplicateGroups++
        $unknown = @($members | Where-Object { $_.ScoreStatus -eq 'UNKNOWN' })
        $played = @($members | Where-Object { $_.ScoreStatus -eq 'PLAYED' })
        $hasUnknown = ($unknown.Count -gt 0)
        # This count is compiled across EVERY indexed song.ini in the library,
        # not merely songs in this duplicate group. Prefer the most common
        # charter, then the larger chart file, then a stable folder path.
        # Prefer an intact copy over a version Clone Hero itself rejected.
        $keeperChoices = @($members | Where-Object {
            !$badFolderKeys.ContainsKey((Get-FolderKey $_.Folder))
        })
        if ($keeperChoices.Count -eq 0) { $keeperChoices = $members }
        $winner = $keeperChoices | Sort-Object `
            @{ Expression = 'CharterLibraryCount'; Descending = $true }, `
            @{ Expression = 'ChartBytes'; Descending = $true }, `
            @{ Expression = 'Folder'; Descending = $false } | Select-Object -First 1
        if ($hasUnknown) {
            if ($canRankUnknown) { $unknownGroupsRanked++ }
            else { $blockedGroups++ }
        }
        foreach ($song in $members) {
            $action = 'KEEP'
            $reason = ''
            if ($song.ScoreStatus -eq 'PLAYED') {
                # A confirmed score ALWAYS wins over popularity and is never
                # removed, even if several versions of a song were played.
                $reason = 'Confirmed play history or saved score; always protected'
            } elseif ($hasUnknown -and !$canRankUnknown) {
                $action = 'REVIEW'
                $reason = 'Score or cache validation unavailable; entire uncertain group protected'
            } elseif ($hasUnknown) {
                if ($song.Folder -eq $winner.Folder) {
                    $reason = "Preferred charter '$($winner.Charter)' has $($winner.CharterLibraryCount) charts across indexed library; kept despite unknown score status in group"
                } else {
                    # This is not proof that the chart has never been played.
                    # The script may MOVE these folders, but will not DELETE them.
                    $action = 'QUARANTINE_ONLY'
                    $reason = "Charter-count fallback: preferred '$($winner.Charter)' ($($winner.CharterLibraryCount) indexed charts); score status uncertain, quarantine only"
                }
            } elseif ($song.Folder -eq $winner.Folder -and $keeperChoices.Count -lt $members.Count) {
                $reason = 'Kept a working version because another copy was reported broken'
            } elseif ($played.Count -gt 0) {
                $action = 'REMOVE'
                $reason = 'Verified unplayed duplicate; confirmed played copies preserved'
            } elseif ($song.Folder -eq $winner.Folder) {
                $reason = 'No plays in group; preferred charter by full-library chart count (then chart size)'
            } else {
                $action = 'REMOVE'
                $reason = 'Verified unplayed duplicate; another charter has higher full-library chart count/tie-break'
            }
            # The browser report lists ONLY song folders selected for removal.
            # Nothing being kept or protected is included in this report.
            if ($action -in @('REMOVE', 'QUARANTINE_ONLY')) {
                $thisCharter = $song.Charter
                if ([string]::IsNullOrWhiteSpace($thisCharter)) { $thisCharter = '(not listed)' }
                $bestCharter = $winner.Charter
                if ([string]::IsNullOrWhiteSpace($bestCharter)) { $bestCharter = '(not listed)' }

                if ($action -eq 'QUARANTINE_ONLY') {
                    $allowed = 'Move'
                    $prefix = 'Play history is uncertain. '
                } else {
                    $allowed = 'Delete'
                    $prefix = 'No saved score matched this copy. '
                }
                if ($badFolderKeys.ContainsKey((Get-FolderKey $song.Folder))) {
                    $because = 'Clone Hero reported this version as broken. An intact copy is preferred.'
                } elseif ($played.Count -gt 0) {
                    $because = 'Another copy has a saved score.'
                } elseif ($song.CharterLibraryCount -lt $winner.CharterLibraryCount) {
                    $because = "$thisCharter has $($song.CharterLibraryCount) charts in your library. $bestCharter has $($winner.CharterLibraryCount), so this copy was selected."
                } elseif ($song.ChartBytes -lt $winner.ChartBytes) {
                    $because = "The charters both have $($song.CharterLibraryCount) charts. This chart file is smaller."
                } else {
                    $because = "The charters have the same chart count and file size, so folder order broke the tie."
                }

                $plan.Add([pscustomobject][ordered]@{
                    'Reason Type' = 'Duplicate'
                    'Song' = $song.Name
                    'Artist' = $song.Artist
                    'Charter of This Extra Copy' = $thisCharter
                    'Total Charts by This Charter' = $song.CharterLibraryCount
                    'Suggested Action' = $allowed
                    'Why This Copy Was Chosen' = $prefix + $because
                    'Folder to Remove From Library' = $song.Folder
                })
            }
            if ($action -eq 'REMOVE') {
                $remove.Add($song)
                $deleteCandidates.Add($song)
            } elseif ($action -eq 'QUARANTINE_ONLY') {
                $remove.Add($song)
                $quarantineOnly.Add($song)
            }
        }
    }

    # Include Clone Hero's own scan errors alongside duplicate recommendations.
    # Do NOT classify a song as bad merely because it has no guitar chart.
    # Ignore warnings, no-instrument reports, and duplicate-chart log entries.
    $duplicateExtras = $remove.Count
    $badSongsAdded = 0
    $badSongsMoved = 0
    $badSongsDeletable = 0
    $alreadySelected = @{}
    $selectedPlan = @{}
    foreach ($existingSong in $remove) {
        $alreadySelected[(Get-FolderKey $existingSong.Folder)] = $existingSong
    }
    foreach ($p in $plan) {
        $selectedPlan[(Get-FolderKey $p.'Folder to Remove From Library')] = $p
    }
    $songsByFolder = @{}
    foreach ($existingSong in $songs) {
        $songsByFolder[(Get-FolderKey $existingSong.Folder)] = $existingSong
    }
    foreach ($bad in $badCandidates) {
        $badKey = Get-FolderKey $bad.Folder
        if ($selectedPlan.ContainsKey($badKey)) {
            # Never select a folder twice. Retain its safer existing action,
            # but recheck the scan error right before any file operation.
            $p = $selectedPlan[$badKey]
            $p.'Why This Copy Was Chosen' += ' Clone Hero also reported this folder as a bad song: ' + $bad.Reason
            if ($alreadySelected.ContainsKey($badKey)) {
                $alreadySelected[$badKey] | Add-Member -NotePropertyName IsBadSong -NotePropertyValue $true -Force
            }
            continue
        }
        $songMeta = $null
        if ($songsByFolder.ContainsKey($badKey)) {
            $songMeta = $songsByFolder[$badKey]
        }
        $badName = Split-Path -Leaf $bad.Folder
        $badArtist = '(not listed)'
        $badCharter = '(not listed)'
        $status = 'UNKNOWN'
        if ($null -ne $songMeta) {
            if ($songMeta.Name) { $badName = $songMeta.Name }
            if ($songMeta.Artist) { $badArtist = $songMeta.Artist }
            if ($songMeta.Charter) { $badCharter = $songMeta.Charter }
            $status = $songMeta.ScoreStatus
        } else {
            # No song.ini might mean a former played chart lost its metadata.
            # Check any existing cache link before treating its history as unknown.
            $badIni = Join-Path $bad.Folder 'song.ini'
            if (Test-Path -LiteralPath $badIni -PathType Leaf) {
                try {
                    $meta = Read-SongIni $badIni
                    if ($meta.Name) { $badName = $meta.Name }
                    if ($meta.Artist) { $badArtist = $meta.Artist }
                    if ($meta.Charter) { $badCharter = $meta.Charter }
                } catch { }
            }
            if ($scoreReady -and $cacheReady -and $cache.ContainsKey($badKey)) {
                $status = 'UNPLAYED'
                foreach ($h in $cache[$badKey]) {
                    if ($scoreMap.ContainsKey($h)) { $status = 'PLAYED'; break }
                }
                # An outdated cache cannot certify that there is no play record.
                if ($status -eq 'UNPLAYED' -and
                    $cacheLastScanUtc -lt $bad.LogTimeUtc.AddMinutes(-10)) {
                    $status = 'UNKNOWN'
                }
            }
        }
        # Deleted bad songs must have verified non-played history, not merely
        # a fresh game error. All unknown/played problems go to quarantine.
        $allowed = if ($status -eq 'UNPLAYED') { 'Delete' } else { 'Move' }
        $history = if ($status -eq 'PLAYED') {
            'Its saved score or play history is protected; moving only.'
        } elseif ($status -eq 'UNPLAYED') {
            'No saved scores match this indexed song.'
        } else {
            'Play history could not be confirmed; moving only.'
        }
        $badObj = [pscustomobject]@{
            Name = $badName
            Artist = $badArtist
            Charter = $badCharter
            Folder = $bad.Folder
            IsBadSong = $true
            ScoreStatus = $status
        }
        $remove.Add($badObj)
        $alreadySelected[$badKey] = $badObj
        if ($allowed -eq 'Delete') {
            $deleteCandidates.Add($badObj)
            $badSongsDeletable++
        } else {
            $quarantineOnly.Add($badObj)
            $badSongsMoved++
        }
        $badSongsAdded++
        $plan.Add([pscustomobject][ordered]@{
            'Reason Type' = 'Bad song'
            'Song' = $badName
            'Artist' = $badArtist
            'Charter of This Extra Copy' = $badCharter
            'Total Charts by This Charter' = ''
            'Suggested Action' = $allowed
            'Why This Copy Was Chosen' = $bad.Reason + ' ' + $history
            'Folder to Remove From Library' = $bad.Folder
        })
    }

    # Preserve played charts even if they later become broken.
    # Modes 2/3 can move them to quarantine. Mode 4 leaves them untouched.
    $playedBadProtected = 0
    if ($deleteAll) {
        foreach ($selectedSong in @($remove.ToArray())) {
            $isBad = ($selectedSong.PSObject.Properties['IsBadSong'] -and $selectedSong.IsBadSong)
            if ($isBad -and $selectedSong.ScoreStatus -eq 'PLAYED') {
                $playedBadProtected++
                $null = $remove.Remove($selectedSong)
                $null = $quarantineOnly.Remove($selectedSong)
                $null = $deleteCandidates.Remove($selectedSong)
                foreach ($p in @($plan.ToArray())) {
                    if ((Get-FolderKey $p.'Folder to Remove From Library') -eq
                        (Get-FolderKey $selectedSong.Folder)) {
                        $null = $plan.Remove($p)
                    }
                }
            }
        }
        $badSongsAdded = [Math]::Max(0, $badSongsAdded - $playedBadProtected)
    }

    # GAME-REPORTED DUPLICATE CHARTS
    # The game can reject a chart before caching it, so ordinary cache-based
    # duplicate rules sometimes leave every copy in place. Resolve those
    # rejections IN THE SAME run as regular duplicates and genuinely bad songs.
    # We never trust a log path alone: require an intact counterpart, and
    # never remove the final surviving chart from a matched set.
    $gameDuplicatesAdded = 0
    $gameDuplicatesProtected = 0
    $gameDuplicatesUnmatched = 0
    $gameCandidates = New-Object 'System.Collections.Generic.List[object]'
    $gameProtectedKeepers = @{}
    foreach ($entry in $gameDuplicateErrors) {
        if (!$entry.InLibrary -or !$entry.Exists) { continue }
        $badKey = Get-FolderKey $entry.Folder
        if (!$songsByFolder.ContainsKey($badKey)) {
            $gameDuplicatesUnmatched++
            continue
        }
        $badSong = $songsByFolder[$badKey]
        $scorePriority = 0
        if ($badSong.ScoreStatus -eq 'PLAYED') { $scorePriority = 1 }
        $gameCandidates.Add([pscustomobject]@{
            Song = $badSong
            FolderKey = $badKey
            ScorePriority = $scorePriority
            CharterCount = $badSong.CharterLibraryCount
            ChartBytes = $badSong.ChartBytes
            Folder = $badSong.Folder
        })
    }
    # Process lower-priority chart copies first. If two reported folders have
    # no third copy, this keeps the stronger charter's version in the library.
    $gameCandidatesSorted = @($gameCandidates.ToArray() | Sort-Object `
        @{Expression='ScorePriority';Descending=$false}, `
        @{Expression='CharterCount';Descending=$false}, `
        @{Expression='ChartBytes';Descending=$false}, `
        @{Expression='Folder';Descending=$false})
    $chartFileFingerprints = @{}
    foreach ($candidate in $gameCandidatesSorted) {
        $badKey = $candidate.FolderKey
        $badSong = $candidate.Song
        if ($alreadySelected.ContainsKey($badKey) -or $gameProtectedKeepers.ContainsKey($badKey)) { continue }
        if (!(Test-CHSingleSongFolder $badSong.Folder)) {
            $gameDuplicatesProtected++
            continue
        }
        if (!$badSong.ChartFile -or $badSong.ChartBytes -le 0 -or
            !(Test-Path -LiteralPath $badSong.ChartFile -PathType Leaf)) {
            $gameDuplicatesUnmatched++
            continue
        }
        if (!$gameDuplicateLogPath -or
            !(Test-CHBadSongReportFresh $badSong.Folder $gameDuplicateLogTimeUtc)) {
            $gameDuplicatesProtected++
            continue
        }

        $peers = @()
        $matchMethod = ''
        # A game-reported duplicate with the SAME title/artist in another song
        # folder is suitable for QUARANTINE, not for automatic deletion.
        if ($badSong.DuplicateKey -and $groups.ContainsKey($badSong.DuplicateKey)) {
            $peers = @($groups[$badSong.DuplicateKey].ToArray() | Where-Object {
                $otherKey = Get-FolderKey $_.Folder
                $otherKey -ne $badKey -and
                !$alreadySelected.ContainsKey($otherKey) -and
                !$badFolderKeys.ContainsKey($otherKey) -and
                $_.ChartFile -and $_.ChartBytes -gt 0 -and
                (Test-Path -LiteralPath $_.ChartFile -PathType Leaf)
            })
            if ($peers.Count -gt 0) { $matchMethod = 'Matching song title and artist, also confirmed as a duplicate by Clone Hero' }
        }
        # Different metadata can describe the same chart bytes. Compare only
        # charts of the SAME file size, a necessary condition for byte equality.
        # Hashes are cached across all reported game duplicates during this run.
        if ($peers.Count -eq 0) {
            $sizeKey = [string]$badSong.ChartBytes
            if ($chartsByByteSize.ContainsKey($sizeKey) -and
                $chartsByByteSize[$sizeKey].Count -gt 1) {
                try {
                    if (!$chartFileFingerprints.ContainsKey($badSong.ChartFile)) {
                        $chartFileFingerprints[$badSong.ChartFile] = (Get-FileHash -LiteralPath $badSong.ChartFile -Algorithm SHA256 -ErrorAction Stop).Hash
                    }
                    $suspectHash = $chartFileFingerprints[$badSong.ChartFile]
                    $foundPeer = New-Object 'System.Collections.Generic.List[object]'
                    foreach ($otherSong in $chartsByByteSize[$sizeKey]) {
                        $otherKey = Get-FolderKey $otherSong.Folder
                        if ($otherKey -eq $badKey -or $alreadySelected.ContainsKey($otherKey) -or
                            $badFolderKeys.ContainsKey($otherKey) -or !$otherSong.ChartFile -or
                            !(Test-Path -LiteralPath $otherSong.ChartFile -PathType Leaf)) { continue }
                        if (!$chartFileFingerprints.ContainsKey($otherSong.ChartFile)) {
                            $chartFileFingerprints[$otherSong.ChartFile] = (Get-FileHash -LiteralPath $otherSong.ChartFile -Algorithm SHA256 -ErrorAction Stop).Hash
                        }
                        if ($chartFileFingerprints[$otherSong.ChartFile] -eq $suspectHash) {
                            $foundPeer.Add($otherSong)
                        }
                    }
                    $peers = @($foundPeer.ToArray())
                    if ($peers.Count -gt 0) { $matchMethod = 'Identical chart file still exists in another folder' }
                } catch {
                    # If files cannot be read, keep them rather than guessing.
                    $peers = @()
                }
            }
        }
        if ($peers.Count -eq 0) {
            $gameDuplicatesUnmatched++
            continue
        }
        # Ensure exactly which copy remains, and favor confirmed saved scores
        # followed by the charter with the most charts in the entire library.
        $peer = @($peers | Sort-Object `
            @{Expression={ if ($_.ScoreStatus -eq 'PLAYED') { 1 } else { 0 } };Descending=$true}, `
            @{Expression={ if ($gameDuplicateFolderKeys.ContainsKey((Get-FolderKey $_.Folder))) { 0 } else { 1 } };Descending=$true}, `
            @{Expression='CharterLibraryCount';Descending=$true}, `
            @{Expression='ChartBytes';Descending=$true}, `
            @{Expression='Folder';Descending=$false})[0]

        $sameChartVerified = $false
        try {
            # Compare actual chart files. A shared hash in an old song cache
            # does not prove today's files are identical. Match size first to
            # avoid hashing a pair that cannot possibly match.
            if ($badSong.ChartBytes -gt 0 -and
                $badSong.ChartBytes -eq $peer.ChartBytes -and
                (Test-Path -LiteralPath $peer.ChartFile -PathType Leaf)) {
                if (!$chartFileFingerprints.ContainsKey($badSong.ChartFile)) {
                    $chartFileFingerprints[$badSong.ChartFile] = (Get-FileHash -LiteralPath $badSong.ChartFile -Algorithm SHA256 -ErrorAction Stop).Hash
                }
                if (!$chartFileFingerprints.ContainsKey($peer.ChartFile)) {
                    $chartFileFingerprints[$peer.ChartFile] = (Get-FileHash -LiteralPath $peer.ChartFile -Algorithm SHA256 -ErrorAction Stop).Hash
                }
                $sameChartVerified = ($chartFileFingerprints[$badSong.ChartFile] -eq $chartFileFingerprints[$peer.ChartFile])
            }
        } catch { $sameChartVerified = $false }
        # Never risk the only known copy containing a saved score when
        # equivalence to the remaining chart has not been established.
        if ($badSong.ScoreStatus -eq 'PLAYED' -and
            (!$sameChartVerified -or $deleteAll)) {
            # Moving a verified identical played copy is reversible (2/3).
            # Never permanently delete a played chart in option 4.
            $gameDuplicatesProtected++
            continue
        }
        # Game-log-only selections are QUARANTINE_ONLY: absent cache records
        # are not proof that a rejected chart has never been played.
        $reasonText = 'Clone Hero flagged this chart as a duplicate. ' + $matchMethod + '. '
        $reasonText += "Keeping $($peer.Charter)'s version in the song library. "
        if ($badSong.ScoreStatus -eq 'PLAYED') {
            $reasonText += 'Same chart verified in the remaining copy, protecting the saved score.'
        } else {
            $reasonText += 'Score history for this rejected chart is not fully verified, so moving is safer.'
        }
        # Lock this counterpart so later error entries cannot remove it too.
        $gameProtectedKeepers[(Get-FolderKey $peer.Folder)] = $true
        $badSong | Add-Member -NotePropertyName IsGameLogDuplicate -NotePropertyValue $true -Force
        $badSong | Add-Member -NotePropertyName GameDuplicateKeeper -NotePropertyValue $peer.Folder -Force
        $badSong | Add-Member -NotePropertyName GameDuplicateLogTimeUtc -NotePropertyValue $gameDuplicateLogTimeUtc -Force
        $badSong | Add-Member -NotePropertyName GameDuplicateSameChart -NotePropertyValue $sameChartVerified -Force
        $remove.Add($badSong)
        $quarantineOnly.Add($badSong)
        $alreadySelected[$badKey] = $badSong
        $gameDuplicatesAdded++
        $plan.Add([pscustomobject][ordered]@{
            'Reason Type' = 'Duplicate reported by Clone Hero'
            'Song' = $badSong.Name
            'Artist' = $badSong.Artist
            'Charter of This Extra Copy' = $badSong.Charter
            'Total Charts by This Charter' = $badSong.CharterLibraryCount
            'Suggested Action' = 'Move'
            'Why This Copy Was Chosen' = $reasonText
            'Folder to Remove From Library' = $badSong.Folder
        })
    }

    # When the regular duplicate logic already selected a game-rejected
    # chart, explain this extra evidence in the removal-only browser report.
    # This does not create extra removals or compromise score protection.
    $gameDuplicatesAlreadySelected = 0
    foreach ($p in $plan) {
        $pkey = Get-FolderKey $p.'Folder to Remove From Library'
        if ($gameDuplicateFolderKeys.ContainsKey($pkey)) {
            $gameDuplicatesAlreadySelected++
            if ($p.'Reason Type' -ne 'Duplicate reported by Clone Hero') {
                $p.'Why This Copy Was Chosen' += ' Clone Hero also flagged this chart as a duplicate during its song scan.'
            }
        }
    }

    # Make the saved preview reflect the action chosen THIS run.
    # Mode 1 shows the conservative recommendation; modes 2-4 show actual intentions.
    if ($moveOnly) {
        foreach ($item in $plan) { $item.'Suggested Action' = 'Move' }
    } elseif ($deleteAll) {
        foreach ($item in $plan) { $item.'Suggested Action' = 'Delete' }
    }
    $sortedPlan = @($plan.ToArray() | Sort-Object Artist, Song, 'Charter of This Extra Copy')
    Save-EasyHtmlReport -Path $planPath -ReportType Proposed -Items $sortedPlan

    # Summarize unique folders, not overlapping error categories or chart groups.
    # Longer explanations stay in the HTML report instead of the main screen.
    $selectedDuplicateCount = @($plan | Where-Object { $_.'Reason Type' -ne 'Bad song' }).Count
    $selectedProblemCount = @($plan | Where-Object { $_.'Reason Type' -eq 'Bad song' }).Count

    Write-Host ''
    Write-Host '========== SONG CHECK RESULTS ==========' -ForegroundColor Cyan
    Write-Host "Songs checked: $($songs.Count)" -ForegroundColor DarkCyan
    Write-Host "Folders selected for cleanup: $($remove.Count)" -ForegroundColor Yellow
    Write-Host "  Extra song copies: $selectedDuplicateCount"
    Write-Host "  Other problem songs: $selectedProblemCount"

    # Clone Hero's own duplicate report may include entries left untouched for
    # safety. Show progress in one sentence instead of repeating four counters.
    if ($gameDuplicateErrors.Count -gt 0) {
        Write-Host "Clone Hero reported $($gameDuplicateErrors.Count) duplicate errors; $gameDuplicatesAlreadySelected are included above."
    } elseif (!$badLogUsed -and !$gameDuplicateLogPath) {
        Write-Host 'No Clone Hero problem list found. Only song copies were checked.' -ForegroundColor Yellow
    }
    if ($blockedGroups -gt 0 -or $gameDuplicatesUnmatched -gt 0 -or $gameDuplicatesProtected -gt 0) {
        Write-Host 'Some copies were left alone because a safe replacement could not be confirmed.' -ForegroundColor Yellow
    }
    if ($badSongsSkippedOldScan -gt 0 -or $badSongsSkippedSafety -gt 0) {
        Write-Host 'Some problem songs were skipped. Run Scan Songs in Clone Hero, then try again.' -ForegroundColor DarkCyan
    }
    if ($playedBadProtected -gt 0) {
        Write-Host 'Songs with saved scores were protected from permanent deletion.' -ForegroundColor Green
    }

    if ($mode -eq '1') {
        Write-Host ''
        Write-Host 'This was only a check. Nothing was moved or deleted.' -ForegroundColor Green
        if ($remove.Count -gt 0) {
            Write-Host "  Safer to move instead of delete: $($quarantineOnly.Count)"
            Write-Host "  Can be deleted (no saved scores found): $($deleteCandidates.Count)"
        }
    }
    Write-CHGold 'To see each song and the reason, choose 6 on the main menu.'
    Write-Host ''

    if ($scanErrors.Count -gt 0 -or $readErrors.Count -gt 0) {
        $scanIssues = New-Object 'System.Collections.Generic.List[string]'
        foreach ($e in $scanErrors) { $scanIssues.Add("Cannot scan folder: $e") }
        foreach ($e in $readErrors) { $scanIssues.Add("Cannot read song: $e") }
        $scanIssues | Set-Content -LiteralPath $errorsPath -Encoding UTF8
        Write-Warning "Some songs could not be checked. No changes allowed. Details: $errorsPath"
        $apply = $false
    }
    # All three action modes work from the same list of selected duplicates and bad songs.
    # The difference is whether each selected folder is MOVED or DELETED.
    $selectedForOperation = $remove
    if (!$apply -or $selectedForOperation.Count -eq 0) {
        if ($mode -ne '1') { Write-Host 'No changes made.' -ForegroundColor Green }
        exit 0
    }

    Write-Host ''
    if ($moveOnly) {
        Write-Host "MOVE SONGS: $($selectedForOperation.Count) selected folders will be moved to:" -ForegroundColor Yellow
        Write-Host $QuarantineRoot -ForegroundColor Yellow
        Write-Host 'Nothing will be permanently deleted.' -ForegroundColor Green
    } elseif ($moveAndDelete) {
        Write-Host 'MOVE + DELETE:' -ForegroundColor Yellow
        Write-Host "  - $($quarantineOnly.Count) uncertain or played problem songs will be moved to safety."
        Write-Host "  - $($deleteCandidates.Count) verified unplayed song folders will be permanently deleted." -ForegroundColor Red
        Write-Host 'Permanent deletions do not go to the Recycle Bin.' -ForegroundColor Red
    } elseif ($deleteAll) {
        Write-Host 'DELETE ALL SELECTED SONGS' -ForegroundColor Red
        Write-Host "All $($selectedForOperation.Count) selected duplicate or bad-song folders will be permanently deleted." -ForegroundColor Red
        if ($quarantineOnly.Count -gt 0) {
            Write-Host "$($quarantineOnly.Count) of these have uncertain play history and would normally only be moved." -ForegroundColor Red
        }
        Write-Host 'Nothing deleted by this option goes to the Recycle Bin.' -ForegroundColor Red
    }

    Write-Host "Review the removal list before proceeding: $planPath"
    Write-Host "This would affect $($selectedForOperation.Count) song folders."
    if ($deleteAll) {
        $confirm = (Read-Host 'Type DELETE ALL to confirm, or press Enter to cancel').Trim().ToUpperInvariant()
        if ($confirm -ne 'DELETE ALL') {
            Write-Host 'Cancelled. Reports are saved. No changes made.'
            exit 0
        }
    } else {
        Write-Host 'Type ' -NoNewline
        Write-Host 'APPLY' -ForegroundColor Green -NoNewline
        Write-Host ' to confirm, or press Enter to cancel: ' -NoNewline
        $confirm = (Read-Host).Trim().ToUpperInvariant()
        if ($confirm -ne 'APPLY') {
            Write-Host 'Cancelled. Reports are saved. No changes made.'
            exit 0
        }
    }

    # Keep the automatic safety copies, but do not clutter the removal reports.
    $backupDir = Join-Path $ReportDir 'Score Data Backups'
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    if ($scoreReady) {
        Copy-Item -LiteralPath $scorePath -Destination (Join-Path $backupDir "scoredata_backup_$RunStamp.bin") -ErrorAction Stop
    }
    if ($cacheReady) {
        Copy-Item -LiteralPath $cachePath -Destination (Join-Path $backupDir "songcache_backup_$RunStamp.bin") -ErrorAction Stop
    }

    $actionLog = New-Object 'System.Collections.Generic.List[object]'
    # The proposal already contains the detailed chart comparison / error
    # explanation. Carry it into the completed report for the actual outcome.
    $planReasonsByFolder = @{}
    foreach ($plannedItem in $plan) {
        $planKey = Get-FolderKey $plannedItem.'Folder to Remove From Library'
        if ($planKey) { $planReasonsByFolder[$planKey] = $plannedItem }
    }
    $rootKey = Get-FolderKey $Root
    $deleteCandidateKeys = @{}
    foreach ($candidate in $deleteCandidates) {
        $deleteCandidateKeys[(Get-FolderKey $candidate.Folder)] = $true
    }
    $selectedRootKeys = @{}
    foreach ($selectedSong in $selectedForOperation) {
        $selectedRootKeys[(Get-FolderKey $selectedSong.Folder)] = $true
    }
    $successes = 0
    foreach ($song in $selectedForOperation) {
        $src = $song.Folder
        $key = Get-FolderKey $src
        $result = 'SKIPPED'
        $detail = ''
        $target = ''
        try {
            if (!$key.StartsWith($rootKey + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Outside configured library.'
            }
            if ($key -eq (Get-FolderKey $ReportDir)) { throw 'Report folder protected.' }
            if (!(Test-CHSafeAncestors $src $Root)) {
                throw 'Song folder or its parent uses a junction/symlink; refusing to touch files.'
            }
            # Reconfirm the kept duplicate and the game's original report before
            # touching a chart selected only because of a game scan error.
            if ($song.PSObject.Properties['IsGameLogDuplicate'] -and $song.IsGameLogDuplicate) {
                if ($selectedRootKeys.ContainsKey((Get-FolderKey $song.GameDuplicateKeeper))) {
                    throw 'The intended kept copy is also selected for removal; refusing to continue.'
                }
                if (!(Test-Path -LiteralPath $song.GameDuplicateKeeper -PathType Container)) {
                    throw 'The other copy is missing; cannot safely remove this chart.'
                }
                if (!(Test-CHSingleSongFolder $song.GameDuplicateKeeper)) {
                    throw 'The intended kept copy is no longer a safe single-song folder.'
                }
                if (!(Test-CHBadSongReportFresh $src $song.GameDuplicateLogTimeUtc)) {
                    throw 'Files changed since Clone Hero reported the duplicate; rescan first.'
                }
                if ($song.ScoreStatus -eq 'PLAYED' -and !$song.GameDuplicateSameChart) {
                    throw 'Played chart cannot be removed without a verified identical copy.'
                }
            }
            $isBad = ($song.PSObject.Properties['IsBadSong'] -and $song.IsBadSong)
            if (!(Test-Path -LiteralPath (Join-Path $src 'song.ini') -PathType Leaf) -and !$isBad) {
                throw 'song.ini missing at action time.'
            }
            if ($isBad -and !(Test-CHSingleSongFolder $src)) {
                throw 'The bad-song folder is no longer a safe single-song folder.'
            }
            if ($isBad -and $badLogUsed) {
                $originalBad = @($badCandidates | Where-Object { (Get-FolderKey $_.Folder) -eq $key } | Select-Object -First 1)
                if ($originalBad.Count -gt 0 -and !(Test-CHBadSongReportFresh $src $originalBad[0].LogTimeUtc)) {
                    throw 'Song files changed since the last Clone Hero scan; rescan first.'
                }
            }
            # A "song folder" must not contain more songs deeper in its directory tree.
            $nested = Get-ChildItem -LiteralPath $src -Recurse -File -ErrorAction Stop |
                Where-Object {
                    (Get-FolderKey $_.DirectoryName) -ne $key -and
                    $_.Name -match '(?i)^song\.ini$|^notes\.(chart|mid|midi)$'
                } | Select-Object -First 1
            if ($nested) { throw 'Contains nested song folders; refusing to remove a pack.' }
            $shouldDelete = $false
            if ($deleteAll) {
                $shouldDelete = $true
            } elseif ($moveAndDelete -and $deleteCandidateKeys.ContainsKey($key)) {
                # In mode 3, only the verified/certain extras are permanently deleted.
                $shouldDelete = $true
            }

            if ($shouldDelete) {
                Remove-Item -LiteralPath $src -Recurse -Force -ErrorAction Stop
                $result = 'DELETED'
            } else {
                $rel = $src.Substring($Root.TrimEnd('\').Length).TrimStart('\')
                $target = Join-Path $QuarantineRoot $rel
                if (Test-Path -LiteralPath $target) { $target += '_CHDUPE_' + [guid]::NewGuid().ToString('N').Substring(0, 8) }
                if (!(Test-CHSafeAncestors $QuarantineRoot $QuarantineRoot) -or
                    !(Test-CHSafeAncestors (Split-Path -Parent $target) $QuarantineRoot)) {
                    throw 'Quarantine destination uses a junction or symlink.'
                }
                New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
                Move-Item -LiteralPath $src -Destination $target -ErrorAction Stop
                $result = 'MOVED'
                $originalPlan = if ($planReasonsByFolder.ContainsKey($key)) { $planReasonsByFolder[$key] } else { $null }
                $reasonToSave = if ($null -ne $originalPlan) { [string]$originalPlan.'Why This Copy Was Chosen' } else { 'Selected by the cleaner.' }
                try {
                    Write-CHQuarantineEntry -Original $src -HeldAt $target -SongName $song.Name -SongArtist $song.Artist -Reason $reasonToSave
                } catch {
                    Write-Warning "Song was moved, but its quarantine history could not be saved: $($_.Exception.Message)"
                }
            }
            $successes++
        } catch {
            $result = 'SKIPPED_OR_ERROR'
            $detail = $_.Exception.Message
            Write-Warning "Unable to change $src -- $detail"
        }
        $simpleResult = switch ($result) {
            'MOVED' { 'Moved to safe holding folder' }
            'DELETED' { 'Permanently deleted' }
            'SKIPPED_OR_ERROR' { 'Not changed - see problem' }
            default { 'Not changed' }
        }
        $reasonForAction = ''
        $reasonTypeForAction = 'Song selected for cleanup'
        if ($planReasonsByFolder.ContainsKey($key)) {
            $originalPlanItem = $planReasonsByFolder[$key]
            $reasonForAction = [string] $originalPlanItem.'Why This Copy Was Chosen'
            $reasonTypeForAction = [string] $originalPlanItem.'Reason Type'
        }
        $actionLog.Add([pscustomobject][ordered]@{
            'Song' = $song.Name
            'Artist' = $song.Artist
            'Charter' = $song.Charter
            'What Happened' = $simpleResult
            'Reason Type' = $reasonTypeForAction
            'Reason For Action' = $reasonForAction
            'Problem (if any)' = $detail
            'Original Folder' = $src
            'Moved To (if applicable)' = $target
        })
        if (($actionLog.Count % 100) -eq 0) { Write-Host "Processed $($actionLog.Count) planned removals..." }
    }
    $sortedResults = @($actionLog.ToArray() | Sort-Object Artist, Song)
    Save-EasyHtmlReport -Path $actionsPath -ReportType Completed -Items $sortedResults
    Write-Host ''
    Write-Host "Finished: $successes/$($selectedForOperation.Count) selected folders processed." -ForegroundColor Green
    Write-Host "Changes report saved: $actionsPath"
    Write-CHGold 'Choose option 6 from the menu to open the newest saved report.'
    if ($moveOnly -or $moveAndDelete) { Write-Host "Moved folders: $QuarantineRoot" }
    Write-Host 'Open Clone Hero and run Scan Songs after checking the results.' -ForegroundColor DarkCyan
} catch {
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
