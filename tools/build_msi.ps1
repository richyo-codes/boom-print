param(
  [string]$Configuration = "Release",
  [string]$BundleDir = "",
  [string]$OutputDir = "",
  [string]$ProductName = "BoomPrint",
  [string]$Manufacturer = "RND Software",
  [string]$ProductVersion = ""
)

$ErrorActionPreference = "Stop"

function Convert-ToMsiVersion {
  param([string]$InputVersion)

  if ([string]::IsNullOrWhiteSpace($InputVersion)) {
    return "1.0.0"
  }

  $normalized = $InputVersion.Trim()
  if ($normalized.StartsWith("v")) {
    $normalized = $normalized.Substring(1)
  }

  $semverMatch = [regex]::Match($normalized, "^(?<maj>\d+)\.(?<min>\d+)\.(?<pat>\d+)")
  if ($semverMatch.Success) {
    return "$($semverMatch.Groups['maj'].Value).$($semverMatch.Groups['min'].Value).$($semverMatch.Groups['pat'].Value)"
  }

  $digits = [regex]::Matches($normalized, "\d+") | ForEach-Object { $_.Value }
  if ($digits.Count -ge 3) {
    return "$($digits[0]).$($digits[1]).$($digits[2])"
  }
  if ($digits.Count -eq 2) {
    return "$($digits[0]).$($digits[1]).0"
  }
  if ($digits.Count -eq 1) {
    return "$($digits[0]).0.0"
  }

  return "1.0.0"
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$bundlePath = if ([string]::IsNullOrWhiteSpace($BundleDir)) {
  Join-Path $repoRoot "build/windows/x64/runner/$Configuration"
} else {
  $BundleDir
}
$bundlePath = (Resolve-Path $bundlePath).Path

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
  $OutputDir = Join-Path $repoRoot "build/windows/x64/installer"
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$OutputDir = (Resolve-Path $OutputDir).Path

$exePath = Join-Path $bundlePath "boomprint.exe"
if (!(Test-Path $exePath)) {
  throw "Expected app bundle executable not found: $exePath"
}

if ([string]::IsNullOrWhiteSpace($ProductVersion)) {
  try {
    $gitVersion = (git describe --always --tags --dirty 2>$null).Trim()
  } catch {
    $gitVersion = ""
  }
  $ProductVersion = Convert-ToMsiVersion -InputVersion $gitVersion
} else {
  $ProductVersion = Convert-ToMsiVersion -InputVersion $ProductVersion
}

if (!(Get-Command dotnet -ErrorAction SilentlyContinue)) {
  throw "dotnet was not found; it is required to install or update WiX."
}

if (Get-Command wix -ErrorAction SilentlyContinue) {
  dotnet tool update --global wix --version 7.*
} else {
  dotnet tool install --global wix --version 7.*
}
$env:PATH = "$env:USERPROFILE\.dotnet\tools;$env:PATH"

$wixPath = Join-Path $repoRoot "windows/installer/Product.wxs"
if (!(Test-Path $wixPath)) {
  throw "WiX source not found: $wixPath"
}

$msiName = "boomprint-$ProductVersion.msi"
$msiPath = Join-Path $OutputDir $msiName

Write-Host "Building MSI from bundle: $bundlePath"
Write-Host "MSI version: $ProductVersion"
Write-Host "Output: $msiPath"

& wix build $wixPath `
  -arch x64 `
  -d "SourceDir=$bundlePath" `
  -d "ProductName=$ProductName" `
  -d "Manufacturer=$Manufacturer" `
  -d "ProductVersion=$ProductVersion" `
  -o $msiPath

if ($LASTEXITCODE -ne 0) {
  throw "WiX build failed with exit code $LASTEXITCODE"
}

Write-Host "MSI build completed: $msiPath"
