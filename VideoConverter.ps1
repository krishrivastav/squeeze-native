param([Parameter(ValueFromRemainingArguments = $true)][string[]]$InputPaths)

# =====================================================================
#  Video Converter  -  converts any video to YouTube-ready MP4 (H.264)
#  Max video bitrate default: 750 KBps (= 6000 kbps)
#  Needs FFmpeg (winget install "FFmpeg (Essentials Build)")
# =====================================================================

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$AppName = 'Video Converter'
$VideoExtensions = @(
    '.mts', '.m2ts', '.ts', '.tod', '.mod', '.trp', '.tp', '.mxf', '.vob', '.vro',
    '.mp4', '.m4v', '.mov', '.qt', '.mkv', '.avi', '.wmv', '.asf', '.flv', '.f4v',
    '.webm', '.mpg', '.mpeg', '.m2v', '.3gp', '.3g2', '.ogv', '.divx', '.dv', '.rm', '.rmvb', '.wtv'
)
$InterlacedLikely = @('.mts', '.m2ts', '.ts', '.tod', '.mod', '.trp', '.tp', '.mpg', '.mpeg', '.m2v', '.vob', '.vro', '.mxf', '.dv')
$PresetNames = @('veryfast', 'faster', 'medium')   # Fast, Balanced, Best quality

$SettingsDir = Join-Path $env:APPDATA 'VideoConverter'
$SettingsFile = Join-Path $SettingsDir 'settings.json'

$script:ffmpeg = $null
$script:ffprobe = $null
$script:running = $false
$script:cancel = $false
$script:exitAfter = $false
$script:proc = $null
$script:idx = 0
$script:total = 0
$script:added = @{}

# ---------------------------------------------------------------------
#  Helpers
# ---------------------------------------------------------------------
function Show-Msg([string]$text, [string]$icon = 'Information') {
    [void][System.Windows.Forms.MessageBox]::Show($text, $AppName, 'OK', $icon)
}

function Quote-Arg([string]$s) {
    return '"' + ($s -replace '"', '\"') + '"'
}

function ConvertTo-Num($x) {
    $r = 0.0
    if ($null -ne $x -and [double]::TryParse([string]$x, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$r)) {
        return $r
    }
    return 0.0
}

function Format-Size([long]$b) {
    if ($b -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N0} MB' -f ($b / 1MB)) }
    return ('{0:N0} KB' -f ($b / 1KB))
}

function Format-Eta([double]$sec) {
    if ($sec -lt 60) { return 'less than a minute' }
    $m = [int][Math]::Ceiling($sec / 60)
    if ($m -ge 60) { return ('{0} h {1} min' -f [int][Math]::Floor($m / 60), ($m % 60)) }
    return "$m min"
}

function Find-Tool([string]$name) {
    $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        (Join-Path $PSScriptRoot "$name.exe"),
        (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\$name.exe")
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    $pkg = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path -LiteralPath $pkg) {
        $f = Get-ChildItem -LiteralPath $pkg -Recurse -Filter "$name.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { return $f.FullName }
    }
    return $null
}

function Ensure-Tools {
    if (-not $script:ffmpeg) { $script:ffmpeg = Find-Tool 'ffmpeg' }
    if (-not $script:ffprobe) { $script:ffprobe = Find-Tool 'ffprobe' }
    if ($script:ffmpeg -and $script:ffprobe) { return $true }
    Show-Msg ("FFmpeg was not found on this computer.`n`n" +
        "If it was installed just now, please restart the PC once and try again.`n`n" +
        "Otherwise open Command Prompt and type:`n" +
        "winget install `"FFmpeg (Essentials Build)`"") 'Warning'
    return $false
}

function Invoke-Capture([string]$exe, [string]$arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    $p.Dispose()
    return $out
}

function Load-Settings {
    $s = @{
        OutputFolder = (Join-Path ([Environment]::GetFolderPath('MyVideos')) 'Converted')
        BitrateKBps  = 750
        Quality      = 1
    }
    try {
        if (Test-Path -LiteralPath $SettingsFile) {
            $j = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
            if ($j.OutputFolder) { $s.OutputFolder = [string]$j.OutputFolder }
            if ($j.BitrateKBps) { $s.BitrateKBps = [int]$j.BitrateKBps }
            if ($null -ne $j.Quality) { $s.Quality = [int]$j.Quality }
        }
    } catch { }
    return $s
}

function Save-Settings {
    try {
        if (-not (Test-Path -LiteralPath $SettingsDir)) { New-Item -ItemType Directory -Path $SettingsDir -Force | Out-Null }
        @{
            OutputFolder = $txtOut.Text
            BitrateKBps  = [int]$numRate.Value
            Quality      = $cmbQuality.SelectedIndex
        } | ConvertTo-Json | Set-Content -LiteralPath $SettingsFile -Encoding UTF8
    } catch { }
}

function Write-Log([string]$msg) {
    $txtLog.AppendText($msg + [Environment]::NewLine)
}

# ---------------------------------------------------------------------
#  Video analysis and ffmpeg command building
# ---------------------------------------------------------------------
function Get-VideoInfo([string]$path) {
    $a = '-v error -show_entries format=duration,bit_rate:stream=codec_type,codec_name,width,height,field_order,bit_rate,r_frame_rate,channels -of json -i ' + (Quote-Arg $path)
    $json = Invoke-Capture $script:ffprobe $a
    if ([string]::IsNullOrWhiteSpace($json)) { throw 'This file could not be read (it may be damaged or not a video).' }
    $info = $json | ConvertFrom-Json
    $v = @($info.streams | Where-Object { $_.codec_type -eq 'video' }) | Select-Object -First 1
    $au = @($info.streams | Where-Object { $_.codec_type -eq 'audio' }) | Select-Object -First 1
    if (-not $v) { throw 'No video found in this file.' }

    $fps = 0.0
    if ($v.r_frame_rate -match '^(\d+)/(\d+)$' -and [double]$Matches[2] -ne 0) {
        $fps = [double]$Matches[1] / [double]$Matches[2]
    }
    $vbr = ConvertTo-Num $v.bit_rate
    if ($vbr -le 0) {
        $fbr = ConvertTo-Num $info.format.bit_rate
        if ($fbr -gt 0) { $vbr = [Math]::Max(0, $fbr - 256000) }
    }
    return [pscustomobject]@{
        Width      = [int](ConvertTo-Num $v.width)
        Height     = [int](ConvertTo-Num $v.height)
        Fps        = $fps
        FieldOrder = [string]$v.field_order
        VideoKbps  = [int]($vbr / 1000)
        AudioCodec = $(if ($au) { [string]$au.codec_name } else { '' })
        Channels   = $(if ($au) { [int](ConvertTo-Num $au.channels) } else { 0 })
        Duration   = (ConvertTo-Num $info.format.duration)
    }
}

function New-FfmpegPlan([string]$src, [string]$dst, $info, [int]$rateKBps, [string]$preset, [bool]$forceAudioEncode = $false) {
    $cap = $rateKBps * 8
    $target = $cap
    $notes = @()

    # Do not pad low-bitrate sources up to the cap
    if ($info.VideoKbps -gt 0) {
        $want = [int]($info.VideoKbps * 1.25)
        if ($want -lt $cap) {
            $target = [Math]::Min($cap, [Math]::Max($want, 800))
            $notes += 'source already below the cap'
        }
    }

    # Video filters
    $filters = @()
    $ext = [System.IO.Path]::GetExtension($src).ToLower()
    $fo = $info.FieldOrder
    if (@('tt', 'bb', 'tb', 'bt') -contains $fo) {
        $filters += 'yadif=0:-1:0'
        $notes += 'deinterlaced'
    } elseif (([string]::IsNullOrEmpty($fo) -or $fo -eq 'unknown') -and ($InterlacedLikely -contains $ext)) {
        $filters += 'yadif=0:-1:1'
        $notes += 'deinterlace if needed'
    }
    if ($info.Width -gt 2560 -or $info.Height -gt 2560) {
        if ($info.Width -ge $info.Height) { $filters += 'scale=1920:-2' } else { $filters += 'scale=-2:1920' }
        $notes += 'scaled down to 1080p'
    }

    $gop = 60
    if ($info.Fps -gt 0) { $gop = [Math]::Max(12, [int][Math]::Round($info.Fps * 2)) }

    $a = @('-y', '-hide_banner', '-loglevel', 'error', '-nostdin', '-fflags', '+genpts', '-i', (Quote-Arg $src), '-map', '0:v:0')

    $audioCopy = $false
    if ($info.AudioCodec) {
        $a += @('-map', '0:a:0')
        if ($info.AudioCodec -eq 'aac' -and -not $forceAudioEncode) {
            $a += @('-c:a', 'copy')
            $audioCopy = $true
            $audioText = 'audio copied (AAC)'
        } else {
            $a += @('-c:a', 'aac', '-b:a', '192k')
            if ($info.Channels -gt 2) { $a += @('-ac', '2') }
            $audioText = 'audio to AAC 192k'
        }
    } else {
        $a += '-an'
        $audioText = 'no audio'
    }

    $a += @('-c:v', 'libx264', '-preset', $preset, '-profile:v', 'high', '-pix_fmt', 'yuv420p',
        '-b:v', "${target}k", '-maxrate', "${target}k", '-bufsize', ('{0}k' -f ($target * 2)),
        '-g', "$gop", '-flags', '+cgop')
    if ($filters.Count -gt 0) { $a += @('-vf', (Quote-Arg ($filters -join ','))) }
    $a += @('-movflags', '+faststart', '-max_muxing_queue_size', '1024', '-progress', 'pipe:1', '-nostats', (Quote-Arg $dst))

    $summary = '{0}x{1}, {2} kbps max, {3}' -f $info.Width, $info.Height, $target, $audioText
    if ($notes.Count -gt 0) { $summary += ' (' + ($notes -join ', ') + ')' }

    return [pscustomobject]@{
        Args      = ($a -join ' ')
        AudioCopy = $audioCopy
        Summary   = $summary
    }
}

function Get-UniqueOutput([string]$folder, [string]$base) {
    $p = Join-Path $folder ($base + '.mp4')
    $n = 1
    while (Test-Path -LiteralPath $p) {
        $p = Join-Path $folder ("$base ($n).mp4")
        $n++
    }
    return $p
}

# Runs ffmpeg and keeps the window responsive while it works
function Invoke-Ffmpeg([string]$argLine, [double]$duration, $item) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:ffmpeg
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = [System.Diagnostics.Process]::Start($psi)
    $script:proc = $proc
    try { $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } catch { }

    if ($duration -le 0) { $barFile.Style = 'Marquee' } else { $barFile.Style = 'Continuous' }

    $outTask = $proc.StandardOutput.ReadLineAsync()
    $errTask = $proc.StandardError.ReadLineAsync()
    $outEof = $false
    $errEof = $false
    $errLines = New-Object 'System.Collections.Generic.List[string]'
    $curSec = 0.0
    $speed = ''
    $cancelled = $false
    $name = $item.Text

    while (-not $proc.HasExited -or -not $outEof -or -not $errEof) {
        while (-not $outEof -and $outTask.IsCompleted) {
            $line = $outTask.Result
            if ($null -eq $line) { $outEof = $true; break }
            if ($line -like 'out_time_us=*') { $curSec = (ConvertTo-Num $line.Substring(12)) / 1000000.0 }
            elseif ($line -like 'out_time_ms=*') { $curSec = (ConvertTo-Num $line.Substring(12)) / 1000000.0 }
            elseif ($line -like 'speed=*') { $speed = $line.Substring(6).Trim() }
            $outTask = $proc.StandardOutput.ReadLineAsync()
        }
        while (-not $errEof -and $errTask.IsCompleted) {
            $line = $errTask.Result
            if ($null -eq $line) { $errEof = $true; break }
            if ($line.Trim()) {
                $errLines.Add($line)
                if ($errLines.Count -gt 6) { $errLines.RemoveAt(0) }
            }
            $errTask = $proc.StandardError.ReadLineAsync()
        }

        if ($script:cancel -and -not $cancelled -and -not $proc.HasExited) {
            $cancelled = $true
            try { $proc.Kill() } catch { }
        }

        # Update the screen
        $pct = 0.0
        if ($duration -gt 0) { $pct = [Math]::Min(100.0, [Math]::Max(0.0, $curSec / $duration * 100.0)) }
        $text = $name
        if ($duration -gt 0) {
            $barFile.Value = [int]($pct * 10)
            $item.SubItems[2].Text = ('Converting {0:N0}%' -f $pct)
            $text += ('  -  {0:N0}%' -f $pct)
            if ($pct -gt 2 -and $watch.Elapsed.TotalSeconds -gt 5) {
                $text += '  -  about ' + (Format-Eta ($watch.Elapsed.TotalSeconds * (100.0 - $pct) / $pct)) + ' left'
            }
        }
        if ($speed -and $speed -ne 'N/A') { $text += "  -  speed $speed" }
        if (-not $cancelled) { $lblFile.Text = $text }
        $frac = (($script:idx - 1) + ($pct / 100.0)) / [Math]::Max(1, $script:total)
        $barAll.Value = [int][Math]::Min(1000, $frac * 1000)

        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }

    $proc.WaitForExit()
    $code = $proc.ExitCode
    $script:proc = $null
    $proc.Dispose()
    $barFile.Style = 'Continuous'

    return [pscustomobject]@{
        ExitCode  = $code
        Cancelled = $cancelled
        Errors    = ($errLines -join ' | ')
    }
}

# ---------------------------------------------------------------------
#  Batch conversion
# ---------------------------------------------------------------------
function Set-Running([bool]$on) {
    $script:running = $on
    foreach ($c in @($btnStart, $btnAddFiles, $btnAddFolder, $btnRemove, $btnClear, $btnOut, $numRate, $cmbQuality)) {
        $c.Enabled = -not $on
    }
    $btnCancel.Enabled = $on
}

function Run-Batch([string]$outDir) {
    $script:cancel = $false
    Set-Running $true

    $rate = [int]$numRate.Value
    $preset = $PresetNames[$cmbQuality.SelectedIndex]
    $items = @($lv.Items | Where-Object { $_.SubItems[2].Text -notlike 'Done*' })
    $total = $items.Count
    $script:total = $total
    $ok = 0
    $failed = @()
    $idx = 0
    $barAll.Value = 0
    $barFile.Value = 0

    foreach ($item in $items) {
        if ($script:cancel) { continue }
        $idx++
        $script:idx = $idx
        $src = [string]$item.Tag
        $item.SubItems[2].Text = 'Starting...'
        $item.EnsureVisible()
        $lblOverall.Text = "Video $idx of $total"
        $lblFile.Text = 'Preparing: ' + $item.Text
        $barFile.Value = 0
        $part = $null

        try {
            $info = Get-VideoInfo $src
            $base = [System.IO.Path]::GetFileNameWithoutExtension($src)
            $final = Get-UniqueOutput $outDir $base
            $part = $final.Substring(0, $final.Length - 4) + '.part.mp4'

            $plan = New-FfmpegPlan $src $part $info $rate $preset $false
            Write-Log ("[{0}/{1}] {2}: {3}" -f $idx, $total, $item.Text, $plan.Summary)
            $res = Invoke-Ffmpeg $plan.Args $info.Duration $item

            if (-not $res.Cancelled -and $res.ExitCode -ne 0 -and $plan.AudioCopy) {
                Write-Log '    Audio copy did not work, trying again with audio re-encoded...'
                Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
                $plan = New-FfmpegPlan $src $part $info $rate $preset $true
                $res = Invoke-Ffmpeg $plan.Args $info.Duration $item
            }

            if ($res.Cancelled) {
                Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
                $item.SubItems[2].Text = 'Cancelled'
                Write-Log '    Cancelled.'
            } elseif ($res.ExitCode -eq 0 -and (Test-Path -LiteralPath $part)) {
                Move-Item -LiteralPath $part -Destination $final -Force
                $size = (Get-Item -LiteralPath $final).Length
                $item.SubItems[2].Text = 'Done (' + (Format-Size $size) + ')'
                $ok++
                Write-Log ('    Done: ' + [System.IO.Path]::GetFileName($final))
            } else {
                Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
                $item.SubItems[2].Text = 'FAILED'
                $failed += $item.Text
                Write-Log ('    FAILED: ' + $res.Errors)
            }
        } catch {
            if ($part) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
            $item.SubItems[2].Text = 'FAILED'
            $failed += $item.Text
            Write-Log ('    FAILED: ' + $_.Exception.Message)
        }
        $barAll.Value = [int][Math]::Min(1000, ($idx / [Math]::Max(1, $total)) * 1000)
    }

    $wasCancelled = $script:cancel
    Set-Running $false
    $barFile.Value = 0
    $lblFile.Text = 'Ready'

    if ($script:exitAfter) { $form.Close(); return }

    if ($wasCancelled) {
        $lblOverall.Text = 'Stopped'
        Show-Msg "Stopped. $ok video(s) were finished before you cancelled." 'Information'
        return
    }
    if ($total -eq 0) {
        $lblOverall.Text = 'Nothing to do'
        Show-Msg 'There is nothing left to convert - every video in the list is already done.'
        return
    }

    $barAll.Value = 1000
    $lblOverall.Text = 'All finished'
    $msg = "$ok of $total video(s) converted."
    if ($failed.Count -gt 0) {
        $msg += "`n`nThese could not be converted (see the box at the bottom for details):`n" + ($failed -join "`n")
    }
    if ($ok -gt 0) {
        $msg += "`n`nOpen the folder with the converted videos?"
        $r = [System.Windows.Forms.MessageBox]::Show($msg, $AppName, 'YesNo', 'Information')
        if ($r -eq 'Yes') { Start-Process -FilePath $outDir }
    } else {
        Show-Msg $msg 'Warning'
    }
}

# ---------------------------------------------------------------------
#  Adding files to the list
# ---------------------------------------------------------------------
function Add-Paths($paths, [bool]$filter) {
    $files = New-Object 'System.Collections.Generic.List[string]'
    foreach ($p in $paths) {
        if (-not $p) { continue }
        if (Test-Path -LiteralPath $p -PathType Container) {
            Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $VideoExtensions -contains $_.Extension.ToLower() } |
                ForEach-Object { $files.Add($_.FullName) }
        } elseif (Test-Path -LiteralPath $p -PathType Leaf) {
            $e = [System.IO.Path]::GetExtension($p).ToLower()
            if (-not $filter -or ($VideoExtensions -contains $e)) { $files.Add($p) }
        }
    }
    $lv.BeginUpdate()
    foreach ($f in $files) {
        $key = $f.ToLower()
        if ($script:added.ContainsKey($key)) { continue }
        $script:added[$key] = $true
        $len = 0
        try { $len = (Get-Item -LiteralPath $f).Length } catch { }
        $item = New-Object System.Windows.Forms.ListViewItem([System.IO.Path]::GetFileName($f))
        [void]$item.SubItems.Add((Format-Size $len))
        [void]$item.SubItems.Add('Waiting')
        $item.Tag = $f
        [void]$lv.Items.Add($item)
    }
    $lv.EndUpdate()
}

# ---------------------------------------------------------------------
#  Window
# ---------------------------------------------------------------------
function New-Ctl([string]$type, [string]$text, [int]$x, [int]$y, [int]$w, [int]$h) {
    $c = New-Object $type
    $c.Text = $text
    $c.Location = [System.Drawing.Point]::new($x, $y)
    $c.Size = [System.Drawing.Size]::new($w, $h)
    return $c
}

try {
    $settings = Load-Settings
    $fontNormal = New-Object System.Drawing.Font('Segoe UI', 10)
    $fontBold = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $fontBig = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $AppName
    $form.StartPosition = 'CenterScreen'
    $form.ClientSize = [System.Drawing.Size]::new(780, 650)
    $form.MinimumSize = [System.Drawing.Size]::new(796, 640)
    $form.Font = $fontNormal
    $form.AllowDrop = $true

    $lblTitle = New-Ctl 'System.Windows.Forms.Label' 'Video Converter  -  makes any video ready for YouTube' 15 8 750 28
    $lblTitle.Font = $fontBig

    $lblStep1 = New-Ctl 'System.Windows.Forms.Label' '1.  Pick your videos (or drag and drop them into the list below)' 15 42 750 22
    $lblStep1.Font = $fontBold

    $btnAddFiles = New-Ctl 'System.Windows.Forms.Button' 'Add videos...' 15 66 150 32
    $btnAddFolder = New-Ctl 'System.Windows.Forms.Button' 'Add a folder...' 175 66 150 32
    $btnRemove = New-Ctl 'System.Windows.Forms.Button' 'Remove selected' 335 66 150 32
    $btnClear = New-Ctl 'System.Windows.Forms.Button' 'Clear list' 495 66 120 32

    $lv = New-Ctl 'System.Windows.Forms.ListView' '' 15 104 750 170
    $lv.View = 'Details'
    $lv.FullRowSelect = $true
    $lv.HideSelection = $false
    $lv.AllowDrop = $true
    $lv.Anchor = [System.Windows.Forms.AnchorStyles]'Top,Bottom,Left,Right'
    [void]$lv.Columns.Add('Video', 430)
    [void]$lv.Columns.Add('Size', 90)
    [void]$lv.Columns.Add('Status', 200)

    $lblStep2 = New-Ctl 'System.Windows.Forms.Label' '2.  Save the converted videos in this folder:' 15 284 750 22
    $lblStep2.Font = $fontBold
    $txtOut = New-Ctl 'System.Windows.Forms.TextBox' $settings.OutputFolder 15 308 640 26
    $txtOut.ReadOnly = $true
    $btnOut = New-Ctl 'System.Windows.Forms.Button' 'Change...' 665 305 100 30

    $lblStep3 = New-Ctl 'System.Windows.Forms.Label' '3.  Options (you can leave these as they are)' 15 346 750 22
    $lblStep3.Font = $fontBold
    $lblRate = New-Ctl 'System.Windows.Forms.Label' 'Max bitrate:' 15 377 90 24
    $numRate = New-Ctl 'System.Windows.Forms.NumericUpDown' '' 105 374 70 26
    $numRate.Minimum = 100
    $numRate.Maximum = 2000
    $numRate.Increment = 50
    $numRate.Value = [Math]::Min(2000, [Math]::Max(100, [int]$settings.BitrateKBps))
    $lblRateInfo = New-Ctl 'System.Windows.Forms.Label' '' 180 377 220 24
    $lblQ = New-Ctl 'System.Windows.Forms.Label' 'Speed:' 410 377 55 24
    $cmbQuality = New-Ctl 'System.Windows.Forms.ComboBox' '' 465 374 300 26
    $cmbQuality.DropDownStyle = 'DropDownList'
    [void]$cmbQuality.Items.Add('Fast  (quickest, a little less quality)')
    [void]$cmbQuality.Items.Add('Balanced  (recommended)')
    [void]$cmbQuality.Items.Add('Best quality  (slowest)')
    $cmbQuality.SelectedIndex = [Math]::Min(2, [Math]::Max(0, [int]$settings.Quality))

    $btnStart = New-Ctl 'System.Windows.Forms.Button' 'START CONVERTING' 15 412 330 48
    $btnStart.Font = $fontBig
    $btnStart.BackColor = [System.Drawing.Color]::FromArgb(46, 139, 87)
    $btnStart.ForeColor = [System.Drawing.Color]::White
    $btnStart.FlatStyle = 'Flat'
    $btnCancel = New-Ctl 'System.Windows.Forms.Button' 'Cancel' 355 412 130 48
    $btnCancel.Enabled = $false
    $btnOpen = New-Ctl 'System.Windows.Forms.Button' 'Open output folder' 495 412 270 48

    $lblFile = New-Ctl 'System.Windows.Forms.Label' 'Ready' 15 470 750 22
    $lblFile.AutoEllipsis = $true
    $barFile = New-Ctl 'System.Windows.Forms.ProgressBar' '' 15 494 750 20
    $barFile.Maximum = 1000
    $lblOverall = New-Ctl 'System.Windows.Forms.Label' 'Overall progress' 15 520 750 22
    $barAll = New-Ctl 'System.Windows.Forms.ProgressBar' '' 15 544 750 20
    $barAll.Maximum = 1000

    $txtLog = New-Ctl 'System.Windows.Forms.TextBox' '' 15 572 750 68
    $txtLog.Multiline = $true
    $txtLog.ReadOnly = $true
    $txtLog.ScrollBars = 'Vertical'
    $txtLog.BackColor = [System.Drawing.Color]::White
    $txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)

    $bl = [System.Windows.Forms.AnchorStyles]'Bottom,Left'
    $blr = [System.Windows.Forms.AnchorStyles]'Bottom,Left,Right'
    $br = [System.Windows.Forms.AnchorStyles]'Bottom,Right'
    foreach ($c in @($lblStep2, $lblStep3, $lblRate, $numRate, $lblRateInfo, $lblQ, $btnStart, $btnCancel)) { $c.Anchor = $bl }
    foreach ($c in @($txtOut, $lblFile, $barFile, $lblOverall, $barAll, $txtLog, $btnOpen, $cmbQuality)) { $c.Anchor = $blr }
    $btnOut.Anchor = $br
    $btnOpen.Anchor = $br
    $cmbQuality.Anchor = $br
    $lblQ.Anchor = $br

    $form.Controls.AddRange(@(
            $lblTitle, $lblStep1, $btnAddFiles, $btnAddFolder, $btnRemove, $btnClear, $lv,
            $lblStep2, $txtOut, $btnOut, $lblStep3, $lblRate, $numRate, $lblRateInfo, $lblQ, $cmbQuality,
            $btnStart, $btnCancel, $btnOpen, $lblFile, $barFile, $lblOverall, $barAll, $txtLog))

    # --- events ---
    $updateRateInfo = {
        $kbps = [int]$numRate.Value * 8
        $lblRateInfo.Text = "KBps  (= $kbps kbps)"
    }
    $numRate.Add_ValueChanged($updateRateInfo)
    & $updateRateInfo

    $btnAddFiles.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = 'Choose videos'
        $dlg.Multiselect = $true
        $pattern = (($VideoExtensions | ForEach-Object { '*' + $_ }) -join ';')
        $dlg.Filter = "Video files|$pattern|All files|*.*"
        if ($dlg.ShowDialog() -eq 'OK') { Add-Paths $dlg.FileNames $false }
    })

    $btnAddFolder.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Choose a folder - every video inside it will be added'
        if ($dlg.ShowDialog() -eq 'OK') { Add-Paths @($dlg.SelectedPath) $true }
    })

    $btnRemove.Add_Click({
        foreach ($it in @($lv.SelectedItems)) {
            $script:added.Remove(([string]$it.Tag).ToLower())
            $lv.Items.Remove($it)
        }
    })

    $btnClear.Add_Click({
        $lv.Items.Clear()
        $script:added = @{}
        $lblOverall.Text = 'Overall progress'
        $barAll.Value = 0
    })

    $btnOut.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Choose where the converted videos should be saved'
        $dlg.ShowNewFolderButton = $true
        if (Test-Path -LiteralPath $txtOut.Text) { $dlg.SelectedPath = $txtOut.Text }
        if ($dlg.ShowDialog() -eq 'OK') {
            $txtOut.Text = $dlg.SelectedPath
            Save-Settings
        }
    })

    $btnOpen.Add_Click({
        if (Test-Path -LiteralPath $txtOut.Text) { Start-Process -FilePath $txtOut.Text }
        else { Show-Msg 'That folder does not exist yet. It will be created when you convert something.' }
    })

    $btnCancel.Add_Click({
        $script:cancel = $true
        $btnCancel.Enabled = $false
        $lblFile.Text = 'Cancelling...'
    })

    $btnStart.Add_Click({
        if ($script:running) { return }
        if ($lv.Items.Count -eq 0) {
            Show-Msg ('Please add some videos first.' + "`n`n" + 'Use "Add videos..." or drag and drop files into the list.')
            return
        }
        if (-not (Ensure-Tools)) { return }
        $outDir = $txtOut.Text.Trim()
        if (-not $outDir) { Show-Msg 'Please choose a folder to save the converted videos in (step 2).'; return }
        try {
            if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
        } catch {
            Show-Msg ('Could not create the folder:' + "`n" + $outDir + "`n`nPlease choose another folder.") 'Warning'
            return
        }
        Save-Settings
        Run-Batch $outDir
    })

    $dragEnter = {
        if (-not $script:running -and $_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
            $_.Effect = [System.Windows.Forms.DragDropEffects]::Copy
        }
    }
    $dragDrop = {
        if ($script:running) { return }
        $dropped = $_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
        if ($dropped) { Add-Paths $dropped $true }
    }
    $form.Add_DragEnter($dragEnter)
    $form.Add_DragDrop($dragDrop)
    $lv.Add_DragEnter($dragEnter)
    $lv.Add_DragDrop($dragDrop)

    $form.Add_FormClosing({
        if ($script:running) {
            $r = [System.Windows.Forms.MessageBox]::Show('A conversion is still running. Stop it and close the program?', $AppName, 'YesNo', 'Question')
            if ($r -eq 'Yes') {
                $script:exitAfter = $true
                $script:cancel = $true
            }
            $_.Cancel = $true
        } else {
            Save-Settings
        }
    })

    $form.Add_Shown({
        [void](Ensure-Tools)
        if ($InputPaths) { Add-Paths $InputPaths $true }
    })

    [void]$form.ShowDialog()
} catch {
    [void][System.Windows.Forms.MessageBox]::Show(('Something went wrong:' + "`n`n" + $_.Exception.Message), $AppName, 'OK', 'Error')
}
