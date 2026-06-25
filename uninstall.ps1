<#
.SYNOPSIS
  Removes Agent Status Lights hooks from Claude Code and/or Codex CLI.
  Only removes OUR entries (matched by status-light.ps1); leaves everything else.

.PARAMETER Target
  all (default) | claude | codex
.PARAMETER Plan
  Dry run.
#>
[CmdletBinding()]
param(
  [ValidateSet('all','claude','codex')]
  [string]$Target = 'all',
  [switch]$Plan
)

$ErrorActionPreference = 'Stop'
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$BackupDir = Join-Path $Root 'backups'
$Marker = 'status-light.ps1'

$ClaudeSettings = Join-Path $env:USERPROFILE '.claude\settings.json'
$CodexHooks = Join-Path $env:USERPROFILE '.codex\hooks.json'

function Ok($m){ Write-Host $m -ForegroundColor Green }
function Warn($m){ Write-Host $m -ForegroundColor Yellow }
function PlanLine($m){ Write-Host "  [plan] $m" -ForegroundColor DarkGray }

function Backup-File($path) {
  if (-not (Test-Path $path)) { return $null }
  if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $dest = Join-Path $BackupDir ((Split-Path $path -Leaf) + ".$stamp.bak")
  Copy-Item $path $dest -Force
  return $dest
}

function Strip-Ours($hooksObj) {
  $clean = [ordered]@{}
  foreach ($p in $hooksObj.PSObject.Properties) {
    $groups = New-Object System.Collections.ArrayList
    foreach ($g in @($p.Value)) {
      if (-not $g) { continue }
      if (-not $g.hooks) { [void]$groups.Add($g); continue }
      $kept = @($g.hooks | Where-Object { $_.command -notlike "*$Marker*" })
      if ($kept.Count -gt 0) {
        $ng = [ordered]@{}
        if ($g.PSObject.Properties.Name -contains 'matcher') { $ng['matcher'] = $g.matcher }
        $ng['hooks'] = $kept
        [void]$groups.Add([pscustomobject]$ng)
      }
    }
    if ($groups.Count -gt 0) { $clean[$p.Name] = $groups.ToArray() }
  }
  return $clean
}

function Uninstall-Claude {
  Write-Host "`n--- Claude Code ---" -ForegroundColor Cyan
  if (-not (Test-Path $ClaudeSettings)) { Warn "no settings.json; nothing to do"; return }
  $obj = Get-Content $ClaudeSettings -Raw -Encoding UTF8 | ConvertFrom-Json
  if (-not ($obj.PSObject.Properties.Name -contains 'hooks')) { Warn "no hooks key; nothing to do"; return }
  if ($Plan) { PlanLine "remove status-light hooks from $ClaudeSettings (keep others)"; return }
  $bk = Backup-File $ClaudeSettings; if ($bk) { Ok "backed up -> $bk" }
  $cleanHooks = Strip-Ours $obj.hooks
  $new = [ordered]@{}
  foreach ($p in $obj.PSObject.Properties) { if ($p.Name -ne 'hooks') { $new[$p.Name] = $p.Value } }
  if ($cleanHooks.Count -gt 0) { $new['hooks'] = $cleanHooks }
  ($new | ConvertTo-Json -Depth 12) | Set-Content -Path $ClaudeSettings -Encoding UTF8
  Ok "removed our Claude hooks (run /hooks to verify)"
}

function Uninstall-Codex {
  Write-Host "`n--- Codex CLI ---" -ForegroundColor Cyan
  if (-not (Test-Path $CodexHooks)) { Warn "no hooks.json; nothing to do"; return }
  $obj = Get-Content $CodexHooks -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($Plan) { PlanLine "remove status-light hooks from $CodexHooks (keep others)"; PlanLine "config.toml 'hooks =' pointer left in place (harmless)"; return }
  $bk = Backup-File $CodexHooks; if ($bk) { Ok "backed up -> $bk" }
  $clean = Strip-Ours $obj
  ($clean | ConvertTo-Json -Depth 12) | Set-Content -Path $CodexHooks -Encoding UTF8
  Ok "removed our Codex hooks from $CodexHooks"
  Warn "Note: 'hooks = \"hooks.json\"' in config.toml is left in place (harmless if hooks.json is empty)."
}

Write-Host "Agent Status Lights uninstaller" -ForegroundColor Cyan
if ($Plan) { Warn "PLAN MODE - no files will be changed." }
if ($Target -in @('all','claude')) { try { Uninstall-Claude } catch { Warn "Claude uninstall error: $_" } }
if ($Target -in @('all','codex'))  { try { Uninstall-Codex }  catch { Warn "Codex uninstall error: $_" } }
Ok "`nDone."
