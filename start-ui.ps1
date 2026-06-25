<#
.SYNOPSIS
  Starts the Agent Status Lights local dashboard at http://localhost:<port>.
  Prefers the Node server (ui/server.js, zero dependencies). Falls back to the
  pure-PowerShell server (ui/server.ps1) if Node is unavailable.
.PARAMETER NoBrowser
  Do not auto-open the browser.
#>
[CmdletBinding()]
param([switch]$NoBrowser)

$ErrorActionPreference = 'Continue'
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$ServerJs = Join-Path $Root 'ui\server.js'
$ServerPs = Join-Path $Root 'ui\server.ps1'
$ConfigPath = Join-Path $Root 'config\status-light.config.json'

$port = 8787
try { $port = (Get-Content $ConfigPath -Raw | ConvertFrom-Json).serverPort } catch {}
if (-not $port) { $port = 8787 }
$url = "http://localhost:$port"

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $NoBrowser) {
  Start-Job -ScriptBlock { param($u) Start-Sleep -Seconds 2; Start-Process $u } -ArgumentList $url | Out-Null
}

if ($node) {
  Write-Host "Starting Node UI server at $url ..." -ForegroundColor Cyan
  Write-Host "(Ctrl+C to stop)`n" -ForegroundColor DarkGray
  & node $ServerJs
} else {
  Write-Host "Node not found; starting pure-PowerShell server at $url ..." -ForegroundColor Yellow
  & powershell -NoProfile -ExecutionPolicy Bypass -File $ServerPs
}
