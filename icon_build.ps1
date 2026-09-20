$base = 'd:\Madeira\Madeira\app\Madeira\Assets.xcassets\AppIcon.appiconset'
New-Item -ItemType Directory -Force -Path $base | Out-Null

$entries = @(
  @{ name='icon_20.png'; size=20 },
  @{ name='icon_20@2x.png'; size=40 },
  @{ name='icon_20@3x.png'; size=60 },
  @{ name='icon_29.png'; size=29 },
  @{ name='icon_29@2x.png'; size=58 },
  @{ name='icon_29@3x.png'; size=87 },
  @{ name='icon_40.png'; size=40 },
  @{ name='icon_40@2x.png'; size=80 },
  @{ name='icon_40@3x.png'; size=120 },
  @{ name='icon_60@2x.png'; size=120 },
  @{ name='icon_60@3x.png'; size=180 },
  @{ name='icon_76.png'; size=76 },
  @{ name='icon_76@2x.png'; size=152 },
  @{ name='icon_83.5@2x.png'; size=167 },
  @{ name='icon_1024.png'; size=1024 }
)

Add-Type -AssemblyName System.Drawing

foreach ($entry in $entries) {
    $size = [int]$entry.size
    $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb(255, 0, 0, 0))
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    $outerFrame = New-Object System.Drawing.RectangleF(8, 8, $size - 16, $size - 16)
    $outerPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $outerRadius = [float]($size * 0.18)
    $outerPath.AddArc($outerFrame.Left, $outerFrame.Top, $outerRadius * 2, $outerRadius * 2, 180, 90)
    $outerPath.AddArc($outerFrame.Right - ($outerRadius * 2), $outerFrame.Top, $outerRadius * 2, $outerRadius * 2, 270, 90)
    $outerPath.AddArc($outerFrame.Right - ($outerRadius * 2), $outerFrame.Bottom - ($outerRadius * 2), $outerRadius * 2, $outerRadius * 2, 0, 90)
    $outerPath.AddArc($outerFrame.Left, $outerFrame.Bottom - ($outerRadius * 2), $outerRadius * 2, $outerRadius * 2, 90, 90)
    $outerPath.CloseFigure()

    $blackBrush = [System.Drawing.Brushes]::Black
    $g.FillPath($blackBrush, $outerPath)

    $outlinePen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 26, 26, 26), [float](max(2, [math]::Floor($size / 35))))
    $g.DrawPath($outlinePen, $outerPath)

    $whiteBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 245, 245, 245))
    $shell = [System.Drawing.RectangleF]::FromLTRB($size * 0.18, $size * 0.20, $size * 0.82, $size * 0.76)
    $controllerPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $shellR = [float]($size * 0.13)
    $controllerPath.AddArc($shell.Left, $shell.Top, $shellR * 2, $shellR * 2, 180, 90)
    $controllerPath.AddArc($shell.Right - ($shellR * 2), $shell.Top, $shellR * 2, $shellR * 2, 270, 90)
    $controllerPath.AddArc($shell.Right - ($shellR * 2), $shell.Bottom - ($shellR * 2), $shellR * 2, $shellR * 2, 0, 90)
    $controllerPath.AddArc($shell.Left, $shell.Bottom - ($shellR * 2), $shellR * 2, $shellR * 2, 90, 90)
    $controllerPath.CloseFigure()
    $g.FillPath($whiteBrush, $controllerPath)

    $darkBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 18, 18, 18))
    $grayBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 90, 90, 90))

    $dpadW = [float]($size * 0.13)
    $dpadH = [float]($size * 0.19)
    $g.FillRectangle($darkBrush, [float]($size * 0.23), [float]($size * 0.36), $dpadW, $dpadH)
    $g.FillRectangle($darkBrush, [float]($size * 0.18), [float]($size * 0.42), [float]($size * 0.18), $dpadH)

    $stickR = [float]($size * 0.058)
    $g.FillEllipse($grayBrush, [float]($size * 0.28 - $stickR), [float]($size * 0.66 - $stickR), [float]($stickR * 2), [float]($stickR * 2))
    $g.FillEllipse($grayBrush, [float]($size * 0.70 - $stickR), [float]($size * 0.66 - $stickR), [float]($stickR * 2), [float]($stickR * 2))

    $btnR = [float]($size * 0.045)
    $btnPositions = @(
      ([float]($size * 0.70), [float]($size * 0.35)),
      ([float]($size * 0.80), [float]($size * 0.47)),
      ([float]($size * 0.70), [float]($size * 0.59)),
      ([float]($size * 0.60), [float]($size * 0.47))
    )

    $buttonColors = @(
      [System.Drawing.Color]::FromArgb(255, 62, 238, 127),
      [System.Drawing.Color]::FromArgb(255, 255, 92, 92),
      [System.Drawing.Color]::FromArgb(255, 92, 152, 255),
      [System.Drawing.Color]::FromArgb(255, 255, 214, 92)
    )

    for ($i = 0; $i -lt $btnPositions.Length; $i++) {
        $pt = $btnPositions[$i]
        $brush = New-Object System.Drawing.SolidBrush($buttonColors[$i])
        $g.FillEllipse($brush, [float]($pt[0] - $btnR), [float]($pt[1] - $btnR), [float]($btnR * 2), [float]($btnR * 2))
    }

    $g.Dispose()
    $bmp.Save((Join-Path $base $entry.name), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

$images = @(
  @{ idiom='iphone'; size='20x20'; scale='2x'; filename='icon_20@2x.png' },
  @{ idiom='iphone'; size='20x20'; scale='3x'; filename='icon_20@3x.png' },
  @{ idiom='iphone'; size='29x29'; scale='2x'; filename='icon_29@2x.png' },
  @{ idiom='iphone'; size='29x29'; scale='3x'; filename='icon_29@3x.png' },
  @{ idiom='iphone'; size='40x40'; scale='2x'; filename='icon_40@2x.png' },
  @{ idiom='iphone'; size='40x40'; scale='3x'; filename='icon_40@3x.png' },
  @{ idiom='iphone'; size='60x60'; scale='2x'; filename='icon_60@2x.png' },
  @{ idiom='iphone'; size='60x60'; scale='3x'; filename='icon_60@3x.png' },
  @{ idiom='ipad'; size='20x20'; scale='1x'; filename='icon_20.png' },
  @{ idiom='ipad'; size='29x29'; scale='1x'; filename='icon_29.png' },
  @{ idiom='ipad'; size='40x40'; scale='1x'; filename='icon_40.png' },
  @{ idiom='ipad'; size='76x76'; scale='1x'; filename='icon_76.png' },
  @{ idiom='ipad'; size='76x76'; scale='2x'; filename='icon_76@2x.png' },
  @{ idiom='ipad'; size='83.5x83.5'; scale='2x'; filename='icon_83.5@2x.png' },
  @{ idiom='ios-marketing'; size='1024x1024'; scale='1x'; filename='icon_1024.png' }
)

$json = @{ images = $images; info = @{ author='xcode'; version = 1 } } | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText((Join-Path $base 'Contents.json'), $json)

Write-Output "created $(Get-ChildItem $base -File | Measure-Object | Select-Object -ExpandProperty Count) files"
