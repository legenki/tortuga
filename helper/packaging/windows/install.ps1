# Install the Tortuga helper for this Windows user (no admin rights needed):
# copy it to %LOCALAPPDATA%\Tortuga and register it as the org.tortuga.helper
# native messaging host for Firefox, and — when the Chrome ID is pinned — for
# Chrome and Chromium. Run from the unzipped folder:
#   powershell -ExecutionPolicy Bypass -File install.ps1
$ErrorActionPreference = 'Stop'
$from = $PSScriptRoot
$to = Join-Path $env:LOCALAPPDATA 'Tortuga'
New-Item -ItemType Directory -Force -Path (Join-Path $to 'pt') | Out-Null
Copy-Item (Join-Path $from 'tortuga-helper.exe') $to -Force
Copy-Item (Join-Path $from 'pt\*') (Join-Path $to 'pt') -Force
Copy-Item (Join-Path $from 'uninstall.ps1') $to -Force

$ids = Get-Content (Join-Path $from 'ids.json') -Raw | ConvertFrom-Json
$exe = Join-Path $to 'tortuga-helper.exe'

function Write-HostManifest($file, $allowedKey, $allowed) {
  $manifest = [ordered]@{
    name = 'org.tortuga.helper'
    description = 'Tortuga helper'
    path = $exe
    type = 'stdio'
  }
  $manifest[$allowedKey] = @($allowed)
  $path = Join-Path $to $file
  # UTF-8 without a byte-order mark: browsers read the manifest as JSON.
  [System.IO.File]::WriteAllText($path, ($manifest | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding $false))
  return $path
}

function Register-Host($registryKey, $manifestPath) {
  $key = "HKCU:\Software\$registryKey\NativeMessagingHosts\org.tortuga.helper"
  New-Item -Force -Path $key | Out-Null
  Set-Item -Path $key -Value $manifestPath
}

$firefox = Write-HostManifest 'firefox.json' 'allowed_extensions' $ids.firefox
Register-Host 'Mozilla' $firefox
Write-Output "Firefox: $firefox"
if ($ids.chrome) {
  $chrome = Write-HostManifest 'chrome.json' 'allowed_origins' "chrome-extension://$($ids.chrome)/"
  Register-Host 'Google\Chrome' $chrome
  Register-Host 'Chromium' $chrome
  Write-Output "Chrome and Chromium: $chrome"
} else {
  Write-Output 'Chrome ID not pinned: registered for Firefox only.'
}
Write-Output "Installed in $to"
