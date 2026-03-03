#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Validates the template end-to-end: pack, install, scaffold, build.
.DESCRIPTION
    Performs a local validation cycle:
    1. Packs the template NuGet package
    2. Installs it locally
    3. Scaffolds an Alloy project + Aspire overlay
    4. Runs the post-setup migration script
    5. Builds the generated solution
.EXAMPLE
    ./eng/validate-template.ps1
    ./eng/validate-template.ps1 -ProjectName TestValidation
#>
param(
    [string]$ProjectName = 'ValidationTest',
    [switch]$SkipPack,
    [switch]$KeepOutput
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path $PSScriptRoot -Parent
$ArtifactsDir = Join-Path $RepoRoot 'artifacts'
$TestDir = Join-Path $RepoRoot '.test-output' $ProjectName

# ── Step 1: Pack ──────────────────────────────────────────────────────────────
if (-not $SkipPack) {
    Write-Host "`n[1/6] Packing template..." -ForegroundColor Yellow
    & "$PSScriptRoot/pack.ps1" -OutputDir $ArtifactsDir
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} else {
    Write-Host "`n[1/6] Skipping pack (using existing artifact)" -ForegroundColor DarkGray
}

$pkg = Get-ChildItem $ArtifactsDir -Filter '*.nupkg' | Select-Object -First 1
if (-not $pkg) {
    Write-Error "No .nupkg found in $ArtifactsDir. Run without -SkipPack."
    exit 1
}

# ── Step 2: Install template ─────────────────────────────────────────────────
Write-Host "`n[2/6] Installing template..." -ForegroundColor Yellow

# Uninstall first (ignore errors if not installed)
dotnet new uninstall AvantiBit.Optimizely.Templates 2>$null
dotnet new install $pkg.FullName
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# ── Step 3: Scaffold Alloy project ──────────────────────────────────────────
Write-Host "`n[3/6] Scaffolding Alloy project..." -ForegroundColor Yellow

if (Test-Path $TestDir) {
    Remove-Item $TestDir -Recurse -Force
}
New-Item -ItemType Directory -Path $TestDir -Force | Out-Null

Push-Location $TestDir
try {
    dotnet new epi-alloy-mvc -n $ProjectName
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    # ── Step 4: Scaffold Aspire overlay ──────────────────────────────────────
    Write-Host "`n[4/6] Scaffolding Aspire overlay..." -ForegroundColor Yellow
    dotnet new alloy-aspire-scaffold -n $ProjectName
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    # ── Step 5: Verify key files ─────────────────────────────────────────────
    Write-Host "`n[5/6] Verifying output..." -ForegroundColor Yellow

    $checks = @(
        @{ Path = "$ProjectName.slnx"; Desc = "Solution file" },
        @{ Path = "$ProjectName.AppHost/$ProjectName.AppHost.csproj"; Desc = "AppHost project" },
        @{ Path = "$ProjectName.ServiceDefaults/$ProjectName.ServiceDefaults.csproj"; Desc = "ServiceDefaults project" },
        @{ Path = "$ProjectName/$ProjectName.csproj"; Desc = "Alloy project (in subdirectory)" }
    )

    $allOk = $true
    foreach ($check in $checks) {
        if (Test-Path $check.Path) {
            Write-Host "  OK   $($check.Desc)" -ForegroundColor Green
        } else {
            Write-Host "  FAIL $($check.Desc): $($check.Path) not found" -ForegroundColor Red
            $allOk = $false
        }
    }

    # Verify parameter substitutions
    $appHostProgram = Get-Content "$ProjectName.AppHost/Program.cs" -Raw
    if ($appHostProgram -match "WithReplicas\(2\)") {
        Write-Host "  OK   Instance count parameter applied" -ForegroundColor Green
    } else {
        Write-Host "  WARN Instance count may not have been substituted" -ForegroundColor Yellow
    }
    if ($appHostProgram -match 'RoundRobin') {
        Write-Host "  OK   LB strategy parameter applied" -ForegroundColor Green
    } else {
        Write-Host "  WARN LB strategy may not have been substituted" -ForegroundColor Yellow
    }

    # Verify CMS 13 migration was applied
    $csproj = Get-Content "$ProjectName/$ProjectName.csproj" -Raw
    if ($csproj -match 'net10\.0') {
        Write-Host "  OK   TFM migrated to net10.0" -ForegroundColor Green
    } else {
        Write-Host "  WARN TFM migration may not have been applied" -ForegroundColor Yellow
    }
    if ($csproj -match '13\.0\.0-preview3') {
        Write-Host "  OK   EPiServer.CMS bumped to 13.0.0-preview3" -ForegroundColor Green
    } else {
        Write-Host "  WARN EPiServer.CMS version bump may not have been applied" -ForegroundColor Yellow
    }

    if (-not $allOk) {
        Write-Error "Validation failed - missing expected files"
        exit 1
    }

    # ── Step 6: Build ────────────────────────────────────────────────────────
    Write-Host "`n[6/6] Building solution..." -ForegroundColor Yellow
    dotnet restore "$ProjectName.slnx"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    dotnet build "$ProjectName.slnx" --no-restore
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Write-Host "`nValidation PASSED" -ForegroundColor Green
} finally {
    Pop-Location

    if (-not $KeepOutput) {
        Write-Host "Cleaning up test output..." -ForegroundColor DarkGray
        Remove-Item $TestDir -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "Test output kept at: $TestDir" -ForegroundColor Cyan
    }
}
