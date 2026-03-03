#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Packs the template into a NuGet package.
.DESCRIPTION
    Builds the AvantiBit.Optimizely.Templates NuGet package from the repo root.
    Output goes to ./artifacts/.
.EXAMPLE
    ./eng/pack.ps1
    ./eng/pack.ps1 -Configuration Release
#>
param(
    [string]$Configuration = 'Release',
    [string]$OutputDir = (Join-Path $PSScriptRoot '..' 'artifacts')
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path $PSScriptRoot -Parent

Push-Location $RepoRoot
try {
    Write-Host "Packing AvantiBit.Optimizely.Templates..." -ForegroundColor Cyan

    if (Test-Path $OutputDir) {
        Remove-Item "$OutputDir/*.nupkg" -Force -ErrorAction SilentlyContinue
    }

    dotnet pack AvantiBit.Optimizely.Templates.csproj `
        -c $Configuration `
        -o $OutputDir

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Pack failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }

    $pkg = Get-ChildItem $OutputDir -Filter '*.nupkg' | Select-Object -First 1
    Write-Host "Package created: $($pkg.FullName)" -ForegroundColor Green
} finally {
    Pop-Location
}
