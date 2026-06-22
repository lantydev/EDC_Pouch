<#
.SYNOPSIS
Convert PNG images to Garmin MIP-safe PNG-8.

.DESCRIPTION
Garmin MIP screens can display only a fixed RGB222 palette:
R/G/B each use one of 0, 85, 170, 255. That gives 64 visible colors.

This script converts true-color PNG images into indexed PNG-8 files whose
opaque pixels use only those 64 Garmin MIP colors. Transparent pixels are stored
in one extra transparent palette slot through PNG tRNS, so they do not remap to
a visible color.

The default dither algorithm is Floyd-Steinberg error diffusion with serpentine
scan. It usually looks much better than direct nearest-color remapping because
it avoids large flat color blocks.

Pipeline:
  PNG RGBA input
    -> optional resize
    -> RGB222 quantization
    -> optional Floyd-Steinberg dithering
    -> PNG-8 output with PLTE + tRNS

.PARAMETER InputPath
PNG file or folder containing PNG files.

.PARAMETER OutputDir
Output folder. Default: mip_out.

.PARAMETER Size
Square target size, for example -Size 240. Cannot be used with -Width/-Height.

.PARAMETER Width
Target width. If -Height is omitted, height is computed from the source aspect
ratio for each image.

.PARAMETER Height
Target height. If -Width is omitted, width is computed from the source aspect
ratio for each image.

.PARAMETER FitMode
Fit keeps the source aspect ratio and centers it on a transparent canvas.
Stretch fills the target rectangle and may distort the image. Default: Fit.
Valid values: Fit, Stretch.

.PARAMETER Dither
FloydSteinberg uses error diffusion dithering. None uses plain nearest-color
mapping. Default: FloydSteinberg.
Valid values: FloydSteinberg, None.

.PARAMETER AlphaThreshold
Pixels with alpha lower than this value become transparent. Default: 128.

.PARAMETER Recurse
When InputPath is a folder, also process PNGs in subfolders.

.PARAMETER Help
Print detailed usage and exit.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\convert_garmin_mip.ps1 -InputPath .\icon.png

Convert one PNG, keep its original size, write to .\mip_out\icon.png.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\convert_garmin_mip.ps1 -InputPath .\surf\items_64 -OutputDir .\surf\items_64_mip

Convert all PNG files directly inside .\surf\items_64.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\convert_garmin_mip.ps1 -InputPath .\_original -OutputDir .\MIP_240 -Size 240

Convert a folder to 240x240 Garmin MIP-safe PNG-8 images.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\convert_garmin_mip.ps1 -InputPath .\_original -OutputDir .\MIP_282x470 -Width 282 -Height 470

Convert a folder to a rectangular Garmin screen size.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\convert_garmin_mip.ps1 -InputPath .\surf_bg.png -Width 280

Resize to width 280 and automatically compute height from the source aspect
ratio.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\convert_garmin_mip.ps1 -InputPath .\icons -Dither None

Disable dithering. Useful for very flat pixel art or hard-edged UI icons.

.NOTES
If the script is called with missing or invalid values for its own parameters,
it prints the usage text automatically.
#>

param(
    [string]$InputPath,

    [string]$OutputDir = "mip_out",

    [int]$Size = 0,
    [int]$Width = 0,
    [int]$Height = 0,

    [string]$FitMode = "Fit",

    [string]$Dither = "FloydSteinberg",

    [int]$AlphaThreshold = 128,
    [switch]$Recurse,
    [Alias("h")]
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

function Show-Usage {
    $scriptName = Split-Path -Leaf $PSCommandPath
    Write-Output @"
Garmin MIP PNG conversion
=========================

Purpose
  Convert true-color PNG images to Garmin MIP-safe PNG-8.
  Opaque pixels use only the fixed RGB222 MIP colors:
    0, 85, 170, 255 per RGB channel = 64 visible colors.
  Transparent pixels use one extra transparent palette slot.

Default algorithm
  Floyd-Steinberg dithering, serpentine scan.

Usage
  powershell -ExecutionPolicy Bypass -File .\$scriptName -InputPath <file-or-folder> [options]

Required
  -InputPath <path>        PNG file, or folder containing PNG files.

Options
  -OutputDir <path>        Output folder. Default: mip_out
  -Size <n>                Square target size, e.g. -Size 240
  -Width <w>               Target width. Height is auto-computed if omitted.
  -Height <h>              Target height. Width is auto-computed if omitted.
  -Width <w> -Height <h>   Exact rectangular target size.
  -FitMode Fit|Stretch     Fit keeps aspect ratio. Stretch fills target. Default: Fit
  -Dither FloydSteinberg|None
                            FloydSteinberg reduces visible color blocks. Default: FloydSteinberg
  -AlphaThreshold <0-255>  Alpha below this value becomes transparent. Default: 128
  -Recurse                 Process subfolders when InputPath is a folder.
  -Help                    Print this help.

Examples
  # One image, keep original size:
  powershell -ExecutionPolicy Bypass -File .\$scriptName -InputPath .\icon.png

  # Folder of 64x64 icons:
  powershell -ExecutionPolicy Bypass -File .\$scriptName -InputPath .\surf\items_64 -OutputDir .\surf\items_64_mip

  # Square Garmin assets:
  powershell -ExecutionPolicy Bypass -File .\$scriptName -InputPath .\_original -OutputDir .\MIP_240 -Size 240

  # Rectangular Garmin assets:
  powershell -ExecutionPolicy Bypass -File .\$scriptName -InputPath .\_original -OutputDir .\MIP_282x470 -Width 282 -Height 470

  # Resize by width, keep aspect ratio:
  powershell -ExecutionPolicy Bypass -File .\$scriptName -InputPath .\surf_bg.png -Width 280

  # Resize by height, keep aspect ratio:
  powershell -ExecutionPolicy Bypass -File .\$scriptName -InputPath .\surf_bg.png -Height 166

  # No dithering for hard-edged icons:
  powershell -ExecutionPolicy Bypass -File .\$scriptName -InputPath .\icons -Dither None

Notes
  - Do not set -OutputDir to the same folder as the input files.
  - Use -Size OR -Width/-Height, not both.
  - If only -Width or only -Height is given, the other side is computed from
    each source image's aspect ratio.
  - Unknown PowerShell parameter names are rejected by PowerShell before the script can print this help.
"@
}

function Stop-WithUsage {
    param([string]$Message)
    Write-Output "ERROR: $Message"
    Write-Output ""
    Show-Usage
    exit 1
}

if ($Help) {
    Show-Usage
    exit 0
}

if ([string]::IsNullOrWhiteSpace($InputPath)) {
    Stop-WithUsage "Missing required parameter: -InputPath"
}

$fitModeValue = switch ($FitMode.ToLowerInvariant()) {
    "fit" { "Fit" }
    "stretch" { "Stretch" }
    default { $null }
}
if (-not $fitModeValue) {
    Stop-WithUsage "Invalid -FitMode '$FitMode'. Valid values: Fit, Stretch."
}
$FitMode = $fitModeValue

$ditherValue = switch ($Dither.ToLowerInvariant()) {
    "floydsteinberg" { "FloydSteinberg" }
    "fs" { "FloydSteinberg" }
    "none" { "None" }
    default { $null }
}
if (-not $ditherValue) {
    Stop-WithUsage "Invalid -Dither '$Dither'. Valid values: FloydSteinberg, None."
}
$Dither = $ditherValue

if ($Size -lt 0 -or $Width -lt 0 -or $Height -lt 0) {
    Stop-WithUsage "-Size, -Width and -Height must be zero or positive integers."
}

if ($Size -gt 0) {
    if ($Width -gt 0 -or $Height -gt 0) {
        Stop-WithUsage "Use either -Size or -Width/-Height, not both."
    }
    $Width = $Size
    $Height = $Size
}

if ($AlphaThreshold -lt 0 -or $AlphaThreshold -gt 255) {
    Stop-WithUsage "-AlphaThreshold must be in the range 0..255."
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    Stop-WithUsage "-OutputDir cannot be empty."
}

$resolvedInput = Resolve-Path -LiteralPath $InputPath -ErrorAction SilentlyContinue
if (-not $resolvedInput) {
    Stop-WithUsage "Input path not found: $InputPath"
}
$inputFull = [System.IO.Path]::GetFullPath($resolvedInput.Path)
if (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir = Join-Path (Get-Location).Path $OutputDir
}
$outputFull = [System.IO.Path]::GetFullPath($OutputDir)
if (-not (Test-Path -LiteralPath $outputFull)) {
    New-Item -ItemType Directory -Path $outputFull | Out-Null
}

$csharp = @'
using System;
using System.IO;
using System.IO.Compression;

public static class GarminMipPng8 {
    static uint[] crcT;
    static int[] L = new int[] { 0x00, 0x55, 0xAA, 0xFF };

    static GarminMipPng8() {
        crcT = new uint[256];
        for (uint n = 0; n < 256; n++) {
            uint c = n;
            for (int k = 0; k < 8; k++) {
                c = ((c & 1) != 0) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            }
            crcT[n] = c;
        }
    }

    static uint Crc(byte[] d) {
        uint c = 0xFFFFFFFFu;
        for (int i = 0; i < d.Length; i++) c = crcT[(c ^ d[i]) & 0xFF] ^ (c >> 8);
        return c ^ 0xFFFFFFFFu;
    }

    static uint Adler(byte[] d) {
        uint a = 1, b = 0;
        for (int i = 0; i < d.Length; i++) {
            a = (a + d[i]) % 65521u;
            b = (b + a) % 65521u;
        }
        return (b << 16) | a;
    }

    static byte[] Zlib(byte[] d) {
        using (var ms = new MemoryStream()) {
            ms.WriteByte(0x78);
            ms.WriteByte(0x9C);
            using (var ds = new DeflateStream(ms, CompressionLevel.Optimal, true)) {
                ds.Write(d, 0, d.Length);
            }
            uint a = Adler(d);
            ms.WriteByte((byte)((a >> 24) & 0xFF));
            ms.WriteByte((byte)((a >> 16) & 0xFF));
            ms.WriteByte((byte)((a >> 8) & 0xFF));
            ms.WriteByte((byte)(a & 0xFF));
            return ms.ToArray();
        }
    }

    public static byte[] Chunk(string type, byte[] data) {
        byte[] tb = System.Text.Encoding.ASCII.GetBytes(type);
        byte[] combo = new byte[tb.Length + data.Length];
        Buffer.BlockCopy(tb, 0, combo, 0, tb.Length);
        Buffer.BlockCopy(data, 0, combo, tb.Length, data.Length);
        uint crc = Crc(combo);

        byte[] outBytes = new byte[4 + combo.Length + 4];
        int len = data.Length;
        outBytes[0] = (byte)((len >> 24) & 0xFF);
        outBytes[1] = (byte)((len >> 16) & 0xFF);
        outBytes[2] = (byte)((len >> 8) & 0xFF);
        outBytes[3] = (byte)(len & 0xFF);
        Buffer.BlockCopy(combo, 0, outBytes, 4, combo.Length);

        int end = outBytes.Length - 4;
        outBytes[end] = (byte)((crc >> 24) & 0xFF);
        outBytes[end + 1] = (byte)((crc >> 16) & 0xFF);
        outBytes[end + 2] = (byte)((crc >> 8) & 0xFF);
        outBytes[end + 3] = (byte)(crc & 0xFF);
        return outBytes;
    }

    public static byte[] Ihdr(int w, int h) {
        byte[] r = new byte[13];
        r[0] = (byte)((w >> 24) & 0xFF);
        r[1] = (byte)((w >> 16) & 0xFF);
        r[2] = (byte)((w >> 8) & 0xFF);
        r[3] = (byte)(w & 0xFF);
        r[4] = (byte)((h >> 24) & 0xFF);
        r[5] = (byte)((h >> 16) & 0xFF);
        r[6] = (byte)((h >> 8) & 0xFF);
        r[7] = (byte)(h & 0xFF);
        r[8] = 8;  // bit depth
        r[9] = 3;  // indexed color
        r[10] = 0; // compression
        r[11] = 0; // filter
        r[12] = 0; // interlace
        return r;
    }

    public static byte[] Idat(byte[] idx, int w, int h) {
        byte[] raw = new byte[(w + 1) * h];
        for (int y = 0; y < h; y++) {
            raw[y * (w + 1)] = 0;
            Buffer.BlockCopy(idx, y * w, raw, y * (w + 1) + 1, w);
        }
        return Zlib(raw);
    }

    static int Q(float v) {
        if (v < 0f) v = 0f;
        if (v > 255f) v = 255f;
        if (v < 43f) return 0;
        if (v < 128f) return 1;
        if (v < 213f) return 2;
        return 3;
    }

    public static byte[] ConvertNearest(byte[] bgra, int w, int h, int stride, int alphaThreshold) {
        byte[] idx = new byte[w * h];
        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                int o = y * stride + x * 4;
                int p = y * w + x;
                byte bv = bgra[o];
                byte gv = bgra[o + 1];
                byte rv = bgra[o + 2];
                byte av = bgra[o + 3];
                if (av < alphaThreshold) {
                    idx[p] = 64;
                } else {
                    idx[p] = (byte)(Q(rv) * 16 + Q(gv) * 4 + Q(bv));
                }
            }
        }
        return idx;
    }

    public static byte[] ConvertFloydSteinberg(byte[] bgra, int w, int h, int stride, int alphaThreshold) {
        int n = w * h;
        float[] rB = new float[n];
        float[] gB = new float[n];
        float[] bB = new float[n];
        byte[] aB = new byte[n];

        for (int y = 0; y < h; y++) {
            for (int x = 0; x < w; x++) {
                int o = y * stride + x * 4;
                int p = y * w + x;
                bB[p] = bgra[o];
                gB[p] = bgra[o + 1];
                rB[p] = bgra[o + 2];
                aB[p] = bgra[o + 3];
            }
        }

        byte[] idx = new byte[n];
        for (int y = 0; y < h; y++) {
            bool rev = (y & 1) == 1;
            int xs = rev ? w - 1 : 0;
            int xe = rev ? -1 : w;
            int st = rev ? -1 : 1;

            for (int x = xs; x != xe; x += st) {
                int p = y * w + x;
                if (aB[p] < alphaThreshold) {
                    idx[p] = 64;
                    continue;
                }

                int ri = Q(rB[p]);
                int gi = Q(gB[p]);
                int bi = Q(bB[p]);
                int qr = L[ri];
                int qg = L[gi];
                int qb = L[bi];
                idx[p] = (byte)(ri * 16 + gi * 4 + bi);

                float er = rB[p] - qr;
                float eg = gB[p] - qg;
                float eb = bB[p] - qb;
                int dx = st;
                bool aheadOK = rev ? x > 0 : x < w - 1;
                bool behindOK = rev ? x < w - 1 : x > 0;

                if (aheadOK) {
                    int ni = p + dx;
                    rB[ni] += er * 7f / 16f;
                    gB[ni] += eg * 7f / 16f;
                    bB[ni] += eb * 7f / 16f;
                }
                if (y + 1 < h) {
                    int below = p + w;
                    if (behindOK) {
                        int ni = below - dx;
                        rB[ni] += er * 3f / 16f;
                        gB[ni] += eg * 3f / 16f;
                        bB[ni] += eb * 3f / 16f;
                    }
                    rB[below] += er * 5f / 16f;
                    gB[below] += eg * 5f / 16f;
                    bB[below] += eb * 5f / 16f;
                    if (aheadOK) {
                        int ni = below + dx;
                        rB[ni] += er * 1f / 16f;
                        gB[ni] += eg * 1f / 16f;
                        bB[ni] += eb * 1f / 16f;
                    }
                }
            }
        }
        return idx;
    }
}
'@

Add-Type -TypeDefinition $csharp -ReferencedAssemblies System.IO.Compression, System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Drawing

$levels = @(0x00, 0x55, 0xAA, 0xFF)
$plte = New-Object 'byte[]' (65 * 3)
$i = 0
foreach ($r in $levels) {
    foreach ($g in $levels) {
        foreach ($b in $levels) {
            $plte[$i * 3] = $r
            $plte[$i * 3 + 1] = $g
            $plte[$i * 3 + 2] = $b
            $i++
        }
    }
}
$plte[64 * 3] = 0xFF
$plte[64 * 3 + 1] = 0x00
$plte[64 * 3 + 2] = 0xFF

$trns = New-Object 'byte[]' 65
for ($j = 0; $j -lt 64; $j++) { $trns[$j] = 255 }
$trns[64] = 0

$sig = [byte[]]@(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
$plteChunk = [GarminMipPng8]::Chunk("PLTE", $plte)
$trnsChunk = [GarminMipPng8]::Chunk("tRNS", $trns)
$iendChunk = [GarminMipPng8]::Chunk("IEND", (New-Object 'byte[]' 0))

function Write-MipPng8 {
    param(
        [string]$Path,
        [int]$W,
        [int]$H,
        [byte[]]$Indices
    )

    $ihdrChunk = [GarminMipPng8]::Chunk("IHDR", [GarminMipPng8]::Ihdr($W, $H))
    $idatChunk = [GarminMipPng8]::Chunk("IDAT", [GarminMipPng8]::Idat($Indices, $W, $H))

    $fs = [System.IO.File]::Create($Path)
    try {
        $fs.Write($sig, 0, $sig.Length)
        $fs.Write($ihdrChunk, 0, $ihdrChunk.Length)
        $fs.Write($plteChunk, 0, $plteChunk.Length)
        $fs.Write($trnsChunk, 0, $trnsChunk.Length)
        $fs.Write($idatChunk, 0, $idatChunk.Length)
        $fs.Write($iendChunk, 0, $iendChunk.Length)
    } finally {
        $fs.Close()
    }
}

function Convert-OnePng {
    param([System.IO.FileInfo]$File)

    $srcBmp = [System.Drawing.Bitmap]::FromFile($File.FullName)
    try {
        $srcW = $srcBmp.Width
        $srcH = $srcBmp.Height
        if ($Width -gt 0 -and $Height -gt 0) {
            $dstW = $Width
            $dstH = $Height
        } elseif ($Width -gt 0) {
            $dstW = $Width
            $dstH = [math]::Max(1, [int][math]::Round($srcH * ([double]$Width / $srcW)))
        } elseif ($Height -gt 0) {
            $dstH = $Height
            $dstW = [math]::Max(1, [int][math]::Round($srcW * ([double]$Height / $srcH)))
        } else {
            $dstW = $srcW
            $dstH = $srcH
        }

        $canvas = New-Object System.Drawing.Bitmap $dstW, $dstH, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($canvas)
        try {
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            $g.Clear([System.Drawing.Color]::Transparent)

            if ($FitMode -eq "Fit") {
                $scale = [math]::Min([double]$dstW / $srcW, [double]$dstH / $srcH)
                $newW = [math]::Max(1, [int][math]::Round($srcW * $scale))
                $newH = [math]::Max(1, [int][math]::Round($srcH * $scale))
                $dx = [int][math]::Floor(($dstW - $newW) / 2)
                $dy = [int][math]::Floor(($dstH - $newH) / 2)
                $g.DrawImage($srcBmp, $dx, $dy, $newW, $newH)
            } else {
                $g.DrawImage($srcBmp, 0, 0, $dstW, $dstH)
            }
        } finally {
            $g.Dispose()
        }
    } finally {
        $srcBmp.Dispose()
    }

    try {
        $rect = New-Object System.Drawing.Rectangle 0, 0, $canvas.Width, $canvas.Height
        $bd = $canvas.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $stride = $bd.Stride
            $buf = New-Object 'byte[]' ($stride * $canvas.Height)
            [System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $buf, 0, $buf.Length)
        } finally {
            $canvas.UnlockBits($bd)
        }

        if ($Dither -eq "None") {
            $indices = [GarminMipPng8]::ConvertNearest($buf, $canvas.Width, $canvas.Height, $stride, $AlphaThreshold)
        } else {
            $indices = [GarminMipPng8]::ConvertFloydSteinberg($buf, $canvas.Width, $canvas.Height, $stride, $AlphaThreshold)
        }

        $outPath = Join-Path $outputFull $File.Name
        if ([System.IO.Path]::GetFullPath($outPath).Equals([System.IO.Path]::GetFullPath($File.FullName), [System.StringComparison]::OrdinalIgnoreCase)) {
            Stop-WithUsage "Refusing to overwrite input file: $($File.FullName). Choose a different -OutputDir."
        }

        Write-MipPng8 -Path $outPath -W $canvas.Width -H $canvas.Height -Indices $indices
        $outSize = (Get-Item -LiteralPath $outPath).Length
        Write-Output ("{0,-32} {1,4}x{2,-4} -> {3,4}x{4,-4} {5,8:N1} KB" -f $File.Name, $srcW, $srcH, $canvas.Width, $canvas.Height, ($outSize / 1KB))
    } finally {
        $canvas.Dispose()
    }
}

$inputItem = Get-Item -LiteralPath $inputFull
if ($inputItem.PSIsContainer) {
    $files = Get-ChildItem -LiteralPath $inputItem.FullName -Filter *.png -File -Recurse:$Recurse | Sort-Object FullName
} else {
    if ($inputItem.Extension.ToLowerInvariant() -ne ".png") {
        Stop-WithUsage "Input file must be a PNG: $($inputItem.FullName)"
    }
    $files = @($inputItem)
}

if ($files.Count -eq 0) {
    Stop-WithUsage "No PNG files found in input folder: $($inputItem.FullName)"
}

Write-Output ("Input:  {0}" -f $inputFull)
Write-Output ("Output: {0}" -f $outputFull)
Write-Output ("Files:  {0} PNG(s)" -f $files.Count)
Write-Output ("Mode:   RGB222 PNG-8, dither={0}, fit={1}, alpha<{2}=transparent" -f $Dither, $FitMode, $AlphaThreshold)
Write-Output ""

foreach ($file in $files) {
    Convert-OnePng -File $file
}

Write-Output ""
Write-Output "Done."
