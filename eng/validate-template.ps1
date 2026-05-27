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
    dotnet new alloy-aspire-scaffold -n $ProjectName --allow-scripts Yes
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
        Write-Host "  OK   Instance count parameter applied (default 2)" -ForegroundColor Green
    } else {
        Write-Host "  WARN Instance count may not have been substituted" -ForegroundColor Yellow
    }
    if ($appHostProgram -match 'RoundRobin') {
        Write-Host "  OK   LB strategy parameter applied" -ForegroundColor Green
    } else {
        Write-Host "  WARN LB strategy may not have been substituted" -ForegroundColor Yellow
    }

    # Verify overlay was applied (CMS 13 GA assumed — no migration)
    $csproj = Get-Content "$ProjectName/$ProjectName.csproj" -Raw
    if ($csproj -match 'net10\.0') {
        Write-Host "  OK   TFM is net10.0 (upstream)" -ForegroundColor Green
    } else {
        Write-Host "  FAIL TFM is not net10.0" -ForegroundColor Red
        $allOk = $false
    }
    if ($csproj -match 'EPiServer\.Azure"\s+Version="13\.0\.2"') {
        Write-Host "  OK   EPiServer.Azure 13.0.2 added" -ForegroundColor Green
    } else {
        Write-Host "  FAIL EPiServer.Azure 13.0.2 reference missing" -ForegroundColor Red
        $allOk = $false
    }
    $startup = Get-Content "$ProjectName/Startup.cs" -Raw -ErrorAction SilentlyContinue
    if ($startup -and ($startup -match 'AddAzureBlobProvider') -and ($startup -match 'AddAzureEventProvider')) {
        Write-Host "  OK   Azure blob + event providers wired in Startup.cs" -ForegroundColor Green
    } else {
        Write-Host "  FAIL Azure provider registrations missing from Startup.cs" -ForegroundColor Red
        $allOk = $false
    }

    # ── aspire#14041 workaround checks ──────────────────────────────────────
    if (Test-Path "$ProjectName/SplitConnectionServiceBusSetup.cs") {
        Write-Host "  OK   SplitConnectionServiceBusSetup.cs in web project (aspire#14041 workaround)" -ForegroundColor Green
    } else {
        Write-Host "  FAIL SplitConnectionServiceBusSetup.cs missing from $ProjectName/ (aspire#14041 workaround)" -ForegroundColor Red
        $allOk = $false
    }
    if ($startup -and $startup -match 'services\.Replace\(\s*ServiceDescriptor\.Transient<IServiceBusSetup,\s*SplitConnectionServiceBusSetup>') {
        Write-Host "  OK   IServiceBusSetup swap injected in Startup.cs (aspire#14041 workaround)" -ForegroundColor Green
    } else {
        Write-Host "  FAIL services.Replace<IServiceBusSetup> missing from Startup.cs (aspire#14041 workaround)" -ForegroundColor Red
        $allOk = $false
    }
    if ($appHostProgram -match 'AdminConnectionString' -and $appHostProgram -match 'emulatorhealth') {
        Write-Host "  OK   AppHost injects AdminConnectionString from emulatorhealth endpoint" -ForegroundColor Green
    } else {
        Write-Host "  FAIL AppHost missing AdminConnectionString env-var block (aspire#14041 workaround)" -ForegroundColor Red
        $allOk = $false
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
