<#
.SYNOPSIS
  Pure-PowerShell fallback UI server (used only if Node is unavailable).
  Uses System.Net.HttpListener bound to localhost (no admin needed for localhost).
  Serves the same UI + a subset of the API.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$UiDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Root = Split-Path -Parent $UiDir
$ConfigPath = Join-Path $Root 'config\status-light.config.json'
$Light = Join-Path $Root 'status-light.ps1'
$Test = Join-Path $Root 'test-status.ps1'
$Install = Join-Path $Root 'install.ps1'
$Uninstall = Join-Path $Root 'uninstall.ps1'
$StateDir = Join-Path $env:TEMP 'agent-status-lights'

$port = 8787
try { $port = (Get-Content $ConfigPath -Raw | ConvertFrom-Json).serverPort } catch {}
if (-not $port) { $port = 8787 }

function Read-Json($p) { try { return Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null } }

function Resolve-OpenRgb($cfg) {
  if ($cfg.openRgbPath -and (Test-Path $cfg.openRgbPath)) { return $cfg.openRgbPath }
  foreach ($n in 'OpenRGB','OpenRGB.exe') { $c = Get-Command $n -ErrorAction SilentlyContinue; if ($c) { return $c.Source } }
  foreach ($g in @('C:\Program Files\OpenRGB\OpenRGB.exe', (Join-Path $env:USERPROFILE 'scoop\apps\openrgb\current\OpenRGB.exe'))) { if (Test-Path $g) { return $g } }
  return $null
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
try { $listener.Start() } catch {
  Write-Host "Failed to bind http://localhost:$port/  ($_)" -ForegroundColor Red
  Write-Host "Tip: pick another port in config, or use the Node server (start-ui.ps1)." -ForegroundColor Yellow
  return
}
Write-Host "PowerShell UI server running at http://localhost:$port  (Ctrl+C to stop)" -ForegroundColor Green

$ctypes = @{ '.html'='text/html'; '.js'='application/javascript'; '.css'='text/css' }

while ($listener.IsListening) {
  try {
    $ctx = $listener.GetContext()
    $req = $ctx.Request
    $res = $ctx.Response
    $path = $req.Url.AbsolutePath
    $body = ''
    if ($req.HasEntityBody) {
      $sr = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
      $body = $sr.ReadToEnd(); $sr.Close()
    }
    $bodyObj = $null; if ($body) { try { $bodyObj = $body | ConvertFrom-Json } catch {} }

    function Send($obj, $code=200, $ctype='application/json') {
      $bytes = [System.Text.Encoding]::UTF8.GetBytes(($(if ($ctype -eq 'application/json') { $obj | ConvertTo-Json -Depth 10 } else { $obj })))
      $res.StatusCode = $code; $res.ContentType = $ctype
      $res.ContentLength64 = $bytes.Length
      $res.OutputStream.Write($bytes, 0, $bytes.Length)
      $res.OutputStream.Close()
    }

    if ($req.HttpMethod -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
      Send (Get-Content (Join-Path $UiDir 'index.html') -Raw) 200 'text/html'
    }
    elseif ($req.HttpMethod -eq 'GET' -and ($path -eq '/app.js' -or $path -eq '/styles.css')) {
      $f = Join-Path $UiDir ($path.TrimStart('/'))
      Send (Get-Content $f -Raw) 200 ($ctypes[[System.IO.Path]::GetExtension($f)])
    }
    elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/api/state') {
      $cfg = Read-Json $ConfigPath
      $exe = Resolve-OpenRgb $cfg
      Send ([pscustomobject]@{
        config = $cfg
        state = Read-Json (Join-Path $StateDir 'state.json')
        events = @(Read-Json (Join-Path $StateDir 'events.json'))
        openrgb = if ($exe) { @{ installed=$true; path=$exe } } else { @{ installed=$false } }
        provider = (Read-Json (Join-Path $StateDir 'state.json')).provider
        env = @{ TERM_PROGRAM=$env:TERM_PROGRAM; VSCODE_PID=$env:VSCODE_PID }
      })
    }
    elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/status') {
      $st = $bodyObj.status
      & powershell -NoProfile -ExecutionPolicy Bypass -File $Light -Status $st -Source ui | Out-Null
      Send @{ ok=$true; status=$st }
    }
    elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/config') {
      if (Test-Path $ConfigPath) { Copy-Item $ConfigPath ("$ConfigPath." + (Get-Date -Format 'yyyyMMddHHmmss') + '.bak') -Force }
      ($bodyObj | ConvertTo-Json -Depth 10) | Set-Content $ConfigPath -Encoding UTF8
      Send @{ ok=$true }
    }
    elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/test') {
      Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Test,'-DelaySeconds','1')
      Send @{ ok=$true; out='test launched in new window' }
    }
    elseif ($req.HttpMethod -eq 'POST' -and ($path -eq '/api/install' -or $path -eq '/api/uninstall')) {
      $script = if ($path -eq '/api/install') { $Install } else { $Uninstall }
      $target = if ($bodyObj.target) { $bodyObj.target } else { 'all' }
      $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script,'-Target',$target)
      if ($bodyObj.plan) { $args += '-Plan' }
      $out = & powershell @args | Out-String
      Send @{ ok=$true; out=$out }
    }
    elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/api/devices') {
      $cfg = Read-Json $ConfigPath; $exe = Resolve-OpenRgb $cfg
      if ($exe) { $out = & $exe --list-devices 2>&1 | Out-String; Send @{ installed=$true; path=$exe; raw=$out } }
      else { Send @{ installed=$false; devices=@() } }
    }
    else { $res.StatusCode = 404; $res.OutputStream.Close() }
  } catch {
    try { $res.StatusCode = 500; $res.OutputStream.Close() } catch {}
  }
}
