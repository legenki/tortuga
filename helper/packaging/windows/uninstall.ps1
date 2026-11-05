# Remove the Tortuga helper installed by install.ps1 for this Windows user.
# The helper's data (%APPDATA%\Tortuga\tortuga-helper) and downloads
# (Downloads\Tortuga) are left alone.
$ErrorActionPreference = 'SilentlyContinue'
foreach ($k in 'Mozilla', 'Google\Chrome', 'Chromium') {
  Remove-Item -Path "HKCU:\Software\$k\NativeMessagingHosts\org.tortuga.helper" -Force
}
$to = Join-Path $env:LOCALAPPDATA 'Tortuga'
foreach ($f in 'tortuga-helper.exe', 'firefox.json', 'chrome.json', 'uninstall.ps1') {
  Remove-Item -Path (Join-Path $to $f) -Force
}
Remove-Item -Path (Join-Path $to 'pt') -Recurse -Force
Write-Output 'Tortuga helper removed.'
