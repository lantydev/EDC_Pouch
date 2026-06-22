# EDC Pouch watch album packer: image/video -> GIF + base64 text.
#
# Requirements:
#   Put ffmpeg.exe in this script folder, or make it available in PATH.
#   ffprobe.exe is optional; with it the script can print exact output frame count.
#
# Examples:
#   .\make_gif.ps1 .\photo.jpg
#   .\make_gif.ps1 .\photo.jpg -MaxKB 32 -MaxDim 240
#   .\make_gif.ps1 .\movie.mp4 -MaxKB 48 -MaxDim 220 -Seconds 8 -Fps 10 -MaxColors 64
#   .\make_gif.ps1 -MaxKB 28 -MaxDim 180
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
    [object]$MaxKB = $null,

    # Optional longest output side limit.
    [object]$MaxDim = $null,

    # Optional video sampling fps.
    [object]$Fps = $null,

    # Optional video duration from -Start.
    [object]$Seconds = $null,

    # Optional maximum video frames after similar-frame skipping.
    [object]$MaxFrames = $null,

    # Optional GIF palette size. 64 uses the fixed Garmin MIP RGB222 palette:
    # each RGB channel is 0/85/170/255.
    [object]$MaxColors = $null,

    # Optional start offset for video clips.
    [object]$Start = 0.0,

    [string]$Mode = "auto",

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
    Write-Host "  .\$script <video> -MaxKB 48 -MaxDim 220 -Seconds 8 -Fps 10 -MaxColors 64"
    Write-Host "  .\$script -Help"
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Yellow
    Write-Host "  .\$script .\photo.jpg"
    Write-Host "  .\$script .\movie.mp4"
    Write-Host "  .\$script .\photo.jpg -MaxKB 32 -MaxDim 240"
    Write-Host "  .\$script .\movie.mp4 -MaxKB 48 -MaxDim 220 -Seconds 8 -Fps 10 -MaxColors 64"
    Write-Host "  .\$script .\movie.mp4 -MaxKB 32 -MaxDim 180 -Start 5 -Seconds 6"
    Write-Host "  .\$script -MaxKB 28 -MaxDim 180"
    Write-Host ""
    Write-Host "Garmin watch-friendly full example:" -ForegroundColor Yellow
    Write-Host "  .\$script .\movie.mp4 -Mode video -Output .\watch.gif -MaxKB 50 -MaxDim 240 -Fps 10 -Seconds 8 -MaxFrames 48 -MaxColors 64 -Start 0"
    Write-Host "  # input file: source image/video; put it first so PowerShell binds it to Path."
    Write-Host "  # -Mode video: forces video handling when the extension is unusual or ambiguous."
    Write-Host "  # -Output .\watch.gif: writes watch.gif and watch.b64 together."
    Write-Host "  # -MaxKB 50: keeps GIF bytes small for watch storage, decoding time, and URL import."
    Write-Host "  # -MaxDim 240: caps the longest side for small round Garmin screens and lower memory use."
    Write-Host "  # -Fps 10: enough motion for watch playback without wasting frames."
    Write-Host "  # -Seconds 8: short clips decode faster and leave less work for the watch CPU."
    Write-Host "  # -MaxFrames 48: a hard frame cap after similar-frame skipping; protects memory/time."
    Write-Host "  # -MaxColors 64: uses the fixed Garmin MIP RGB222 palette, not a random GIF palette."
    Write-Host "  # -Start 0: starts at the beginning; raise it to cut away an intro."
    Write-Host "  # -KeepTemp: optional debug flag; add only when you want to inspect trial GIFs."
    Write-Host "  # Similar-frame skipping is enabled only when -MaxKB or -MaxFrames is supplied."
    Write-Host ""
    Write-Host "Parameters:" -ForegroundColor Yellow
    Write-Host "  All limits are opt-in. If you omit a limit, the script does not apply that limit."
    Write-Host "  -MaxKB       Optional final GIF size limit in KB. Omitted: no size limit"
    Write-Host "  -MaxDim      Optional longest output side limit. Omitted: keep source dimensions"
    Write-Host "  -Fps         Optional video sampling fps. Omitted: keep source timing"
    Write-Host "  -Seconds     Optional video duration from -Start. Omitted: no duration trim"
    Write-Host "  -MaxFrames   Optional maximum video frames; also enables similar-frame skipping"
    Write-Host "  -MaxColors   Optional GIF palette limit. 64 = fixed Garmin MIP RGB222 colors"
    Write-Host "  -Start       Video start offset in seconds. Default: 0"
    Write-Host "  -Mode        auto/image/video. Default: auto"
    Write-Host "  -Output      Optional output .gif path. .b64 is written next to it"
    Write-Host "  -KeepTemp    Keep temporary trial GIFs for inspection"
    Write-Host ""
    Write-Host "Requirements:" -ForegroundColor Yellow
    Write-Host "  Put ffmpeg.exe next to this script. ffprobe.exe is optional."
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

function Pick-Input {
    $exts = @(
        ".jpg", ".jpeg", ".png", ".bmp", ".webp", ".gif", ".tif", ".tiff",
        ".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm", ".wmv", ".flv",
        ".mpeg", ".mpg", ".ts", ".m2ts", ".3gp"
    )
    $files = Get-ChildItem -Path $PSScriptRoot -File |
        Where-Object {
            $exts -contains $_.Extension.ToLowerInvariant() -and
            $_.Extension.ToLowerInvariant() -ne ".b64" -and
            $_.BaseName -notmatch "^(sample|out|tmp)$"
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

function Invoke-Checked([string]$exe, [string[]]$argv) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $lines = @(& $exe @argv 2>&1 | ForEach-Object { $_.ToString() })
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
            $detail = ($lines | Select-Object -Last 30) -join "`n"
            throw "$([System.IO.Path]::GetFileName($exe)) exited with code $LASTEXITCODE`nCommand: $shownArgs`n$detail"
        }
    } finally {
        $ErrorActionPreference = $old
    }
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
        "palettegen=max_colors=${colors}:stats_mode=single"
    } else {
        "palettegen=stats_mode=single"
    }
    return "[0:v]$pre,split[a][b];[a]$paletteGen[p];[b][p]paletteuse=dither=sierra2_4a"
}

function New-VideoFilter($dim, $colors, $fps, $seconds, $maxFrames, [bool]$useMipPalette, [bool]$skipSimilar) {
    $parts = New-Object System.Collections.Generic.List[string]
    if (Has-Value $fps) { [void]$parts.Add("fps=$fps") }
    $scale = New-ScaleExpr $dim
    if (Has-Value $scale) { [void]$parts.Add($scale) }

    # Near-duplicate frames are skipped only when the user explicitly asks for a
    # byte/frame limit. With no limits supplied, the script keeps the source
    # cadence instead of doing hidden compression.
    if ($skipSimilar) { [void]$parts.Add("mpdecimate") }
    if (Has-Value $fps) {
        [void]$parts.Add("setpts=N/($fps*TB)")
    } else {
        [void]$parts.Add("setpts=PTS-STARTPTS")
    }

    if ((Has-Value $seconds) -and $seconds -gt 0) {
        [void]$parts.Add("trim=duration=$(Format-DoubleArg $seconds)")
    }
    if (Has-Value $maxFrames) {
        [void]$parts.Add("trim=end_frame=$maxFrames")
    }
    [void]$parts.Add("format=rgba")

    $pre = Join-Filters ($parts.ToArray())
    if ($useMipPalette) {
        return "[0:v]$pre[v];[v][1:v]paletteuse=dither=sierra2_4a"
    }
    $paletteGen = if (Has-Value $colors) {
        "palettegen=max_colors=${colors}:stats_mode=diff"
    } else {
        "palettegen=stats_mode=diff"
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
    [double]$start
) {
    $args = @("-hide_banner", "-loglevel", "error", "-y")
    if ($video -and $start -gt 0) {
        $args += @("-ss", ([string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0:0.###}", $start)))
    }
    $args += @("-i", $inputPath)
    if ($palettePath -ne $null -and $palettePath.Length -gt 0) {
        $args += @("-i", $palettePath)
    }
    $args += @("-an", "-filter_complex", $filter)
    if (-not $video) {
        $args += @("-frames:v", "1")
    }
    $args += @($outputGif)
    Invoke-Checked $ffmpeg $args
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
        48
    ) 1 | Where-Object { $_ -le $maxDim }
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
    return Get-UniqueNumbers @(
        $fps,
        [int]($fps * 0.80),
        [int]($fps * 0.65),
        [int]($fps * 0.50),
        [int]($fps * 0.35),
        2,
        1
    ) 1 | Where-Object { $_ -le $fps }
}

function New-SecondsCandidates($seconds, [bool]$sizeLimited) {
    if (-not (Has-Value $seconds)) { return @($null) }
    if (-not $sizeLimited -or $seconds -le 0) { return @($seconds) }
    return @(
        $seconds,
        [Math]::Max(1.0, $seconds * 0.75),
        [Math]::Max(1.0, $seconds * 0.55),
        [Math]::Max(1.0, $seconds * 0.38)
    )
}

function New-FrameCandidates($maxFrames, [bool]$sizeLimited) {
    if (-not (Has-Value $maxFrames)) { return @($null) }
    if (-not $sizeLimited) { return @($maxFrames) }
    return Get-UniqueNumbers @(
        $maxFrames,
        [int]($maxFrames * 0.75),
        [int]($maxFrames * 0.55),
        [int]($maxFrames * 0.38),
        1
    ) 1 | Where-Object { $_ -le $maxFrames }
}

function Format-CandidateLabel($value, [string]$noneLabel) {
    if (Has-Value $value) { return $value.ToString() }
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
    $MaxKB = Convert-OptionalIntParam "MaxKB" $MaxKB
    $MaxDim = Convert-OptionalIntParam "MaxDim" $MaxDim
    $Fps = Convert-OptionalIntParam "Fps" $Fps
    $Seconds = Convert-OptionalDoubleParam "Seconds" $Seconds
    $MaxFrames = Convert-OptionalIntParam "MaxFrames" $MaxFrames
    $MaxColors = Convert-OptionalIntParam "MaxColors" $MaxColors
    $Start = Convert-DoubleParam "Start" $Start

    if (Has-Value $MaxKB) { Assert-Min "MaxKB" $MaxKB 1 }
    if (Has-Value $MaxDim) { Assert-Min "MaxDim" $MaxDim 1 }
    if (Has-Value $Fps) { Assert-Min "Fps" $Fps 1 }
    if (Has-Value $Seconds) { Assert-Min "Seconds" $Seconds 0 }
    if (Has-Value $MaxFrames) { Assert-Min "MaxFrames" $MaxFrames 1 }
    if (Has-Value $MaxColors) { Assert-Range "MaxColors" $MaxColors 2 256 }
    Assert-Min "Start" $Start 0
    Assert-OneOf "Mode" $Mode @("auto", "image", "video")

    if (-not $Path) { $Path = Pick-Input }
    if (-not (Test-Path -LiteralPath $Path)) {
        Fail-Usage "Input file not found: $Path"
    }
    $inFull = (Resolve-Path -LiteralPath $Path).Path
    $ffmpeg = Find-Tool "ffmpeg.exe"
    $ffprobe = $null
    try {
        $ffprobe = Find-Tool "ffprobe.exe"
    } catch {
        Write-Warning "ffprobe.exe not found; conversion still works, but output frame count is estimated/unknown."
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

$isVideo = if ($Mode -eq "video") { $true } elseif ($Mode -eq "image") { $false } else { Is-VideoPath $inFull }
$sizeLimited = Has-Value $MaxKB
$maxBytes = if ($sizeLimited) { [int64]$MaxKB * 1024 } else { 0 }
$tmpDir = Join-Path $env:TEMP ("edc-photo-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmpDir | Out-Null
$mipPalettePath = Join-Path $tmpDir "garmin-mip-rgb222-64.ppm"
Write-GarminMip64Palette $mipPalettePath

    $paletteMode = if (-not (Has-Value $MaxColors)) {
        "dynamic<=256"
    } elseif ($MaxColors -eq 64) {
        "GarminMIP64"
    } elseif ($MaxColors -gt 64) {
        "dynamic<=${MaxColors}, fallback=GarminMIP64"
    } else {
        "dynamic<=${MaxColors}"
    }
    $limits = New-Object System.Collections.Generic.List[string]
    if ($sizeLimited) { [void]$limits.Add("max=${MaxKB}KB") }
    if (Has-Value $MaxDim) { [void]$limits.Add("dim<=${MaxDim}") }
    if ($isVideo -and (Has-Value $Fps)) { [void]$limits.Add("fps<=${Fps}") }
    if ($isVideo -and (Has-Value $Seconds)) { [void]$limits.Add("sec<=${Seconds}") }
    if ($isVideo -and (Has-Value $MaxFrames)) { [void]$limits.Add("frames<=${MaxFrames}") }
    if (Has-Value $MaxColors) { [void]$limits.Add("colors<=${MaxColors}") }
    if ($limits.Count -eq 0) { [void]$limits.Add("unrestricted") }

    Write-Host "[input] $inFull" -ForegroundColor Cyan
    Write-Host "[mode]  $(if ($isVideo) { 'video' } else { 'image' })  $($limits -join ' ') palette=$paletteMode" -ForegroundColor Cyan

    $dims = @(New-DimCandidates $MaxDim $sizeLimited)
    $colorCandidates = @(New-ColorCandidates $MaxColors $sizeLimited)
    $fpsCandidates = @(New-FpsCandidates $Fps $sizeLimited)
    $secondsCandidates = @(New-SecondsCandidates $Seconds $sizeLimited)
    $frameCandidates = @(New-FrameCandidates $MaxFrames $sizeLimited)

    $bestPath = $null
    $bestInfo = $null
    $attempt = 0

    $dimIndex = 0
    $colorIndex = 0
    $fpsIndex = 0
    $secIndex = 0
    $frameIndex = 0
    $maxAttempts = if ($sizeLimited) { if ($isVideo) { 96 } else { 48 } } else { 1 }

    while ($attempt -lt $maxAttempts) {
        $dim = $dims[$dimIndex]
        $colors = $colorCandidates[$colorIndex]
        $fpsTry = $fpsCandidates[$fpsIndex]
        $sec = $secondsCandidates[$secIndex]
        $maxFramesTry = $frameCandidates[$frameIndex]

        $attempt++
        $tmpGif = Join-Path $tmpDir ("try-$attempt.gif")
        $useMipPalette = ((Has-Value $colors) -and $colors -eq 64)
        $paletteArg = if ($useMipPalette) { $mipPalettePath } else { $null }
        if ($isVideo) {
            $skipSimilar = ($sizeLimited -or (Has-Value $maxFramesTry))
            $f = New-VideoFilter $dim $colors $fpsTry $sec $maxFramesTry $useMipPalette $skipSimilar
            Invoke-EncodeGif $ffmpeg $inFull $tmpGif $f $paletteArg $true $Start
        } else {
            $f = New-ImageFilter $dim $colors $useMipPalette
            Invoke-EncodeGif $ffmpeg $inFull $tmpGif $f $paletteArg $false 0
        }

        $size = (Get-Item $tmpGif).Length
        $frames = if ($isVideo) { Get-GifFrameCount $ffprobe $tmpGif } else { 1 }
        $frameLabel = if ($frames -lt 0) { "?" } else { $frames.toString() }
        $kb = [Math]::Round($size / 1024.0, 1)
        $videoLabel = if ($isVideo) {
            " fps=$(Format-CandidateLabel $fpsTry 'source') sec=$(Format-CandidateLabel $sec 'full') cap=$(Format-CandidateLabel $maxFramesTry 'none')"
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
                Seconds = $sec; MaxFrames = $maxFramesTry; Frames = $frames
            }
            break
        }

        # Degrade in watch-friendly order:
        #   1. if the user asked for >64 colors, step down toward the watch palette;
        #   2. try smaller dimensions while preserving Garmin MIP 64 colors;
        #   3. then reduce fps/clip seconds for video;
        #   4. only then go below 64 colors if the byte limit still cannot be met.
        if ($colorIndex + 1 -lt $colorCandidates.Count -and (Has-Value $colors) -and $colors -gt 64) {
            $colorIndex++
        } elseif ($dimIndex + 1 -lt $dims.Count) {
            $dimIndex++
        } elseif ($isVideo -and $fpsIndex + 1 -lt $fpsCandidates.Count) {
            $fpsIndex++
        } elseif ($isVideo -and $frameIndex + 1 -lt $frameCandidates.Count) {
            $frameIndex++
        } elseif ($isVideo -and $secIndex + 1 -lt $secondsCandidates.Count) {
            $secIndex++
        } elseif ($colorIndex + 1 -lt $colorCandidates.Count) {
            $colorIndex++
        } else {
            break
        }
    }

    if (-not $bestPath) {
        throw "Could not fit under ${MaxKB}KB with the limits you supplied. Add or lower -MaxDim, -Fps, -Seconds, -MaxFrames, or -MaxColors, or increase -MaxKB."
    }

    Copy-Item -Path $bestPath -Destination $gifOut -Force
    $bytes = [System.IO.File]::ReadAllBytes($gifOut)
    $b64 = [Convert]::ToBase64String($bytes)
    [System.IO.File]::WriteAllText($b64Out, $b64, [System.Text.Encoding]::ASCII)

    $finalFrames = if ([int]$bestInfo.Frames -lt 0) { "?" } else { $bestInfo.Frames.toString() }
    Write-Host ""
    Write-Host ("[GIF] {0} bytes ({1}KB), frames={2}, dim={3}, colors={4}" -f
        $bestInfo.Size,
        [Math]::Round($bestInfo.Size / 1024.0, 1),
        $finalFrames,
        (Format-DimLabel $bestInfo.Dim),
        (Format-CandidateLabel $bestInfo.Colors "auto")) -ForegroundColor Green
    Write-Host "[saved] $gifOut" -ForegroundColor Green
    Write-Host ("[saved] {0} ({1} chars)" -f $b64Out, $b64.Length) -ForegroundColor Green
    Write-Host ""
    Write-Host "Use Photo Album -> + Add -> URL, pointing to a raw text file containing the .b64 contents." -ForegroundColor Yellow
} catch {
    Fail-Usage $_.Exception.Message
} finally {
    if ($tmpDir -eq $null) {
        # Error happened before temp directory creation.
    } elseif ($KeepTemp) {
        Write-Host "[temp] $tmpDir" -ForegroundColor Yellow
    } else {
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
