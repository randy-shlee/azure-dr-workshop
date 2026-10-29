#requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$assets = Join-Path $root 'workshop\assets'
$text = [IO.File]::ReadAllText((Join-Path $assets 'architecture.template.svg'))
$text = [regex]::Replace($text, '__ICON_([a-z-]+)__', {
    param($match)
    $file = Join-Path $assets "azure-icons\$($match.Groups[1].Value).svg"
    if (-not (Test-Path -LiteralPath $file)) { throw "Missing official Azure icon: $file" }
    'data:image/svg+xml;base64,' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($file))
})
if ($text -match '__ICON_') { throw 'Unresolved diagram icon placeholder.' }
$null = [xml]$text
[IO.File]::WriteAllText((Join-Path $assets 'architecture.svg'), $text, [Text.UTF8Encoding]::new($false))
Write-Output 'Rendered self-contained workshop architecture.svg using unchanged official Azure SVG icons.'
