<#
.SYNOPSIS
  Cycles through every status so you can see/hear what each one does, then
  prints a diagnostic report (OpenRGB present? device detected? provider used?).
.PARAMETER DelaySeconds
  Pause between statuses (default 2).
.PARAMETER NoCycle
  Skip the visual cycle, only print diagnostics.
#>
[CmdletBinding()]
param(
  [int]$DelaySeconds = 2,
  [switch]$NoCycle
)

$ErrorActionPreference = 'Continue'
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Light = Join-Path $Root 'status-light.ps1'
$ConfigPath = Join-Path $Root 'config\status-light.config.json'

function Section($t) { Write-Host "`n===== $t =====" -ForegroundColor Cyan }

Section 'DIAGNOSTICS'
$cfg = $null
try { $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json } catch { Write-Host "config unreadable: $_" -ForegroundColor Red }

# OpenRGB resolution (mirror of engine logic)
function Resolve-OpenRgb($cfg) {
  if ($cfg -and $cfg.openRgbPath -and (Test-Path $cfg.openRgbPath)) { return $cfg.openRgbPath }
  foreach ($n in 'OpenRGB','OpenRGB.exe') {
    $c = Get-Command $n -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
  }
  foreach ($g in @(
    'C:\Program Files\OpenRGB\OpenRGB.exe',
    'C:\Program Files (x86)\OpenRGB\OpenRGB.exe',
    (Join-Path $env:LOCALAPPDATA 'OpenRGB\OpenRGB.exe'),
    (Join-Path $env:USERPROFILE 'scoop\apps\openrgb\current\OpenRGB.exe'))) {
    if (Test-Path $g) { return $g }
  }
  return $null
}

$exe = Resolve-OpenRgb $cfg
if ($exe) {
  Write-Host "OpenRGB: FOUND -> $exe" -ForegroundColor Green
  Write-Host "Listing devices (timeout 8s)..." -ForegroundColor Gray
  try {
    $job = Start-Job -ScriptBlock { param($e) & $e --list-devices 2>&1 } -ArgumentList $exe
    if (Wait-Job $job -Timeout 8) {
      $out = Receive-Job $job
      Write-Host ($out | Out-String)
      if ($cfg -and $cfg.deviceName -and ($out -match [regex]::Escape($cfg.deviceName))) {
        Write-Host "Anne Pro 2 / '$($cfg.deviceName)': DETECTED" -ForegroundColor Green
      } else {
        Write-Host "Configured device '$($cfg.deviceName)' NOT detected in the list above." -ForegroundColor Yellow
      }
    } else {
      Write-Host "OpenRGB --list-devices timed out (is the SDK server reachable?)." -ForegroundColor Yellow
    }
    Remove-Job $job -Force -ErrorAction SilentlyContinue
  } catch { Write-Host "device listing error: $_" -ForegroundColor Yellow }
} else {
  Write-Host "OpenRGB: NOT INSTALLED -> running in FALLBACK mode (console + notification + sound)." -ForegroundColor Yellow
}

Write-Host ""
Write-Host ("VS Code terminal : {0}" -f ($(if ($env:TERM_PROGRAM -eq 'vscode') {'yes'} else {'no'}))) -ForegroundColor Gray
Write-Host ("TERM_PROGRAM     : {0}" -f $env:TERM_PROGRAM) -ForegroundColor Gray
Write-Host ("State dir        : {0}" -f (Join-Path $env:TEMP 'agent-status-lights')) -ForegroundColor Gray

if ($NoCycle) { return }

Section 'VISUAL CYCLE'
Write-Host "Watch your keyboard (if OpenRGB is set up) and this console. Listen for sounds on approval/error.`n" -ForegroundColor Gray

$sequence = @(
  @{ s='idle';     d='Idle / ready (white)' },
  @{ s='working';  d='Working / agent started (blue #0982FC)' },
  @{ s='approval'; d='Needs approval (orange #FC682A) + sound' },
  @{ s='done';     d='Done (green #00FF00)' },
  @{ s='error';    d='Error (purple #8D3EF9) + sound' },
  @{ s='normal';   d='Back to normal (white)' }
)

foreach ($step in $sequence) {
  Write-Host (">> {0}" -f $step.d) -ForegroundColor White
  & powershell -NoProfile -ExecutionPolicy Bypass -File $Light -Status $step.s -Source 'test' -Message $step.d | Out-Null
  Start-Sleep -Seconds $DelaySeconds
}

Section 'MULTI-SESSION TEST'
Write-Host "Simulating two concurrent sessions: A finishes while B is still working." -ForegroundColor Gray
& powershell -NoProfile -ExecutionPolicy Bypass -File $Light -Status working -Source 'test' -SessionId 'A' -Message 'session A working' | Out-Null
Start-Sleep -Seconds 1
& powershell -NoProfile -ExecutionPolicy Bypass -File $Light -Status working -Source 'test' -SessionId 'B' -Message 'session B working' | Out-Null
Start-Sleep -Seconds 1
Write-Host "Session A done -> should STAY working color (B still running), NOT green." -ForegroundColor Yellow
& powershell -NoProfile -ExecutionPolicy Bypass -File $Light -Status done -Source 'test' -SessionId 'A' -Message 'session A done' | Out-Null
Start-Sleep -Seconds $DelaySeconds
Write-Host "Session B done -> now everything done -> GREEN." -ForegroundColor Green
& powershell -NoProfile -ExecutionPolicy Bypass -File $Light -Status done -Source 'test' -SessionId 'B' -Message 'session B done' | Out-Null
Start-Sleep -Seconds $DelaySeconds

Section 'DONE'
Write-Host "Test complete. Turning light off." -ForegroundColor Gray
& powershell -NoProfile -ExecutionPolicy Bypass -File $Light -Status off -Source 'test' | Out-Null
Write-Host "Tip: open the UI with  ./start-ui.ps1  for live control." -ForegroundColor Cyan
