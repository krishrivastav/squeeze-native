param([Parameter(ValueFromRemainingArguments = $true)][string[]]$InputPaths)

# =====================================================================
#  Video Converter  -  converts any video to YouTube-ready MP4 (H.264)
#  Max video bitrate default: 750 KBps (= 6000 kbps)
#  Needs FFmpeg (winget install "FFmpeg (Essentials Build)")
# =====================================================================

# ---- Update checker settings (EDIT THESE) ---------------------------
# The program looks at VideoConverter.ps1 in your GitHub repo and compares
# the $AppVersion line below with the one in the repo.
# To publish an update: raise $AppVersion, then upload the file to GitHub.
$AppVersion = '1.1.0'
$UpdateRepo = 'YOUR-GITHUB-USERNAME/YOUR-REPO'   # example: 'johndoe/video-converter'
$UpdateBranch = 'main'
$UpdateFile = 'VideoConverter.ps1'
# ---------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$AppName = 'video_convert'
$VideoExtensions = @(
    '.mts', '.m2ts', '.ts', '.tod', '.mod', '.trp', '.tp', '.mxf', '.vob', '.vro',
    '.mp4', '.m4v', '.mov', '.qt', '.mkv', '.avi', '.wmv', '.asf', '.flv', '.f4v',
    '.webm', '.mpg', '.mpeg', '.m2v', '.3gp', '.3g2', '.ogv', '.divx', '.dv', '.rm', '.rmvb', '.wtv'
)
$InterlacedLikely = @('.mts', '.m2ts', '.ts', '.tod', '.mod', '.trp', '.tp', '.mpg', '.mpeg', '.m2v', '.vob', '.vro', '.mxf', '.dv')
$PresetNames = @('veryfast', 'faster', 'medium')   # Fast, Balanced, Best quality
# Resolution choices: 0 = automatic, -1 = keep original, otherwise the "p" value
$ResValues = @(0, -1, 2160, 1440, 1080, 720, 480, 360)

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
        Resolution   = 0
        SizeValue    = 100
        SizeUnit     = 0
    }
    try {
        if (Test-Path -LiteralPath $SettingsFile) {
            $j = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
            if ($j.OutputFolder) { $s.OutputFolder = [string]$j.OutputFolder }
            if ($j.BitrateKBps) { $s.BitrateKBps = [int]$j.BitrateKBps }
            if ($null -ne $j.Quality) { $s.Quality = [int]$j.Quality }
            if ($null -ne $j.Resolution) { $s.Resolution = [int]$j.Resolution }
            if ($j.SizeValue) { $s.SizeValue = [double]$j.SizeValue }
            if ($null -ne $j.SizeUnit) { $s.SizeUnit = [int]$j.SizeUnit }
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
            Resolution   = $cmbRes.SelectedIndex
            SizeValue    = [double]$numSize.Value
            SizeUnit     = $cmbUnit.SelectedIndex
        } | ConvertTo-Json | Set-Content -LiteralPath $SettingsFile -Encoding UTF8
    } catch { }
}

function Write-Log([string]$msg) {
    $txtLog.AppendText($msg + [Environment]::NewLine)
}

# ---------------------------------------------------------------------
#  Update checker (reads VideoConverter.ps1 from your GitHub repo)
# ---------------------------------------------------------------------
function Install-Update([string]$text, $remote) {
    $self = $PSCommandPath
    if (-not $self -or -not (Test-Path -LiteralPath $self)) {
        Show-Msg 'The update could not be installed because the program file was not found.' 'Warning'
        return
    }
    if ($text.Length -lt 5000 -or $text -notmatch 'System\.Windows\.Forms') {
        Show-Msg 'The downloaded file does not look right, so the update was cancelled.' 'Warning'
        return
    }
    $backup = $self + '.bak'
    try {
        Copy-Item -LiteralPath $self -Destination $backup -Force
        [System.IO.File]::WriteAllText($self, $text, (New-Object System.Text.UTF8Encoding($true)))
    } catch {
        try { if (Test-Path -LiteralPath $backup) { Copy-Item -LiteralPath $backup -Destination $self -Force } } catch { }
        Show-Msg ('The update could not be installed:' + "`n`n" + $_.Exception.Message) 'Warning'
        return
    }
    Show-Msg "Updated to version $remote. The program will now restart."
    Save-Settings
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', (Quote-Arg $self))
    $script:exitAfter = $true
    $form.Close()
}

function Check-ForUpdate([bool]$silent) {
    if ($UpdateRepo -like 'YOUR-*') {
        if (-not $silent) {
            Show-Msg 'The update checker is not set up yet. Open VideoConverter.ps1 in Notepad and fill in the GitHub details at the top of the file.'
        }
        return
    }
    if ($script:running) { return }
    $oldText = $lblFile.Text
    $lblFile.Text = 'Checking for updates...'
    [System.Windows.Forms.Application]::DoEvents()
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $url = "https://raw.githubusercontent.com/$UpdateRepo/$UpdateBranch/$UpdateFile"
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 6
        $text = $resp.Content
        if ($text -is [byte[]]) { $text = [System.Text.Encoding]::UTF8.GetString($text) }
        $text = [string]$text
        $m = [regex]::Match($text, '\$AppVersion\s*=\s*''([0-9][0-9.]*)''')
        if (-not $m.Success) { throw 'The version number could not be read from GitHub.' }
        $remote = [version]$m.Groups[1].Value
        $local = [version]$AppVersion
        if ($remote -gt $local) {
            $r = [System.Windows.Forms.MessageBox]::Show("A new version ($remote) is available. You have version $local.`n`nUpdate now?", $AppName, 'YesNo', 'Question')
            if ($r -eq 'Yes') { Install-Update $text $remote }
        } elseif (-not $silent) {
            Show-Msg "You already have the newest version ($AppVersion)."
        }
    } catch {
        if (-not $silent) {
            Show-Msg ('Could not check for updates.' + "`n`n" + 'Please check the internet connection and try again.' + "`n`n" + $_.Exception.Message) 'Warning'
        }
    } finally {
        if (-not $script:running -and -not $script:exitAfter) { $lblFile.Text = $oldText }
    }
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
        AudioKbps  = $(if ($au) { [int]((ConvertTo-Num $au.bit_rate) / 1000) } else { 0 })
        Channels   = $(if ($au) { [int](ConvertTo-Num $au.channels) } else { 0 })
        Duration   = (ConvertTo-Num $info.format.duration)
    }
}

function New-FfmpegPlan([string]$src, [string]$dst, $info, $opt, [bool]$forceAudioEncode = $false) {
    $cap = [int]$opt.RateKBps * 8
    $target = $cap
    $notes = @()
    $short = [Math]::Min($info.Width, $info.Height)

    # 1. Audio: copy AAC as it is, convert anything else
    $audioMode = 'none'
    $audioKbps = 0
    $audioRate = 192
    if ($info.AudioCodec) {
        if ($info.AudioCodec -eq 'aac' -and -not $forceAudioEncode) {
            $audioMode = 'copy'
            $audioKbps = $info.AudioKbps
            if ($audioKbps -le 0) { $audioKbps = 160 }
        } else {
            $audioMode = 'encode'
            $audioKbps = 192
        }
    }

    # 2. Video bitrate: never pad a low-bitrate source up to the cap
    if ($info.VideoKbps -gt 0) {
        $want = [int]($info.VideoKbps * 1.25)
        if ($want -lt $cap) {
            $target = [Math]::Min($cap, [Math]::Max($want, 800))
            $notes += 'source already below the cap'
        }
    }

    # 3. Output resolution
    $scaleTo = 0
    $resH = [int]$opt.ResHeight
    if ($resH -gt 0) {
        if ($short -gt $resH) {
            $scaleTo = $resH
            $f = $resH / $short
            $target = [Math]::Min($target, [Math]::Max(600, [int]($target * $f * $f)))
            $notes += "resized to ${resH}p, bitrate lowered to match"
        } else {
            $notes += 'already smaller than the chosen resolution, size kept'
        }
    } elseif ($resH -eq 0) {
        if ($info.Width -gt 2560 -or $info.Height -gt 2560) {
            $scaleTo = 1080
            $notes += 'shrunk to 1080p'
        }
    }

    # 4. Wanted file size (applies to each video)
    if ([double]$opt.SizeMB -gt 0) {
        if ($info.Duration -gt 0) {
            $totalKbps = ([double]$opt.SizeMB * 8388.608 * 0.95) / $info.Duration
            if ($totalKbps -lt 1000 -and $audioMode -ne 'none' -and $audioKbps -gt 96) {
                $audioMode = 'encode'
                $audioKbps = 96
                $audioRate = 96
                $notes += 'audio lowered to 96k to save space'
            }
            $vidKbps = [int]($totalKbps - $audioKbps)
            if ($vidKbps -lt 100) {
                $vidKbps = 100
                $notes += 'wanted size is too small for this video, so quality will be low and the file may be bigger than asked'
            } elseif ($vidKbps -gt $target) {
                $notes += 'file will be smaller than asked, more would not improve it'
            }
            $target = [Math]::Min($target, $vidKbps)
            $notes += ('aiming for about ' + (Format-Size ([long]([double]$opt.SizeMB * 1MB))))
        } else {
            $notes += 'video length unknown, so the size could not be targeted'
        }
    }

    # 5. Video filters
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
    if ($scaleTo -gt 0) {
        # Works for landscape and portrait: the shorter side becomes the chosen value, never enlarges
        $filters += ("scale=w='trunc(iw*min(1,{0}/min(iw,ih))/2)*2':h='trunc(ih*min(1,{0}/min(iw,ih))/2)*2'" -f $scaleTo)
    }

    $gop = 60
    if ($info.Fps -gt 0) { $gop = [Math]::Max(12, [int][Math]::Round($info.Fps * 2)) }

    # 6. Build the command line
    $a = @('-y', '-hide_banner', '-loglevel', 'error', '-nostdin', '-fflags', '+genpts', '-i', (Quote-Arg $src), '-map', '0:v:0')

    if ($audioMode -eq 'copy') {
        $a += @('-map', '0:a:0', '-c:a', 'copy')
        $audioText = 'audio copied (AAC)'
    } elseif ($audioMode -eq 'encode') {
        $a += @('-map', '0:a:0', '-c:a', 'aac', '-b:a', "${audioRate}k")
        if ($info.Channels -gt 2) { $a += @('-ac', '2') }
        $audioText = "audio to AAC ${audioRate}k"
    } else {
        $a += '-an'
        $audioText = 'no audio'
    }

    $a += @('-c:v', 'libx264', '-preset', $opt.Preset, '-profile:v', 'high', '-pix_fmt', 'yuv420p',
        '-b:v', "${target}k", '-maxrate', "${target}k", '-bufsize', ('{0}k' -f ($target * 2)),
        '-g', "$gop", '-flags', '+cgop')
    if ($filters.Count -gt 0) { $a += @('-vf', (Quote-Arg ($filters -join ','))) }
    $a += @('-movflags', '+faststart', '-max_muxing_queue_size', '1024', '-progress', 'pipe:1', '-nostats', (Quote-Arg $dst))

    $summary = '{0}x{1}, {2} kbps max, {3}' -f $info.Width, $info.Height, $target, $audioText
    if ($notes.Count -gt 0) { $summary += ' (' + ($notes -join '; ') + ')' }

    return [pscustomobject]@{
        Args      = ($a -join ' ')
        AudioCopy = ($audioMode -eq 'copy')
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
function Update-SizeControls {
    $on = ($chkSize.Checked -and -not $script:running)
    $numSize.Enabled = $on
    $cmbUnit.Enabled = $on
}

function Set-Running([bool]$on) {
    $script:running = $on
    foreach ($c in @($btnStart, $btnAddFiles, $btnAddFolder, $btnRemove, $btnClear, $btnOut, $numRate, $cmbQuality, $cmbRes, $chkSize, $btnUpdate)) {
        $c.Enabled = -not $on
    }
    $btnCancel.Enabled = $on
    Update-SizeControls
}

function Run-Batch([string]$outDir) {
    $script:cancel = $false
    Set-Running $true

    $sizeMB = 0.0
    if ($chkSize.Checked) {
        $sizeMB = [double]$numSize.Value
        if ($cmbUnit.SelectedIndex -eq 1) { $sizeMB = $sizeMB * 1024 }
    }
    $opt = [pscustomobject]@{
        RateKBps  = [int]$numRate.Value
        Preset    = $PresetNames[$cmbQuality.SelectedIndex]
        ResHeight = $ResValues[$cmbRes.SelectedIndex]
        SizeMB    = $sizeMB
    }

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

            $plan = New-FfmpegPlan $src $part $info $opt $false
            Write-Log ("[{0}/{1}] {2}: {3}" -f $idx, $total, $item.Text, $plan.Summary)
            $res = Invoke-Ffmpeg $plan.Args $info.Duration $item

            if (-not $res.Cancelled -and $res.ExitCode -ne 0 -and $plan.AudioCopy) {
                Write-Log '    Audio copy did not work, trying again with audio re-encoded...'
                Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
                $plan = New-FfmpegPlan $src $part $info $opt $true
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
                Write-Log ('    Done: ' + [System.IO.Path]::GetFileName($final) + '  (' + (Format-Size $size) + ')')
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
    $fontSmall = New-Object System.Drawing.Font('Segoe UI', 8.5)
    $grey = [System.Drawing.Color]::FromArgb(100, 100, 100)

    # Vertical layout: the list shrinks on small screens so everything fits
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $yL = 102
    $listH = [Math]::Max(60, [Math]::Min(170, $wa.Height - 50 - 540))
    $y2 = $yL + $listH + 10      # step 2 label
    $y3 = $y2 + 64              # step 3 label
    $yA = $y3 + 28              # bitrate / speed row
    $yB = $yA + 34              # resolution row
    $yC = $yB + 34              # file size row
    $yS = $yC + 40              # start button
    $yF = $yS + 58              # current file label
    $yFB = $yF + 24             # current file bar
    $yO = $yFB + 26             # overall label
    $yOB = $yO + 24             # overall bar
    $yLog = $yOB + 30           # log box
    $clientH = $yLog + 56 + 10

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$AppName v$AppVersion"
    $form.StartPosition = 'CenterScreen'
    $form.ClientSize = [System.Drawing.Size]::new(780, $clientH)
    $form.MinimumSize = [System.Drawing.Size]::new($form.Width, ($form.Height - ($listH - 60)))
    $form.Font = $fontNormal
    $form.AllowDrop = $true

    $lblTitle = New-Ctl 'System.Windows.Forms.Label' 'VC Native' 15 8 610 28
    $lblTitle.Font = $fontBig
    $btnUpdate = New-Ctl 'System.Windows.Forms.Button' 'Check for updates' 635 8 130 28
    $btnUpdate.Font = $fontSmall
    $btnUpdate.Anchor = [System.Windows.Forms.AnchorStyles]'Top,Right'

    $lblStep1 = New-Ctl 'System.Windows.Forms.Label' '1.  Pick your videos (or drag and drop them into the list below)' 15 42 750 22
    $lblStep1.Font = $fontBold

    $btnAddFiles = New-Ctl 'System.Windows.Forms.Button' 'Add videos...' 15 66 150 32
    $btnAddFolder = New-Ctl 'System.Windows.Forms.Button' 'Add a folder...' 175 66 150 32
    $btnRemove = New-Ctl 'System.Windows.Forms.Button' 'Remove selected' 335 66 150 32
    $btnClear = New-Ctl 'System.Windows.Forms.Button' 'Clear list' 495 66 120 32

    $lv = New-Ctl 'System.Windows.Forms.ListView' '' 15 $yL 750 $listH
    $lv.View = 'Details'
    $lv.FullRowSelect = $true
    $lv.HideSelection = $false
    $lv.AllowDrop = $true
    $lv.Anchor = [System.Windows.Forms.AnchorStyles]'Top,Bottom,Left,Right'
    [void]$lv.Columns.Add('Video', 430)
    [void]$lv.Columns.Add('Size', 90)
    [void]$lv.Columns.Add('Status', 200)

    $lblStep2 = New-Ctl 'System.Windows.Forms.Label' '2.  Save the converted videos in this folder:' 15 $y2 750 22
    $lblStep2.Font = $fontBold
    $txtOut = New-Ctl 'System.Windows.Forms.TextBox' $settings.OutputFolder 15 ($y2 + 24) 640 26
    $txtOut.ReadOnly = $true
    $btnOut = New-Ctl 'System.Windows.Forms.Button' 'Change...' 665 ($y2 + 21) 100 30

    $lblStep3 = New-Ctl 'System.Windows.Forms.Label' '3.  Options (you can leave these as they are)' 15 $y3 750 22
    $lblStep3.Font = $fontBold

    # Row A: max bitrate + speed
    $lblRate = New-Ctl 'System.Windows.Forms.Label' 'Max bitrate:' 15 ($yA + 3) 90 24
    $numRate = New-Ctl 'System.Windows.Forms.NumericUpDown' '' 105 $yA 70 26
    $numRate.Minimum = 100
    $numRate.Maximum = 2000
    $numRate.Increment = 50
    $numRate.Value = [Math]::Min(2000, [Math]::Max(100, [int]$settings.BitrateKBps))
    $lblKBps = New-Ctl 'System.Windows.Forms.Label' 'KBps' 180 ($yA + 3) 50 24
    $lblQ = New-Ctl 'System.Windows.Forms.Label' 'Speed:' 410 ($yA + 3) 55 24
    $cmbQuality = New-Ctl 'System.Windows.Forms.ComboBox' '' 465 $yA 300 26
    $cmbQuality.DropDownStyle = 'DropDownList'
    [void]$cmbQuality.Items.Add('Fast  (quickest, a little less quality)')
    [void]$cmbQuality.Items.Add('Balanced  (recommended)')
    [void]$cmbQuality.Items.Add('Best quality  (slowest)')
    $cmbQuality.SelectedIndex = [Math]::Min(2, [Math]::Max(0, [int]$settings.Quality))

    # Row B: resolution
    $lblRes = New-Ctl 'System.Windows.Forms.Label' 'Resolution:' 15 ($yB + 3) 90 24
    $cmbRes = New-Ctl 'System.Windows.Forms.ComboBox' '' 105 $yB 220 26
    $cmbRes.DropDownStyle = 'DropDownList'
    foreach ($t in @('Automatic  (recommended)', 'Keep original size', '2160p  (4K)', '1440p', '1080p  (Full HD)', '720p  (HD)', '480p', '360p')) { [void]$cmbRes.Items.Add($t) }
    $cmbRes.SelectedIndex = [Math]::Min($ResValues.Count - 1, [Math]::Max(0, [int]$settings.Resolution))
    $lblResHint = New-Ctl 'System.Windows.Forms.Label' 'Small videos are never enlarged.  Automatic only shrinks 4K to 1080p.' 335 ($yB + 5) 430 22
    $lblResHint.Font = $fontSmall
    $lblResHint.ForeColor = $grey

    # Row C: wanted file size
    $chkSize = New-Ctl 'System.Windows.Forms.CheckBox' 'Make every video about this size:' 15 ($yC + 2) 265 24
    $numSize = New-Ctl 'System.Windows.Forms.NumericUpDown' '' 285 $yC 95 26
    $numSize.DecimalPlaces = 1
    $numSize.Minimum = [decimal]0.1
    $numSize.Maximum = 100000
    $numSize.Increment = 10
    $numSize.Value = [decimal][Math]::Min(100000, [Math]::Max(0.1, [double]$settings.SizeValue))
    $cmbUnit = New-Ctl 'System.Windows.Forms.ComboBox' '' 385 $yC 60 26
    $cmbUnit.DropDownStyle = 'DropDownList'
    [void]$cmbUnit.Items.Add('MB')
    [void]$cmbUnit.Items.Add('GB')
    $cmbUnit.SelectedIndex = [Math]::Min(1, [Math]::Max(0, [int]$settings.SizeUnit))
    $lblSizeHint = New-Ctl 'System.Windows.Forms.Label' 'Approximate, applies to each video in the list.' 455 ($yC + 5) 310 22
    $lblSizeHint.Font = $fontSmall
    $lblSizeHint.ForeColor = $grey

    $btnStart = New-Ctl 'System.Windows.Forms.Button' 'START CONVERTING' 15 $yS 330 48
    $btnStart.Font = $fontBig
    $btnStart.BackColor = [System.Drawing.Color]::FromArgb(46, 139, 87)
    $btnStart.ForeColor = [System.Drawing.Color]::White
    $btnStart.FlatStyle = 'Flat'
    $btnCancel = New-Ctl 'System.Windows.Forms.Button' 'Cancel' 355 $yS 130 48
    $btnCancel.Enabled = $false
    $btnOpen = New-Ctl 'System.Windows.Forms.Button' 'Open output folder' 495 $yS 270 48

    $lblFile = New-Ctl 'System.Windows.Forms.Label' 'Ready' 15 $yF 750 22
    $lblFile.AutoEllipsis = $true
    $barFile = New-Ctl 'System.Windows.Forms.ProgressBar' '' 15 $yFB 750 20
    $barFile.Maximum = 1000
    $lblOverall = New-Ctl 'System.Windows.Forms.Label' 'Overall progress' 15 $yO 750 22
    $barAll = New-Ctl 'System.Windows.Forms.ProgressBar' '' 15 $yOB 750 20
    $barAll.Maximum = 1000

    $txtLog = New-Ctl 'System.Windows.Forms.TextBox' '' 15 $yLog 750 56
    $txtLog.Multiline = $true
    $txtLog.ReadOnly = $true
    $txtLog.ScrollBars = 'Vertical'
    $txtLog.BackColor = [System.Drawing.Color]::White
    $txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)

    $bl = [System.Windows.Forms.AnchorStyles]'Bottom,Left'
    $blr = [System.Windows.Forms.AnchorStyles]'Bottom,Left,Right'
    $br = [System.Windows.Forms.AnchorStyles]'Bottom,Right'
    foreach ($c in @($lblStep2, $lblStep3, $lblRate, $numRate, $lblKBps, $lblRes, $cmbRes, $lblResHint,
            $chkSize, $numSize, $cmbUnit, $lblSizeHint, $btnStart, $btnCancel)) { $c.Anchor = $bl }
    foreach ($c in @($txtOut, $lblFile, $barFile, $lblOverall, $barAll, $txtLog)) { $c.Anchor = $blr }
    foreach ($c in @($btnOut, $btnOpen, $cmbQuality, $lblQ)) { $c.Anchor = $br }

    $form.Controls.AddRange(@(
            $lblTitle, $btnUpdate, $lblStep1, $btnAddFiles, $btnAddFolder, $btnRemove, $btnClear, $lv,
            $lblStep2, $txtOut, $btnOut, $lblStep3,
            $lblRate, $numRate, $lblKBps, $lblQ, $cmbQuality,
            $lblRes, $cmbRes, $lblResHint,
            $chkSize, $numSize, $cmbUnit, $lblSizeHint,
            $btnStart, $btnCancel, $btnOpen, $lblFile, $barFile, $lblOverall, $barAll, $txtLog))

    Update-SizeControls

    # --- events ---
    $chkSize.Add_CheckedChanged({ Update-SizeControls })

    $btnUpdate.Add_Click({ Check-ForUpdate $false })

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
        Check-ForUpdate $true
    })

    [void]$form.ShowDialog()
} catch {
    [void][System.Windows.Forms.MessageBox]::Show(('Something went wrong:' + "`n`n" + $_.Exception.Message), $AppName, 'OK', 'Error')
}
