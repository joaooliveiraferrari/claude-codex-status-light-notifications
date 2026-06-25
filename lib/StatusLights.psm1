<#
  StatusLights.psm1 - reusable core for Agent Status Lights.

  This module holds ALL the logic (config, providers, fallbacks, state, sessions)
  so every entry point (status-light.ps1, test-status.ps1, the UI server) shares
  one implementation. Import it with:

      Import-Module (Join-Path $PSScriptRoot 'lib\StatusLights.psm1') -Force

  Public function: Set-AgentStatus. Everything else is a building block you can
  reuse or swap (e.g. add a new RGB provider) without editing the entry scripts.
#>

# Project root = parent of this /lib folder. Works no matter where the repo is cloned.
$script:SlRoot     = Split-Path -Parent $PSScriptRoot
$script:SlConfig   = Join-Path $script:SlRoot 'config\status-light.config.json'
$script:SlStateDir = Join-Path $env:TEMP 'agent-status-lights'
$script:SlState    = Join-Path $script:SlStateDir 'state.json'
$script:SlEvents   = Join-Path $script:SlStateDir 'events.json'
$script:SlLog      = Join-Path $script:SlStateDir 'status-light.log'

$script:SlPriority = @{ approval = 5; working = 4; error = 3; done = 2; idle = 1; normal = 1; off = 0 }

function Get-SlRoot { return $script:SlRoot }

function Initialize-SlStateDir {
  if (-not (Test-Path $script:SlStateDir)) {
    New-Item -ItemType Directory -Path $script:SlStateDir -Force | Out-Null
  }
}

function Write-SlLog {
  param([string]$Message, [string]$Source = 'lib')
  try {
    Initialize-SlStateDir
    $line = ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Source, $Message)
    Add-Content -Path $script:SlLog -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    $fi = Get-Item $script:SlLog -ErrorAction SilentlyContinue
    if ($fi -and $fi.Length -gt 256KB) {
      $tail = Get-Content $script:SlLog -Tail 400 -ErrorAction SilentlyContinue
      Set-Content -Path $script:SlLog -Value $tail -Encoding UTF8 -ErrorAction SilentlyContinue
    }
  } catch {}
}

function Get-SlConfig {
  $default = [ordered]@{
    openRgbPath = ''; deviceIndex = -1; deviceName = 'Anne Pro 2'; allowAllDevices = $false
    enableOpenRgb = $true
    openRgbMode = 'static'; openRgbTimeoutMs = 8000; serverPort = 8787
    enableNotifications = $true; enableSounds = $true; soundOnStatuses = @('approval','error')
    notifyOnStatuses = @('working','approval','done','error')
    sessionMaxAgeMinutes = 180; doneExpireMinutes = 30
    colors = [ordered]@{
      working='#0982FC'; approval='#FC682A'; done='#00FF00'; error='#8D3EF9'
      idle='#FEFEFF'; normal='#FEFEFF'; off='#000000'
    }
  }
  try {
    if (Test-Path $script:SlConfig) {
      $json = Get-Content $script:SlConfig -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($p in $json.PSObject.Properties) {
        if ($p.Name -eq 'colors' -and $p.Value) {
          foreach ($c in $p.Value.PSObject.Properties) { $default.colors[$c.Name] = $c.Value }
        } elseif ($default.Contains($p.Name)) {
          $default[$p.Name] = $p.Value
        }
      }
    }
  } catch { Write-SlLog "config parse failed, using defaults: $_" }
  return $default
}

function ConvertFrom-SlHex {
  param([string]$Hex)
  $h = ($Hex -replace '#','').Trim()
  if ($h.Length -ne 6) { $h = 'FEFEFF' }
  return [pscustomobject]@{
    Plain = $h.ToUpper()
    R = [Convert]::ToInt32($h.Substring(0,2),16)
    G = [Convert]::ToInt32($h.Substring(2,2),16)
    B = [Convert]::ToInt32($h.Substring(4,2),16)
  }
}

function Resolve-SlOpenRgbPath {
  param($Config)
  if ($Config.openRgbPath -and (Test-Path $Config.openRgbPath)) { return $Config.openRgbPath }
  foreach ($n in 'OpenRGB','OpenRGB.exe') {
    $c = Get-Command $n -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
  }
  $guesses = @(
    'C:\Program Files\OpenRGB\OpenRGB.exe',
    'C:\Program Files (x86)\OpenRGB\OpenRGB.exe',
    (Join-Path $env:LOCALAPPDATA 'OpenRGB\OpenRGB.exe'),
    (Join-Path $env:USERPROFILE 'scoop\apps\openrgb\current\OpenRGB.exe'),
    (Join-Path $env:USERPROFILE 'scoop\shims\OpenRGB.exe')
  )
  foreach ($g in $guesses) { if (Test-Path $g) { return $g } }
  return $null
}

# Run an exe with a hard timeout so a hung provider can never block the caller.
function Invoke-SlProcess {
  param([string]$Exe, [string[]]$Arguments, [int]$TimeoutMs = 8000)
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    # Windows PowerShell 5.1 / .NET 4.x has no ProcessStartInfo.ArgumentList; use the
    # classic .Arguments string (quote any arg containing whitespace).
    $psi.Arguments = (($Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' ')
    $p = [System.Diagnostics.Process]::Start($psi)
    if (-not $p.WaitForExit($TimeoutMs)) {
      try { $p.Kill() } catch {}
      return [pscustomobject]@{ Ok=$false; Out=''; Err='timeout'; Code=-1 }
    }
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    return [pscustomobject]@{ Ok=($p.ExitCode -eq 0); Out=$out; Err=$err; Code=$p.ExitCode }
  } catch {
    return [pscustomobject]@{ Ok=$false; Out=''; Err="$_"; Code=-1 }
  }
}

function Get-SlOpenRgbDevices {
  param([string]$Exe, $Config)
  $devices = @()
  if (-not $Exe) { return $devices }
  $r = Invoke-SlProcess -Exe $Exe -Arguments @('--list-devices') -TimeoutMs $Config.openRgbTimeoutMs
  if ($r.Ok -and $r.Out) {
    foreach ($line in ($r.Out -split "`r?`n")) {
      if ($line -match '^\s*(\d+):\s*(.+?)\s*$') {
        $devices += [pscustomobject]@{ Index=[int]$Matches[1]; Name=$Matches[2] }
      }
    }
  }
  return $devices
}

# --- RGB provider: OpenRGB. Returns 'openrgb' or 'fallback'. ---
function Set-SlOpenRgb {
  param($Config, [string]$HexPlain, [string]$StatusName)
  $exe = Resolve-SlOpenRgbPath $Config
  if (-not $exe) { return 'fallback' }

  $mode = if ($Config.openRgbMode) { [string]$Config.openRgbMode } else { 'static' }
  $deviceArgs = @()

  if ([int]$Config.deviceIndex -ge 0) {
    $deviceArgs = @('--device', [string][int]$Config.deviceIndex)
  } elseif ($Config.deviceName) {
    $devs = Get-SlOpenRgbDevices -Exe $exe -Config $Config
    $match = $devs | Where-Object { $_.Name -like "*$($Config.deviceName)*" } | Select-Object -First 1
    if ($match) { $deviceArgs = @('--device', [string]$match.Index) }
    elseif ($Config.allowAllDevices) { $deviceArgs = @() }
    else { Write-SlLog "OpenRGB present but '$($Config.deviceName)' not detected and allowAllDevices=false -> fallback"; return 'fallback' }
  } elseif ($Config.allowAllDevices) {
    $deviceArgs = @()
  } else {
    Write-SlLog "OpenRGB present but no deviceIndex/deviceName and allowAllDevices=false -> fallback"
    return 'fallback'
  }

  $argList = @() + $deviceArgs + @('--mode', $mode, '--color', $HexPlain)
  $r = Invoke-SlProcess -Exe $exe -Arguments $argList -TimeoutMs $Config.openRgbTimeoutMs
  if ($r.Ok) { Write-SlLog "OpenRGB set $StatusName ($HexPlain)"; return 'openrgb' }
  Write-SlLog "OpenRGB failed ($($r.Err)) -> fallback"
  return 'fallback'
}

# --- Fallback providers ---
function Show-SlNotification {
  param([string]$Title, [string]$Text)
  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ni.Icon = [System.Drawing.SystemIcons]::Information
    $ni.Visible = $true
    $ni.BalloonTipTitle = $Title
    $ni.BalloonTipText = $Text
    $ni.ShowBalloonTip(3000)
    Start-Sleep -Milliseconds 200
    $ni.Dispose()
    return $true
  } catch { Write-SlLog "notification failed: $_"; return $false }
}

function Invoke-SlSound {
  param([string]$StatusName)
  try {
    switch ($StatusName) {
      'approval' { [System.Media.SystemSounds]::Exclamation.Play() }
      'error'    { [System.Media.SystemSounds]::Hand.Play() }
      default    { [System.Media.SystemSounds]::Asterisk.Play() }
    }
    return $true
  } catch { return $false }
}

function Write-SlConsole {
  param([string]$StatusName, [string]$HexPlain, [string]$Message)
  $map = @{ working='Cyan'; approval='Yellow'; done='Green'; error='Magenta'; idle='White'; normal='White'; off='DarkGray' }
  $color = $map[$StatusName]; if (-not $color) { $color = 'White' }
  $line = "[agent-status] $($StatusName.ToUpper())  #$HexPlain"
  if ($Message) { $line += "  - $Message" }
  try { Write-Host $line -ForegroundColor $color } catch { Write-Output $line }
}

# --- State / sessions ---
function Get-SlState {
  try { if (Test-Path $script:SlState) { return (Get-Content $script:SlState -Raw -Encoding UTF8 | ConvertFrom-Json) } }
  catch { Write-SlLog "state parse failed: $_" }
  return $null
}

function Save-SlState {
  param($State)
  try { Initialize-SlStateDir; ($State | ConvertTo-Json -Depth 8) | Set-Content -Path $script:SlState -Encoding UTF8 }
  catch { Write-SlLog "state save failed: $_" }
}

function Add-SlEvent {
  param($Event)
  try {
    Initialize-SlStateDir
    $list = @()
    if (Test-Path $script:SlEvents) {
      $existing = Get-Content $script:SlEvents -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($existing) { $list = @($existing) }
    }
    $list += $Event
    if ($list.Count -gt 30) { $list = $list[($list.Count-30)..($list.Count-1)] }
    ($list | ConvertTo-Json -Depth 6) | Set-Content -Path $script:SlEvents -Encoding UTF8
  } catch {}
}

function Read-SlStdinSessionId {
  try {
    if ([Console]::IsInputRedirected) {
      $raw = [Console]::In.ReadToEnd()
      if ($raw) {
        $obj = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($obj) {
          foreach ($k in 'session_id','sessionId','session','conversation_id','id') {
            if ($obj.$k) { return [string]$obj.$k }
          }
        }
      }
    }
  } catch {}
  return $null
}

<#
.SYNOPSIS
  Apply an agent status across all providers + fallbacks, honoring multi-session rules.
.OUTPUTS
  PSCustomObject with effective status, color, provider, and flags. Never throws.
#>
function Set-AgentStatus {
  [CmdletBinding()]
  param(
    [ValidateSet('working','approval','done','error','idle','normal','off')]
    [string]$Status,
    [string]$SessionId,
    [string]$Source = 'manual',
    [string]$Message = '',
    [switch]$FromHook
  )

  $cfg = Get-SlConfig
  $now = Get-Date

  if (-not $SessionId) {
    if ($FromHook) { $SessionId = Read-SlStdinSessionId }
    if (-not $SessionId) { $SessionId = "$Source-default" }
  }

  $mutex = $null
  try { $mutex = New-Object System.Threading.Mutex($false, 'agent-status-lights-state') } catch {}
  $haveLock = $false
  if ($mutex) { try { $haveLock = $mutex.WaitOne(2000) } catch { $haveLock = $false } }

  $result = $null
  try {
    $state = Get-SlState
    if (-not $state) { $state = [pscustomobject]@{ sessions = (New-Object psobject); effective='idle'; updated=$now.ToString('o') } }

    # Normalize sessions: only accept entries that actually have status + ts.
    $sessions = @{}
    if ($state.sessions) {
      foreach ($p in $state.sessions.PSObject.Properties) {
        $v = $p.Value
        if ($v -and ($v.PSObject.Properties.Name -contains 'status') -and ($v.PSObject.Properties.Name -contains 'ts')) {
          $sessions[$p.Name] = $v
        }
      }
    }

    if ($Status -eq 'off') {
      $sessions = @{}
    } else {
      $sessions[$SessionId] = [pscustomobject]@{ status=$Status; source=$Source; message=$Message; ts=$now.ToString('o') }
    }

    # Prune stale + expired-done sessions
    $maxAge = [double]$cfg.sessionMaxAgeMinutes
    $doneExp = [double]$cfg.doneExpireMinutes
    $keep = @{}
    foreach ($k in $sessions.Keys) {
      $s = $sessions[$k]
      $age = ($now - [datetime]::Parse($s.ts)).TotalMinutes
      if ($age -gt $maxAge) { continue }
      if ($s.status -eq 'done' -and $age -gt $doneExp) { continue }
      $keep[$k] = $s
    }
    $sessions = $keep

    # Effective status = highest priority among live sessions
    if ($Status -eq 'off') { $effective = 'off' }
    elseif ($sessions.Count -eq 0) { $effective = 'idle' }
    else {
      $effective = 'idle'; $best = -1
      foreach ($k in $sessions.Keys) {
        $st = [string]$sessions[$k].status
        $pr = $script:SlPriority[$st]; if ($null -eq $pr) { $pr = 0 }
        if ($pr -gt $best) { $best = $pr; $effective = $st }
      }
    }

    $colorHex = $cfg.colors[$effective]; if (-not $colorHex) { $colorHex = $cfg.colors['idle'] }
    $hex = ConvertFrom-SlHex $colorHex

    $provider = if ($cfg.enableOpenRgb) { Set-SlOpenRgb -Config $cfg -HexPlain $hex.Plain -StatusName $effective } else { 'disabled' }
    Write-SlConsole -StatusName $effective -HexPlain $hex.Plain -Message $Message

    $notified = $false
    if ($cfg.enableNotifications -and (@($cfg.notifyOnStatuses) -contains $effective)) {
      $titles = @{ working='Agent working'; approval='Needs your approval'; done='Task done'; error='Task error' }
      $t = $titles[$effective]; if (-not $t) { $t = "Agent: $effective" }
      $body = if ($Message) { $Message } else { "$Source - $effective" }
      $notified = Show-SlNotification -Title $t -Text $body
    }

    $played = $false
    if ($cfg.enableSounds -and (@($cfg.soundOnStatuses) -contains $effective)) {
      $played = Invoke-SlSound -StatusName $effective
    }

    $sessObj = New-Object psobject
    foreach ($k in $sessions.Keys) { $sessObj | Add-Member -NotePropertyName $k -NotePropertyValue $sessions[$k] }
    $newState = [pscustomobject]@{
      sessions=$sessObj; effective=$effective; color=('#'+$hex.Plain); provider=$provider; updated=$now.ToString('o')
    }
    Save-SlState $newState
    Add-SlEvent ([pscustomobject]@{
      ts=$now.ToString('o'); source=$Source; sessionId=$SessionId; requested=$Status
      effective=$effective; color=('#'+$hex.Plain); provider=$provider; notified=$notified; sound=$played; message=$Message
    })
    Write-SlLog "req=$Status eff=$effective provider=$provider sid=$SessionId" $Source

    $result = [pscustomobject]@{ effective=$effective; color=('#'+$hex.Plain); provider=$provider; notified=$notified; sound=$played; sessions=$sessions.Count }
  }
  catch { Write-SlLog "Set-AgentStatus error (suppressed): $_" $Source }
  finally {
    if ($mutex -and $haveLock) { try { $mutex.ReleaseMutex() } catch {} }
    if ($mutex) { try { $mutex.Dispose() } catch {} }
  }
  return $result
}

Export-ModuleMember -Function Set-AgentStatus, Get-SlConfig, Resolve-SlOpenRgbPath, Get-SlOpenRgbDevices, ConvertFrom-SlHex, Get-SlState, Get-SlRoot
