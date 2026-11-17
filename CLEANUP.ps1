#Requires -Version 7
<#
  CLEANUP.ps1 - one .rar per project folder (WinRAR), several folders at once.
  Start it with RUN.bat (asks the questions, remembers your last answers in RUN_settings.json).
  When a run ends it asks "what next": paste a new folder path to run it with the same settings, R = same folder again,
  S = change the settings, Q = quit.
  Optional switches: -Recheck  AUDIT: test every existing project .rar, also where nothing is left to add or delete
                     -Reset    ignore the saved answers
                     -Trust    an existing non-empty .rar is accepted without reading it (fast; do not use after an interrupted run)
#>
param([switch]$Recheck, [switch]$Reset, [switch]$Trust)

$ErrorActionPreference = 'Stop'
$here    = $PSScriptRoot
$cfgFile = Join-Path $here 'RUN_settings.json'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Google Docs/Sheets/Slides... on a Google Drive folder are online shortcuts, not real files: Rar cannot open them ("Incorrect function", exit 6).
# They are left in the folder (never archived, never deleted). .lnk shortcuts to Drive paths fail the same way. *.damaged = an archive that failed its test (renamed, never deleted).
$googleTypes = @('*.gdoc', '*.gsheet', '*.gslides', '*.gform', '*.gdraw', '*.gtable', '*.gjam', '*.gmap', '*.gsite', '*.gscript', '*.lnk')
# Other compressed files: asked as question 6 (Exclude = not newly added, stay in the folder; Include = added like any other file).
# Either way the working archive "<folder name>.rar" is never decided by these name patterns: it is always found by its exact path and never added to itself.
# A file that the archive already holds (same relative path and size) is cleaned from the folder in both cases.
$packedList = @('*.rar', '*.zip', '*.7z', '*.gz', '*.tgz', '*.tar', '*.bz2', '*.xz', '*.cab')
$tempTypes   = @('*.damaged', '*.rartemp')

# ---------- helpers ----------
function Ask([string]$prompt, [string]$default) {
    $a = Read-Host "$prompt [$default]"
    if ([string]::IsNullOrWhiteSpace($a)) { return $default }
    return $a.Trim().Trim('"')
}
function AskInt([string]$prompt, [int]$default, [int]$min, [int]$max) {
    while ($true) {
        $a = Ask $prompt "$default"
        $n = 0
        if ([int]::TryParse($a, [ref]$n) -and $n -ge $min -and $n -le $max) { return $n }
        Write-Host "   Enter a whole number from $min to $max." -ForegroundColor Yellow
    }
}
# Moves everything from $src into $dst (the same project folder, duplicated by Drive sync as "<name> (1)"). Nothing is overwritten:
#  - a folder that exists on both sides is merged one level down
#  - a file that does not exist in $dst is moved
#  - a file with the same name: identical (same size AND SHA-256) -> the redundant copy in $src is removed; different -> moved as "<name> (N).ext"
# Returns counts; $src is removed only when it ends up empty.
function Merge-Folder([string]$src, [string]$dst, [hashtable]$c) {
    foreach ($it in @(Get-ChildItem -LiteralPath $src -Force -ErrorAction Stop)) {
        $to = Join-Path $dst $it.Name
        try {
            if ($it.PSIsContainer) {
                if (Test-Path -LiteralPath $to -PathType Container) { Merge-Folder $it.FullName $to $c }
                elseif (Test-Path -LiteralPath $to) { $c.Kept++ }
                else { Move-Item -LiteralPath $it.FullName -Destination $to -ErrorAction Stop; $c.Moved++ }
            }
            elseif (-not (Test-Path -LiteralPath $to)) { Move-Item -LiteralPath $it.FullName -Destination $to -ErrorAction Stop; $c.Moved++ }
            else {
                $other = Get-Item -LiteralPath $to
                if ($other.PSIsContainer) { $c.Kept++ }
                elseif ($other.Length -eq $it.Length -and (Get-FileHash -LiteralPath $to -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $it.FullName -Algorithm SHA256).Hash) {
                    Remove-Item -LiteralPath $it.FullName -Force; $c.Same++
                }
                else {
                    $stem = [System.IO.Path]::GetFileNameWithoutExtension($it.Name); $ext = $it.Extension; $n = 1
                    while (Test-Path -LiteralPath (Join-Path $dst "$stem ($n)$ext")) { $n++ }
                    Move-Item -LiteralPath $it.FullName -Destination (Join-Path $dst "$stem ($n)$ext") -ErrorAction Stop; $c.Moved++
                }
            }
        }
        catch { $c.Kept++; Write-Host ("  MERGE kept ({0}): {1}" -f $_.Exception.Message, $it.FullName) -ForegroundColor Yellow }
    }
    if (@(Get-ChildItem -LiteralPath $src -Force -ErrorAction SilentlyContinue).Count -eq 0) { Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue; $c.Removed++ }
}
# Inside a folder that was just merged, duplicate sub-folders can meet ("181112_A" and "181112_A (1)", "sub" and "sub (1)", at any depth): merge each group into the
# OLDEST by created date (it then takes the plain name when that is free), then look inside every child the same way. Nothing is overwritten (see Merge-Folder).
function Merge-DupChildren([string]$dir, [hashtable]$c) {
    $kids = @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)
    foreach ($g in @($kids | Group-Object { $_.Name -replace '( \(\d+\))+$', '' } | Where-Object { $_.Count -gt 1 })) {
        $baseG = $g.Name
        $sortedG = @($g.Group | Sort-Object CreationTimeUtc, Name)
        $targetG = $sortedG[0]
        foreach ($dG in @($sortedG | Select-Object -Skip 1)) {
            Write-Host ("    inner duplicate: {0}  ->  merged into the oldest  {1}   (in {2})" -f $dG.Name, $targetG.Name, $dir) -ForegroundColor Cyan
            try { Merge-Folder $dG.FullName $targetG.FullName $c } catch { Write-Host ("    inner merge failed ({0}): {1}" -f $_.Exception.Message, $dG.FullName) -ForegroundColor Yellow }
        }
        if ($targetG.Name -ne $baseG) {
            $plainG = Join-Path $dir $baseG
            if (-not (Test-Path -LiteralPath $plainG)) { try { Rename-Item -LiteralPath $targetG.FullName -NewName $baseG -ErrorAction Stop } catch { } }
        }
    }
    foreach ($k in @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)) { Merge-DupChildren $k.FullName $c }
}
# ---- shortcuts to FOLDERS (Google Drive "Add shortcut to Drive": .lnk files whose target lies under <drive>:\.shortcut-targets-by-id\<id>\...) ----
# A shortcut keeps only a pointer to a folder owned by someone else: if that source is removed or access is withdrawn, the pointer breaks. The shortcut is replaced by a REAL
# folder of the same name in our drive with a COPY of everything inside (files and folders; nothing is overwritten; desktop.ini/Thumbs.db are left out). The .lnk is deleted
# only after every file of the source is confirmed in the copy with the same size. The source is never changed or deleted.
function Get-RelFileMap([string]$root) {
    $m = @{}
    $len = $root.TrimEnd('\', '/').Length
    foreach ($f in @(Get-ChildItem -LiteralPath $root -File -Recurse -Force -ErrorAction SilentlyContinue)) {
        if ($f.Name -in 'desktop.ini', 'Thumbs.db') { continue }
        $m[$f.FullName.Substring($len).TrimStart('\', '/').ToLowerInvariant()] = $f.Length
    }
    return $m
}
function Copy-FolderNoOverwrite([string]$src, [string]$dst) {
    if ($IsWindows -and (Get-Command robocopy -ErrorAction SilentlyContinue)) {
        & robocopy $src $dst /E /XC /XN /XO /XF desktop.ini Thumbs.db /R:2 /W:3 /MT:8 /NFL /NDL /NJH /NJS /NP 2>&1 | Out-Null
        return ($LASTEXITCODE -lt 8)   # robocopy: 0-7 = success (files copied / extra / mismatch flags), 8+ = failures
    }
    $ok = $true   # portable fallback (no robocopy)
    $len = $src.TrimEnd('\', '/').Length
    foreach ($d in @(Get-ChildItem -LiteralPath $src -Directory -Recurse -Force -ErrorAction SilentlyContinue)) {
        $t = Join-Path $dst $d.FullName.Substring($len).TrimStart('\', '/')
        if (-not (Test-Path -LiteralPath $t)) { try { New-Item -ItemType Directory -Path $t -Force | Out-Null } catch { $ok = $false } }
    }
    foreach ($f in @(Get-ChildItem -LiteralPath $src -File -Recurse -Force -ErrorAction SilentlyContinue)) {
        if ($f.Name -in 'desktop.ini', 'Thumbs.db') { continue }
        $t = Join-Path $dst $f.FullName.Substring($len).TrimStart('\', '/')
        if (Test-Path -LiteralPath $t) { continue }
        try { $td = Split-Path -Parent $t; if (-not (Test-Path -LiteralPath $td)) { New-Item -ItemType Directory -Path $td -Force | Out-Null }; Copy-Item -LiteralPath $f.FullName -Destination $t -ErrorAction Stop } catch { $ok = $false }
    }
    return $ok
}
# returns a short status text; $resolve = scriptblock(lnkPath) -> target path or $null
function Convert-ShortcutFolder([string]$lnk, [scriptblock]$resolve) {
    $target = & $resolve $lnk
    if (-not $target) { return @{ Kind = 'skip'; Text = 'target unreadable' } }
    if (Test-Path -LiteralPath $target -PathType Leaf) { return @{ Kind = 'skip'; Text = "shortcut to a FILE, left alone: $target" } }
    if (-not (Test-Path -LiteralPath $target -PathType Container)) { return @{ Kind = 'broken'; Text = "BROKEN (the target no longer exists or is not shared with you): $target" } }
    $dst = Join-Path (Split-Path -Parent $lnk) ([System.IO.Path]::GetFileNameWithoutExtension($lnk))
    if (Test-Path -LiteralPath $dst -PathType Leaf) { return @{ Kind = 'skip'; Text = "a FILE with the folder's name already exists: $dst" } }
    if (-not (Test-Path -LiteralPath $dst -PathType Container)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
    $srcMap = Get-RelFileMap $target
    $okCopy = Copy-FolderNoOverwrite $target $dst
    $dstMap = Get-RelFileMap $dst
    $miss = @($srcMap.Keys | Where-Object { -not $dstMap.ContainsKey($_) -or $dstMap[$_] -ne $srcMap[$_] })
    if ($miss.Count -gt 0) { return @{ Kind = 'kept'; Text = ("copy NOT complete ({0} of {1} file(s) missing or different in the copy, e.g. {2}): the shortcut is kept" -f $miss.Count, $srcMap.Count, $miss[0]) } }
    Remove-Item -LiteralPath $lnk -Force
    $mb = [Math]::Round((($srcMap.Values | Measure-Object -Sum).Sum) / 1MB, 1)
    return @{ Kind = 'done'; Text = ("replaced by a real folder: {0} file(s), {1} MB, all confirmed (source untouched): {2}" -f $srcMap.Count, $mb, $dst) }
}
# last 2 non-empty lines of a WinRAR output, for messages: ": line1 | line2"
function Get-Tail([string]$o) {
    $l = @($o -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 2)
    if ($l.Count -gt 0) { return (': ' + ($l -join ' | ')) } else { return '' }
}
function Fmt([int]$s) {   # 45s | 10m10s | 1h02m03s
    if ($s -ge 3600)     { '{0}h{1:00}m{2:00}s' -f [int][Math]::Floor($s / 3600), [int][Math]::Floor(($s % 3600) / 60), ($s % 60) }
    elseif ($s -ge 60)   { '{0}m{1:00}s' -f [int][Math]::Floor($s / 60), ($s % 60) }
    else                 { '{0}s' -f $s }
}
# Windows "Copy as path" on several folders gives one quoted path per line. Read-Host takes only the first line; the rest would wait in the keyboard
# buffer and answer the NEXT question by mistake. So read every pending line here and join them. (Press Enter once more if a "+" line appears.)
function Read-Pasted([string]$prompt) {
    $lines = @(Read-Host $prompt)
    try {
        Start-Sleep -Milliseconds 250
        while ([Console]::KeyAvailable) {
            $lines += (Read-Host '       +')
            Start-Sleep -Milliseconds 250
        }
    } catch { }   # no console keyboard (redirected input): the first line only
    return (($lines | Where-Object { $_ -and $_.Trim() }) -join ' ; ')
}
# one or several folders in one line: the whole text is one folder | "A","B" quoted | A ; B | A | B | A , B
function Parse-Paths([string]$text) {
    $t = $text.Trim()
    if (-not $t) { return @() }
    if (Test-Path -LiteralPath $t -PathType Container) { return @($t) }      # the whole text is one folder (even if its name has commas)
    if (Test-Path -LiteralPath $t -PathType Leaf) { return @($t) }           # the whole text is one file (a loose .rar)
    $quoted = @([regex]::Matches($t, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value.Trim() })
    if ($quoted.Count -gt 0) { return $quoted }
    return @($t -split '[;|,]' | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_ })
}
# "<stem> (N).rar" with the first N that is free in the folder: an incoming duplicate archive is never written over an existing one
function Get-FreeRarPath([string]$folder, [string]$stem) {
    $n = 1
    while (Test-Path -LiteralPath (Join-Path $folder "$stem ($n).rar")) { $n++ }
    return (Join-Path $folder "$stem ($n).rar")
}
# A pasted path that is a loose .rar FILE (not a folder): make the folder named like the .rar (an " (N)" copy goes into the plain-name folder when that exists)
# and MOVE the .rar into it; nothing is overwritten or deleted. The folder then takes the place of the file in the list.
function Convert-LooseRar([string[]]$list) {
    $out = @()
    foreach ($x in $list) {
        if ((Test-Path -LiteralPath $x -PathType Leaf) -and ([System.IO.Path]::GetExtension($x) -ieq '.rar')) {
            $f = Get-Item -LiteralPath $x
            $base = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
            if ($base -match '\.part\d+$') { $out += $x; continue }
            $par = $f.DirectoryName
            $plain = $base -replace '( \(\d+\))+$', ''
            $dest = if ($plain -ne $base -and (Test-Path -LiteralPath (Join-Path $par $plain) -PathType Container)) { Join-Path $par $plain } else { Join-Path $par $base }
            try {
                if (-not (Test-Path -LiteralPath $dest -PathType Container)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
                $target = Join-Path $dest $f.Name
                if (Test-Path -LiteralPath $target) {   # the folder already has its own .rar: this one moves in as "<name> (N).rar" and is merged by the duplicate-.rar step
                    $plainStem = [System.IO.Path]::GetFileNameWithoutExtension($target) -replace '( \(\d+\))+$', ''
                    $target = Get-FreeRarPath $dest $plainStem
                }
                Move-Item -LiteralPath $f.FullName -Destination $target -ErrorAction Stop
                Write-Host ("       Loose .rar moved into its own folder: {0}  ->  {1}" -f $f.Name, $target) -ForegroundColor Cyan
                $out += $dest
            }
            catch { Write-Host ("       Could not move the loose .rar ({0}): {1}" -f $_.Exception.Message, $x) -ForegroundColor Yellow; $out += $x }
        }
        else { $out += $x }
    }
    return @($out)
}
function Resolve-Folders([string[]]$list) {
    $list = @(Convert-LooseRar $list)
    $bad = @($list | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Container) })
    foreach ($x in $bad) { Write-Host "       Not a folder: $x" -ForegroundColor Yellow }
    if ($list.Count -eq 0) { Write-Host '       Enter at least one folder.' -ForegroundColor Yellow }
    if ($list.Count -eq 0 -or $bad.Count -gt 0) { return $null }
    $res = @($list | ForEach-Object { (Resolve-Path -LiteralPath $_).ProviderPath } | Select-Object -Unique)
    foreach ($a in $res) {
        foreach ($b in $res) {
            if ($a -ne $b -and $b.StartsWith($a.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-Host "       '$b' is inside '$a': enter only one of them (it would be archived twice)." -ForegroundColor Yellow
                return $null
            }
        }
    }
    return $res
}
function Read-Folders([string[]]$default) {
    Write-Host '       Several folders: separate them with ;  (same settings; an extra question asks whether they run together or one by one)' -ForegroundColor DarkGray
    while ($true) {
        $a = Read-Pasted ('       > [' + ($default -join ' ; ') + ']')
        $list = if ([string]::IsNullOrWhiteSpace($a)) { @($default) } else { @(Parse-Paths $a) }
        $ok = Resolve-Folders $list
        if ($ok) {
            if (@($ok).Count -gt 1) { Write-Host "       $(@($ok).Count) folders understood:" -ForegroundColor Green; $ok | ForEach-Object { Write-Host "         + $_" } }
            return $ok
        }
    }
}
function Read-LogDir([string]$default) {
    while ($true) {
        $d = Ask '       >' $default
        try {
            if (-not (Test-Path -LiteralPath $d -PathType Container)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
            $probe = Join-Path $d '.write-test'
            Set-Content -LiteralPath $probe -Value 'x'; Remove-Item -LiteralPath $probe -Force
            return (Resolve-Path -LiteralPath $d).ProviderPath
        } catch { Write-Host '       Cannot write to that folder.' -ForegroundColor Yellow }
    }
}
# CPU presets from the number of logical processors; returns the chosen preset and the cores to use
function Get-Cpu([int]$cores, [int]$preset, [int]$custom) {
    $reserve = if ($cores -le 4) { 1 } else { 2 }
    switch ($preset) {
        1 { $use = [Math]::Max(1, [int][Math]::Floor($cores * 0.25)); $name = 'Eco';         $prio = 'BelowNormal' }
        2 { $use = [Math]::Max(1, [int][Math]::Floor($cores * 0.50)); $name = 'Balanced';    $prio = 'Normal' }
        3 { $use = [Math]::Max(1, $cores - $reserve);                 $name = 'Performance'; $prio = 'Normal' }
        default { $use = [Math]::Min([Math]::Max(1, $custom), $cores); $name = 'Custom';     $prio = 'Normal' }
    }
    [pscustomobject]@{ Preset = $preset; Name = $name; CoresUse = $use; Priority = $prio }
}
function Read-Cpu([int]$cores, [int]$defPreset, [int]$defCustom) {
    $reserve = if ($cores -le 4) { 1 } else { 2 }
    $eco  = [Math]::Max(1, [int][Math]::Floor($cores * 0.25))
    $bal  = [Math]::Max(1, [int][Math]::Floor($cores * 0.50))
    $perf = [Math]::Max(1, $cores - $reserve)
    Write-Host ("       [1] Eco ............ {0} of {1} cores, low priority  (PC stays smooth)" -f $eco, $cores)
    Write-Host ("       [2] Balanced ....... {0} of {1} cores" -f $bal, $cores)
    Write-Host ("       [3] Performance .... {0} of {1} cores  ({2} left for other apps)" -f $perf, $cores, ($cores - $perf))
    Write-Host  '       [4] Custom ......... you type the number of cores'
    $preset = AskInt '       >' $defPreset 1 4
    $custom = $defCustom
    if ($preset -eq 4) { $custom = AskInt '       Number of cores' $defCustom 1 $cores }
    return @{ Preset = $preset; Custom = $custom }
}
# compression methods = the same list as WinRAR's "Compression method" box (Store ... Best)
$levels = @(
    @{ Arg = '-m0'; Name = 'Store';   Note = 'no compression; fastest; the .rar is as big as the folder; CPU stays low' },
    @{ Arg = '-m1'; Name = 'Fastest'; Note = 'lightest compression' },
    @{ Arg = '-m2'; Name = 'Fast';    Note = '' },
    @{ Arg = '-m3'; Name = 'Normal';  Note = 'WinRAR default; good size and speed (recommended)' },
    @{ Arg = '-m4'; Name = 'Good';    Note = 'smaller .rar, slower' },
    @{ Arg = '-m5'; Name = 'Best';    Note = 'smallest .rar, slowest, uses all allowed cores' }
)
function Read-Level([int]$default) {
    for ($k = 0; $k -lt $levels.Count; $k++) {
        $star = if (($k + 1) -eq $default) { ' (default)' } else { '' }
        Write-Host ("       [{0}] {1,-8} {2}{3}" -f ($k + 1), $levels[$k].Name, $levels[$k].Note, $star)
    }
    return (AskInt '       >' $default 1 $levels.Count)
}
function Read-Archives([int]$default) {
    Write-Host '       [1] Exclude ... .rar .zip .7z .gz .tgz .tar .bz2 .xz .cab are NOT added; they stay in the folder as they are (default)'
    Write-Host '       [2] Include ... they are added like any other file (not the default)'
    Write-Host '       (the working archive <folder name>.rar is never added to itself; a file already inside the archive is cleaned from the folder either way)' -ForegroundColor DarkGray
    return (AskInt '       >' $default 1 2)
}
# Several RUN.bat windows can run at the same time. The files they share (RUN_settings.json, the resume log) are written one window at a time,
# guarded by a mutex that works between windows; a short retry covers a file that is still busy (Google Drive, antivirus).
$fileMutex = [System.Threading.Mutex]::new($false, 'REIKA_RarArchiver_SharedFiles')
function Use-Lock([scriptblock]$action) {
    $got = $false
    try { $got = $fileMutex.WaitOne(30000) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    if (-not $got) { throw 'another window is using the shared log files (waited 30 s)' }
    try {
        for ($try = 1; $try -le 8; $try++) {
            try { return (& $action) }
            catch { if ($try -eq 8) { throw }; Start-Sleep -Milliseconds 300 }
        }
    }
    finally { $fileMutex.ReleaseMutex() }
}
function Read-Orphans([int]$default) {
    Write-Host '       [1] Leave them ......... a loose .rar directly in the folder is ignored (default)'
    Write-Host '       [2] Create a folder .... for each loose <name>.rar: create the folder <name> and MOVE the .rar into it (nothing is deleted), then it is checked like any other project'
    return (AskInt '       >' $default 1 2)
}
function Read-Nested([int]$default) {
    Write-Host '       [1] Leave them ......... a <folder>\<folder>.rar lying INSIDE a project folder stays as it is'
    Write-Host '       [2] Unpack them ........ extract each such .rar back into its folder, and delete the .rar ONLY after every file is confirmed on disk; the project .rar then contains them'
    return (AskInt '       >' $default 1 2)
}
function Read-Shortcuts([int]$default) {
    Write-Host '       [1] Leave them ......... a .lnk shortcut to a folder (e.g. Drive shortcuts to folders shared by others) stays a shortcut'
    Write-Host '       [2] Replace them ....... create a REAL folder of the same name and COPY everything inside from the shortcut target (nothing overwritten; the shortcut is deleted only after every file is confirmed; the source is never touched)'
    return (AskInt '       >' $default 1 2)
}
function Read-Together([int]$default) {
    Write-Host '       [1] One by one ......... the second folder starts when the first one is finished'
    Write-Host '       [2] At the same time ... all folders share the parallel jobs; best while Google Drive is the slow part'
    return (AskInt '       >' $default 1 2)
}
function Save-Config($s) {
    Use-Lock { [pscustomobject]@{ Folders = @($s.Folders); LogDir = $s.LogDir; Jobs = $s.Jobs; Preset = $s.Preset; CustomCores = $s.Custom; Method = $s.Level; Archives = $s.Archives; Schema = 3; Orphans = $s.Orphans; Nested = $s.Nested; Shortcuts = $s.Shortcuts; Together = $s.Together } |
        ConvertTo-Json | Set-Content -LiteralPath $cfgFile -Encoding utf8 }
}

# ---------- one run: archive every project folder under the given folder(s); several folders share one pool of jobs ----------
function Invoke-Archive($s, $rarExe, $cpu, [string[]]$roots, [int]$idx, [int]$count) {
    $jobs = $s.Jobs; $logDir = $s.LogDir
    $mt = [Math]::Max(1, [int][Math]::Floor($cpu.CoresUse / $jobs))   # threads per Rar.exe
    $packedTypes  = if ($s.Archives -eq 2) { @() } else { $packedList }     # question 6: 1 = exclude other archives, 2 = include them
    $excludeTypes = $googleTypes + $packedTypes + $tempTypes

    # logs: all in the sub-folder "logs" of the log folder
    $logSub = Join-Path $logDir 'logs'
    New-Item -ItemType Directory -Path $logSub -Force | Out-Null
    $stamp   = Get-Date -Format 'yyyyMMdd-HHmm'
    $runLog  = if ($count -gt 1) { Join-Path $logSub "rar-run-$stamp-w$PID-$idx.log" } else { Join-Path $logSub "rar-run-$stamp-w$PID.log" }   # w<process id>: one file per window
    $logFile = Join-Path $logSub 'rar-archive-log.csv'      # resume log: folders already finished
    # older versions kept the resume log and run logs directly in the log folder: move them into logs\
    $oldCsv = Join-Path $logDir 'rar-archive-log.csv'
    if ((Test-Path -LiteralPath $oldCsv) -and -not (Test-Path -LiteralPath $logFile)) { Move-Item -LiteralPath $oldCsv -Destination $logFile }
    Get-ChildItem -LiteralPath $logDir -Filter 'rar-run-*.log' -File -ErrorAction SilentlyContinue | ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination $logSub -ErrorAction SilentlyContinue }

    # WinRAR writes a full working copy of the archive while it builds or updates it (__rar_*.rartemp). By default that is the project folder,
    # on Google Drive. -w puts it in <log folder>\logs\works instead. Old leftovers of an interrupted run are removed here (they are only temp files).
    $workRoot = Join-Path $logSub 'works'
    New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
    # each window works in works\<its process id>; folders of windows that are no longer running (and temp files of older versions) are removed
    Get-ChildItem -LiteralPath $workRoot -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $pidN = 0
        if ($_.PSIsContainer) {
            if ([int]::TryParse($_.Name, [ref]$pidN) -and $pidN -ne $PID -and -not (Get-Process -Id $pidN -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
        }
        elseif ($_.Name -like '__rar_*.rartemp') { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    }
    $work = Join-Path $workRoot "$PID"
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    # one lock file per project folder: a second window that reaches a folder this window is working on skips it (BUSY)
    $lockDir = Join-Path $logSub 'locks'
    New-Item -ItemType Directory -Path $lockDir -Force | Out-Null

    try { Start-Transcript -LiteralPath $runLog | Out-Null } catch { Write-Host " (run log not written: $($_.Exception.Message))" -ForegroundColor Yellow }
    try {
        $level      = $levels[$s.Level - 1].Arg
        $store      = ($s.Level -eq 1)
        $skipPacked = '-msjpg;jpeg;png;gif;webp;mp4;mov;avi;mkv;mp3;zip;rar;7z;pdf;docx;xlsx;pptx'

        $logged = @{}
        if (-not $Recheck -and (Test-Path -LiteralPath $logFile)) {
            (Use-Lock { Import-Csv -LiteralPath $logFile }) | ForEach-Object { $logged[$_.Path] = $_ }
        }

        # loose <name>.rar files directly in a listed folder: make the folder <name>, MOVE the .rar into it as <name>\<name>.rar (never overwrite, never delete);
        # the new folder is then found below as a project folder and its .rar is checked like any other
        # A listed folder X with its own loose archive lying NEXT to it (<parent>\X.rar, <parent>\X (1).rar): move it INTO X. Nothing is overwritten or deleted:
        # if X\X.rar already exists the incoming one becomes "X (N).rar", which the duplicate-.rar step merges.
        foreach ($rt in $roots) {
            try {
                $parX = Split-Path -Parent $rt.TrimEnd('\'); $leafX = Split-Path -Leaf $rt.TrimEnd('\')
                if (-not $parX -or -not $leafX) { continue }
                foreach ($sib in @(Get-ChildItem -LiteralPath $parX -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match ('^' + [regex]::Escape($leafX) + '( \(\d+\))*\.rar$') })) {
                    $tgtX = Join-Path $rt $sib.Name
                    if (Test-Path -LiteralPath $tgtX) {
                        $nX = 1; while (Test-Path -LiteralPath (Join-Path $rt "$leafX ($nX).rar")) { $nX++ }
                        $tgtX = Join-Path $rt "$leafX ($nX).rar"
                    }
                    Move-Item -LiteralPath $sib.FullName -Destination $tgtX -ErrorAction Stop
                    Write-Host ("  SIBLING .rar moved into its folder: {0}  ->  {1}" -f $sib.FullName, $tgtX) -ForegroundColor Cyan
                }
            }
            catch { Write-Host ("  SIBLING .rar not moved ({0}): {1}" -f $_.Exception.Message, $rt) -ForegroundColor Yellow }
        }

        if ($s.Orphans -eq 2) {
            $nMoved = 0; $nConflict = 0; $nSkipped = 0
            foreach ($rt in $roots) {
                # a listed folder that IS a project (YYMMDD_...) owns its .rar files: they are its content, never "loose"
                $rtLeaf = Split-Path -Leaf $rt.TrimEnd('\')
                if ($rtLeaf -match '^\d{6}_') { Write-Host ("  LOOSE step skipped, this is a project folder itself: {0}" -f $rt) -ForegroundColor DarkGray; continue }
                foreach ($f in @(Get-ChildItem -LiteralPath $rt -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ieq '.rar' })) {
                    $base = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
                    if ([string]::IsNullOrWhiteSpace($base) -or $base -match '\.part\d+$') { $nSkipped++; Write-Host ("  LOOSE skipped (part of a split archive or no name): {0}" -f $f.Name) -ForegroundColor Yellow; continue }
                    # an " (N)" copy goes into the plain-name folder when that exists
                    $plainB = $base -replace '( \(\d+\))+$', ''
                    $dest = if ($plainB -ne $base -and (Test-Path -LiteralPath (Join-Path $rt $plainB) -PathType Container)) { Join-Path $rt $plainB } else { Join-Path $rt $base }
                    $target = Join-Path $dest $f.Name
                    try {
                        if (Test-Path -LiteralPath $target) {   # the folder already has this .rar: the loose one moves in as "<name> (N).rar" and the duplicate-.rar step merges it
                            $target = Get-FreeRarPath $dest $plainB
                            $nConflict++
                        }
                        if (-not (Test-Path -LiteralPath $dest -PathType Container)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
                        Move-Item -LiteralPath $f.FullName -Destination $target -ErrorAction Stop
                        $nMoved++; Write-Host ("  LOOSE moved: {0}  ->  {1}" -f $f.Name, $dest) -ForegroundColor Cyan
                    }
                    catch { $nSkipped++; Write-Host ("  LOOSE FAILED ({0}): {1}" -f $_.Exception.Message, $f.FullName) -ForegroundColor Red }
                }
            }
            if ($nMoved + $nConflict + $nSkipped -gt 0) { Write-Host ("Loose .rar files: {0} moved into their own folder | {1} kept (already there) | {2} skipped/failed" -f $nMoved, $nConflict, $nSkipped) }
        }

        # duplicate LISTED folders (project folders or GROUP_ folders): a listed folder X with "X (N)" folders beside it (Drive sync copies) is merged
        # together with them into the OLDEST of the group by created date; that folder then takes the plain name X when it is free. Nothing is overwritten
        # or lost (identical files are dropped, different ones kept as "<file> (dupN).ext"). The list then holds the merged folder (once).
        $mc = @{ Moved = 0; Same = 0; Kept = 0; Removed = 0 }
        $newRoots = @(); $handledG = @{}
        foreach ($rt in $roots) {
            try {
                $parR = Split-Path -Parent $rt.TrimEnd('\'); $leafR = Split-Path -Leaf $rt.TrimEnd('\')
                if (-not $parR -or -not $leafR) { $newRoots += $rt; continue }
                $baseR = $leafR -replace '( \(\d+\))+$', ''
                $gkey = ($parR + '\' + $baseR).ToLowerInvariant()
                if ($handledG.ContainsKey($gkey)) { $newRoots += $handledG[$gkey]; continue }
                $grp = @(Get-ChildItem -LiteralPath $parR -Directory -ErrorAction SilentlyContinue | Where-Object { ($_.Name -replace '( \(\d+\))+$', '') -eq $baseR })
                if ($grp.Count -gt 1) {
                    $sortedG = @($grp | Sort-Object CreationTimeUtc, Name)
                    $targetG = $sortedG[0]
                    foreach ($dG in @($sortedG | Select-Object -Skip 1)) {
                        Write-Host ("  DUPLICATE folder: {0}  ->  merged into the oldest  {1}" -f $dG.Name, $targetG.Name) -ForegroundColor Cyan
                        Merge-Folder $dG.FullName $targetG.FullName $mc
                    }
                    $finalG = $targetG.FullName
                    if ($targetG.Name -ne $baseR) {
                        $plainG = Join-Path $parR $baseR
                        if (-not (Test-Path -LiteralPath $plainG)) {
                            Rename-Item -LiteralPath $targetG.FullName -NewName $baseR -ErrorAction Stop
                            Write-Host ("  renamed {0}  ->  {1}" -f $targetG.Name, $baseR) -ForegroundColor Cyan
                            $finalG = $plainG
                        }
                        else { Write-Host ("  kept the name {0} (the plain name still holds items that could not be merged)" -f $targetG.Name) -ForegroundColor Yellow }
                    }
                    Merge-DupChildren $finalG $mc
                    $handledG[$gkey] = $finalG; $newRoots += $finalG
                }
                else { $handledG[$gkey] = $rt; $newRoots += $rt }
            }
            catch { Write-Host ("  DUPLICATE folder merge failed ({0}): {1}" -f $_.Exception.Message, $rt) -ForegroundColor Yellow; $newRoots += $rt }
        }
        $roots = @($newRoots | Select-Object -Unique)

        # duplicate PROJECT folders: "<name> (N)" next to "<name>" (Drive sync copy) are merged into "<name>"; nothing is overwritten or lost,
        # identical files (same size and SHA-256) are not kept twice, different files with the same name are both kept ("<file> (1).ext")
        foreach ($rt in $roots) {
            $rtLeaf0 = Split-Path -Leaf $rt.TrimEnd('\')
            if ($rtLeaf0 -match '^\d{6}_') { continue }
            $parents = @($rt) + @(Get-ChildItem -LiteralPath $rt -Directory -Filter 'GROUP_*' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
            foreach ($par in $parents) {
                $dirs = @(Get-ChildItem -LiteralPath $par -Directory -ErrorAction SilentlyContinue)
                # groups: "<name>", "<name> (1)", "<name> (2)"... (only when at least two of them exist)
                foreach ($g in @($dirs | Group-Object { $_.Name -replace '( \(\d+\))+$', '' } | Where-Object { $_.Count -gt 1 })) {
                    $baseName = $g.Name
                    $sorted = @($g.Group | Sort-Object CreationTimeUtc, Name)
                    $target = $sorted[0]    # the OLDEST by created date receives everything
                    foreach ($d in @($sorted | Select-Object -Skip 1)) {
                        Write-Host ("  DUPLICATE project folder: {0}  ->  merged into the oldest  {1}" -f $d.Name, $target.Name) -ForegroundColor Cyan
                        try { Merge-Folder $d.FullName $target.FullName $mc } catch { Write-Host ("  MERGE failed ({0}): {1}" -f $_.Exception.Message, $d.FullName) -ForegroundColor Yellow }
                    }
                    # the oldest may be the "(N)" one: it gets the plain name, if that name is free now
                    if ($target.Name -ne $baseName) {
                        $plain = Join-Path $par $baseName
                        if (-not (Test-Path -LiteralPath $plain)) {
                            try { Rename-Item -LiteralPath $target.FullName -NewName $baseName -ErrorAction Stop; Write-Host ("  renamed {0}  ->  {1}" -f $target.Name, $baseName) -ForegroundColor Cyan }
                            catch { Write-Host ("  rename failed ({0}): {1}" -f $_.Exception.Message, $target.FullName) -ForegroundColor Yellow }
                        }
                        else { Write-Host ("  kept the name {0} (the plain name still holds items that could not be merged)" -f $target.Name) -ForegroundColor Yellow }
                    }
                    # duplicates that now meet INSIDE the merged folder (sub-projects, sub-folders, at any depth) are merged the same way
                    $finalC = if (Test-Path -LiteralPath (Join-Path $par $baseName) -PathType Container) { Join-Path $par $baseName } else { $target.FullName }
                    try { Merge-DupChildren $finalC $mc } catch { Write-Host ("  inner merge failed ({0}): {1}" -f $_.Exception.Message, $finalC) -ForegroundColor Yellow }
                }
            }
        }
        if ($mc.Moved + $mc.Same + $mc.Kept + $mc.Removed -gt 0) { Write-Host ("Duplicate project folders: {0} item(s) moved | {1} identical file(s) not kept twice | {2} kept (see above) | {3} folder(s) removed" -f $mc.Moved, $mc.Same, $mc.Kept, $mc.Removed) -ForegroundColor Cyan }

        # shortcuts to folders -> real folders (see Convert-ShortcutFolder)
        if ($s.Shortcuts -eq 2 -and $IsWindows) {
            $wsh = $null
            try { $wsh = New-Object -ComObject WScript.Shell } catch { Write-Host '  SHORTCUT step skipped: Windows shortcut reader (WScript.Shell) not available' -ForegroundColor Yellow }
            if ($wsh) {
                $resolveLnk = { param($p) try { $t = $wsh.CreateShortcut($p).TargetPath; if ($t) { $t } else { $null } } catch { $null } }
                $nSc = @{ done = 0; broken = 0; kept = 0; skip = 0 }
                foreach ($rt in $roots) {
                    foreach ($l in @(Get-ChildItem -LiteralPath $rt -File -Recurse -Force -Filter '*.lnk' -ErrorAction SilentlyContinue)) {
                        try {
                            $r = Convert-ShortcutFolder $l.FullName $resolveLnk
                            $nSc[$r.Kind]++
                            $col = switch ($r.Kind) { 'done' { 'Cyan' } 'broken' { 'Red' } 'kept' { 'Yellow' } default { 'DarkGray' } }
                            Write-Host ("  SHORTCUT {0}: {1}  ->  {2}" -f $r.Kind.ToUpper(), $l.FullName, $r.Text) -ForegroundColor $col
                        }
                        catch { $nSc['kept']++; Write-Host ("  SHORTCUT failed ({0}): {1}" -f $_.Exception.Message, $l.FullName) -ForegroundColor Yellow }
                    }
                }
                if ($nSc.done + $nSc.broken + $nSc.kept -gt 0) { Write-Host ("Shortcuts: {0} replaced by real folders | {1} broken (left, target gone) | {2} kept (copy incomplete) | {3} other" -f $nSc.done, $nSc.broken, $nSc.kept, $nSc.skip) -ForegroundColor Cyan }
            }
        }

        # the project folders of each folder in the list; with several folders they are interleaved, so every folder progresses at the same time
        $lists = @()
        foreach ($rt in $roots) {
            # a listed folder that IS a project folder (named YYMMDD_..., or already holding its own <foldername>.rar) is ONE project: its sub-folders go into ITS .rar
            $rtName = Split-Path -Leaf $rt.TrimEnd('\')
            if ($rtName -match '^\d{6}_' -or (Test-Path -LiteralPath (Join-Path $rt "$rtName.rar") -PathType Leaf)) {
                $lists += , @(Get-Item -LiteralPath $rt)
                continue
            }
            $one = @(Get-ChildItem -LiteralPath $rt -Directory | ForEach-Object {
                if ($_.Name -like 'GROUP_*') { Get-ChildItem -LiteralPath $_.FullName -Directory } else { $_ }
            })
            # a listed folder with NO sub-folders but with files is itself ONE project folder (you pasted the project folder, not the folder that holds them)
            if ($one.Count -eq 0 -and @(Get-ChildItem -LiteralPath $rt -File -Force -ErrorAction SilentlyContinue).Count -gt 0) {
                $one = @(Get-Item -LiteralPath $rt)
            }
            $lists += , $one
        }
        $maxLen = [int](($lists | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum)
        $all = @()
        for ($k = 0; $k -lt $maxLen; $k++) { foreach ($l in $lists) { if ($k -lt $l.Count) { $all += $l[$k] } } }

        # AUTO-REPAIR of the wrong "LOOSE" step of older versions: a project folder whose ONLY content is wrapper folders (<proj>, <proj> (1), or a folder holding
        # nothing but its own <name>.rar) gets everything moved back up into the project folder. Nothing is overwritten (a name clash stays where it is) and
        # nothing is deleted except the emptied wrapper folder. Needs no log and no question.
        $nFix = 0
        foreach ($pr in $all) {
            try {
                # up to 5 passes: a wrapper can hold another wrapper (<proj>\<proj>\<proj>)
                for ($pass = 0; $pass -lt 5; $pass++) {
                    $kids = @(Get-ChildItem -LiteralPath $pr.FullName -Force -ErrorAction Stop)
                    if ($kids.Count -eq 0) { break }
                    # Google shortcuts (.gdoc ...), .lnk, desktop.ini, Thumbs.db do not count as "real" content when deciding that only wrappers are left
                    $base = $pr.Name -replace '( \(\d+\))+$', ''
                    $noise = @($kids | Where-Object { -not $_.PSIsContainer -and ($_.Name -match ('^' + [regex]::Escape($base) + '( \(\d+\))*\.rar$') -or $_.Name -match '\.(gdoc|gsheet|gslides|gdraw|gform|gmap|gsite|gjam|lnk)$' -or $_.Name -in 'desktop.ini', 'Thumbs.db') })
                    $kids = @($kids | Where-Object { $noise.FullName -notcontains $_.FullName })
                    if ($kids.Count -eq 0) { break }
                    $base = $pr.Name -replace '( \(\d+\))+$', ''
                    $isWrap = {
                        param($k)
                        if (-not $k.PSIsContainer) { return $false }
                        if ($k.Name -eq $pr.Name -or $k.Name -eq $base -or $k.Name -match ('^' + [regex]::Escape($base) + '( \(\d+\))+$')) { return 'move' }
                        $in = @(Get-ChildItem -LiteralPath $k.FullName -Force -ErrorAction SilentlyContinue)
                        if ($in.Count -eq 1 -and -not $in[0].PSIsContainer -and $in[0].Name -ieq ($k.Name + '.rar')) { return 'keep' }   # <sub>\<sub>.rar: left for the inner step to unpack
                        return $false
                    }
                    # proceed when ONLY wrappers are left, or when a wrapper named like the project holds the project's own <name>.rar (clear proof of the old mistake,
                    # even if real folders like CLIENT\ sit beside it); real folders are never touched
                    $ownRar = '^' + [regex]::Escape($base) + '( \(\d+\))*\.rar$'
                    $strong = @($kids | Where-Object { (& $isWrap $_) -eq 'move' -and @(Get-ChildItem -LiteralPath $_.FullName -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $ownRar }).Count -gt 0 })
                    if (@($kids | Where-Object { -not (& $isWrap $_) }).Count -gt 0 -and $strong.Count -eq 0) { break }
                    foreach ($w in $kids) {
                        if ((& $isWrap $w) -ne 'move') { continue }
                        # the wrapper is renamed first, so an item inside it with the wrapper's own name can move up without a clash
                        $tmpW = Join-Path $pr.FullName ('.unwrap_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
                        Move-Item -LiteralPath $w.FullName -Destination $tmpW -ErrorAction Stop
                        foreach ($it in @(Get-ChildItem -LiteralPath $tmpW -Force)) {
                            $to = Join-Path $pr.FullName $it.Name
                            if (Test-Path -LiteralPath $to) {
                                # the project already has its own <name>.rar: the wrapped one comes back as "<name> (N).rar", and the duplicate-merge step merges it
                                if (-not $it.PSIsContainer -and $it.Extension -ieq '.rar') {
                                    $nn = 1; $stem = [System.IO.Path]::GetFileNameWithoutExtension($it.Name)
                                    while (Test-Path -LiteralPath (Join-Path $pr.FullName "$stem ($nn).rar")) { $nn++ }
                                    Move-Item -LiteralPath $it.FullName -Destination (Join-Path $pr.FullName "$stem ($nn).rar") -ErrorAction Stop
                                    $nFix++; Write-Host ("  REPAIR kept as duplicate to merge: {0} ({1}).rar" -f $stem, $nn) -ForegroundColor Cyan
                                    continue
                                }
                                Write-Host ("  REPAIR clash, left in place: {0}" -f $it.FullName) -ForegroundColor Yellow; continue
                            }
                            Move-Item -LiteralPath $it.FullName -Destination $to -ErrorAction Stop
                            $nFix++
                        }
                        if (@(Get-ChildItem -LiteralPath $tmpW -Force).Count -eq 0) { Remove-Item -LiteralPath $tmpW -Force }
                        else { Move-Item -LiteralPath $tmpW -Destination (Join-Path $pr.FullName ($w.Name + ' (clash)')) -ErrorAction SilentlyContinue }
                    }
                }
            }
            catch { Write-Host ("  REPAIR failed ({0}): {1}" -f $_.Exception.Message, $pr.FullName) -ForegroundColor Yellow }
            # leftover EMPTY wrapper folders (named like the project, "<project> (N)", or ".unwrap_*") anywhere below it are removed, deepest first
            try {
                $b0 = $pr.Name -replace '( \(\d+\))+$', ''
                foreach ($e in @(Get-ChildItem -LiteralPath $pr.FullName -Directory -Recurse -Force -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending)) {
                    if (($e.Name -eq $pr.Name -or $e.Name -eq $b0 -or $e.Name -match ('^' + [regex]::Escape($b0) + '( \(\d+\))+$') -or $e.Name -like '.unwrap_*') -and @(Get-ChildItem -LiteralPath $e.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                        Remove-Item -LiteralPath $e.FullName -Force -ErrorAction Stop
                        Write-Host ("  REPAIR removed empty folder: {0}" -f $e.FullName) -ForegroundColor DarkGray
                    }
                }
            }
            catch { }
        }
        if ($nFix -gt 0) { Write-Host ("Repair of older wrong moves: {0} item(s) moved back into their project folder" -f $nFix) -ForegroundColor Cyan }

        # inner .rar files: <sub>\<sub>.rar inside a project folder (made by an older run) are unpacked back into <sub>; the .rar is deleted only
        # when every file in it exists on disk with the same size. The project's own .rar is then built from the whole folder.
        $readListO = {
            param($exe, $archive)
            $lines = & $exe lt -scfr $archive 2>$null
            if ($LASTEXITCODE -ne 0) { return $null }
            $map = @{}
            $name = $null; $type = $null
            foreach ($line in $lines) {
                if     ($line -match '^\s*Name:\s(.*)$')     { $name = $Matches[1].Trim().Replace('/', '\'); $type = $null }
                elseif ($line -match '^\s*Type:\s*(\w+)')    { $type = $Matches[1] }
                elseif ($line -match '^\s*Size:\s*(\d+)')    { if ($name -and $type -eq 'File') { $map[$name.ToLowerInvariant()] = [int64]$Matches[1] } }
            }
            if ($map.Count -eq 0) { return $null }
            return $map
        }
        $pendingStray = @()   # stray .rar files unpacked this run: deleted only after the project .rar itself confirms every file
        if ($s.Nested -eq 2) {
            $nU = 0; $nK = 0; $mainMaps = @{}
            foreach ($pr in $all) {
                $cands = @()   # pairs: the stray .rar and the folder it is unpacked into
                foreach ($d in @(Get-ChildItem -LiteralPath $pr.FullName -Directory -Recurse -Force -ErrorAction SilentlyContinue)) {
                    $ir = Join-Path $d.FullName "$($d.Name).rar"
                    if (-not (Test-Path -LiteralPath $ir -PathType Leaf)) { continue }
                    if ($d.Name -eq (Split-Path -Leaf $d.Parent.FullName)) { continue }   # <proj>\<proj>\<proj>.rar: the project's own archive, never touched
                    # stray = the .rar carries the folder's own name AND is the ONLY thing in that folder (the old run packed everything and deleted it).
                    # A .rar/.zip beside other files (source code, deliverables...) is real content and is never touched.
                    $others = @(Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $ir -and $_.Name -notin 'desktop.ini', 'Thumbs.db' -and $_.Name -notmatch '\.(gdoc|gsheet|gslides|gdraw|gform|gmap|gsite|gjam|lnk)$' })
                    # NO resume log here (it can be inaccurate: restored files, a run stopped by hand). An own-named .rar that is ALONE in its folder may be unpacked;
                    # one with other content beside it is only ever REMOVED when the project .rar is proven to hold every one of its files (proof-only, flag = $true).
                    $cands += , @($ir, $d.FullName, ($others.Count -gt 0))
                }
                # a .rar lying directly in the project folder, named like a sub-folder (the old mistake made <sub>.rar next to / instead of <sub>\): proof-only, i.e. it is
                # removed only when the project .rar already holds every one of its files under <sub>\ (same path, same size); a real archive is never touched
                $pBase = $pr.Name -replace '( \(\d+\))+$', ''
                foreach ($f in @(Get-ChildItem -LiteralPath $pr.FullName -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ieq '.rar' })) {
                    $x = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
                    if ($x -eq $pBase -or $x -match ('^' + [regex]::Escape($pBase) + '( \(\d+\))+$')) { continue }
                    $cands += , @($f.FullName, (Join-Path $pr.FullName $x), $true)
                }
                foreach ($c in $cands) {
                    $ir = $c[0]; $dest = $c[1]; $proofOnly = [bool]$c[2]
                    try {
                        if (-not $proofOnly) {   # proof-only candidates are never unpacked, so their own test is not needed: the decision rests on the TESTED project .rar
                            & $rarExe t -idq $ir 2>&1 | Out-Null
                            if ($LASTEXITCODE -ne 0) { throw 'archive failed its test' }
                        }
                        $im = & $readListO $rarExe $ir
                        if (-not $im) {
                            if ($proofOnly) { continue }
                            $nm = @(& $rarExe lb $ir 2>$null | Where-Object { $_ })
                            if ($LASTEXITCODE -eq 0 -and $nm.Count -eq 0) {   # passed its test and holds nothing: deleting it loses nothing
                                Remove-Item -LiteralPath $ir -Force
                                $nU++; Write-Host ("  INNER empty archive removed: {0}" -f $ir) -ForegroundColor Cyan
                                continue
                            }
                            throw 'file list unreadable'
                        }
                        $realIn = @($im.Keys | Where-Object { $_ -notmatch '(^|\\)(desktop\.ini|thumbs\.db)$' })
                        if ($realIn.Count -eq 0 -and $proofOnly) { continue }
                        if ($realIn.Count -eq 0) {   # only system files Drive recreates by itself: nothing of yours is inside, deleting the .rar loses nothing
                            Remove-Item -LiteralPath $ir -Force
                            $nU++; Write-Host ("  INNER only desktop.ini inside, removed: {0}" -f $ir) -ForegroundColor Cyan
                            continue
                        }
                        # TEST FIRST: is everything in the stray already inside the project's own .rar (same path, same size)? Then it is redundant and safe to remove now.
                        $mainRar = Join-Path $pr.FullName "$($pr.Name).rar"
                        $prefix = $dest.Substring($pr.FullName.Length).TrimStart('\').ToLowerInvariant()
                        if ($prefix) { $prefix += '\' }
                        # the project .rar is TESTED (rar t) before its file list is trusted for a delete decision; a stale log is never enough
                        if (-not $mainMaps.ContainsKey($pr.FullName)) {
                            $mainMaps[$pr.FullName] = $null
                            if (Test-Path -LiteralPath $mainRar -PathType Leaf) {
                                & $rarExe t -idq $mainRar 2>&1 | Out-Null
                                if ($LASTEXITCODE -eq 0) { $mainMaps[$pr.FullName] = & $readListO $rarExe $mainRar }
                            }
                        }
                        $mm = $mainMaps[$pr.FullName]
                        $notIn = if ($mm) { @($realIn | Where-Object { -not $mm.ContainsKey(($prefix + $_.ToLowerInvariant())) -or $mm[($prefix + $_.ToLowerInvariant())] -ne $im[$_] }) } else { $realIn }
                        if ($notIn.Count -eq 0) {
                            Remove-Item -LiteralPath $ir -Force
                            $nU++; Write-Host ("  INNER stray confirmed inside the project .rar ({0} file(s), same size), removed: {1}" -f $realIn.Count, $ir) -ForegroundColor Cyan
                            continue
                        }
                        if ($proofOnly) { continue }   # not proven redundant and not alone in its folder: left exactly as it is
                        # not (fully) in the project .rar yet: unpack it, but KEEP the stray .rar until the project .rar has been built and confirms every file
                        if (-not (Test-Path -LiteralPath $dest -PathType Container)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
                        $xo = & $rarExe x -idq -y -o- '-x*desktop.ini' '-x*Thumbs.db' "-op$dest" $ir 2>&1 | Out-String   # -op<path>: no trailing backslash inside quotes
                        $xc = $LASTEXITCODE
                        if ($xc -ne 0) { throw ("extract failed, WinRAR exit $xc" + $(Get-Tail $xo)) }
                        foreach ($k in $im.Keys) {
                            if ($k -match '(^|\\)(desktop\.ini|thumbs\.db)$') { continue }
                            $fp = Join-Path $dest $k
                            if (-not (Test-Path -LiteralPath $fp -PathType Leaf) -or (Get-Item -LiteralPath $fp).Length -ne $im[$k]) { throw "not confirmed on disk: $k" }
                        }
                        $pendingStray += , @($ir, $im, $mainRar, $prefix)
                        $nU++; Write-Host ("  INNER unpacked (the stray .rar stays until the project .rar confirms it): {0}  ->  {1}" -f $ir, $dest) -ForegroundColor Cyan
                    }
                    catch { $nK++; Write-Host ("  INNER kept ({0}): {1}" -f $_.Exception.Message, $ir) -ForegroundColor Yellow }
                }
            }
            if ($nU + $nK -gt 0) { Write-Host ("Inner .rar files: {0} unpacked | {1} kept" -f $nU, $nK) }
        }

        # The resume log may be STALE (a .rar can change or be damaged after it was logged), so it is NOT used to skip testing any more:
        # every existing project .rar is tested again (rar t) on every run, before anything is added or deleted. Only the -Trust switch skips that.
        $trustLog = @{}
        $skippedByLog = if ($Trust) { 'NOT tested (-Trust)' } elseif ($Recheck) { 'ALL tested (-Recheck audit)' } else { 'tested when anything is added or deleted' }
        $targets = @($all)
        $total = $targets.Count
        if (@($roots).Count -gt 1) {
            Write-Host "`nFOLDERS RUNNING TOGETHER ($(@($roots).Count)):" -ForegroundColor Cyan
            $q = 0
            foreach ($rt in $roots) { Write-Host ("  {0}. {1}  ({2} project folders)" -f ($q + 1), $rt, @($lists[$q]).Count); $q++ }
        }
        else { Write-Host "`nFOLDER $idx of ${count}: $($roots[0])" -ForegroundColor Cyan }
        Write-Host ("RAR Archiver v$ScriptVersion | Folders: {0} | project .rar: {1} | parallel: {2} | level: {3}" -f @($all).Count, $skippedByLog, $jobs, $level)
        if ($total -eq 0) { Write-Host 'Nothing to do.' }
        else {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $i = 0; $nDone = 0; $nAdded = 0; $nSkip = 0; $nFail = 0; $nEmpty = 0; $nBusy = 0
            $active = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new()
            Write-Host ("Starting up to {0} folders at the same time. Many START lines in a row = they are running together; a line is printed when one FINISHES." -f $jobs) -ForegroundColor DarkGray

            $targets | ForEach-Object -ThrottleLimit $jobs -Parallel {
                $rarExe = $using:rarExe; $level = $using:level; $skipPacked = $using:skipPacked; $store = $using:store; $mt = $using:mt; $excludeTypes = $using:excludeTypes; $googleTypes = $using:googleTypes; $packedTypes = $using:packedTypes; $tempTypes = $using:tempTypes; $trust = $using:Trust; $recheck = $using:Recheck; $active = $using:active; $trustLog = $using:trustLog; $work = $using:work; $lockDir = $using:lockDir
                $dir = $_.FullName; $n = $_.Name
                $rar = Join-Path $dir "$n.rar"
                $status = $null

                # one folder must never stop the others: no "stop on error" here, and any error becomes a FAIL line
                $ErrorActionPreference = 'Continue'
                $PSNativeCommandUseErrorActionPreference = $false
                $msg = ''

                # leftovers of an interrupted run in the project folder: WinRAR temp files only, safe to remove
                Get-ChildItem -LiteralPath $dir -Filter '__rar_*.rartemp' -File -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

                $t0 = Get-Date
                $null = $active.TryAdd($n, $n)
                Write-Host ("{0:HH:mm:ss} -- START {1}" -f $t0, $n)

                # the archive's own file list: relative path (lower case) -> size. $null = could not be read.
                $readList = {
                    param($exe, $archive)
                    $lines = & $exe lt -scfr $archive 2>$null
                    if ($LASTEXITCODE -ne 0) { return $null }
                    $map = @{}
                    $name = $null; $type = $null
                    foreach ($line in $lines) {
                        if     ($line -match '^\s*Name:\s(.*)$')     { $name = $Matches[1].Trim().Replace('/', '\'); $type = $null }
                        elseif ($line -match '^\s*Type:\s*(\w+)')    { $type = $Matches[1] }
                        elseif ($line -match '^\s*Size:\s*(\d+)')    { if ($name -and $type -eq 'File') { $map[$name.ToLowerInvariant()] = [int64]$Matches[1] } }
                    }
                    if ($map.Count -eq 0) { return $null }
                    return $map
                }
                # every file in the folder except the working .rar (found by its exact path), WinRAR temp/damaged files and the Google/.lnk shortcuts Rar cannot read
                $skipNames = $googleTypes + $tempTypes
                $listFiles = {
                    @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue |
                        Where-Object { $fn = $_.Name; $_.FullName -ne $rar -and -not ($skipNames | Where-Object { $fn -like $_ }) })
                }
                $isPacked = { param($f) $fn = $f.Name; [bool]($packedTypes | Where-Object { $fn -like $_ }) }

                # lock this project folder for this window (a lock file in the logs folder, never in the project folder)
                $lockStream = $null; $lockFile = $null; $busy = $false
                try {
                    $key = [System.BitConverter]::ToString([System.Security.Cryptography.SHA1]::HashData([System.Text.Encoding]::UTF8.GetBytes($dir.ToLowerInvariant()))) -replace '-', ''
                    $lockFile = Join-Path $lockDir "$key.lock"
                    $lockStream = [System.IO.File]::Open($lockFile, 'OpenOrCreate', 'ReadWrite', 'None')
                } catch [System.IO.IOException] { $busy = $true }
                catch { }   # lock folder unavailable: work without the lock

                try {
                    if ($busy) { $status = 'busy'; $msg = 'this folder is being processed by another window; skipped here' }
                    else {
                    # 1. what is in the folder, and what is to be ADDED (other compressed files are never newly added)
                    $files = & $listFiles
                    $left  = @($files | Where-Object { -not (& $isPacked $_) })

                    # 2. an existing .rar: is it good? (the log or -Trust save reading it again). A .rar is NEVER deleted:
                    #    it may be the only copy of files that were archived (and deleted) earlier.
                    $rarOk = $false
                    if (Test-Path -LiteralPath $rar) {
                        # The project .rar is TESTED (rar t) whenever the run could delete something that depends on it (a file left in the folder, a duplicate
                        # .rar, a stray). A project with nothing left in the folder deletes nothing, so it is not read at all (-Recheck = audit: test every one).
                        if (($trust -and (Get-Item -LiteralPath $rar).Length -gt 0) -or (-not $recheck -and $files.Count -eq 0)) { $rarOk = $true }
                        else {
                            & $rarExe t -idq $rar 2>&1 | Out-Null
                            if ($LASTEXITCODE -eq 0) { $rarOk = $true }
                            elseif ($files.Count -eq 0) {
                                $status = 'FAIL damaged'
                                $msg = 'the .rar failed its test and no other files are in the folder: kept untouched (WinRAR "Repair archive" can use its recovery record)'
                            }
                            else { Move-Item -LiteralPath $rar -Destination "$rar.damaged" -Force }   # files are still here: rebuild from them, keep the old file renamed
                        }
                    }

                    # 2b. duplicate archives "<name> (N).rar" (Drive sync copies): EXTRACT each into a temp folder (desktop.ini / Thumbs.db are left out: Google Drive
                    #     refuses to create them), then place every file into this project folder: missing -> moved in; same relative path and same size -> the
                    #     redundant copy is dropped; same path but different size -> kept as "<file> (dup1).ext". Only when every file is placed is the duplicate
                    #     .rar deleted. Step 3 then adds the new files and folders to the main .rar (originals are deleted only after its test).
                    if ($rarOk -and -not $status) {
                        $dups = @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match ('^' + [regex]::Escape($n) + '( \(\d+\))+\.rar$') } | Sort-Object Name)
                        foreach ($d in $dups) {
                            $tmp = Join-Path $work ('dup_' + [guid]::NewGuid().ToString('N'))
                            try {
                                $to = & $rarExe t -idq $d.FullName 2>&1 | Out-String
                                if ($LASTEXITCODE -ne 0) { throw 'the duplicate failed its test' }
                                New-Item -ItemType Directory -Path $tmp -Force | Out-Null
                                $xo = & $rarExe x -idq -y '-x*desktop.ini' '-x*Thumbs.db' "-op$tmp" $d.FullName 2>&1 | Out-String
                                $xc = $LASTEXITCODE
                                if ($xc -ne 0 -and $xc -ne 10) { $xl = @($xo -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 2); throw ("extract failed, WinRAR exit $xc" + $(if ($xl.Count -gt 0) { ': ' + ($xl -join ' | ') } else { '' })) }
                                $placed = 0; $same = 0; $kept = 0; $fail = 0
                                foreach ($dd in @(Get-ChildItem -LiteralPath $tmp -Directory -Recurse -Force -ErrorAction SilentlyContinue)) {
                                    $rd = $dd.FullName.Substring($tmp.Length).TrimStart('\')
                                    $tgtD = Join-Path $dir $rd
                                    if (-not (Test-Path -LiteralPath $tgtD)) { try { New-Item -ItemType Directory -Path $tgtD -Force | Out-Null } catch { $fail++ } }
                                }
                                foreach ($ff in @(Get-ChildItem -LiteralPath $tmp -File -Recurse -Force -ErrorAction SilentlyContinue)) {
                                    $rel = $ff.FullName.Substring($tmp.Length).TrimStart('\')
                                    $tgt = Join-Path $dir $rel
                                    try {
                                        $tgtDir = Split-Path -Parent $tgt
                                        if (-not (Test-Path -LiteralPath $tgtDir)) { New-Item -ItemType Directory -Path $tgtDir -Force | Out-Null }
                                        if (-not (Test-Path -LiteralPath $tgt)) { Move-Item -LiteralPath $ff.FullName -Destination $tgt -ErrorAction Stop; $placed++ }
                                        elseif ((Get-Item -LiteralPath $tgt).Length -eq $ff.Length) { $same++ }
                                        else {
                                            $stem = [System.IO.Path]::GetFileNameWithoutExtension($ff.Name); $ext = $ff.Extension; $k = 1
                                            while (Test-Path -LiteralPath (Join-Path $tgtDir "$stem (dup$k)$ext")) { $k++ }
                                            Move-Item -LiteralPath $ff.FullName -Destination (Join-Path $tgtDir "$stem (dup$k)$ext") -ErrorAction Stop; $kept++
                                        }
                                    }
                                    catch { $fail++ }
                                }
                                if ($fail -eq 0) {
                                    Remove-Item -LiteralPath $d.FullName -Force
                                    $msg = (($msg, "duplicate '$($d.Name)' merged ($placed new file(s), $same identical, $kept kept as (dupN)) and deleted") -ne '' -join '; ')
                                }
                                else { $msg = (($msg, "duplicate '$($d.Name)': $fail item(s) could not be placed, duplicate kept") -ne '' -join '; ') }
                            }
                            catch { $msg = (($msg, "duplicate '$($d.Name)' not merged ($($_.Exception.Message)), kept") -ne '' -join '; ') }
                            finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } }
                        }
                        if ($dups.Count -gt 0) {   # the folder now holds the merged files: list again so step 3 adds them
                            $files = & $listFiles
                            $left  = @($files | Where-Object { -not (& $isPacked $_) })
                        }
                    }

                    # 3. build the archive, or ADD the leftovers to the existing one (u = add new and newer files). WinRAR never deletes originals (no -df): step 4 deletes a file only
                    #    when the (tested) archive's own list has the same path and size, so a file that WinRAR could only READ PARTLY stays in the folder.
                    $nBefore = -1; $nAfter = -1
                    if ($status) { }     # damaged archive with nothing to rebuild from: reported above
                    elseif ($rarOk -and $left.Count -eq 0) { $status = 'skip' }     # good archive and nothing more to add
                    else {
                        $cmd = if ($rarOk) { 'u' } else { 'a' }
                        if ($rarOk) { $m0 = & $readList $rarExe $rar; if ($m0) { $nBefore = $m0.Count } }
                        $opts = @($cmd, '-r', '-ep1', '-s', '-rr', '-t', "-mt$mt", '-dh', '-idq', "-w$work", $level)   # -s solid, -rr recovery record, -t test, -df delete after = the WinRAR boxes ticked
                        if (-not $store) { $opts += $skipPacked }
                        foreach ($x in $excludeTypes) { $opts += "-x$x" }
                        # WinRAR asks "[I]gnore, i[G]nore all, [R]etry, [Q]uit" on a read error and WAITS for a key: nobody is there, so the answers are piped in:
                        # retry twice, then ignore all (the file's readable part is archived; step 4 keeps a file whose size differs). If the input ever ends, Rar aborts instead of hanging.
                        $answers = "R`nR`n" + ("G`n" * 500)
                        $out = $answers | & $rarExe @opts "-x$rar" $rar "$dir\*" 2>&1 | Out-String
                        $code = $LASTEXITCODE
                        # Google Drive sometimes cannot open/write a file for a moment (exit 5 / 6): wait and run the same (idempotent) command again, up to 2 more times
                        for ($try = 1; $try -le 2 -and ($code -eq 5 -or $code -eq 6); $try++) {
                            Start-Sleep -Seconds (5 * $try)
                            if (Test-Path -LiteralPath $rar) { $opts[0] = 'u' }
                            $out = $answers | & $rarExe @opts "-x$rar" $rar "$dir\*" 2>&1 | Out-String
                            $code = $LASTEXITCODE
                        }
                        # exit 1 = warning, 12 = read error that was ignored: accepted ONLY if the archive passes its full test; the files that had errors stay in the folder
                        if ($code -eq 1 -or $code -eq 12) {
                            $wl = @($out -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 2)
                            & $rarExe t -idq $rar 2>&1 | Out-Null
                            if ($LASTEXITCODE -eq 0) { $msg = ("WinRAR warning (exit {0}, e.g. a file Google Drive could not read; it is kept in the folder): {1}" -f $code, ($wl -join ' | ')); $code = 0 }
                        }
                        if ($code -eq 0) { $status = if ($rarOk) { 'added' } else { 'done' } }
                        elseif ($code -eq 10) { $status = if ($rarOk) { 'skip' } else { 'empty' } }   # nothing more can be added
                        else {
                            $status = "FAIL exit $code"
                            $lines = @($out -split "`r?`n" | Where-Object { $_.Trim() })
                            $msg = ($lines | Select-Object -Last 3) -join ' | '
                        }
                    }

                    # 4. CLEAN UP: a file still in the folder is deleted ONLY when the archive is good (tested now, or by the log / -Trust) and its own
                    #    file list has the same relative path AND the same size. This covers files left by an interrupted run, and other compressed
                    #    files that are already inside. Nothing else is deleted.
                    $map = $null; $already = 0; $rest = @(); $nNot = 0; $nSize = 0; $nDelFail = 0; $firstDelErr = ''; $exNot = @(); $exSize = @(); $sampleKey = ''
                    if ($status -in 'skip', 'added', 'done') {
                        $rest = & $listFiles
                        if ($rest.Count -gt 0) {
                            $map = & $readList $rarExe $rar
                            if ($map) {
                                $nAfter = $map.Count
                                $sampleKey = [string]($map.Keys | Select-Object -First 1)
                                foreach ($f in $rest) {
                                    $relShown = $f.FullName.Substring($dir.Length).TrimStart('\', '/')
                                    $rel = $relShown.ToLowerInvariant()
                                    if (-not $map.ContainsKey($rel)) {
                                        $nNot++; if ($exNot.Count -lt 2) { $exNot += $relShown }
                                    }
                                    elseif ($map[$rel] -ne $f.Length) {
                                        $nSize++; if ($exSize.Count -lt 2) { $exSize += "$relShown (folder $($f.Length) bytes, archive $($map[$rel]))" }
                                    }
                                    else {
                                        # Google Drive can hold a file for a moment: try again after 3 s and 6 s, and keep the real error for the message
                                        $delMsg = ''
                                        for ($dt = 0; $dt -le 2; $dt++) {
                                            if ($dt -gt 0) { Start-Sleep -Seconds (3 * $dt) }
                                            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $delMsg = '' } catch { $delMsg = $_.Exception.Message }
                                            if (-not (Test-Path -LiteralPath $f.FullName)) { break }
                                        }
                                        if (Test-Path -LiteralPath $f.FullName) { $nDelFail++; if (-not $firstDelErr) { $firstDelErr = "$relShown : $delMsg" } } else { $already++ }
                                    }
                                }
                                if ($already -gt 0) {
                                    # empty sub-folders left behind (deepest first)
                                    Get-ChildItem -LiteralPath $dir -Directory -Recurse -Force -ErrorAction SilentlyContinue |
                                        Sort-Object { $_.FullName.Length } -Descending |
                                        Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue) } |
                                        Remove-Item -Force -ErrorAction SilentlyContinue
                                }
                                $rest = & $listFiles
                            }
                        }
                        if ($already -gt 0 -and $status -eq 'skip') { $status = 'added' }   # something was cleaned up
                        $notAdded = @($rest | Where-Object { -not (& $isPacked $_) })
                        $kept     = @($rest | Where-Object { & $isPacked $_ })
                        $parts = @()
                        if ($already -gt 0)         { $parts += "$already file(s) confirmed in the archive (same path and size) and removed from the folder" }
                        if ($status -eq 'added')    { $parts += $(if ($nBefore -ge 0 -and $nAfter -ge 0) { "archive entries before $nBefore, after $nAfter" } else { 'archive file list unavailable' }) }
                        if ($notAdded.Count -gt 0) {
                            if ($map) {
                                $why = @()
                                if ($nNot -gt 0)     { $why += "$nNot not in the archive list (e.g. $($exNot -join ' | '))" }
                                if ($nSize -gt 0)    { $why += "$nSize with a different size (e.g. $($exSize -join ' | '))" }
                                if ($nDelFail -gt 0) { $why += "$nDelFail could not be deleted after 3 tries (first: $firstDelErr)" }
                                $parts += ("$($notAdded.Count) file(s) still left, kept: " + ($why -join '; ') + "; archive path style: '$sampleKey'")
                            }
                            else { $parts += ("$($notAdded.Count) file(s) still left in the folder (archive file list unavailable, nothing deleted), e.g. " + (($notAdded | Select-Object -First 3 | ForEach-Object { $_.Name }) -join ', ')) }
                        }
                        if ($kept.Count -gt 0)      { $parts += "$($kept.Count) other compressed file(s) kept in the folder (never added)" }
                        if ($parts.Count -gt 0) { $msg = (($msg, ($parts -join '; ')) -ne '' -join '; ') }
                    }
                    }   # end of: not busy
                }
                catch {
                    $status = 'FAIL error'
                    $msg = $_.Exception.Message
                }

                if ($lockStream) { $lockStream.Dispose(); Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue }
                $v = ''; $null = $active.TryRemove($n, [ref]$v)
                $t1 = Get-Date
                $size = 0; $ticks = 0
                if ($status -in 'done', 'added', 'skip' -and (Test-Path -LiteralPath $rar)) {
                    $f = Get-Item -LiteralPath $rar; $size = $f.Length; $ticks = $f.LastWriteTimeUtc.Ticks
                }
                [pscustomobject]@{ Path = $dir; Name = $n; Status = $status; Size = $size; Ticks = $ticks; Time = $t1.ToString('s'); Msg = $msg; End = $t1; Secs = [int][Math]::Round(($t1 - $t0).TotalSeconds) }
            } | ForEach-Object {
                $i++
                switch -Wildcard ($_.Status) { 'done' { $nDone++ } 'added' { $nAdded++ } 'skip' { $nSkip++ } 'empty' { $nEmpty++ } 'busy' { $nBusy++ } default { $nFail++ } }
                $el  = $sw.Elapsed
                $eta = [TimeSpan]::FromSeconds($el.TotalSeconds / $i * ($total - $i))
                $label = if ($_.Status -like 'FAIL*') { $_.Status } else { $_.Status.ToUpper() }
                Write-Host ("{0:HH:mm:ss} -- {1} {2} ({3}) [{4}/{5}]" -f $_.End, $label, $_.Name, (Fmt $_.Secs), $i, $total)
                if ($_.Msg) { Write-Host ("      reason: {0}" -f $_.Msg) -ForegroundColor Yellow }
                Write-Progress -Activity 'Archiving' -Status "$i / $total  | running now $($active.Count)  | done $nDone  added $nAdded  skip $nSkip  empty $nEmpty  busy $nBusy  fail $nFail  | ETA $($eta.ToString('hh\:mm\:ss'))" -PercentComplete ([int](100 * $i / $total))
                if ($_.Status -in 'done', 'added', 'skip') {
                    $row = $_ | Select-Object Path, Status, Size, Ticks, Time
                    Use-Lock { $row | Export-Csv -LiteralPath $logFile -Append }   # PowerShell 7 writes no type line by default; -NoTypeInformation is obsolete and printed a warning per folder
                }
            }
            Write-Progress -Activity 'Archiving' -Completed
            Write-Host ("`nFINISHED  done {0} | added to existing {1} | skip {2} | empty {3} | busy (other window) {4} | FAIL {5} | total time {6:hh\:mm\:ss}" -f $nDone, $nAdded, $nSkip, $nEmpty, $nBusy, $nFail, $sw.Elapsed)
            # stray .rar files unpacked at the start: delete each ONLY when the project .rar (now built) holds every one of its files with the same size
            foreach ($ps in $pendingStray) {
                $irp = $ps[0]; $imp = $ps[1]; $mainP = $ps[2]; $pfx = $ps[3]
                if (-not (Test-Path -LiteralPath $irp -PathType Leaf)) { continue }   # already gone (e.g. packed with "include other archives")
                try {
                    & $rarExe t -idq $mainP 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw 'the project .rar failed its test' }
                    $mp = & $readListO $rarExe $mainP
                    if (-not $mp) { throw 'the project .rar file list is unreadable' }
                    $miss = @($imp.Keys | Where-Object { $_ -notmatch '(^|\\)(desktop\.ini|thumbs\.db)$' -and (-not $mp.ContainsKey(($pfx + $_.ToLowerInvariant())) -or $mp[($pfx + $_.ToLowerInvariant())] -ne $imp[$_]) })
                    if ($miss.Count -gt 0) { throw ("{0} file(s) not confirmed in the project .rar, e.g. {1}" -f $miss.Count, $miss[0]) }
                    Remove-Item -LiteralPath $irp -Force
                    Write-Host ("  INNER stray .rar confirmed in the project .rar, removed: {0}" -f $irp) -ForegroundColor Cyan
                }
                catch { Write-Host ("  INNER stray .rar KEPT ({0}): {1}" -f $_.Exception.Message, $irp) -ForegroundColor Yellow }
            }
            if ($nFail -gt 0) { Write-Host ' Folders marked FAIL keep their original files; choose R below to retry them.' -ForegroundColor Yellow }
        }
        Write-Host "Resume log: $logFile"
        Write-Host "Run log:    $runLog"
    }
    catch { Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red }
    finally {
        try { Stop-Transcript | Out-Null } catch { }
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue   # this window's temp copies only
    }
}

# ---------- header + checks ----------
Clear-Host
Write-Host '=============================================================='
Write-Host '   RAR ARCHIVER  -  one .rar per project folder (WinRAR)'
Write-Host '=============================================================='

$rarExe = @('C:\Program Files\WinRAR\Rar.exe', 'C:\Program Files (x86)\WinRAR\Rar.exe') | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $rarExe) { Write-Host ' WinRAR Rar.exe not found. Install WinRAR first.' -ForegroundColor Red; return }
$cores = [Environment]::ProcessorCount
Write-Host (" PowerShell 7 ........ OK  ({0})" -f $PSVersionTable.PSVersion)
Write-Host " WinRAR Rar.exe ...... OK  ($rarExe)"
Write-Host " CPU ................. $cores logical processors detected"
Write-Host ''

# ---------- saved answers become the defaults ----------
function Get-SavedFolders($cfg, [string]$fallback) {
    $list = @()
    if ($cfg.Folders) { $list = @($cfg.Folders) } elseif ($cfg.Folder) { $list = @($cfg.Folder) }
    $list = @($list | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) })
    if ($list.Count -gt 0) { return $list }
    return @($fallback)
}
$cfg = $null
if (-not $Reset -and (Test-Path -LiteralPath $cfgFile)) {
    try { $cfg = Get-Content -LiteralPath $cfgFile -Raw -Encoding utf8 | ConvertFrom-Json } catch { $cfg = $null }
}
$s = @{
    Folders = @(Get-SavedFolders $cfg $here)
    LogDir = if ($cfg.LogDir) { $cfg.LogDir } else { $here }
    Jobs   = if ($cfg.Jobs)   { [int]$cfg.Jobs } else { 64 }
    Preset = if ($cfg.Preset) { [int]$cfg.Preset } else { 3 }
    Together = if ($cfg.Together) { [int]$cfg.Together } else { 2 }
    Archives = if ($cfg -and [int]$cfg.Schema -ge 3 -and $cfg.Archives) { [int]$cfg.Archives } else { 1 }   # default: EXCLUDE other archives (.zip/.rar... stay as they are); answers saved by 1.4.0 are not reused
    Orphans = if ($cfg.Orphans) { [int]$cfg.Orphans } else { 2 }
    Nested = if ($cfg.Nested) { [int]$cfg.Nested } else { 2 }
    Shortcuts = if ($cfg.Shortcuts) { [int]$cfg.Shortcuts } else { 2 }
    Level  = if ($cfg.Method -and [int]$cfg.Method -le $levels.Count) { [int]$cfg.Method } else { 4 }
    Custom = if ($cfg.CustomCores) { [int]$cfg.CustomCores } else { [Math]::Max(1, $cores - 1) }
}
if ($cfg) { Write-Host " (answers of the last run loaded from RUN_settings.json; Enter keeps them)`n" -ForegroundColor DarkGray }

# ---------- update check ----------
# latest.txt: line 1 = newest version (MAJOR.MINOR.PATCH), line 2 = download link of the zip, line 3 = SHA-256 of that zip.
# A newer version is installed automatically (no question). The zip must match the SHA-256 in latest.txt, or it is discarded.
# Only CLEANUP.ps1 is replaced (RUN.bat is running right now, so a newer one is saved as RUN.bat.new). The old CLEANUP.ps1 is MOVED into
# "old version\<version>\" next to the script; only the 3 newest folders there are kept. Nothing outside this script folder is touched.
$ScriptVersion = '1.9.0'   # semantic version MAJOR.MINOR.PATCH: PATCH = fix, MINOR = new feature, MAJOR = changed behaviour; keep latest.txt in step
$updateUrl = if ($cfg -and $cfg.UpdateUrl) { [string]$cfg.UpdateUrl } else { 'https://drive.google.com/uc?export=download&id=1WQk3C1l9WXLhQfSzl6jvCOBKhU6O5awf' }
if ($env:RAR_UPDATED_FROM) { Write-Host (" Updated: v{0} -> v{1}" -f $env:RAR_UPDATED_FROM, $ScriptVersion) -ForegroundColor Green; Remove-Item Env:\RAR_UPDATED_FROM -ErrorAction SilentlyContinue; $justUpdated = $true } else { $justUpdated = $false }
$upStatus = ''
try {
    $resp = Invoke-WebRequest -Uri $updateUrl -TimeoutSec 8 -UseBasicParsing -ErrorAction Stop
    $txt = if ($resp.Content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($resp.Content) } else { [string]$resp.Content }
    $latest = @($txt -split "`r?`n" | Where-Object { $_.Trim() })
    $lv = $null; $cv = [version]$ScriptVersion
    if ($latest.Count -ge 1 -and [version]::TryParse($latest[0].Trim().TrimStart('vV'), [ref]$lv) -and $lv -gt $cv) {
        $link = if ($latest.Count -ge 2) { $latest[1].Trim() } else { '' }
        Write-Host (" NEW VERSION AVAILABLE: v{0} (you have v{1})" -f $lv.ToString(), $ScriptVersion) -ForegroundColor Yellow
        $doUp = $false; $id = ''
        if ($link -match '/d/([A-Za-z0-9_-]+)') { $id = $Matches[1] }   # taken now: the -match below overwrites $Matches
        if ($id -and $latest.Count -ge 3 -and $latest[2].Trim() -match '^[0-9A-Fa-f]{64}$') {
            $doUp = $true   # always updates, no question (the SHA-256 below still has to match)
        }
        else { Write-Host "   Download: $link" -ForegroundColor Yellow }
        if ($doUp) {
            $sha = $latest[2].Trim().ToUpperInvariant()
            $tmpD = Join-Path ([System.IO.Path]::GetTempPath()) ('rar-update-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path $tmpD -Force | Out-Null
            try {
                $zipF = Join-Path $tmpD 'new.zip'
                Invoke-WebRequest -Uri ($(if ($cfg -and $cfg.UpdateDownloadBase) { [string]$cfg.UpdateDownloadBase } else { 'https://drive.google.com/uc?export=download&confirm=t&id=' }) + $id) -OutFile $zipF -TimeoutSec 120 -UseBasicParsing -ErrorAction Stop
                if ((Get-FileHash -LiteralPath $zipF -Algorithm SHA256).Hash.ToUpperInvariant() -ne $sha) { throw 'the download does not match the SHA-256 in latest.txt (discarded)' }
                $exD = Join-Path $tmpD 'x'
                Expand-Archive -LiteralPath $zipF -DestinationPath $exD -Force
                $newPs = Join-Path $exD 'CLEANUP.ps1'
                if (-not (Test-Path -LiteralPath $newPs)) { throw 'CLEANUP.ps1 is not in the zip' }
                if ((Get-Content -LiteralPath $newPs -Raw) -notmatch [regex]::Escape("`$ScriptVersion = '" + $lv.ToString() + "'")) { throw 'the zip does not contain the announced version' }
                $oldD = Join-Path $here ('old version\' + $ScriptVersion)
                New-Item -ItemType Directory -Path $oldD -Force | Out-Null
                Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $oldD 'CLEANUP.ps1') -Force   # old copy is safe first, then the file is overwritten in place
                Copy-Item -LiteralPath $newPs -Destination $PSCommandPath -Force
                $newBat = Join-Path $exD 'RUN.bat'
                if ((Test-Path -LiteralPath $newBat) -and (Test-Path -LiteralPath (Join-Path $here 'RUN.bat')) -and
                    (Get-FileHash -LiteralPath $newBat).Hash -ne (Get-FileHash -LiteralPath (Join-Path $here 'RUN.bat')).Hash) {
                    Copy-Item -LiteralPath $newBat -Destination (Join-Path $here 'RUN.bat.new') -Force
                    Write-Host '   A newer RUN.bat is saved as RUN.bat.new (replace RUN.bat with it when this window is closed).' -ForegroundColor Yellow
                }
                # keep only the 3 newest old versions
                $oldAll = @(Get-ChildItem -LiteralPath (Join-Path $here 'old version') -Directory -ErrorAction SilentlyContinue |
                    Sort-Object { $v0 = $null; if ([version]::TryParse($_.Name, [ref]$v0)) { $v0 } else { [version]'0.0' } } -Descending)
                foreach ($od in ($oldAll | Select-Object -Skip 3)) { Remove-Item -LiteralPath $od.FullName -Recurse -Force -ErrorAction SilentlyContinue }
                Write-Host ("   Updated to v{0}. The previous version is in: {1}" -f $lv.ToString(), $oldD) -ForegroundColor Green
                Write-Host '   Restarting...' -ForegroundColor Green
                $relaunch = $true
            }
            catch { Write-Host ("   Update failed ({0}); continuing with v{1}." -f $_.Exception.Message, $ScriptVersion) -ForegroundColor Yellow }
            finally { Remove-Item -LiteralPath $tmpD -Recurse -Force -ErrorAction SilentlyContinue }
            if ($relaunch) {
                $env:RAR_UPDATED_FROM = $ScriptVersion
                $argsOut = @(); if ($Recheck) { $argsOut += '-Recheck' }; if ($Reset) { $argsOut += '-Reset' }; if ($Trust) { $argsOut += '-Trust' }
                & (Get-Process -Id $PID).Path -NoLogo -ExecutionPolicy Bypass -File $PSCommandPath @argsOut
                exit $LASTEXITCODE
            }
        }
        Write-Host ''
    }
    elseif ($latest.Count -ge 1 -and $lv) { $upStatus = "up to date (latest is v$($lv.ToString()))" }
    else { $snip = ($txt -replace '\s+', ' '); if ($snip.Length -gt 80) { $snip = $snip.Substring(0, 80) }; $upStatus = "update check: latest.txt has no readable version (got: $snip)" }
}
catch { $upStatus = 'update check skipped: ' + $_.Exception.Message }
if (-not $justUpdated) {
    if ($upStatus -like 'up to date*') { Write-Host (" RAR Archiver v{0}: {1}" -f $ScriptVersion, $upStatus) -ForegroundColor DarkGray }
    elseif ($upStatus) { Write-Host (" RAR Archiver v{0}: {1}" -f $ScriptVersion, $upStatus) -ForegroundColor Yellow }
}

# ---------- main loop: ask, run, then "what next" ----------
$askAll = $true
while ($true) {
    if ($askAll) {
        Write-Host ' [1/2] Folder(s) to compress'
        $s.Folders = @(Read-Folders $s.Folders)
        Write-Host "`n [2/2] Customize advanced config? (log folder, parallel jobs, CPU, compression, other archives, loose/inner .rar)"
        $adv = (Ask '       Y / N  >' 'N').Trim()
        if ($adv -match '^(y|yes)$') {
            Write-Host "`n [adv 1/8] Folder for the log files"
            $s.LogDir = Read-LogDir $s.LogDir
            Write-Host "`n [adv 2/8] Parallel jobs (how many folders at once, 1-64)"
            $s.Jobs = AskInt '       >' $s.Jobs 1 64
            Write-Host "`n [adv 3/8] CPU use"
            $c = Read-Cpu $cores $s.Preset $s.Custom
            $s.Preset = $c.Preset; $s.Custom = $c.Custom
            Write-Host "`n [adv 4/8] Compression method (same list as WinRAR; Store uses almost no CPU)"
            $s.Level = Read-Level $s.Level
            Write-Host "`n [adv 5/8] Other archives inside the folders"
            $s.Archives = Read-Archives $s.Archives
            Write-Host "`n [adv 6/8] Loose .rar files lying directly in the folder(s) (not inside a project folder)"
            $s.Orphans = Read-Orphans $s.Orphans
            Write-Host "`n [adv 7/8] Small .rar files made INSIDE sub-folders of a project by an older run"
            $s.Nested = Read-Nested $s.Nested
            Write-Host "`n [adv 8/9] Shortcuts (.lnk) to folders inside the project folders"
            $s.Shortcuts = Read-Shortcuts $s.Shortcuts
        }
        if (@($s.Folders).Count -gt 1) {
            if ($adv -match '^(y|yes)$') {
                Write-Host "`n [adv 9/9] Several folders: together or one by one?"
                $s.Together = Read-Together $s.Together
            }
        }
        $askAll = $false
    }
    $cpu = Get-Cpu $cores $s.Preset $s.Custom
    $mtShow = [Math]::Max(1, [int][Math]::Floor($cpu.CoresUse / $s.Jobs))

    Write-Host "`n--------------------------------------------------------------"
    Write-Host ' SUMMARY'
    if (@($s.Folders).Count -eq 1) { Write-Host "   Compress ..... $($s.Folders[0])" }
    else {
        Write-Host "   Compress ..... $(@($s.Folders).Count) folders, one by one:"
        $k = 0
        foreach ($f in $s.Folders) { $k++; Write-Host "                  $k. $f" }
    }
    Write-Host "   Log files .... $($s.LogDir)\logs"
    Write-Host "   Temp files ... $($s.LogDir)\logs\works   (WinRAR working copy; needs free space for the biggest .rar)"
    Write-Host "   Jobs ......... $($s.Jobs) at once"
    Write-Host "   CPU .......... $($cpu.Name): $($cpu.CoresUse) of $cores cores, $mtShow thread(s) per job, priority $($cpu.Priority)"
    Write-Host ('   Compression .. ' + $levels[$s.Level - 1].Name + '  (' + $levels[$s.Level - 1].Arg + ')')
    if (@($s.Folders).Count -gt 1) { Write-Host ('   Folders ...... ' + $(if ($s.Together -eq 2) { 'AT THE SAME TIME (one shared pool of jobs)' } else { 'one by one' })) }
    Write-Host ('   Loose .rar ... ' + $(if ($s.Orphans -eq 2) { 'a folder is CREATED for each and the .rar is MOVED into it (nothing deleted)' } else { 'left alone' }))
    Write-Host ('   Shortcuts .... ' + $(if ($s.Shortcuts -eq 2) { 'folder shortcuts (.lnk) are REPLACED by a real folder with a copy of the target (shortcut deleted only after every file is confirmed)' } else { 'left alone' }))
    Write-Host ('   Inner .rar ... ' + $(if ($s.Nested -eq 2) { 'UNPACKED back into their folder, then deleted once every file is confirmed' } else { 'left alone' }))
    Write-Host ('   Other archives ' + $(if ($s.Archives -eq 2) { 'INCLUDED (.rar .zip .7z ... are added)' } else { 'EXCLUDED (.rar .zip .7z ... stay in the folder)' }))
    Write-Host ' WARNING: the original files are DELETED after each .rar passes its test.' -ForegroundColor Yellow
    Write-Host '--------------------------------------------------------------'

    if ((Read-Host ' Type YES to start, anything else to cancel') -ceq 'YES') {
        Save-Config $s
        # limit the cores this process (and its Rar.exe children) may use
        try {
            $me = Get-Process -Id $PID
            if ($IsWindows -and $cores -lt 64) {
                $mask = if ($cpu.CoresUse -lt $cores) { [int64]((1L -shl $cpu.CoresUse) - 1) } else { [int64]((1L -shl $cores) - 1) }
                $me.ProcessorAffinity = [IntPtr]$mask
            }
            $me.PriorityClass = [System.Diagnostics.ProcessPriorityClass]$cpu.Priority
        } catch { Write-Host " (could not set CPU limit: $($_.Exception.Message))" -ForegroundColor Yellow }

        $count = @($s.Folders).Count
        if ($count -eq 1 -or $s.Together -eq 2) {
            Invoke-Archive $s $rarExe $cpu @($s.Folders) 1 1
        }
        else {
            $idx = 0
            foreach ($root in $s.Folders) {
                $idx++
                Invoke-Archive $s $rarExe $cpu @($root) $idx $count
            }
            Write-Host "`nALL $count FOLDERS PROCESSED." -ForegroundColor Green
        }
    }
    else { Write-Host ' Cancelled.' }

    # ---------- what next? ----------
    while ($true) {
        Write-Host "`n=============================================================="
        Write-Host ' WHAT NEXT?'
        Write-Host '   Paste new folder path(s) + Enter .. run them with the SAME settings (several: separate with ;)'
        Write-Host '   R + Enter ......................... run the same folder(s) again (retries FAIL folders)'
        Write-Host '   S + Enter ......................... change the settings (folder, logs, jobs, CPU)'
        Write-Host '   Q + Enter ......................... quit'
        Write-Host '=============================================================='
        $next = (Read-Pasted ' >').Trim()
        if ([string]::IsNullOrWhiteSpace($next)) { continue }
        if ($next -ieq 'Q') { Write-Host ' Bye.'; return }
        if ($next -ieq 'R') { break }
        if ($next -ieq 'S') { $askAll = $true; break }
        $ok = Resolve-Folders @(Parse-Paths $next)
        if ($ok) { $s.Folders = @($ok); break }
        Write-Host ' Not R, S, Q or existing folder(s).' -ForegroundColor Yellow
    }
}
