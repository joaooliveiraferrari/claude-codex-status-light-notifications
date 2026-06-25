<#
.SYNOPSIS
  Agent Status Lights - CLI entry point. Thin wrapper over lib\StatusLights.psm1.
  Sets keyboard/RGB color via OpenRGB, or falls back to console + Windows
  notification + sound. NEVER throws to the caller: always exits 0 so it can
  never break Claude Code or Codex hooks.

.PARAMETER Status
  working | approval | done | error | idle | normal | off
.PARAMETER SessionId
  Optional id for a concurrent agent session. If omitted and -FromHook is set,
  it is read from the hook JSON on stdin (session_id).
.PARAMETER Source
  Free label: claude | codex | ui | manual | test (logging only).
.PARAMETER FromHook
  Read hook JSON from stdin to extract session_id (safe: hooks pipe stdin).
  Do NOT set for interactive/manual calls (stdin would block).
.PARAMETER Message
  Optional note recorded in state/history.

.EXAMPLE
  ./status-light.ps1 -Status working
  ./status-light.ps1 -Status approval -Source claude -FromHook
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('working','approval','done','error','idle','normal','off')]
  [string]$Status,
  [string]$SessionId,
  [string]$Source = 'manual',
  [switch]$FromHook,
  [string]$Message = ''
)

$ErrorActionPreference = 'Continue'
trap { exit 0 }   # any unhandled terminating error -> exit 0 (never break the agent)

try {
  $root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
  Import-Module (Join-Path $root 'lib\StatusLights.psm1') -Force -ErrorAction Stop
  $null = Set-AgentStatus -Status $Status -SessionId $SessionId -Source $Source -Message $Message -FromHook:$FromHook
} catch {
  # Last-resort fallback so the caller still sees *something* and we still exit 0.
  try { Write-Host "[agent-status] $($Status.ToUpper()) (module load failed: $_)" -ForegroundColor Yellow } catch {}
}

exit 0
