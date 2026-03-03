#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Migrates an existing Optimizely CMS 12 Alloy project to CMS 13 + .NET Aspire integration.

.DESCRIPTION
    This script is run as a post-action by 'dotnet new alloy-aspire-scaffold'.
    It expects to find an Alloy project (AlloyAspireScaffold.csproj) in the same directory.
    The sourceName replacement turns 'AlloyAspireScaffold' into the user's -n value.

    Steps:
      0. Reorganize: move Alloy web files into a subdirectory for clean solution layout
      1-4. Patch .csproj, Program.cs, Startup.cs, apply CMS 12->13 API migrations
      5-8. Clean up, add to .slnx, self-delete

    Each replacement is guarded with -notmatch checks for idempotency.
#>

$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot
$ProjectName = 'AlloyAspireScaffold'
$CsprojPath = Join-Path $ScriptDir "$ProjectName.csproj"

# ── Guard: Alloy project must exist ────────────────────────────────────────────
if (-not (Test-Path $CsprojPath)) {
    Write-Warning "Could not find '$ProjectName.csproj' in '$ScriptDir'."
    Write-Warning "This overlay template expects an existing Alloy project created with 'dotnet new epi-alloy-mvc -n $ProjectName'."
    Write-Warning "Skipping CMS 12 -> 13 migration. AppHost and ServiceDefaults projects were still generated."
    exit 0
}

Write-Host "Migrating '$ProjectName' to CMS 13 + Aspire..." -ForegroundColor Cyan

# ── Helper: Replace text in file (idempotent) ─────────────────────────────────
function Replace-InFile {
    param(
        [string]$Path,
        [string]$Find,
        [string]$Replace,
        [string]$Description,
        [switch]$Regex
    )
    if (-not (Test-Path $Path)) {
        Write-Warning "  SKIP ($Description): File not found: $Path"
        return
    }
    $content = Get-Content $Path -Raw
    if ($null -eq $content) {
        Write-Warning "  SKIP ($Description): File is empty: $Path"
        return
    }
    if ($Regex) {
        if ($content -notmatch $Find) {
            Write-Host "  SKIP ($Description): Pattern not found (already applied?)" -ForegroundColor DarkGray
            return
        }
        $newContent = $content -replace $Find, $Replace
    } else {
        if (-not $content.Contains($Find)) {
            Write-Host "  SKIP ($Description): Pattern not found (already applied?)" -ForegroundColor DarkGray
            return
        }
        $newContent = $content.Replace($Find, $Replace)
    }
    Set-Content $Path -Value $newContent -NoNewline
    Write-Host "  OK   $Description" -ForegroundColor Green
}

# ── Helper: Insert text after a pattern (idempotent) ──────────────────────────
function Insert-AfterPattern {
    param(
        [string]$Path,
        [string]$Pattern,
        [string]$Insert,
        [string]$Guard,
        [string]$Description
    )
    if (-not (Test-Path $Path)) {
        Write-Warning "  SKIP ($Description): File not found: $Path"
        return
    }
    $content = Get-Content $Path -Raw
    if ($content -match [regex]::Escape($Guard)) {
        Write-Host "  SKIP ($Description): Already present" -ForegroundColor DarkGray
        return
    }
    if ($content -notmatch $Pattern) {
        Write-Warning "  SKIP ($Description): Anchor pattern not found"
        return
    }
    $newContent = $content -replace $Pattern, "`$0$Insert"
    Set-Content $Path -Value $newContent -NoNewline
    Write-Host "  OK   $Description" -ForegroundColor Green
}

# ── Helper: Insert using directive (idempotent) ───────────────────────────────
function Add-Using {
    param(
        [string]$Path,
        [string]$Namespace,
        [string]$Description
    )
    if (-not (Test-Path $Path)) {
        Write-Warning "  SKIP ($Description): File not found: $Path"
        return
    }
    $content = Get-Content $Path -Raw
    $directive = "using $Namespace;"
    if ($content.Contains($directive)) {
        Write-Host "  SKIP ($Description): Already present" -ForegroundColor DarkGray
        return
    }
    # Insert after the last existing using
    $newContent = $content -replace '(using [^;]+;\r?\n)(?!using )', "`$1$directive`n"
    if ($newContent -eq $content) {
        # Fallback: prepend
        $newContent = "$directive`n$content"
    }
    Set-Content $Path -Value $newContent -NoNewline
    Write-Host "  OK   $Description" -ForegroundColor Green
}

# ============================================================================
# 0. Reorganize: move Alloy web project into its own subdirectory
# ============================================================================
Write-Host "`n[0/9] Reorganizing solution layout..." -ForegroundColor Yellow

$WebProjectDir = Join-Path $ScriptDir $ProjectName

if (Test-Path $WebProjectDir) {
    Write-Host "  SKIP (Reorganize): $ProjectName/ subdirectory already exists" -ForegroundColor DarkGray
} else {
    New-Item -ItemType Directory -Path $WebProjectDir -Force | Out-Null

    # Items that belong to the overlay (stay at solution root)
    $overlayItems = @(
        "$ProjectName.slnx",
        "$ProjectName.AppHost",
        "$ProjectName.ServiceDefaults",
        'post-setup.ps1',
        $ProjectName   # the subdirectory we just created
    )

    # Move everything else into the web project subdirectory
    Get-ChildItem $ScriptDir -Force | Where-Object {
        $_.Name -notin $overlayItems
    } | ForEach-Object {
        Move-Item $_.FullName -Destination $WebProjectDir
    }

    Write-Host "  OK   Moved Alloy web project files into $ProjectName/" -ForegroundColor Green
}

# All subsequent paths reference files inside the web project subdirectory
$CsprojPath = Join-Path $WebProjectDir "$ProjectName.csproj"

# ============================================================================
# 1. Patch .csproj
# ============================================================================
Write-Host "`n[1/9] Patching $ProjectName.csproj..." -ForegroundColor Yellow

# TFM: net8.0 -> net10.0
Replace-InFile -Path $CsprojPath `
    -Find '<TargetFramework>net8.0</TargetFramework>' `
    -Replace '<TargetFramework>net10.0</TargetFramework>' `
    -Description 'TFM net8.0 -> net10.0'

# EPiServer.CMS version bump
Replace-InFile -Path $CsprojPath `
    -Find 'Include="EPiServer.CMS" Version="12[^"]*"' `
    -Replace 'Include="EPiServer.CMS" Version="13.0.0-preview3"' `
    -Description 'EPiServer.CMS -> 13.0.0-preview3' `
    -Regex

# Wangkanai.Detection version bump
Replace-InFile -Path $CsprojPath `
    -Find 'Include="Wangkanai.Detection" Version="[^"]*"' `
    -Replace 'Include="Wangkanai.Detection" Version="8.20.0"' `
    -Description 'Wangkanai.Detection -> 8.20.0' `
    -Regex

# Add EPiServer.CMS.UI.AspNetIdentity if not present
$csprojContent = Get-Content $CsprojPath -Raw
if ($csprojContent -notmatch 'EPiServer\.CMS\.UI\.AspNetIdentity') {
    Replace-InFile -Path $CsprojPath `
        -Find '<PackageReference Include="EPiServer.CMS"' `
        -Replace '<PackageReference Include="EPiServer.CMS.UI.AspNetIdentity" Version="13.0.0-preview3" />
    <PackageReference Include="EPiServer.CMS"' `
        -Description 'Add EPiServer.CMS.UI.AspNetIdentity package'
} else {
    Write-Host "  SKIP (Add EPiServer.CMS.UI.AspNetIdentity): Already present" -ForegroundColor DarkGray
}

# Add ServiceDefaults project reference (sibling directory, so ../)
$csprojContent = Get-Content $CsprojPath -Raw
if ($csprojContent -notmatch 'ServiceDefaults') {
    Replace-InFile -Path $CsprojPath `
        -Find '</Project>' `
        -Replace "
  <ItemGroup>
    <ProjectReference Include=`"..\$ProjectName.ServiceDefaults\$ProjectName.ServiceDefaults.csproj`" />
  </ItemGroup>
</Project>" `
        -Description 'Add ServiceDefaults project reference'
} else {
    Write-Host "  SKIP (Add ServiceDefaults reference): Already present" -ForegroundColor DarkGray
}

# ============================================================================
# 2. Patch Program.cs - Add .AddServiceDefaults()
# ============================================================================
Write-Host "`n[2/9] Patching Program.cs..." -ForegroundColor Yellow

$programPath = Join-Path $WebProjectDir 'Program.cs'
Insert-AfterPattern -Path $programPath `
    -Pattern '\.ConfigureCmsDefaults\(\)' `
    -Insert "`n    .AddServiceDefaults()" `
    -Guard 'AddServiceDefaults' `
    -Description 'Add .AddServiceDefaults() after .ConfigureCmsDefaults()'

# ============================================================================
# 3. Patch Startup.cs
# ============================================================================
Write-Host "`n[3/9] Patching Startup.cs..." -ForegroundColor Yellow

$startupPath = Join-Path $WebProjectDir 'Startup.cs'

# Add required using directives
Add-Using -Path $startupPath -Namespace 'EPiServer.DependencyInjection' -Description 'Add using EPiServer.DependencyInjection'
Add-Using -Path $startupPath -Namespace 'EPiServer.Data' -Description 'Add using EPiServer.Data'
Add-Using -Path $startupPath -Namespace 'Microsoft.AspNetCore.Diagnostics.HealthChecks' -Description 'Add using Microsoft.AspNetCore.Diagnostics.HealthChecks'

# Add DataAccessOptions configuration
Insert-AfterPattern -Path $startupPath `
    -Pattern '\.AddCms\(\)' `
    -Insert "`n                .AddVisitorGroups()" `
    -Guard 'AddVisitorGroups' `
    -Description 'Add .AddVisitorGroups() after .AddCms()'

# Add DataAccessOptions.UpdateDatabaseCompatibilityLevel
$startupContent = Get-Content $startupPath -Raw
if ($startupContent -notmatch 'UpdateDatabaseCompatibilityLevel') {
    Insert-AfterPattern -Path $startupPath `
        -Pattern 'services\.AddCms\(\)' `
        -Insert ";`n            services.Configure<DataAccessOptions>(o => o.UpdateDatabaseCompatibilityLevel = true)" `
        -Guard 'UpdateDatabaseCompatibilityLevel' `
        -Description 'Add DataAccessOptions.UpdateDatabaseCompatibilityLevel = true'
}

# Add health check endpoint mappings inside UseEndpoints
$startupContent = Get-Content $startupPath -Raw
if ($startupContent -notmatch 'MapHealthChecks') {
    Replace-InFile -Path $startupPath `
        -Find 'endpoints.MapContent();' `
        -Replace 'endpoints.MapContent();
            endpoints.MapHealthChecks("/health");
            endpoints.MapHealthChecks("/alive", new HealthCheckOptions
            {
                Predicate = r => r.Tags.Contains("live")
            });' `
        -Description 'Add health check endpoint mappings'
}

# ============================================================================
# 4. CMS 12 -> 13 API Migrations
# ============================================================================
Write-Host "`n[4/9] Applying CMS 12 -> 13 API migrations..." -ForegroundColor Yellow

# --- 4.1 PageReference -> ContentReference ---
$prFiles = @(
    "Models/Pages/StartPage.cs",
    "Models/Blocks/ContactBlock.cs",
    "Models/Blocks/PageListBlock.cs",
    "Models/Blocks/TeaserBlock.cs",
    "Business/ContentLocator.cs",
    "Business/EditorDescriptors/ContactPageSelector.cs"
)
foreach ($f in $prFiles) {
    $filePath = Join-Path $WebProjectDir $f
    if (Test-Path $filePath) {
        Replace-InFile -Path $filePath `
            -Find 'PageReference' `
            -Replace 'ContentReference' `
            -Description "PageReference -> ContentReference in $f"
    }
}

# --- 4.2 IContentTypeRepository<PageType> -> IContentTypeRepository ---
$ptExtPath = Join-Path $WebProjectDir 'Business/PageTypeExtensions.cs'
if (Test-Path $ptExtPath) {
    Replace-InFile -Path $ptExtPath `
        -Find 'IContentTypeRepository<PageType>' `
        -Replace 'IContentTypeRepository' `
        -Description 'IContentTypeRepository<PageType> -> IContentTypeRepository'

    # The non-generic .Load() returns ContentType, need explicit cast to PageType
    Replace-InFile -Path $ptExtPath `
        -Find 'return pageTypeRepository.Load(pageType);' `
        -Replace 'return (PageType)pageTypeRepository.Load(pageType);' `
        -Description 'Add (PageType) cast for non-generic IContentTypeRepository.Load()'
}

# --- 4.3 InitializationEngine.Locate -> context.Services ---
$renderInitPath = Join-Path $WebProjectDir 'Business/Initialization/CustomizedRenderingInitialization.cs'
Replace-InFile -Path $renderInitPath `
    -Find 'context.Locate.Advanced.GetInstance' `
    -Replace 'context.Services.GetRequiredService' `
    -Description 'InitializationEngine.Locate -> context.Services in CustomizedRenderingInitialization.cs'

# Add using for GetRequiredService extension
if (Test-Path $renderInitPath) {
    Add-Using -Path $renderInitPath -Namespace 'Microsoft.Extensions.DependencyInjection' -Description 'Add using Microsoft.Extensions.DependencyInjection to CustomizedRenderingInitialization.cs'
}

# --- 4.4 SiteDefinition.Current ---
# SiteDefinition.Current is [Obsolete] in CMS 13 (warnings only, not errors).
# Replacing it requires adding ISiteDefinitionResolver DI injection to multiple classes.
# We leave these as-is to keep the migration simple; users can address the warnings later.
Write-Host "  INFO SiteDefinition.Current usages left as-is (obsolete warnings only)" -ForegroundColor DarkGray

# --- 4.5 PageContext.Page -> PageContext.Content ---
$pageControllerBasePath = Join-Path $WebProjectDir 'Controllers/PageControllerBase.cs'
if (Test-Path $pageControllerBasePath) {
    Replace-InFile -Path $pageControllerBasePath `
        -Find 'PageContext.Page' `
        -Replace 'PageContext.Content' `
        -Description 'PageContext.Page -> PageContext.Content in PageControllerBase.cs'
}

# ============================================================================
# 5. Remove LocalDB connection string from appsettings.Development.json
# ============================================================================
Write-Host "`n[5/9] Cleaning appsettings.Development.json..." -ForegroundColor Yellow

$devSettingsPath = Join-Path $WebProjectDir 'appsettings.Development.json'
if (Test-Path $devSettingsPath) {
    try {
        $devSettings = Get-Content $devSettingsPath -Raw | ConvertFrom-Json
        if ($devSettings.ConnectionStrings -and $devSettings.ConnectionStrings.EPiServerDB) {
            $devSettings.ConnectionStrings.PSObject.Properties.Remove('EPiServerDB')
            # If ConnectionStrings is now empty, remove it too
            if (($devSettings.ConnectionStrings.PSObject.Properties | Measure-Object).Count -eq 0) {
                $devSettings.PSObject.Properties.Remove('ConnectionStrings')
            }
            $devSettings | ConvertTo-Json -Depth 10 | Set-Content $devSettingsPath -NoNewline
            Write-Host "  OK   Removed LocalDB connection string from appsettings.Development.json" -ForegroundColor Green
        } else {
            Write-Host "  SKIP (Remove LocalDB connection string): Not found or already removed" -ForegroundColor DarkGray
        }
    } catch {
        Write-Warning "  SKIP (appsettings.Development.json): Failed to parse JSON - $_"
    }
}

# ============================================================================
# 6. Remove App_Data/*.mdf and *.ldf files
# ============================================================================
Write-Host "`n[6/9] Cleaning App_Data database files..." -ForegroundColor Yellow

$appDataPath = Join-Path $WebProjectDir 'App_Data'
if (Test-Path $appDataPath) {
    $dbFiles = Get-ChildItem $appDataPath -Include '*.mdf', '*.ldf' -File -ErrorAction SilentlyContinue
    foreach ($dbFile in $dbFiles) {
        Remove-Item $dbFile.FullName -Force
        Write-Host "  OK   Removed $($dbFile.Name)" -ForegroundColor Green
    }
    if (-not $dbFiles) {
        Write-Host "  SKIP (App_Data cleanup): No .mdf/.ldf files found" -ForegroundColor DarkGray
    }
} else {
    Write-Host "  SKIP (App_Data cleanup): App_Data directory not found" -ForegroundColor DarkGray
}

# ============================================================================
# 7. Move nuget.config to solution root (if not already there)
# ============================================================================
Write-Host "`n[7/9] Moving nuget.config to solution root..." -ForegroundColor Yellow

$nugetConfigInWeb = Join-Path $WebProjectDir 'nuget.config'
$nugetConfigAtRoot = Join-Path $ScriptDir 'nuget.config'
if ((Test-Path $nugetConfigInWeb) -and -not (Test-Path $nugetConfigAtRoot)) {
    Move-Item $nugetConfigInWeb -Destination $nugetConfigAtRoot
    Write-Host "  OK   Moved nuget.config to solution root" -ForegroundColor Green
} elseif (Test-Path $nugetConfigAtRoot) {
    # Already at root; remove duplicate in web project
    if (Test-Path $nugetConfigInWeb) { Remove-Item $nugetConfigInWeb -Force }
    Write-Host "  SKIP (nuget.config): Already at solution root" -ForegroundColor DarkGray
} else {
    Write-Host "  SKIP (nuget.config): Not found" -ForegroundColor DarkGray
}

# ============================================================================
# 8. Add Alloy project to .slnx
# ============================================================================
Write-Host "`n[8/9] Adding $ProjectName to solution..." -ForegroundColor Yellow

$slnxPath = Join-Path $ScriptDir "$ProjectName.slnx"
if (Test-Path $slnxPath) {
    $slnxContent = Get-Content $slnxPath -Raw
    $projectEntry = "  <Project Path=`"$ProjectName/$ProjectName.csproj`" />"
    if ($slnxContent -notmatch [regex]::Escape("$ProjectName.csproj")) {
        Replace-InFile -Path $slnxPath `
            -Find '</Solution>' `
            -Replace "$projectEntry`n</Solution>" `
            -Description "Add $ProjectName/$ProjectName.csproj to .slnx"
    } else {
        Write-Host "  SKIP (Add to .slnx): Project already in solution" -ForegroundColor DarkGray
    }
} else {
    Write-Warning "  SKIP (Add to .slnx): $ProjectName.slnx not found"
}

# ============================================================================
# 9. Self-delete
# ============================================================================
Write-Host "`n[9/9] Cleaning up..." -ForegroundColor Yellow

$scriptPath = Join-Path $ScriptDir 'post-setup.ps1'
if (Test-Path $scriptPath) {
    Remove-Item $scriptPath -Force
    Write-Host "  OK   Removed post-setup.ps1" -ForegroundColor Green
}

Write-Host "`nMigration complete!" -ForegroundColor Green
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. dotnet build $ProjectName.slnx"
Write-Host "  2. cd $ProjectName.AppHost && dotnet run"
Write-Host "  3. Open the Aspire dashboard and verify all resources are healthy"
Write-Host "  4. Register an admin user on first CMS access"
Write-Host "  5. Configure the CMS 13 Application Model (see docs for details)"
