#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Overlays Aspire orchestration onto an existing Optimizely CMS 13 Alloy project.

.DESCRIPTION
    This script is run as a post-action by 'dotnet new alloy-aspire-scaffold'.
    It expects to find a CMS 13 GA Alloy project (AlloyAspireScaffold.csproj) in the same directory.
    The sourceName replacement turns 'AlloyAspireScaffold' into the user's -n value.

    The script:
      - Validates the project is CMS 13 (fails fast on CMS 12 or unknown layouts)
      - Moves Alloy files into a clean subdirectory
      - Adds ServiceDefaults and EPiServer.Azure references
      - Wires the Azure blob and event providers to Aspire-injected connection strings
      - Maps health endpoints
      - Removes the LocalDB connection string
      - Cleans up .mdf/.ldf files (preserves DefaultSiteContent.episerverdata)
      - Moves nuget.config to solution root
      - Adds the Alloy project to .slnx
      - Self-deletes

    Every step is idempotent: re-running the script reports [skip] for already-applied steps
    and [apply] for new changes.

    The script does NOT migrate CMS 12 code. v1.0 of this template assumes upstream
    EPiServer.Templates >= 2.0.1 emits a CMS 13 GA project.
#>

$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot
$ProjectName = 'AlloyAspireScaffold'

$AzurePackageVersion = '13.0.2'
# Container name + topic name are set by the AppHost via env vars
# (EPiServer__Cms__AzureBlobProvider__ContainerName,
#  EPiServer__Cms__AzureEventProvider__TopicName), so they don't need
# to be hard-coded into the Alloy project's Startup.cs.

# ── Counters for end-of-run summary ──────────────────────────────────────────
$script:Applied = 0
$script:Skipped = 0

function Write-Apply { param([string]$Msg) Write-Host "  [apply] $Msg" -ForegroundColor Green; $script:Applied++ }
function Write-Skip  { param([string]$Msg) Write-Host "  [skip]  $Msg" -ForegroundColor DarkGray; $script:Skipped++ }
function Write-Fail  { param([string]$Msg) Write-Host "  [fail]  $Msg" -ForegroundColor Red }

# ── Locate the Alloy .csproj wherever it landed ──────────────────────────────
# Upstream Alloy may emit files flat in $ScriptDir, or inside a $ProjectName
# subdirectory. We also tolerate partial state from an interrupted prior run.
# Search order: canonical subdir, $ScriptDir root, then a shallow recursive fallback.
function Find-AlloyCsproj {
    param([string]$ScriptDir, [string]$ProjectName)

    $canonical = Join-Path $ScriptDir $ProjectName | Join-Path -ChildPath "$ProjectName.csproj"
    if (Test-Path $canonical) { return (Resolve-Path $canonical).Path }

    $rootLevel = Join-Path $ScriptDir "$ProjectName.csproj"
    if (Test-Path $rootLevel) { return (Resolve-Path $rootLevel).Path }

    # Fallback: shallow recursive search, skip overlay/build artefacts.
    $excludedRoots = @("$ProjectName.AppHost", "$ProjectName.ServiceDefaults")
    $found = Get-ChildItem -Path $ScriptDir -Filter "$ProjectName.csproj" -Recurse -Depth 3 -File -ErrorAction SilentlyContinue |
        Where-Object {
            $rel = $_.FullName.Substring($ScriptDir.Length).TrimStart('\','/')
            $firstSegment = ($rel -split '[\\/]')[0]
            ($firstSegment -notin $excludedRoots) -and ($rel -notmatch '[\\/](bin|obj)[\\/]')
        } |
        Select-Object -First 1
    if ($found) { return $found.FullName }

    return $null
}

# ============================================================================
# Validation gate: must be a CMS 13 Alloy project
# ============================================================================
Write-Host "Validating target directory..." -ForegroundColor Cyan

$CsprojPath = Find-AlloyCsproj -ScriptDir $ScriptDir -ProjectName $ProjectName

if (-not $CsprojPath) {
    Write-Warning "Could not locate '$ProjectName.csproj' under '$ScriptDir'."
    Write-Warning "This overlay template expects an existing Alloy project created with:"
    Write-Warning "  dotnet new epi-alloy-mvc -n $ProjectName"
    Write-Warning "(requires EPiServer.Templates >= 2.0.1, which produces CMS 13 GA code)"
    Write-Warning "AppHost and ServiceDefaults projects were generated, but the overlay was skipped."
    exit 0
}

Write-Host "  [ok]    Located Alloy csproj at: $CsprojPath" -ForegroundColor Green

$csprojContent = Get-Content $CsprojPath -Raw

# Look for any EPiServer.CMS* PackageReference and parse its version.
# Accepts both the meta-package (EPiServer.CMS) and the AspNetCore package.
$cmsMatch = [regex]::Match(
    $csprojContent,
    'PackageReference\s+Include="EPiServer\.CMS(?:\.AspNetCore)?"\s+Version="([^"]+)"'
)

if (-not $cmsMatch.Success) {
    Write-Host "  [fail]  Could not find an EPiServer.CMS PackageReference in $ProjectName.csproj." -ForegroundColor Red
    Write-Host "          Is this an Alloy project produced by EPiServer.Templates?" -ForegroundColor Red
    exit 1
}

$cmsVersionRaw = $cmsMatch.Groups[1].Value
$cmsMajor = [int]($cmsVersionRaw -split '[\.\-]')[0]

if ($cmsMajor -lt 13) {
    Write-Host "  [fail]  Detected EPiServer.CMS $cmsVersionRaw (major version $cmsMajor)." -ForegroundColor Red
    Write-Host "          This template requires CMS 13 GA. CMS 12 -> 13 migration is not in scope." -ForegroundColor Red
    Write-Host "          Upgrade the Alloy project via upstream Optimizely tooling first." -ForegroundColor Red
    exit 1
}

Write-Host "  [ok]    Detected EPiServer.CMS $cmsVersionRaw (CMS 13 GA)" -ForegroundColor Green
Write-Host ""
Write-Host "Overlaying Aspire orchestration onto '$ProjectName'..." -ForegroundColor Cyan

# ── Helpers ───────────────────────────────────────────────────────────────────
function Replace-InFile {
    param(
        [string]$Path,
        [string]$Find,
        [string]$Replace,
        [string]$Description,
        [switch]$Regex
    )
    if (-not (Test-Path $Path)) {
        Write-Skip "$Description (file not found)"
        return
    }
    $content = Get-Content $Path -Raw
    if ($null -eq $content) {
        Write-Skip "$Description (file empty)"
        return
    }
    if ($Regex) {
        if ($content -notmatch $Find) { Write-Skip $Description; return }
        $newContent = $content -replace $Find, $Replace
    } else {
        if (-not $content.Contains($Find)) { Write-Skip $Description; return }
        $newContent = $content.Replace($Find, $Replace)
    }
    Set-Content $Path -Value $newContent -NoNewline
    Write-Apply $Description
}

function Insert-AfterPattern {
    param(
        [string]$Path,
        [string]$Pattern,
        [string]$Insert,
        [string]$Guard,
        [string]$Description
    )
    if (-not (Test-Path $Path)) { Write-Skip "$Description (file not found)"; return }
    $content = Get-Content $Path -Raw
    if ($content -match [regex]::Escape($Guard)) { Write-Skip $Description; return }
    if ($content -notmatch $Pattern) { Write-Skip "$Description (anchor not found)"; return }
    $newContent = $content -replace $Pattern, "`$0$Insert"
    Set-Content $Path -Value $newContent -NoNewline
    Write-Apply $Description
}

function Add-Using {
    param(
        [string]$Path,
        [string]$Namespace,
        [string]$Description
    )
    if (-not (Test-Path $Path)) { Write-Skip "$Description (file not found)"; return }
    $content = Get-Content $Path -Raw
    $directive = "using $Namespace;"
    if ($content.Contains($directive)) { Write-Skip $Description; return }
    $newContent = $content -replace '(using [^;]+;\r?\n)(?!using )', "`$1$directive`n"
    if ($newContent -eq $content) {
        $newContent = "$directive`n$content"
    }
    Set-Content $Path -Value $newContent -NoNewline
    Write-Apply $Description
}

# ============================================================================
# 1. Reorganize: move Alloy web project into its own subdirectory
# ============================================================================
# The target layout is $ScriptDir/$ProjectName/<alloy files>. We use the
# discovered $CsprojPath (set during validation) to decide what to do:
#   - csproj already in the canonical subdir → nothing to do
#   - csproj at the $ScriptDir root          → move flat files into the subdir
#   - csproj somewhere else                  → preserve that location, skip reorg
# ============================================================================
Write-Host "`n[1/8] Reorganize solution layout" -ForegroundColor Yellow

$canonicalSubdir = Join-Path $ScriptDir $ProjectName
$canonicalCsproj = Join-Path $canonicalSubdir "$ProjectName.csproj"
$sourceDir = Split-Path $CsprojPath -Parent

if ($CsprojPath -ieq $canonicalCsproj) {
    $WebProjectDir = $canonicalSubdir
    Write-Skip "Reorganize (Alloy already in $ProjectName/ subdirectory)"
}
elseif ($sourceDir -ieq $ScriptDir) {
    # Flat layout. Move every non-overlay item into the canonical subdir.
    if (-not (Test-Path $canonicalSubdir)) {
        New-Item -ItemType Directory -Path $canonicalSubdir -Force | Out-Null
    }

    $overlayItems = @(
        "$ProjectName.slnx",
        "$ProjectName.AppHost",
        "$ProjectName.ServiceDefaults",
        'post-setup.ps1',
        $ProjectName
    )

    $moved = 0
    $conflicts = 0
    Get-ChildItem $ScriptDir -Force | Where-Object {
        $_.Name -notin $overlayItems
    } | ForEach-Object {
        $dest = Join-Path $canonicalSubdir $_.Name
        if (Test-Path $dest) {
            # Partial state from a previous interrupted run; leave existing target alone.
            $conflicts++
        } else {
            Move-Item $_.FullName -Destination $canonicalSubdir
            $moved++
        }
    }

    $WebProjectDir = $canonicalSubdir
    if ($moved -gt 0) {
        $msg = "Moved $moved Alloy item(s) into $ProjectName/"
        if ($conflicts -gt 0) { $msg += " ($conflicts item(s) already present in target)" }
        Write-Apply $msg
    } else {
        Write-Skip "Reorganize (all $conflicts item(s) already in target)"
    }
}
else {
    # Alloy lives in a non-canonical, non-flat location (e.g. nested deeper).
    # Don't risk a move; just operate on it in place.
    $WebProjectDir = $sourceDir
    Write-Host "  [info]  Alloy project located at non-canonical path; operating in place." -ForegroundColor DarkGray
    Write-Skip "Reorganize (non-canonical layout, preserving $WebProjectDir)"
}

$CsprojPath = Join-Path $WebProjectDir "$ProjectName.csproj"

if (-not (Test-Path $CsprojPath)) {
    Write-Fail "Expected $ProjectName.csproj at $CsprojPath after reorganize step, but it is missing."
    exit 1
}

# ============================================================================
# 2. Patch .csproj: add ServiceDefaults reference + EPiServer.Azure package
# ============================================================================
Write-Host "`n[2/8] Patch $ProjectName.csproj" -ForegroundColor Yellow

# 2a. Add EPiServer.Azure for distributed blob storage + event propagation
$csprojContent = Get-Content $CsprojPath -Raw
if ($csprojContent -match 'EPiServer\.Azure"\s+Version=') {
    Write-Skip "Add EPiServer.Azure package reference"
} else {
    Replace-InFile -Path $CsprojPath `
        -Find '<PackageReference Include="EPiServer.CMS"' `
        -Replace "<PackageReference Include=`"EPiServer.Azure`" Version=`"$AzurePackageVersion`" />`n    <PackageReference Include=`"EPiServer.CMS`"" `
        -Description "Add EPiServer.Azure $AzurePackageVersion package reference"
}

# 2b. Add ServiceDefaults project reference
$csprojContent = Get-Content $CsprojPath -Raw
if ($csprojContent -match 'ServiceDefaults') {
    Write-Skip "Add ServiceDefaults project reference"
} else {
    Replace-InFile -Path $CsprojPath `
        -Find '</Project>' `
        -Replace "
  <ItemGroup>
    <ProjectReference Include=`"..\$ProjectName.ServiceDefaults\$ProjectName.ServiceDefaults.csproj`" />
  </ItemGroup>
</Project>" `
        -Description 'Add ServiceDefaults project reference'
}

# ============================================================================
# 3. Patch Program.cs: add .AddServiceDefaults()
# ============================================================================
Write-Host "`n[3/8] Patch Program.cs" -ForegroundColor Yellow

$programPath = Join-Path $WebProjectDir 'Program.cs'
Insert-AfterPattern -Path $programPath `
    -Pattern '\.ConfigureCmsDefaults\(\)' `
    -Insert "`n    .AddServiceDefaults()" `
    -Guard 'AddServiceDefaults' `
    -Description 'Insert .AddServiceDefaults() after .ConfigureCmsDefaults()'

# ============================================================================
# 4. Patch Startup.cs: usings + Azure providers + health endpoints
# ============================================================================
Write-Host "`n[4/8] Patch Startup.cs" -ForegroundColor Yellow

$startupPath = Join-Path $WebProjectDir 'Startup.cs'

Add-Using -Path $startupPath -Namespace 'EPiServer.DependencyInjection' `
    -Description 'Add using EPiServer.DependencyInjection'
Add-Using -Path $startupPath -Namespace 'Microsoft.AspNetCore.Diagnostics.HealthChecks' `
    -Description 'Add using Microsoft.AspNetCore.Diagnostics.HealthChecks'

# 4a. Register Azure blob + event providers after the AddCms() chain.
#
# We inject parameter-less calls. The provider options (ConnectionString,
# ContainerName, TopicName) are populated by Optimizely's auto-binding to
# the EPiServer:Cms:AzureBlobProvider / EPiServer:Cms:AzureEventProvider
# config sections. The AppHost sets the corresponding env vars
# (EPiServer__Cms__AzureBlobProvider__ConnectionString etc.) so that
# Startup.cs needs no IConfiguration capture and no Aspire-specific code.
$azureProvidersBlock = @"


        services.AddAzureBlobProvider();
        services.AddAzureEventProvider();
"@

# Match `.AddCms()` and consume forward (across newlines) to the next semicolon.
# Upstream Alloy 2.0.1+ uses a chained-call shape:
#   services
#       .AddCmsAspNetIdentity<ApplicationUser>()
#       .AddCms()
#       .AddAlloy()
#       .AddEmbeddedLocalization<Startup>();
# so a literal `services.AddCms()` substring never appears. `[\s\S]*?` is
# non-greedy and matches across newlines, ending at the chain's terminating `;`.
Insert-AfterPattern -Path $startupPath `
    -Pattern '\.AddCms\(\)[\s\S]*?;' `
    -Insert $azureProvidersBlock `
    -Guard 'AddAzureBlobProvider' `
    -Description 'Register Azure blob + event providers after AddCms() chain'

# 4b. Map /health and /alive endpoints
$startupContent = Get-Content $startupPath -Raw
if ($startupContent -match 'MapHealthChecks') {
    Write-Skip 'Map /health and /alive endpoints'
} else {
    Replace-InFile -Path $startupPath `
        -Find 'endpoints.MapContent();' `
        -Replace 'endpoints.MapContent();
            endpoints.MapHealthChecks("/health");
            endpoints.MapHealthChecks("/alive", new HealthCheckOptions
            {
                Predicate = r => r.Tags.Contains("live")
            });' `
        -Description 'Map /health and /alive endpoints'
}

# ============================================================================
# 5. Remove LocalDB connection string from appsettings.Development.json
# ============================================================================
Write-Host "`n[5/8] Clean appsettings.Development.json" -ForegroundColor Yellow

$devSettingsPath = Join-Path $WebProjectDir 'appsettings.Development.json'
if (Test-Path $devSettingsPath) {
    try {
        $devSettings = Get-Content $devSettingsPath -Raw | ConvertFrom-Json
        if ($devSettings.ConnectionStrings -and $devSettings.ConnectionStrings.EPiServerDB) {
            $devSettings.ConnectionStrings.PSObject.Properties.Remove('EPiServerDB')
            if (($devSettings.ConnectionStrings.PSObject.Properties | Measure-Object).Count -eq 0) {
                $devSettings.PSObject.Properties.Remove('ConnectionStrings')
            }
            $devSettings | ConvertTo-Json -Depth 10 | Set-Content $devSettingsPath -NoNewline
            Write-Apply 'Removed LocalDB connection string from appsettings.Development.json'
        } else {
            Write-Skip 'Remove LocalDB connection string'
        }
    } catch {
        Write-Fail "Failed to parse appsettings.Development.json: $_"
    }
} else {
    Write-Skip 'Remove LocalDB connection string (file not found)'
}

# ============================================================================
# 6. Remove App_Data/*.mdf and *.ldf (preserve DefaultSiteContent.episerverdata)
# ============================================================================
Write-Host "`n[6/8] Clean App_Data database files" -ForegroundColor Yellow

$appDataPath = Join-Path $WebProjectDir 'App_Data'
if (Test-Path $appDataPath) {
    $dbFiles = Get-ChildItem $appDataPath -Include '*.mdf', '*.ldf' -File -ErrorAction SilentlyContinue
    if ($dbFiles) {
        foreach ($dbFile in $dbFiles) {
            Remove-Item $dbFile.FullName -Force
            Write-Apply "Removed App_Data/$($dbFile.Name)"
        }
    } else {
        Write-Skip 'Clean App_Data database files (none present)'
    }
} else {
    Write-Skip 'Clean App_Data database files (folder not found)'
}

# ============================================================================
# 7. Move nuget.config to solution root
# ============================================================================
Write-Host "`n[7/8] Move nuget.config to solution root" -ForegroundColor Yellow

$nugetConfigInWeb = Join-Path $WebProjectDir 'nuget.config'
$nugetConfigAtRoot = Join-Path $ScriptDir 'nuget.config'
if ((Test-Path $nugetConfigInWeb) -and -not (Test-Path $nugetConfigAtRoot)) {
    Move-Item $nugetConfigInWeb -Destination $nugetConfigAtRoot
    Write-Apply 'Moved nuget.config to solution root'
} elseif (Test-Path $nugetConfigAtRoot) {
    if (Test-Path $nugetConfigInWeb) { Remove-Item $nugetConfigInWeb -Force }
    Write-Skip 'Move nuget.config (already at solution root)'
} else {
    Write-Skip 'Move nuget.config (not found)'
}

# ============================================================================
# 8. Register Alloy project in .slnx
# ============================================================================
Write-Host "`n[8/8] Register $ProjectName in .slnx" -ForegroundColor Yellow

$slnxPath = Join-Path $ScriptDir "$ProjectName.slnx"
if (Test-Path $slnxPath) {
    $slnxContent = Get-Content $slnxPath -Raw
    $projectEntry = "  <Project Path=`"$ProjectName/$ProjectName.csproj`" />"
    if ($slnxContent -match [regex]::Escape("$ProjectName.csproj")) {
        Write-Skip "Register $ProjectName in .slnx"
    } else {
        Replace-InFile -Path $slnxPath `
            -Find '</Solution>' `
            -Replace "$projectEntry`n</Solution>" `
            -Description "Register $ProjectName in .slnx"
    }
} else {
    Write-Skip "Register $ProjectName in .slnx (.slnx not found)"
}

# ============================================================================
# Summary + self-delete
# ============================================================================
Write-Host ""
Write-Host "─────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "Overlay complete. Applied: $script:Applied  Skipped: $script:Skipped" -ForegroundColor Cyan
Write-Host "─────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. dotnet build $ProjectName.slnx"
Write-Host "  2. cd $ProjectName.AppHost && dotnet run"
Write-Host "  3. Open the Aspire dashboard URL printed to the console"
Write-Host "  4. Navigate to the YARP gateway and register an admin user"
Write-Host ""

$scriptPath = Join-Path $ScriptDir 'post-setup.ps1'
if (Test-Path $scriptPath) {
    Remove-Item $scriptPath -Force
}
