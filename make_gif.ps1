# EDC Pouch watch album packer: image/video -> GIF + base64 text.
#
# Requirements:
#   Static PNG/JPEG/BMP/TIFF images use a .NET/System.Drawing fallback and do
#   not require ffmpeg.exe. Video, animated GIF, and WebP input require ffmpeg.exe
#   with the paletteuse filter; dynamic palettes also require palettegen.
#   Put ffmpeg.exe in this script folder, or make it available in PATH, when
#   processing those formats.
#   ffprobe.exe is optional; with it the script can print exact output frame count.
#
# Examples:
#   .\make_gif.ps1 .\photo.jpg
#   .\make_gif.ps1 .\photo.jpg -MaxSizeKB 32 -Dim 240
#   .\make_gif.ps1 .\movie.mp4 -MaxSizeKB 48 -Dim 220 -Fps 10 -Colors 64 -FrameMs 100
#   .\make_gif.ps1 -MaxSizeKB 28 -Dim 180
#
# Behavior:
#   No trimming is done. Videos are sampled across the full source duration.
#   Selected video frames are kept; the script does not de-duplicate them.
#   Add -Dedupe to remove near-duplicate video frames after sampling but before
#   scaling. This can reduce long static sections, but it may reduce frame count.
#   Still images become a single-frame GIF; animated GIF/video inputs stay animated.
#   -MaxSizeKB is the only size cap. If it is set, omitted quality settings may
#   auto-degrade in this order: Fps, then Dim, then Colors.
#   If -Dim, -Fps, or -Colors is written, that value is fixed and will not be
#   changed by the auto-degrade search.
#   For video, -Fps >= 1 uses regular fps sampling. -Fps < 1 uses time buckets:
#   one frame per bucket, preferring keyframes/scene changes and falling back
#   near the middle of the bucket so the whole clip is represented.
#   -FrameMs is applied only after the final GIF is chosen; it changes playback
#   delay, not sampling, retry order, or size-search decisions.
#   Temporary folders are under %TEMP%\edc-photo-*. They are removed on success;
#   -KeepTemp preserves the current run's folder for inspection.
#   Static-image fallback supports common System.Drawing formats such as
#   PNG/JPEG/BMP/TIFF. WebP still needs ffmpeg on most Windows setups.
#
# Output:
#   input.ext -> input.gif
#             -> input.b64
#
# Notes for the Garmin app:
#   The watch album stores raw GIF bytes. The .b64 file must contain ONLY base64 text,
#   without data:image/gif;base64, prefix and without BEGIN/END wrapper lines.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Path,

    # Optional final .gif size limit in KB.
    [object]$MaxSizeKB = $null,

    # Optional longest output side limit.
    [object]$Dim = $null,

    # Optional target video sampling fps.
    [object]$Fps = $null,

    # Optional GIF palette size. 64 uses the fixed Garmin MIP RGB222 palette:
    # each RGB channel is 0/85/170/255.
    [object]$Colors = $null,

    # Optional fixed GIF playback delay per frame in milliseconds.
    [object]$FrameMs = $null,

    # Optional video duplicate-frame removal after sampling, before scaling.
    [switch]$Dedupe,

    [string]$Output,

    [switch]$KeepTemp,

    [switch]$Help
)

$ErrorActionPreference = "Stop"

function Show-Usage {
    $script = Split-Path -Leaf $PSCommandPath
    Write-Host ""
    Write-Host "EDC Pouch GIF/base64 packer" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  .\$script <input image/video> [optional limits]"
    Write-Host "  .\$script <video> -MaxSizeKB 48 -Dim 220 -Fps 10 -Colors 64 -FrameMs 100"
    Write-Host "  .\$script -Help"
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Yellow
    Write-Host "  .\$script .\photo.jpg"
    Write-Host "  .\$script .\movie.mp4"
    Write-Host "  .\$script .\photo.jpg -MaxSizeKB 32"
    Write-Host "  .\$script .\movie.mp4 -MaxSizeKB 48"
    Write-Host "  .\$script .\movie.mp4 -MaxSizeKB 48 -Dim 180"
    Write-Host "  .\$script -MaxSizeKB 28 -Dim 180"
    Write-Host ""
    Write-Host "Garmin watch-friendly full example:" -ForegroundColor Yellow
    Write-Host "  .\$script .\movie.mp4 -Output .\watch.gif -MaxSizeKB 50 -Dim 240 -Fps 10 -Colors 64 -FrameMs 100"
    Write-Host "  # input file: source image/video; put it first so PowerShell binds it to Path."
    Write-Host "  # -Output .\watch.gif: writes watch.gif and watch.b64 together."
    Write-Host "  # -MaxSizeKB 50: limits GIF bytes for watch storage, decoding time, and URL import."
    Write-Host "  # Omit -Dim/-Fps/-Colors when the script may freely degrade them to fit -MaxSizeKB."
    Write-Host "  # Provide -Dim/-Fps/-Colors only when that value must stay fixed."
    Write-Host "  # Sparse video sampling is spread across the whole clip; each time bucket prefers keyframes/scene changes."
    Write-Host "  # -Colors 64: uses the fixed Garmin MIP RGB222 palette, not a random GIF palette."
    Write-Host "  # -FrameMs 100: after sampling is finished, writes every animated GIF frame delay as 100ms."
    Write-Host "  # -Dedupe: optional; removes near-duplicate frames after sampling, before resizing."
    Write-Host "  # -KeepTemp: optional debug flag; add only when you want to inspect trial GIFs."
    Write-Host "  # Omitted quality settings may auto-degrade when -MaxSizeKB is set."
    Write-Host "  # Auto-degrade order is fps, then dimensions, then colors."
    Write-Host ""
    Write-Host "Parameters:" -ForegroundColor Yellow
    Write-Host "  All limits are opt-in. If you omit video limits, the script converts the full clip."
    Write-Host "  -MaxSizeKB   Optional final GIF size limit in KB. Omitted: no size limit"
    Write-Host "  -Dim         Optional fixed longest-side value. Omitted with -MaxSizeKB: auto 240 down to 4"
    Write-Host "  -Fps         Optional fixed sampling fps; decimals are allowed. Below 1 samples sparsely but plays at 1fps"
    Write-Host "  -Colors      Optional fixed GIF palette value. Omitted with -MaxSizeKB: auto 64 down to 2"
    Write-Host "  -FrameMs     Optional fixed animated GIF frame delay in ms, e.g. 100 means 10fps playback"
    Write-Host "  -Dedupe      Optional video/animated-GIF near-duplicate frame removal after sampling"
    Write-Host "  -Output      Optional output .gif path. .b64 is written next to it"
    Write-Host "  -KeepTemp    Keep temporary trial GIFs for inspection"
    Write-Host ""
    Write-Host "Rules:" -ForegroundColor Yellow
    Write-Host "  Full duration is preserved; cut the video yourself before running this script."
    Write-Host "  Written -Dim/-Fps/-Colors values are fixed. Omitted ones may be auto-degraded with -MaxSizeKB."
    Write-Host "  -FrameMs is applied after the final GIF is selected, so it does not affect frame selection."
    Write-Host "  -Dedupe is off by default. If enabled, it may reduce frame count in static sections."
    Write-Host "  -Fps < 1 samples sparse time buckets across the whole clip."
    Write-Host ""
    Write-Host "Requirements:" -ForegroundColor Yellow
    Write-Host "  Static PNG/JPEG/BMP/TIFF images use .NET and do not need ffmpeg.exe."
    Write-Host "  Put a full ffmpeg.exe build next to this script for video/animated GIF/WebP input."
    Write-Host "  That ffmpeg build must include paletteuse; dynamic palettes also need palettegen."
    Write-Host "  ffprobe.exe is optional."
    Write-Host ""
    Write-Host "Output:" -ForegroundColor Yellow
    Write-Host "  input.gif and input.b64. The .b64 file is raw base64 text for Photo Album URL import."
    Write-Host ""
}

function Fail-Usage([string]$message) {
    Write-Host ""
    Write-Host "[error] $message" -ForegroundColor Red
    Show-Usage
    exit 1
}

function Fail-Runtime([string]$message) {
    Write-Host ""
    Write-Host "[error] $message" -ForegroundColor Red
    exit 1
}

function Has-Value($value) {
    if ($value -eq $null) { return $false }
    return $value.ToString().Trim().Length -gt 0
}

function Assert-Range([string]$name, [double]$value, [double]$min, [double]$max) {
    if ($value -lt $min -or $value -gt $max) {
        Fail-Usage "$name must be between $min and $max. Got: $value"
    }
}

function Assert-Min([string]$name, [double]$value, [double]$min) {
    if ($value -lt $min) {
        Fail-Usage "$name must be >= $min. Got: $value"
    }
}

function Convert-IntParam([string]$name, $value) {
    $n = 0
    if ($value -eq $null -or -not [int]::TryParse($value.ToString(), [ref]$n)) {
        Fail-Usage "$name must be an integer. Got: $value"
    }
    return $n
}

function Convert-OptionalIntParam([string]$name, $value) {
    if (-not (Has-Value $value)) { return $null }
    return Convert-IntParam $name $value
}

function Convert-DoubleParam([string]$name, $value) {
    $d = 0.0
    if ($value -eq $null -or -not [double]::TryParse(
            $value.ToString(),
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$d)) {
        Fail-Usage "$name must be a number. Got: $value"
    }
    return $d
}

function Convert-OptionalDoubleParam([string]$name, $value) {
    if (-not (Has-Value $value)) { return $null }
    return Convert-DoubleParam $name $value
}

function Assert-OneOf([string]$name, $value, [object[]]$allowed) {
    if ($allowed -notcontains $value) {
        Fail-Usage "$name must be one of: $($allowed -join ', '). Got: $value"
    }
}

function Find-Tool([string]$name) {
    $local = Join-Path $PSScriptRoot $name
    if (Test-Path $local) { return (Resolve-Path $local).Path }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd -ne $null) { return $cmd.Source }
    throw "Cannot find $name. Put $name in $PSScriptRoot or add it to PATH."
}

function Test-FfmpegUsable([string]$ffmpegPath, [ref]$detail) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $ffmpegPath -version 2>&1
        $detail.Value = (($out | Select-Object -First 5) -join "`n").Trim()
        return $LASTEXITCODE -eq 0
    } catch {
        $detail.Value = $_.Exception.Message
        return $false
    } finally {
        $ErrorActionPreference = $old
    }
}

$script:FfmpegFilterCache = @{}

function Test-FfmpegFilter([string]$ffmpegPath, [string]$filterName, [ref]$detail) {
    $key = "$ffmpegPath|$filterName"
    if ($script:FfmpegFilterCache.ContainsKey($key)) {
        $cached = $script:FfmpegFilterCache[$key]
        $detail.Value = $cached.Detail
        return [bool]$cached.Found
    }

    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $ffmpegPath -h "filter=$filterName" 2>&1
        $text = ($out | Out-String)
        $detail.Value = (($out | Select-Object -First 20) -join "`n").Trim()
        $unknown = $text -match "(?i)(Unknown filter|No such filter)"
        $found = -not $unknown
        $script:FfmpegFilterCache[$key] = @{ Found = $found; Detail = $detail.Value }
        return $found
    } catch {
        # If help probing itself fails for a reason other than a clear missing
        # filter, do not block the real encode; ffmpeg will report the true error.
        $detail.Value = $_.Exception.Message
        $script:FfmpegFilterCache[$key] = @{ Found = $true; Detail = $detail.Value }
        return $true
    } finally {
        $ErrorActionPreference = $old
    }
}

function Assert-FfmpegFilter([string]$ffmpegPath, [string]$filterName, [string]$reason) {
    $detail = ""
    if (-not (Test-FfmpegFilter $ffmpegPath $filterName ([ref]$detail))) {
        throw "ffmpeg.exe does not provide the '$filterName' filter, required for $reason. Replace it with a full FFmpeg build, or put a newer ffmpeg.exe next to this script. Detail: $detail"
    }
}

function Pick-Input {
    $exts = @(
        ".jpg", ".jpeg", ".png", ".bmp", ".webp", ".gif", ".tif", ".tiff",
        ".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm", ".wmv", ".flv",
        ".mpeg", ".mpg", ".ts", ".m2ts", ".3gp"
    )
    $files = Get-ChildItem -Path $PSScriptRoot -File |
        Where-Object {
            $file = $_
            $ext = $file.Extension.ToLowerInvariant()
            $keep = ($exts -contains $ext) -and ($file.BaseName -notmatch "^(sample|out|tmp)$")

            if ($keep -and $ext -eq ".gif") {
                $b64Path = Join-Path $file.DirectoryName ($file.BaseName + ".b64")
                if (Test-Path -LiteralPath $b64Path) {
                    $sameBaseSource = Get-ChildItem -LiteralPath $file.DirectoryName -File |
                        Where-Object {
                            $_.BaseName -eq $file.BaseName -and
                            $_.Extension.ToLowerInvariant() -ne ".gif" -and
                            $exts -contains $_.Extension.ToLowerInvariant()
                        } |
                        Select-Object -First 1
                    if ($sameBaseSource -ne $null) { $keep = $false }
                }
            }

            $keep
        } |
        Sort-Object LastWriteTime -Descending
    if ($files.Count -eq 0) {
        throw "No input image/video found in $PSScriptRoot."
    }
    Write-Host "[auto] $($files[0].Name)" -ForegroundColor Yellow
    return $files[0].FullName
}

function Is-VideoPath([string]$file) {
    $videoExts = @(".gif", ".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm", ".wmv", ".flv",
                   ".mpeg", ".mpg", ".ts", ".m2ts", ".3gp")
    return $videoExts -contains ([System.IO.Path]::GetExtension($file).ToLowerInvariant())
}

function Is-StaticImageFallbackPath([string]$file) {
    $fallbackExts = @(".jpg", ".jpeg", ".png", ".bmp", ".tif", ".tiff")
    return $fallbackExts -contains ([System.IO.Path]::GetExtension($file).ToLowerInvariant())
}

function Invoke-Checked([string]$exe, [string[]]$argv, [object]$progressTotalSeconds = $null, [string]$progressLabel = "") {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $lines = New-Object System.Collections.Generic.List[string]
        $showProgress = Has-Value $progressLabel
        $lastPrint = [DateTime]::MinValue
        $lastPercent = -1

        if ($showProgress) {
            Write-Host "[progress] ffmpeg started; first percentage can take a while while the GIF palette is prepared."
        }

        & $exe @argv 2>&1 | ForEach-Object {
            $line = $_.ToString()
            [void]$lines.Add($line)

            if ($showProgress) {
                $secondsDone = Convert-FfmpegProgressSeconds $line
                if ($secondsDone -ne $null) {
                    $now = Get-Date
                    if ((Has-Value $progressTotalSeconds) -and ([double]$progressTotalSeconds -gt 0)) {
                        $total = [double]$progressTotalSeconds
                        $percent = [Math]::Min(100, [Math]::Max(0, [int][Math]::Floor(($secondsDone / $total) * 100.0)))
                        $status = "{0} / {1}" -f (Format-Seconds $secondsDone), (Format-Seconds $total)
                        Write-Progress -Activity $progressLabel -Status $status -PercentComplete $percent
                        if ($percent -ne $lastPercent -or ($now - $lastPrint).TotalSeconds -ge 2) {
                            Write-Host ("[progress] {0}%  {1}" -f $percent, $status)
                            $lastPrint = $now
                            $lastPercent = $percent
                        }
                    } else {
                        $status = "processed {0}" -f (Format-Seconds $secondsDone)
                        Write-Progress -Activity $progressLabel -Status $status
                        if (($now - $lastPrint).TotalSeconds -ge 2) {
                            Write-Host ("[progress] {0}" -f $status)
                            $lastPrint = $now
                        }
                    }
                }
            }
        }

        if ($showProgress) {
            Write-Progress -Activity $progressLabel -Completed
        }

        if ($LASTEXITCODE -ne 0) {
            $shownArgs = ($argv | ForEach-Object {
                if ($_ -eq "") {
                    '""'
                } elseif ($_ -match "\s") {
                    '"' + $_ + '"'
                } else {
                    $_
                }
            }) -join " "
            $detail = ($lines.ToArray() | Select-Object -Last 30) -join "`n"
            throw "$([System.IO.Path]::GetFileName($exe)) exited with code $LASTEXITCODE`nCommand: $shownArgs`n$detail"
        }
        if ($showProgress) {
            Write-Host "[progress] done"
        }
    } finally {
        $ErrorActionPreference = $old
    }
}

function Convert-FfmpegProgressSeconds([string]$line) {
    if ($line -match "^out_time_(?:us|ms)=(\d+)$") {
        return ([double]$Matches[1]) / 1000000.0
    }
    if ($line -match "^out_time=([0-9:.]+)$") {
        $ts = [TimeSpan]::Zero
        if ([TimeSpan]::TryParse($Matches[1], [Globalization.CultureInfo]::InvariantCulture, [ref]$ts)) {
            return $ts.TotalSeconds
        }
    }
    return $null
}

function Format-Seconds([double]$seconds) {
    $whole = [int][Math]::Max(0, [Math]::Round($seconds))
    $hours = [int][Math]::Floor($whole / 3600)
    $minutes = [int][Math]::Floor(($whole % 3600) / 60)
    $secs = [int]($whole % 60)
    if ($hours -gt 0) {
        return "{0}:{1:00}:{2:00}" -f $hours, $minutes, $secs
    }
    return "{0:00}:{1:00}" -f $minutes, $secs
}

function Get-VideoDurationSeconds($ffprobe, [string]$videoPath) {
    if (-not $ffprobe) { return $null }
    try {
        $out = & $ffprobe @(
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=nokey=1:noprint_wrappers=1",
            $videoPath
        ) 2>$null
        if ($out -is [array]) { $out = $out[0] }
        $d = 0.0
        if ([double]::TryParse(
                ($out | Out-String).Trim(),
                [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$d)) {
            return $d
        }
    } catch {}
    return $null
}

function Get-ProgressTotalSeconds($sourceDuration) {
    if ((Has-Value $sourceDuration) -and ([double]$sourceDuration -gt 0)) {
        return [double]$sourceDuration
    }
    return $null
}

function Get-Base64CharCount([int64]$byteCount) {
    if ($byteCount -le 0) { return [int64]0 }
    return ([int64][Math]::Floor(([double]($byteCount + 2)) / 3.0)) * 4
}

function Write-Base64FileStreaming([string]$inputPath, [string]$outputPath) {
    $inputInfo = Get-Item -LiteralPath $inputPath
    $totalBytes = [int64]$inputInfo.Length
    $expectedChars = Get-Base64CharCount $totalBytes
    $tmpOutputPath = "$outputPath.tmp"
    $inputStream = $null
    $writer = $null
    $completed = $false

    Write-Host ("[b64] streaming {0} bytes -> {1} chars" -f $totalBytes, $expectedChars)
    try {
        Remove-Item -LiteralPath $tmpOutputPath -Force -ErrorAction SilentlyContinue
        $inputStream = [System.IO.File]::Open($inputPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $writer = [System.IO.StreamWriter]::new($tmpOutputPath, $false, [System.Text.Encoding]::ASCII, 1048576)

        $buffer = New-Object byte[] (3 * 1024 * 1024)
        $carry = New-Object byte[] 2
        $carryCount = 0
        $bytesDone = [int64]0
        $lastPrint = [DateTime]::MinValue
        $lastPercent = -1

        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $offset = 0

            if ($carryCount -gt 0) {
                $needed = 3 - $carryCount
                if ($read -ge $needed) {
                    $triple = New-Object byte[] 3
                    [Array]::Copy($carry, 0, $triple, 0, $carryCount)
                    [Array]::Copy($buffer, 0, $triple, $carryCount, $needed)
                    $writer.Write([Convert]::ToBase64String($triple))
                    $offset = $needed
                    $carryCount = 0
                } else {
                    [Array]::Copy($buffer, 0, $carry, $carryCount, $read)
                    $carryCount += $read
                    $bytesDone += $read
                    continue
                }
            }

            $usable = $read - $offset
            $remainder = $usable % 3
            $encodeLen = $usable - $remainder
            if ($encodeLen -gt 0) {
                $writer.Write([Convert]::ToBase64String($buffer, $offset, $encodeLen))
            }
            if ($remainder -gt 0) {
                [Array]::Copy($buffer, $offset + $encodeLen, $carry, 0, $remainder)
                $carryCount = $remainder
            }

            $bytesDone += $read
            $now = Get-Date
            if ($totalBytes -gt 0) {
                $percent = [Math]::Min(100, [Math]::Max(0, [int][Math]::Floor(($bytesDone / [double]$totalBytes) * 100.0)))
                Write-Progress -Activity "Writing base64" -Status ("{0}%  {1} / {2} bytes" -f $percent, $bytesDone, $totalBytes) -PercentComplete $percent
                if ($percent -ne $lastPercent -or ($now - $lastPrint).TotalSeconds -ge 2) {
                    Write-Host ("[b64] {0}%  {1} / {2} bytes" -f $percent, $bytesDone, $totalBytes)
                    $lastPrint = $now
                    $lastPercent = $percent
                }
            }
        }

        if ($carryCount -gt 0) {
            $tail = New-Object byte[] $carryCount
            [Array]::Copy($carry, 0, $tail, 0, $carryCount)
            $writer.Write([Convert]::ToBase64String($tail))
        }

        $writer.Flush()
        $writer.Dispose()
        $writer = $null
        Move-Item -LiteralPath $tmpOutputPath -Destination $outputPath -Force
        $completed = $true
        Write-Progress -Activity "Writing base64" -Completed
        Write-Host "[b64] done"
        return $expectedChars
    } finally {
        if ($writer -ne $null) { $writer.Dispose() }
        if ($inputStream -ne $null) { $inputStream.Dispose() }
        if (-not $completed) {
            Remove-Item -LiteralPath $tmpOutputPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-StaleTempDirs([string]$currentDir) {
    try {
        $tempRoot = [System.IO.Path]::GetTempPath()
        $cutoff = (Get-Date).AddHours(-1)
        $removed = 0
        $dirs = @(Get-ChildItem -LiteralPath $tempRoot -Directory -Filter "edc-photo-*" -ErrorAction SilentlyContinue)

        foreach ($dir in $dirs) {
            $full = $dir.FullName
            if ((Has-Value $currentDir) -and [string]::Equals($full, $currentDir, [StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            $keepPath = Join-Path $full "keep.txt"
            if (Test-Path -LiteralPath $keepPath) {
                continue
            }

            $remove = $false
            $pidPath = Join-Path $full "owner.pid"
            if (Test-Path -LiteralPath $pidPath) {
                $pidText = (Get-Content -LiteralPath $pidPath -Raw -ErrorAction SilentlyContinue).Trim()
                $ownerPid = 0
                if ([int]::TryParse($pidText, [ref]$ownerPid) -and $ownerPid -gt 0) {
                    $remove = ((Get-Process -Id $ownerPid -ErrorAction SilentlyContinue) -eq $null)
                } else {
                    $remove = $true
                }
            } elseif ($dir.LastWriteTime -lt $cutoff) {
                $remove = $true
            }

            if ($remove) {
                Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
                if (-not (Test-Path -LiteralPath $full)) {
                    $removed++
                }
            }
        }

        if ($removed -gt 0) {
            Write-Host "[temp-cleanup] removed $removed stale temp folder(s)" -ForegroundColor Yellow
        }
    } catch {}
}

function Get-GifFrameCount($ffprobe, [string]$gifPath) {
    if (-not $ffprobe) { return -1 }
    try {
        $out = & $ffprobe @(
            "-v", "error",
            "-select_streams", "v:0",
            "-count_frames",
            "-show_entries", "stream=nb_read_frames",
            "-of", "default=nokey=1:noprint_wrappers=1",
            $gifPath
        ) 2>$null
        if ($out -is [array]) { $out = $out[0] }
        $n = 0
        if ([int]::TryParse(($out | Out-String).Trim(), [ref]$n)) { return $n }
    } catch {}
    return 1
}

function Write-GarminMip64Palette([string]$path) {
    $levels = @(0, 85, 170, 255)
    $bytes = New-Object System.Collections.Generic.List[byte]
    # paletteuse is happiest with the usual 16x16 palette image. We repeat the
    # 64 RGB222 colors four times, so the palette image has 256 pixels but only
    # the Garmin MIP 64 unique colors.
    $header = [System.Text.Encoding]::ASCII.GetBytes("P6`n16 16`n255`n")
    foreach ($b in $header) { [void]$bytes.Add([byte]$b) }
    for ($repeat = 0; $repeat -lt 4; $repeat++) {
        foreach ($r in $levels) {
            foreach ($g in $levels) {
                foreach ($b in $levels) {
                    [void]$bytes.Add([byte]$r)
                    [void]$bytes.Add([byte]$g)
                    [void]$bytes.Add([byte]$b)
                }
            }
        }
    }
    [System.IO.File]::WriteAllBytes($path, $bytes.ToArray())
}

function Join-Filters([object[]]$parts) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($p in $parts) {
        if (Has-Value $p) { [void]$out.Add($p.ToString()) }
    }
    return ($out.ToArray() -join ",")
}

function Format-DoubleArg($value) {
    return [string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:0.###}", $value)
}

function New-ScaleExpr($dim) {
    if (-not (Has-Value $dim)) { return "" }
    return "scale=w='if(gte(iw,ih),min($dim,iw),-1)':h='if(gte(iw,ih),-1,min($dim,ih))':flags=lanczos"
}

function New-ImageFilter($dim, $colors, [bool]$useMipPalette) {
    $pre = Join-Filters @((New-ScaleExpr $dim), "format=rgba")
    if ($useMipPalette) {
        return "[0:v]$pre[v];[v][1:v]paletteuse=dither=sierra2_4a"
    }
    $paletteGen = if (Has-Value $colors) {
        "palettegen=max_colors=${colors}:reserve_transparent=0:stats_mode=single"
    } else {
        "palettegen=reserve_transparent=0:stats_mode=single"
    }
    return "[0:v]$pre,split[a][b];[a]$paletteGen[p];[b][p]paletteuse=dither=sierra2_4a"
}

function New-VideoFilter($dim, $colors, $fps, [bool]$useMipPalette, $sourceDuration, [bool]$dedupe) {
    $parts = New-Object System.Collections.Generic.List[string]
    if (Has-Value $fps) {
        if ([double]$fps -ge 1.0) {
            $fpsArg = Format-DoubleArg ([double]$fps)
            [void]$parts.Add("fps=fps=${fpsArg}:round=near")
        } else {
        $interval = 1.0 / [double]$fps
        $intervalArg = Format-DoubleArg $interval
        $goodOffsetArg = Format-DoubleArg ($interval * 0.20)
        $fallbackOffsetArg = Format-DoubleArg ($interval * 0.50)
        $bucket = "floor(t/${intervalArg})"
        $prevBucket = "floor(prev_selected_t/${intervalArg})"
        $bucketStart = "${bucket}*${intervalArg}"
        $bucketOffset = "t-${bucketStart}"
        $goodFrame = "gte(${bucketOffset}\,${goodOffsetArg})*(eq(pict_type\,I)+gt(scene\,0.035))"
        if ((Has-Value $sourceDuration) -and ([double]$sourceDuration -gt 0)) {
            $durationArg = Format-DoubleArg ([double]$sourceDuration)
            $bucketEnd = "min((${bucket}+1)*${intervalArg}\,${durationArg})"
            $fallbackFrame = "gte(t\,${bucketStart}+min(${fallbackOffsetArg}\,(${bucketEnd}-${bucketStart})*0.50))"
        } else {
            $fallbackFrame = "gte(${bucketOffset}\,${fallbackOffsetArg})"
        }
        $firstBucket = "isnan(prev_selected_t)*(${goodFrame}+${fallbackFrame})"
        $nextBucket = "gt(${bucket}\,${prevBucket})*(${goodFrame}+${fallbackFrame})"
        [void]$parts.Add("setpts=PTS-STARTPTS")
        [void]$parts.Add("select='${firstBucket}+${nextBucket}'")
        }
    }
    if ($dedupe) {
        [void]$parts.Add("mpdecimate")
    }
    $scale = New-ScaleExpr $dim
    if (Has-Value $scale) { [void]$parts.Add($scale) }

    [void]$parts.Add("setpts=PTS-STARTPTS")

    [void]$parts.Add("format=rgba")

    $pre = Join-Filters ($parts.ToArray())
    if ($useMipPalette) {
        return "[0:v]$pre[v];[v][1:v]paletteuse=dither=sierra2_4a"
    }
    $paletteGen = if (Has-Value $colors) {
        "palettegen=max_colors=${colors}:reserve_transparent=0:stats_mode=diff"
    } else {
        "palettegen=reserve_transparent=0:stats_mode=diff"
    }
    return "[0:v]$pre,split[a][b];[a]$paletteGen[p];[b][p]paletteuse=dither=sierra2_4a"
}

function Invoke-EncodeGif(
    [string]$ffmpeg,
    [string]$inputPath,
    [string]$outputGif,
    [string]$filter,
    [string]$palettePath,
    [bool]$video,
    [object]$progressTotalSeconds,
    [string]$progressLabel
) {
    $args = @("-loglevel", "error", "-nostdin", "-y")
    if ($video) {
        $args += @("-progress", "pipe:1")
    }
    $args += @("-i", $inputPath)
    if ($palettePath -ne $null -and $palettePath.Length -gt 0) {
        $args += @("-i", $palettePath)
    }
    $args += @("-an", "-filter_complex", $filter)
    if (-not $video) {
        $args += @("-frames:v", "1")
    }
    $args += @("-loop", "0", $outputGif)
    Invoke-Checked $ffmpeg $args $progressTotalSeconds $progressLabel
}

function Set-GifFrameDelay([string]$gifPath, [int]$delayCs) {
    $delay = [Math]::Min(65535, [Math]::Max(1, $delayCs))
    $lo = [byte]($delay -band 0xFF)
    $hi = [byte](($delay -shr 8) -band 0xFF)
    $tmpPath = "$gifPath.delay.tmp"
    $inputStream = $null
    $outputStream = $null
    $completed = $false
    $patched = 0

    function Copy-ExactBytes([int]$count) {
        for ($i = 0; $i -lt $count; $i++) {
            $x = $inputStream.ReadByte()
            if ($x -eq -1) { return $false }
            $outputStream.WriteByte([byte]$x)
        }
        return $true
    }

    function Copy-SubBlocks {
        while ($true) {
            $size = $inputStream.ReadByte()
            if ($size -eq -1) { return $false }
            $outputStream.WriteByte([byte]$size)
            if ($size -eq 0) { return $true }
            if (-not (Copy-ExactBytes $size)) { return $false }
        }
    }

    function Copy-Rest {
        while (($x = $inputStream.ReadByte()) -ne -1) {
            $outputStream.WriteByte([byte]$x)
        }
    }

    try {
        Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
        $inputStream = [System.IO.File]::Open($gifPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $outputStream = [System.IO.File]::Open($tmpPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

        $header = New-Object byte[] 13
        $headerRead = $inputStream.Read($header, 0, $header.Length)
        if ($headerRead -lt $header.Length) {
            throw "Invalid GIF: header is too short."
        }
        $outputStream.Write($header, 0, $header.Length)

        $packed = [int]$header[10]
        if (($packed -band 0x80) -ne 0) {
            $gctBytes = 3 * [int][Math]::Pow(2, (($packed -band 0x07) + 1))
            if (-not (Copy-ExactBytes $gctBytes)) {
                throw "Invalid GIF: global color table is truncated."
            }
        }

        $done = $false
        while (-not $done -and (($marker = $inputStream.ReadByte()) -ne -1)) {
            $outputStream.WriteByte([byte]$marker)

            if ($marker -eq 0x21) {
                $label = $inputStream.ReadByte()
                if ($label -eq -1) { break }
                $outputStream.WriteByte([byte]$label)

                if ($label -ne 0xF9) {
                    if (-not (Copy-SubBlocks)) { break }
                    continue
                }

                $blockSize = $inputStream.ReadByte()
                if ($blockSize -eq -1) { break }
                $outputStream.WriteByte([byte]$blockSize)

                if ($blockSize -ne 4) {
                    if ($blockSize -gt 0 -and -not (Copy-ExactBytes $blockSize)) { break }
                    if (-not (Copy-SubBlocks)) { break }
                    continue
                }

                $data = New-Object byte[] 4
                $read = $inputStream.Read($data, 0, 4)
                if ($read -lt 4) {
                    if ($read -gt 0) { $outputStream.Write($data, 0, $read) }
                    break
                }

                $data[1] = $lo
                $data[2] = $hi
                $outputStream.Write($data, 0, 4)

                $terminator = $inputStream.ReadByte()
                if ($terminator -ne -1) { $outputStream.WriteByte([byte]$terminator) }
                $patched++
                continue
            }

            if ($marker -eq 0x2C) {
                $descriptor = New-Object byte[] 9
                $descriptorRead = $inputStream.Read($descriptor, 0, $descriptor.Length)
                if ($descriptorRead -gt 0) { $outputStream.Write($descriptor, 0, $descriptorRead) }
                if ($descriptorRead -lt $descriptor.Length) { break }

                $imagePacked = [int]$descriptor[8]
                if (($imagePacked -band 0x80) -ne 0) {
                    $lctBytes = 3 * [int][Math]::Pow(2, (($imagePacked -band 0x07) + 1))
                    if (-not (Copy-ExactBytes $lctBytes)) { break }
                }

                $lzwCodeSize = $inputStream.ReadByte()
                if ($lzwCodeSize -eq -1) { break }
                $outputStream.WriteByte([byte]$lzwCodeSize)
                if (-not (Copy-SubBlocks)) { break }
                continue
            }

            if ($marker -eq 0x3B) {
                Copy-Rest
                $done = $true
                break
            }

            Copy-Rest
            $done = $true
        }

        $outputStream.Flush()
        $outputStream.Dispose()
        $outputStream = $null
        $inputStream.Dispose()
        $inputStream = $null
        Move-Item -LiteralPath $tmpPath -Destination $gifPath -Force
        $completed = $true
    } finally {
        if ($outputStream -ne $null) { $outputStream.Dispose() }
        if ($inputStream -ne $null) { $inputStream.Dispose() }
        if (-not $completed) {
            Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
        }
    }

    if ($patched -gt 0) {
        Write-Host ("[timing] {0} frame delay(s) set to {1}cs" -f $patched, $delay)
    }
}

function Ensure-ImageGifFallbackType {
    if ("EdcImageGifFallbackRgb222" -as [type]) { return }

    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class EdcImageGifFallbackRgb222 {
    static int LevelValue(int index, int levels) {
        if (levels <= 1) return 0;
        return (int)Math.Round(index * 255.0 / (levels - 1));
    }

    static Color[] BuildVisiblePalette(int requestedColors) {
        int n = Math.Max(2, Math.Min(256, requestedColors));
        List<Color> colors = new List<Color>();

        if (n < 8) {
            for (int i = 0; i < n; i++) {
                int v = LevelValue(i, n);
                colors.Add(Color.FromArgb(v, v, v));
            }
            return colors.ToArray();
        }

        if (n == 64) {
            int[] levels = new int[] { 0, 85, 170, 255 };
            foreach (int r in levels)
                foreach (int g in levels)
                    foreach (int b in levels)
                        colors.Add(Color.FromArgb(r, g, b));
            return colors.ToArray();
        }

        int rLevels = 2, gLevels = 2, bLevels = 2;
        while (true) {
            int bestChannel = -1;
            int bestProduct = rLevels * gLevels * bLevels;
            int pr = (rLevels + 1) * gLevels * bLevels;
            int pg = rLevels * (gLevels + 1) * bLevels;
            int pb = rLevels * gLevels * (bLevels + 1);

            if (pg <= n && pg > bestProduct) { bestProduct = pg; bestChannel = 1; }
            if (pr <= n && pr > bestProduct) { bestProduct = pr; bestChannel = 0; }
            if (pb <= n && pb > bestProduct) { bestProduct = pb; bestChannel = 2; }

            if (bestChannel < 0) break;
            if (bestChannel == 0) rLevels++;
            else if (bestChannel == 1) gLevels++;
            else bLevels++;
        }

        for (int r = 0; r < rLevels; r++)
            for (int g = 0; g < gLevels; g++)
                for (int b = 0; b < bLevels; b++)
                    colors.Add(Color.FromArgb(LevelValue(r, rLevels), LevelValue(g, gLevels), LevelValue(b, bLevels)));

        return colors.ToArray();
    }

    static int Q(float v) {
        if (v < 0f) v = 0f;
        if (v > 255f) v = 255f;
        if (v < 43f) return 0;
        if (v < 128f) return 1;
        if (v < 213f) return 2;
        return 3;
    }

    static int NearestPaletteSlot(Color[] palette, float r, float g, float b) {
        int best = 0;
        float bestDist = Single.MaxValue;
        for (int i = 0; i < palette.Length; i++) {
            float dr = r - palette[i].R;
            float dg = g - palette[i].G;
            float db = b - palette[i].B;
            float dist = dr * dr + dg * dg + db * db;
            if (dist < bestDist) {
                bestDist = dist;
                best = i;
                if (dist == 0f) break;
            }
        }
        return best;
    }

    static void AddError(float[] rBuf, float[] gBuf, float[] bBuf, bool[] opaque, int w, int h, int x, int y, float er, float eg, float eb, float weight) {
        if (x < 0 || x >= w || y < 0 || y >= h) return;
        int p = y * w + x;
        if (!opaque[p]) return;
        rBuf[p] += er * weight;
        gBuf[p] += eg * weight;
        bBuf[p] += eb * weight;
    }

    public static int[] SaveGif(string inputPath, string outputPath, int maxDim, int requestedColors) {
        int visibleColorCount = Math.Max(2, Math.Min(255, requestedColors));
        Color[] visiblePalette = BuildVisiblePalette(visibleColorCount);

        using (Image src = Image.FromFile(inputPath)) {
            int srcW = src.Width;
            int srcH = src.Height;
            int dstW = srcW;
            int dstH = srcH;

            if (maxDim > 0) {
                int longest = Math.Max(srcW, srcH);
                if (longest > maxDim) {
                    double scale = maxDim / (double)longest;
                    dstW = Math.Max(1, (int)Math.Round(srcW * scale));
                    dstH = Math.Max(1, (int)Math.Round(srcH * scale));
                }
            }

            using (Bitmap rgba = new Bitmap(dstW, dstH, PixelFormat.Format32bppArgb)) {
                using (Graphics g = Graphics.FromImage(rgba)) {
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    g.SmoothingMode = SmoothingMode.HighQuality;
                    g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    g.CompositingQuality = CompositingQuality.HighQuality;
                    g.Clear(Color.Transparent);
                    g.DrawImage(src, 0, 0, dstW, dstH);
                }

                using (Bitmap indexed = new Bitmap(dstW, dstH, PixelFormat.Format8bppIndexed)) {
                    ColorPalette pal = indexed.Palette;
                    pal.Entries[0] = Color.FromArgb(0, 0, 0, 0);
                    for (int i = 0; i < visiblePalette.Length && i + 1 < pal.Entries.Length; i++)
                        pal.Entries[i + 1] = visiblePalette[i];
                    for (int i = visiblePalette.Length + 1; i < pal.Entries.Length; i++)
                        pal.Entries[i] = Color.Black;
                    indexed.Palette = pal;

                    Rectangle rect = new Rectangle(0, 0, dstW, dstH);
                    BitmapData srcData = rgba.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                    BitmapData dstData = indexed.LockBits(rect, ImageLockMode.WriteOnly, PixelFormat.Format8bppIndexed);
                    try {
                        int srcStride = Math.Abs(srcData.Stride);
                        int dstStride = Math.Abs(dstData.Stride);
                        byte[] srcBytes = new byte[srcStride * dstH];
                        byte[] dstBytes = new byte[dstStride * dstH];
                        Marshal.Copy(srcData.Scan0, srcBytes, 0, srcBytes.Length);

                        int n = dstW * dstH;
                        float[] rBuf = new float[n];
                        float[] gBuf = new float[n];
                        float[] bBuf = new float[n];
                        bool[] opaque = new bool[n];

                        for (int y = 0; y < dstH; y++) {
                            int srcRow = y * srcStride;
                            for (int x = 0; x < dstW; x++) {
                                int s = srcRow + x * 4;
                                int p = y * dstW + x;
                                bBuf[p] = srcBytes[s];
                                gBuf[p] = srcBytes[s + 1];
                                rBuf[p] = srcBytes[s + 2];
                                opaque[p] = srcBytes[s + 3] >= 128;
                            }
                        }

                        for (int y = 0; y < dstH; y++) {
                            bool rev = (y & 1) == 1;
                            int xs = rev ? dstW - 1 : 0;
                            int xe = rev ? -1 : dstW;
                            int step = rev ? -1 : 1;
                            int dstRow = y * dstStride;

                            for (int x = xs; x != xe; x += step) {
                                int p = y * dstW + x;
                                if (!opaque[p]) {
                                    dstBytes[dstRow + x] = 0;
                                    continue;
                                }

                                int slot;
                                int qr;
                                int qg;
                                int qb;
                                if (visibleColorCount == 64) {
                                    int ri = Q(rBuf[p]);
                                    int gi = Q(gBuf[p]);
                                    int bi = Q(bBuf[p]);
                                    slot = ri * 16 + gi * 4 + bi;
                                    qr = visiblePalette[slot].R;
                                    qg = visiblePalette[slot].G;
                                    qb = visiblePalette[slot].B;
                                } else {
                                    slot = NearestPaletteSlot(visiblePalette, rBuf[p], gBuf[p], bBuf[p]);
                                    Color q = visiblePalette[slot];
                                    qr = q.R;
                                    qg = q.G;
                                    qb = q.B;
                                }
                                dstBytes[dstRow + x] = (byte)(slot + 1); // index 0 is reserved for transparent pixels.

                                float er = rBuf[p] - qr;
                                float eg = gBuf[p] - qg;
                                float eb = bBuf[p] - qb;

                                if (!rev) {
                                    AddError(rBuf, gBuf, bBuf, opaque, dstW, dstH, x + 1, y, er, eg, eb, 7f / 16f);
                                    AddError(rBuf, gBuf, bBuf, opaque, dstW, dstH, x - 1, y + 1, er, eg, eb, 3f / 16f);
                                    AddError(rBuf, gBuf, bBuf, opaque, dstW, dstH, x, y + 1, er, eg, eb, 5f / 16f);
                                    AddError(rBuf, gBuf, bBuf, opaque, dstW, dstH, x + 1, y + 1, er, eg, eb, 1f / 16f);
                                } else {
                                    AddError(rBuf, gBuf, bBuf, opaque, dstW, dstH, x - 1, y, er, eg, eb, 7f / 16f);
                                    AddError(rBuf, gBuf, bBuf, opaque, dstW, dstH, x + 1, y + 1, er, eg, eb, 3f / 16f);
                                    AddError(rBuf, gBuf, bBuf, opaque, dstW, dstH, x, y + 1, er, eg, eb, 5f / 16f);
                                    AddError(rBuf, gBuf, bBuf, opaque, dstW, dstH, x - 1, y + 1, er, eg, eb, 1f / 16f);
                                }
                            }
                        }

                        Marshal.Copy(dstBytes, 0, dstData.Scan0, dstBytes.Length);
                    } finally {
                        rgba.UnlockBits(srcData);
                        indexed.UnlockBits(dstData);
                    }

                    indexed.Save(outputPath, ImageFormat.Gif);
                }
            }

            return new int[] { dstW, dstH };
        }
    }
}
'@ -ErrorAction Stop
}

function Invoke-ImageGifFallback([string]$inputPath, [string]$outputGif, $dim, $colors) {
    Ensure-ImageGifFallbackType
    $dimArg = if (Has-Value $dim) { [int]$dim } else { 0 }
    $colorArg = if (Has-Value $colors) { [int]$colors } else { 256 }
    return [EdcImageGifFallbackRgb222]::SaveGif($inputPath, $outputGif, $dimArg, $colorArg)
}

function Get-UniqueNumbers([int[]]$values, [int]$minValue) {
    $seen = @{}
    $out = New-Object System.Collections.Generic.List[int]
    foreach ($v in $values) {
        $x = [Math]::Max($minValue, $v)
        if (-not $seen.ContainsKey($x)) {
            $seen[$x] = $true
            [void]$out.Add($x)
        }
    }
    return $out.ToArray()
}

function New-DimCandidates($maxDim, [bool]$sizeLimited) {
    if (-not (Has-Value $maxDim)) { return @($null) }
    if (-not $sizeLimited) { return @($maxDim) }
    return Get-UniqueNumbers @(
        $maxDim,
        [int]($maxDim * 0.90),
        [int]($maxDim * 0.80),
        [int]($maxDim * 0.70),
        [int]($maxDim * 0.60),
        [int]($maxDim * 0.50),
        [int]($maxDim * 0.42),
        [int]($maxDim * 0.34),
        64,
        48,
        32,
        24,
        16,
        12,
        8,
        4
    ) 4 | Where-Object { $_ -le $maxDim }
}

function New-ColorCandidates($maxColors, [bool]$sizeLimited) {
    if (-not (Has-Value $maxColors)) { return @($null) }
    if (-not $sizeLimited) { return @($maxColors) }
    $seen = @{}
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($v in @($maxColors, 192, 128, 96, 64, 48, 32, 24, 16, 8, 4, 2)) {
        if ($v -ge 2 -and $v -le $maxColors -and -not $seen.ContainsKey($v)) {
            $seen[$v] = $true
            [void]$out.Add($v)
        }
    }
    return $out.ToArray()
}

function New-FpsCandidates($fps, [bool]$sizeLimited) {
    if (-not (Has-Value $fps)) { return @($null) }
    if (-not $sizeLimited) { return @($fps) }
    $maxFps = [double]$fps
    $raw = @(
        $maxFps,
        ($maxFps * 0.80),
        ($maxFps * 0.65),
        ($maxFps * 0.50),
        ($maxFps * 0.35),
        ($maxFps * 0.25),
        8,
        6,
        5,
        4,
        3,
        2,
        1,
        0.75,
        0.5,
        0.33,
        0.25,
        0.2,
        0.15,
        0.1,
        0.075,
        0.05
    )
    $seen = @{}
    $out = New-Object System.Collections.Generic.List[double]
    foreach ($v in ($raw | Where-Object { [double]$_ -gt 0 -and [double]$_ -le $maxFps } | Sort-Object -Descending)) {
        $rounded = [Math]::Round([double]$v, 3)
        if ($rounded -le 0) { continue }
        $key = [string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:0.######}", $rounded)
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            [void]$out.Add($rounded)
        }
    }
    return $out.ToArray()
}

function Format-CandidateLabel($value, [string]$noneLabel) {
    if (Has-Value $value) {
        $d = 0.0
        if ([double]::TryParse(
                $value.ToString(),
                [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$d)) {
            return Format-DoubleArg $d
        }
        return $value.ToString()
    }
    return $noneLabel
}

function Format-DimLabel($value) {
    if (Has-Value $value) { return $value.ToString() }
    return "source"
}

if ($Help) {
    Show-Usage
    exit 0
}

$tmpDir = $null
try {
    $userSetDim = Has-Value $Dim
    $userSetFps = Has-Value $Fps
    $userSetColors = Has-Value $Colors

    $MaxSizeKB = Convert-OptionalIntParam "MaxSizeKB" $MaxSizeKB
    $Dim = Convert-OptionalIntParam "Dim" $Dim
    $Fps = Convert-OptionalDoubleParam "Fps" $Fps
    $Colors = Convert-OptionalIntParam "Colors" $Colors
    $FrameMs = Convert-OptionalIntParam "FrameMs" $FrameMs

    if (Has-Value $MaxSizeKB) { Assert-Min "MaxSizeKB" $MaxSizeKB 1 }
    if (Has-Value $Dim) { Assert-Min "Dim" $Dim 4 }
    if ((Has-Value $Fps) -and ([double]$Fps -le 0)) {
        Fail-Usage "Fps must be > 0. Got: $Fps"
    }
    if (Has-Value $Colors) { Assert-Range "Colors" $Colors 2 256 }
    if (Has-Value $FrameMs) { Assert-Range "FrameMs" $FrameMs 10 655350 }

    $frameDelayCs = if (Has-Value $FrameMs) {
        [int][Math]::Ceiling([double]$FrameMs / 10.0)
    } else {
        $null
    }

    if (-not $Path) { $Path = Pick-Input }
    if (-not (Test-Path -LiteralPath $Path)) {
        Fail-Usage "Input file not found: $Path"
    }
    $inFull = (Resolve-Path -LiteralPath $Path).Path
    $isVideo = Is-VideoPath $inFull
    $useStaticFallback = ((-not $isVideo) -and (Is-StaticImageFallbackPath $inFull))
    $ffmpeg = $null
    if (-not $useStaticFallback) {
        try {
            $ffmpeg = Find-Tool "ffmpeg.exe"
        } catch {
            throw "Cannot find ffmpeg.exe. Static PNG/JPEG/BMP/TIFF images use the .NET fallback, but this input needs ffmpeg: $inFull"
        }
        $ffmpegDetail = ""
        if (-not (Test-FfmpegUsable $ffmpeg ([ref]$ffmpegDetail))) {
            throw "ffmpeg.exe was found but does not look usable, and this input needs ffmpeg: $inFull`nDetail: $ffmpegDetail"
        }
    }
    $ffprobe = $null
    if ($ffmpeg -ne $null) {
        try {
            $ffprobe = Find-Tool "ffprobe.exe"
        } catch {
            Write-Warning "ffprobe.exe not found; conversion still works, but output frame count is estimated/unknown."
        }
    }

$dir = [System.IO.Path]::GetDirectoryName($inFull)
$base = [System.IO.Path]::GetFileNameWithoutExtension($inFull)
if ($Output) {
    $gifOut = [System.IO.Path]::GetFullPath($Output)
    if ([System.IO.Path]::GetExtension($gifOut).ToLowerInvariant() -ne ".gif") {
        $gifOut = [System.IO.Path]::ChangeExtension($gifOut, ".gif")
    }
} else {
    $gifOut = Join-Path $dir ($base + ".gif")
}
$b64Out = [System.IO.Path]::ChangeExtension($gifOut, ".b64")

$sourceDuration = if ($isVideo) { Get-VideoDurationSeconds $ffprobe $inFull } else { $null }
$sizeLimited = Has-Value $MaxSizeKB
$maxBytes = if ($sizeLimited) { [int64]$MaxSizeKB * 1024 } else { 0 }
if ($isVideo -and
        -not $sizeLimited -and
        ([System.IO.Path]::GetExtension($inFull).ToLowerInvariant() -ne ".gif") -and
        -not (Has-Value $Dim) -and
        -not (Has-Value $Fps)) {
    $durationLabel = if (Has-Value $sourceDuration) { Format-Seconds ([double]$sourceDuration) } else { "unknown duration" }
    Write-Warning "No video scale/fps limits supplied; converting the full source ($durationLabel). This can take a long time."
}
$dimLimit = $Dim
$fpsLimit = $Fps
$colorsLimit = $Colors
$autoQuality = New-Object System.Collections.Generic.List[string]
if ($sizeLimited) {
    if (-not $userSetDim) {
        $dimLimit = 240
        [void]$autoQuality.Add("dim 240..4")
    }
    if ($isVideo -and -not $userSetFps) {
        $fpsLimit = 10
        [void]$autoQuality.Add("fps 10..0.05")
    }
    if (-not $userSetColors) {
        $colorsLimit = 64
        [void]$autoQuality.Add("colors 64..2")
    }
    if ($autoQuality.Count -gt 0) {
        Write-Host ("[auto-quality] {0}" -f ($autoQuality -join " ")) -ForegroundColor Yellow
    }
}
Remove-StaleTempDirs $null
$tmpDir = Join-Path $env:TEMP ("edc-photo-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmpDir | Out-Null
[System.IO.File]::WriteAllText(
    (Join-Path $tmpDir "owner.pid"),
    $PID.ToString([Globalization.CultureInfo]::InvariantCulture),
    [System.Text.Encoding]::ASCII)
$mipPalettePath = Join-Path $tmpDir "garmin-mip-rgb222-64.ppm"
Write-GarminMip64Palette $mipPalettePath

    $paletteMode = if (-not (Has-Value $colorsLimit)) {
        "dynamic<=256"
    } elseif ($colorsLimit -eq 64) {
        "GarminMIP64"
    } elseif ($colorsLimit -gt 64) {
        "dynamic<=${colorsLimit}, fallback=GarminMIP64"
    } else {
        "dynamic<=${colorsLimit}"
    }
    $limits = New-Object System.Collections.Generic.List[string]
    if ($sizeLimited) { [void]$limits.Add("size<=${MaxSizeKB}KB") }
    if (Has-Value $dimLimit) {
        $dimLabel = if ($userSetDim) { "dim=${dimLimit}" } else { "dim<=${dimLimit}" }
        [void]$limits.Add($dimLabel)
    }
    if ($isVideo -and (Has-Value $fpsLimit)) {
        $fpsLabel = if ($userSetFps) { "fps=${fpsLimit}" } else { "fps<=${fpsLimit}" }
        [void]$limits.Add($fpsLabel)
    }
    if (Has-Value $colorsLimit) {
        $colorsLabel = if ($userSetColors) { "colors=${colorsLimit}" } else { "colors<=${colorsLimit}" }
        [void]$limits.Add($colorsLabel)
    }
    if (Has-Value $FrameMs) { [void]$limits.Add("frame=${FrameMs}ms") }
    if ($isVideo -and $Dedupe) { [void]$limits.Add("dedupe=on") }
    if ($limits.Count -eq 0) { [void]$limits.Add("unrestricted") }
    $backendMode = if ($useStaticFallback) { ".NET" } else { "ffmpeg" }

    Write-Host "[input] $inFull" -ForegroundColor Cyan
    Write-Host "[mode]  $(if ($isVideo) { 'video' } else { 'image' })  $($limits -join ' ') backend=$backendMode palette=$paletteMode" -ForegroundColor Cyan

    $dims = @(New-DimCandidates $dimLimit ($sizeLimited -and -not $userSetDim))
    $colorCandidates = @(New-ColorCandidates $colorsLimit ($sizeLimited -and -not $userSetColors))
    $fpsCandidates = @(New-FpsCandidates $fpsLimit ($sizeLimited -and -not $userSetFps))

    $bestPath = $null
    $bestInfo = $null
    $attempt = 0

    $dimIndex = 0
    $colorIndex = 0
    $fpsIndex = 0
    $maxAttempts = if ($sizeLimited) { if ($isVideo) { 96 } else { 48 } } else { 1 }

    $reuseInputGif = (
        ([System.IO.Path]::GetExtension($inFull).ToLowerInvariant() -eq ".gif") -and
        -not $sizeLimited -and
        -not (Has-Value $dimLimit) -and
        -not (Has-Value $fpsLimit) -and
        -not (Has-Value $colorsLimit) -and
        -not (Has-Value $frameDelayCs) -and
        -not $Dedupe
    )
    if ($reuseInputGif) {
        $size = (Get-Item -LiteralPath $inFull).Length
        $frames = Get-GifFrameCount $ffprobe $inFull
        $bestPath = $inFull
        $bestInfo = @{
            Size = $size; Dim = $null; Colors = $null; Fps = $null;
            Frames = $frames
        }
        Write-Host "[reuse] input is already GIF; writing .b64 without re-encoding." -ForegroundColor Yellow
    }

    if (($ffmpeg -ne $null) -and (-not $reuseInputGif)) {
        Assert-FfmpegFilter $ffmpeg "paletteuse" "applying a GIF palette during ffmpeg conversion"
    }

    while ((-not $bestPath) -and $attempt -lt $maxAttempts) {
        $dim = $dims[$dimIndex]
        $colors = $colorCandidates[$colorIndex]
        $fpsTry = $fpsCandidates[$fpsIndex]

        $attempt++
        $tmpGif = Join-Path $tmpDir ("try-$attempt.gif")
        $useMipPalette = ((Has-Value $colors) -and $colors -eq 64)
        $paletteArg = if ($useMipPalette) { $mipPalettePath } else { $null }
        if ($isVideo) {
            if (-not $useMipPalette) {
                Assert-FfmpegFilter $ffmpeg "palettegen" "generating a dynamic GIF palette during ffmpeg conversion"
            }
            $f = New-VideoFilter $dim $colors $fpsTry $useMipPalette $sourceDuration $Dedupe.IsPresent
            $progressTotal = Get-ProgressTotalSeconds $sourceDuration
            $progressLabel = "Encoding GIF try $attempt"
            Invoke-EncodeGif $ffmpeg $inFull $tmpGif $f $paletteArg $true $progressTotal $progressLabel
        } elseif ($ffmpeg -eq $null) {
            [void](Invoke-ImageGifFallback $inFull $tmpGif $dim $colors)
        } else {
            if (-not $useMipPalette) {
                Assert-FfmpegFilter $ffmpeg "palettegen" "generating a dynamic GIF palette during ffmpeg conversion"
            }
            $f = New-ImageFilter $dim $colors $useMipPalette
            Invoke-EncodeGif $ffmpeg $inFull $tmpGif $f $paletteArg $false $null ""
        }

        $size = (Get-Item $tmpGif).Length
        $frames = if ($isVideo) { Get-GifFrameCount $ffprobe $tmpGif } else { 1 }
        $frameLabel = if ($frames -lt 0) { "?" } else { $frames.toString() }
        $kb = [Math]::Round($size / 1024.0, 1)
        $videoLabel = if ($isVideo) {
            " fps=$(Format-CandidateLabel $fpsTry 'source')"
        } else {
            ""
        }
        Write-Host ("[try {0}] {1}KB dim={2} colors={3}{4}{5} frames={6}" -f
            $attempt, $kb, (Format-DimLabel $dim), (Format-CandidateLabel $colors 'auto'),
            ($(if ($useMipPalette) { " mip64" } else { "" })),
            $videoLabel,
            $frameLabel)

        if ((-not $sizeLimited) -or $size -le $maxBytes) {
            $bestPath = $tmpGif
            $bestInfo = @{
                Size = $size; Dim = $dim; Colors = $colors; Fps = $fpsTry;
                Frames = $frames
            }
            break
        }

        # When a byte limit requires retries, preserve the full video duration:
        # sacrifice fps before dimensions, and only then try palette reductions.
        if ($isVideo -and $fpsIndex + 1 -lt $fpsCandidates.Count) {
            $fpsIndex++
        } elseif ($dimIndex + 1 -lt $dims.Count) {
            $dimIndex++
        } elseif ($colorIndex + 1 -lt $colorCandidates.Count) {
            $colorIndex++
        } else {
            break
        }
    }

    if (-not $bestPath) {
        if ($isVideo) {
            throw "Could not fit under ${MaxSizeKB}KB while preserving the full video duration. Remove or change fixed -Dim/-Fps/-Colors values, or increase -MaxSizeKB."
        }
        throw "Could not fit under ${MaxSizeKB}KB. Remove or change fixed -Dim/-Colors values, or increase -MaxSizeKB."
    }

    $bestFull = (Resolve-Path -LiteralPath $bestPath).Path
    $gifFull = [System.IO.Path]::GetFullPath($gifOut)
    if (-not [string]::Equals($bestFull, $gifFull, [StringComparison]::OrdinalIgnoreCase)) {
        Copy-Item -LiteralPath $bestPath -Destination $gifOut -Force
    }
    if ($isVideo) {
        if (Has-Value $frameDelayCs) {
            Set-GifFrameDelay $gifOut $frameDelayCs
        } elseif ((Has-Value $bestInfo.Fps) -and ([double]$bestInfo.Fps -lt 1.0)) {
            Set-GifFrameDelay $gifOut 100
        }
    }
    $b64Chars = Write-Base64FileStreaming $gifOut $b64Out

    $finalFrames = if ([int]$bestInfo.Frames -lt 0) { "?" } else { $bestInfo.Frames.toString() }
    Write-Host ""
    Write-Host ("[GIF] {0} bytes ({1}KB), frames={2}, dim={3}, colors={4}" -f
        $bestInfo.Size,
        [Math]::Round($bestInfo.Size / 1024.0, 1),
        $finalFrames,
        (Format-DimLabel $bestInfo.Dim),
        (Format-CandidateLabel $bestInfo.Colors "auto")) -ForegroundColor Green
    Write-Host "[saved] $gifOut" -ForegroundColor Green
    Write-Host ("[saved] {0} ({1} chars)" -f $b64Out, $b64Chars) -ForegroundColor Green
    Write-Host ""
    Write-Host "Use Photo Album -> + Add -> URL, pointing to a raw text file containing the .b64 contents." -ForegroundColor Yellow
} catch {
    Fail-Runtime $_.Exception.Message
} finally {
    if ($tmpDir -eq $null) {
        # Error happened before temp directory creation.
    } elseif ($KeepTemp) {
        [System.IO.File]::WriteAllText(
            (Join-Path $tmpDir "keep.txt"),
            "Kept by -KeepTemp on $(Get-Date -Format s)",
            [System.Text.Encoding]::ASCII)
        Write-Host "[temp] $tmpDir" -ForegroundColor Yellow
    } else {
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
