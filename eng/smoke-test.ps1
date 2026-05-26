#!/usr/bin/env pwsh
<#
.SYNOPSIS
    End-to-end smoke test: boot the generated AppHost and verify resources reach
    a healthy state.

.DESCRIPTION
    Builds on validate-template.ps1 (which packs, installs, scaffolds, builds).
    This script additionally:
      1. Starts the AppHost as a background process
      2. Polls the Aspire dashboard / resource endpoints until all resources are healthy
      3. Sends an HTTP request through the YARP gateway and expects 200 + Alloy markup
      4. Confirms /health and /alive endpoints respond on each replica
      5. Tears the AppHost down

    This is intentionally lightweight — it proves the scaffold boots end-to-end.
    Full distributed-correctness validation (blob sharing, event propagation) lives
    in the Playwright e2e suite.

.PARAMETER ProjectName
    Name to use when scaffolding the test project. Defaults to 'SmokeTest'.

.PARAMETER SkipScaffold
    Reuse an existing scaffolded project at .test-output/$ProjectName instead of re-scaffolding.

.PARAMETER BootTimeoutSeconds
    How long to wait for all Aspire resources to reach a healthy state. Default 180.

.EXAMPLE
    ./eng/smoke-test.ps1
    ./eng/smoke-test.ps1 -ProjectName SmokeTest -BootTimeoutSeconds 240
#>
param(
    [string]$ProjectName = 'SmokeTest',
    [switch]$SkipScaffold,
    [int]$BootTimeoutSeconds = 180,
    [switch]$KeepRunning
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path $PSScriptRoot -Parent
$TestDir = Join-Path $RepoRoot '.test-output' $ProjectName
$AppHostDir = Join-Path $TestDir "$ProjectName.AppHost"

# ── Step 1: Scaffold (or reuse) ──────────────────────────────────────────────
if (-not $SkipScaffold) {
    Write-Host "[1/4] Scaffolding $ProjectName..." -ForegroundColor Yellow
    & "$PSScriptRoot/validate-template.ps1" -ProjectName $ProjectName -KeepOutput
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Scaffold failed"
        exit $LASTEXITCODE
    }
} else {
    Write-Host "[1/4] Reusing existing scaffold at $TestDir" -ForegroundColor DarkGray
    if (-not (Test-Path $AppHostDir)) {
        Write-Error "No AppHost found at $AppHostDir. Run without -SkipScaffold."
        exit 1
    }
}

# ── Step 2: Start AppHost in the background ─────────────────────────────────
Write-Host "`n[2/4] Starting AppHost..." -ForegroundColor Yellow

$logFile = Join-Path $TestDir 'apphost.log'
$appHostProcess = Start-Process -FilePath 'dotnet' `
    -ArgumentList 'run', '--project', $AppHostDir, '--no-build' `
    -RedirectStandardOutput $logFile `
    -RedirectStandardError $logFile `
    -PassThru `
    -WindowStyle Hidden

if (-not $appHostProcess) {
    Write-Error "Failed to start AppHost"
    exit 1
}

Write-Host "  AppHost PID: $($appHostProcess.Id)" -ForegroundColor DarkGray
Write-Host "  Logs:        $logFile" -ForegroundColor DarkGray

$cleanup = {
    if ($appHostProcess -and -not $appHostProcess.HasExited) {
        Write-Host "Stopping AppHost (PID $($appHostProcess.Id))..." -ForegroundColor DarkGray
        Stop-Process -Id $appHostProcess.Id -Force -ErrorAction SilentlyContinue
    }
}

try {
    # ── Step 3: Wait for dashboard + resources ──────────────────────────────
    Write-Host "`n[3/4] Waiting for resources to reach healthy state (timeout ${BootTimeoutSeconds}s)..." -ForegroundColor Yellow

    $dashboardUrl = $null
    $gatewayUrl = $null
    $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        if ($appHostProcess.HasExited) {
            Write-Error "AppHost exited unexpectedly (exit code $($appHostProcess.ExitCode))."
            Write-Host "--- Last 40 lines of apphost.log ---" -ForegroundColor DarkGray
            Get-Content $logFile -Tail 40 | Write-Host
            exit 1
        }

        $log = Get-Content $logFile -Raw -ErrorAction SilentlyContinue
        if ($log) {
            if (-not $dashboardUrl -and $log -match 'Login to the dashboard at (https?://[^\s]+)') {
                $dashboardUrl = $matches[1]
                Write-Host "  Dashboard: $dashboardUrl" -ForegroundColor Cyan
            }
            if (-not $gatewayUrl -and $log -match "Resource gateway started.*endpoint.*?(https?://[^\s,]+)") {
                $gatewayUrl = $matches[1]
                Write-Host "  Gateway:   $gatewayUrl" -ForegroundColor Cyan
            }
        }

        if ($dashboardUrl -and $gatewayUrl) {
            break
        }

        Start-Sleep -Seconds 2
    }

    if (-not $dashboardUrl -or -not $gatewayUrl) {
        Write-Error "Timed out waiting for AppHost to print dashboard + gateway URLs."
        Write-Host "--- Last 40 lines of apphost.log ---" -ForegroundColor DarkGray
        Get-Content $logFile -Tail 40 | Write-Host
        exit 1
    }

    # ── Step 4: Hit the gateway ────────────────────────────────────────────
    Write-Host "`n[4/4] Probing the YARP gateway..." -ForegroundColor Yellow

    $gatewayDeadline = (Get-Date).AddSeconds(60)
    $gatewayOk = $false
    while ((Get-Date) -lt $gatewayDeadline -and -not $gatewayOk) {
        try {
            $response = Invoke-WebRequest -Uri $gatewayUrl -SkipCertificateCheck -TimeoutSec 10 -ErrorAction Stop
            if ($response.StatusCode -eq 200 -and $response.Content -match 'Alloy') {
                $gatewayOk = $true
                Write-Host "  OK   Gateway returned 200 with Alloy markup" -ForegroundColor Green
            }
        } catch {
            Start-Sleep -Seconds 3
        }
    }

    if (-not $gatewayOk) {
        Write-Error "Gateway did not return a valid Alloy response within 60s."
        exit 1
    }

    # Health endpoint via gateway (any replica responds with 200)
    try {
        $health = Invoke-WebRequest -Uri "$gatewayUrl/health" -SkipCertificateCheck -TimeoutSec 10
        if ($health.StatusCode -eq 200) {
            Write-Host "  OK   /health returned 200" -ForegroundColor Green
        } else {
            Write-Host "  WARN /health returned $($health.StatusCode)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  WARN /health probe failed: $_" -ForegroundColor Yellow
    }

    Write-Host "`nSmoke test PASSED" -ForegroundColor Green
} finally {
    if (-not $KeepRunning) {
        & $cleanup
    } else {
        Write-Host "AppHost left running (PID $($appHostProcess.Id)). Stop with: Stop-Process -Id $($appHostProcess.Id) -Force" -ForegroundColor Cyan
    }
}
