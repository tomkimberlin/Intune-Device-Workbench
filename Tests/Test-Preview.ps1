# Off-screen visual bounds may include invisible children beyond the client area.
# Capturing them must not squeeze the visible UI or add an empty right gutter.
& {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName System.Drawing
    $savePreviewAst = $mainAst.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Save-WindowPreview'
    }, $true)
    . ([scriptblock]::Create($savePreviewAst.Extent.Text))
    $window = [Windows.Window]::new()
    $window.Background = [Windows.Media.Brushes]::White
    $root = [Windows.Controls.Canvas]::new()
    $root.Width = 320
    $root.Height = 180
    $root.Background = [Windows.Media.Brushes]::White
    $window.Content = $root

    $circle = [Windows.Shapes.Ellipse]::new()
    $circle.Width = 40
    $circle.Height = 40
    $circle.Fill = [Windows.Media.Brushes]::Blue
    [Windows.Controls.Canvas]::SetLeft($circle, 20)
    [Windows.Controls.Canvas]::SetTop($circle, 20)
    $null = $root.Children.Add($circle)

    $edge = [Windows.Shapes.Rectangle]::new()
    $edge.Width = 8
    $edge.Height = 180
    $edge.Fill = [Windows.Media.Brushes]::Green
    [Windows.Controls.Canvas]::SetLeft($edge, 312)
    $null = $root.Children.Add($edge)

    $overflow = [Windows.Shapes.Rectangle]::new()
    $overflow.Width = 80
    $overflow.Height = 30
    $overflow.Fill = [Windows.Media.Brushes]::Transparent
    [Windows.Controls.Canvas]::SetLeft($overflow, 400)
    $null = $root.Children.Add($overflow)

    $previewPath = Join-Path $testRoot 'Preview.Proportions.Test.png'
    try {
        $root.Measure([Windows.Size]::new(320, 180))
        $root.Arrange([Windows.Rect]::new(0, 0, 320, 180))
        $root.UpdateLayout()
        Save-WindowPreview -Path $previewPath
        $preview = [Drawing.Bitmap]::FromFile($previewPath)
        try {
            $circlePixels = @(0..319 | Where-Object {
                $pixel = $preview.GetPixel($_, 40)
                $pixel.B -gt 200 -and $pixel.R -lt 30 -and $pixel.G -lt 30
            })
            Assert-True -Condition ($circlePixels.Count -eq 40 -and $circlePixels[0] -eq 20) -Name 'Preview preserves visual proportions and positions despite invisible overflow'
            Assert-True -Condition ($preview.Width -eq 320 -and $preview.Height -eq 180 -and $preview.GetPixel(316, 90).ToArgb() -eq [Drawing.Color]::Green.ToArgb()) -Name 'Preview fills the client image through its right edge without an extra gutter'
        }
        finally { $preview.Dispose() }
    }
    finally {
        $window.Content = $null
        $window.Close()
        if (Test-Path -LiteralPath $previewPath) { Remove-Item -LiteralPath $previewPath -Force }
    }
}
