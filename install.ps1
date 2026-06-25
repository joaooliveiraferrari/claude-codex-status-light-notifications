<#
.SYNOPSIS
  Installs Agent Status Lights hooks into Claude Code and/or Codex CLI.
  Backs up every file before editing and MERGES (never clobbers) existing hooks.

.PARAMETER Target
  all (default) | claude | codex

.PARAMETER Plan
  Dry run: show exactly what would change, modify nothing.

.NOTES
  - Claude hooks go in ~/.claude/settings.json
  - Codex hooks go in ~/.codex/hooks.json (referenced by ~/.codex/config.toml: hooks = "hooks.json")
  - Idempotent: re-running replaces our own entries, leaves unrelated hooks intact.
  - After Codex install, run `codex` once and TRUST the hooks when prompted.
#>
[CmdletBinding()]
param(
  [ValidateSet('all','claude','codex')]
  [string]$Target = 'all',
  [switch]$Plan
)

$ErrorActionPreference = 'Stop'
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$LightPath = Join-Path $Root 'status-light.ps1'
$BackupDir = Join-Path $Root 'backups'
$Marker = 'status-light.ps1'   # how we recognize our own hook entries

$ClaudeSettings = Join-Path $env:USERPROFILE '.claude\settings.json'
$CodexDir = Join-Path $env:USERPROFILE '.codex'
$CodexConfig = Join-Path $CodexDir 'config.toml'
$CodexHooks = Join-Path $CodexDir 'hooks.json'

function Info($m){ Write-Host $m -ForegroundColor Cyan }
function Ok($m){ Write-Host $m -ForegroundColor Green }
function Warn($m){ Write-Host $m -ForegroundColor Yellow }
function PlanLine($m){ Write-Host "  [plan] $m" -ForegroundColor DarkGray }

function Backup-File($path) {
  if (-not (Test-Path $path)) { return $null }
  if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $name = (Split-Path $path -Leaf) + ".$stamp.bak"
  $dest = Join-Path $BackupDir $name
  Copy-Item $path $dest -Force
  return $dest
}

# NOTE: do NOT name these 'Cmd'/'Group' - 'group' is the built-in alias for
# Group-Object and aliases outrank functions, so it would silently win.
function New-HookCmd($status, $source) {
  return "powershell -NoProfile -ExecutionPolicy Bypass -File `"$LightPath`" -Status $status -Source $source -FromHook"
}

# Build our hook group object for one command string
function New-HookGroup($cmd) {
  return [pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; command = $cmd }) }
}

# Remove our own entries from an event's array; returns a clean ArrayList of groups.
function Strip-Ours($arr) {
  $out = New-Object System.Collections.ArrayList
  foreach ($g in @($arr)) {
    if (-not $g) { continue }
    if (-not $g.hooks) { [void]$out.Add($g); continue }
    $kept = @($g.hooks | Where-Object { $_.command -notlike "*$Marker*" })
    if ($kept.Count -gt 0) {
      $ng = [ordered]@{}
      if ($g.PSObject.Properties.Name -contains 'matcher') { $ng['matcher'] = $g.matcher }
      $ng['hooks'] = $kept
      [void]$out.Add([pscustomobject]$ng)
    }
  }
  return $out
}

# Merge our event->group map into an existing hooks object (PSCustomObject or $null).
# Builds plain object[] values (no nested single-element arrays) so ConvertTo-Json is correct.
function Merge-Hooks($existing, $ourMap) {
  $result = [ordered]@{}
  if ($existing) {
    foreach ($p in $existing.PSObject.Properties) {
      $kept = Strip-Ours $p.Value
      if ($kept.Count -gt 0) { $result[$p.Name] = $kept.ToArray() }
    }
  }
  foreach ($evt in $ourMap.Keys) {
    $list = New-Object System.Collections.ArrayList
    if ($result.Contains($evt)) { foreach ($g in @($result[$evt])) { [void]$list.Add($g) } }
    [void]$list.Add($ourMap[$evt])
    $result[$evt] = $list.ToArray()
  }
  return $result
}

function Install-Claude {
  Info "`n--- Claude Code ---"
  $ourMap = [ordered]@{
    SessionStart     = New-HookGroup (New-HookCmd 'idle'     'claude')
    UserPromptSubmit = New-HookGroup (New-HookCmd 'working'  'claude')
    Notification     = New-HookGroup (New-HookCmd 'approval' 'claude')
    Stop             = New-HookGroup (New-HookCmd 'done'     'claude')
  }

  if (-not (Test-Path $ClaudeSettings)) {
    Warn "settings.json not found at $ClaudeSettings"
    if ($Plan) { PlanLine "would CREATE $ClaudeSettings with our hooks"; return }
    New-Item -ItemType Directory -Path (Split-Path $ClaudeSettings) -Force | Out-Null
    $obj = [ordered]@{}
  } else {
    $obj = Get-Content $ClaudeSettings -Raw -Encoding UTF8 | ConvertFrom-Json
  }

  $existingHooks = if ($obj.PSObject.Properties.Name -contains 'hooks') { $obj.hooks } else { $null }
  $merged = Merge-Hooks $existingHooks $ourMap

  if ($Plan) {
    PlanLine "backup $ClaudeSettings -> backups\"
    PlanLine "merge hooks: SessionStart->idle, UserPromptSubmit->working, Notification->approval, Stop->done"
    PlanLine "preserve all existing non-status-light hooks/keys"
    return
  }

  $bk = Backup-File $ClaudeSettings
  if ($bk) { Ok "backed up -> $bk" }

  # rebuild object preserving all other keys
  $new = [ordered]@{}
  foreach ($p in $obj.PSObject.Properties) {
    if ($p.Name -ne 'hooks') { $new[$p.Name] = $p.Value }
  }
  $new['hooks'] = $merged
  ($new | ConvertTo-Json -Depth 12) | Set-Content -Path $ClaudeSettings -Encoding UTF8
  Ok "Claude hooks installed in $ClaudeSettings"
  Warn "Verify in Claude Code by running:  /hooks"
}

function Install-Codex {
  Info "`n--- Codex CLI ---"
  $ourMap = [ordered]@{
    SessionStart      = New-HookGroup (New-HookCmd 'idle'     'codex')
    UserPromptSubmit  = New-HookGroup (New-HookCmd 'working'  'codex')
    PermissionRequest = New-HookGroup (New-HookCmd 'approval' 'codex')
    Stop              = New-HookGroup (New-HookCmd 'done'     'codex')
  }

  if ($Plan) {
    PlanLine "ensure dir $CodexDir"
    if (Test-Path $CodexHooks) { PlanLine "backup + merge $CodexHooks" } else { PlanLine "create $CodexHooks" }
    if (Test-Path $CodexConfig) { PlanLine "backup $CodexConfig; ensure 'hooks = \"hooks.json\"'" } else { PlanLine "create $CodexConfig with 'hooks = \"hooks.json\"'" }
    PlanLine "you must then run `codex` once and TRUST the hooks"
    return
  }

  if (-not (Test-Path $CodexDir)) { New-Item -ItemType Directory -Path $CodexDir -Force | Out-Null }

  # hooks.json (merge if present)
  $existing = $null
  if (Test-Path $CodexHooks) {
    $bk = Backup-File $CodexHooks; if ($bk) { Ok "backed up -> $bk" }
    try { $existing = Get-Content $CodexHooks -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Warn "existing hooks.json unparseable, starting fresh"; $existing = $null }
  }
  $merged = Merge-Hooks $existing $ourMap
  ($merged | ConvertTo-Json -Depth 12) | Set-Content -Path $CodexHooks -Encoding UTF8
  Ok "Codex hooks written to $CodexHooks"

  # config.toml (ensure hooks pointer)
  if (Test-Path $CodexConfig) {
    $bk = Backup-File $CodexConfig; if ($bk) { Ok "backed up -> $bk" }
    $lines = Get-Content $CodexConfig -Encoding UTF8
    $hasHooks = $lines | Where-Object { $_ -match '^\s*hooks\s*=' }
    if ($hasHooks) {
      Warn "config.toml already has a 'hooks =' line; leaving it as-is:"
      Warn ("    " + ($hasHooks -join "`n    "))
      Warn "If it does not point to hooks.json, edit it manually."
    } else {
      Add-Content -Path $CodexConfig -Value "`n# Added by agent-status-lights" -Encoding UTF8
      Add-Content -Path $CodexConfig -Value 'hooks = "hooks.json"' -Encoding UTF8
      Ok "added 'hooks = \"hooks.json\"' to $CodexConfig"
    }
  } else {
    Set-Content -Path $CodexConfig -Value "# Codex config (created by agent-status-lights)`nhooks = `"hooks.json`"`n" -Encoding UTF8
    Ok "created $CodexConfig with hooks pointer"
  }

  Warn "IMPORTANT: run `codex` once. On first launch it will say 'Hooks need review' -> TRUST them."
  Warn "Verify with:  codex doctor   (and the hooks-review prompt at startup)."
}

Info "Agent Status Lights installer  (project: $Root)"
if ($Plan) { Warn "PLAN MODE - no files will be changed." }

if ($Target -in @('all','claude')) {
  try { Install-Claude } catch { Warn "Claude install error: $_" }
}
if ($Target -in @('all','codex')) {
  try { Install-Codex } catch { Warn "Codex install error: $_" }
}

Ok "`nDone. Test with:  ./test-status.ps1    UI:  ./start-ui.ps1"
