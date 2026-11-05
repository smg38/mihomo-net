# =============================================================================
# win/install.ps1 — Установка Mihomo на Windows
# Версия: 1.0.0
# Требуется: PowerShell 7.4+, права администратора
# Использование:
#   .\install.ps1 -ConfigUrl "http://<IP_C>/mihomo/sub/<token>"
#   .\install.ps1 -ConfigUrl "..." -SkipTun
#   .\install.ps1 -ConfigUrl "..." -InstallDir "D:\mihomo"
# =============================================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$ConfigUrl,

    [string]$InstallDir = "C:\ProgramData\mihomo",
    [switch]$SkipTun,
    [switch]$SkipService
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# --- Проверка прав администратора ---
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Требуются права администратора. Запустите PowerShell от имени администратора."
    exit 1
}

# --- Проверка PowerShell 7.4+ ---
if ($PSVersionTable.PSVersion.Major -lt 7 -or
    ($PSVersionTable.PSVersion.Major -eq 7 -and $PSVersionTable.PSVersion.Minor -lt 4)) {
    Write-Error "Требуется PowerShell 7.4+. Скачайте: https://github.com/PowerShell/PowerShell/releases"
    exit 1
}

# --- Определение архитектуры ---
$arch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "386" }

Write-Host "[1/6] Создание каталогов..." -ForegroundColor Cyan
foreach ($d in @("$InstallDir", "$InstallDir\bin", "$InstallDir\configs", "$InstallDir\data", "$InstallDir\logs")) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

Write-Host "[2/6] Загрузка mihomo.exe (${arch})..." -ForegroundColor Cyan
$mihomoUrl = "https://github.com/MetaCubeX/mihomo/releases/latest/download/mihomo-windows-${arch}-v1-compatible.zip"
$mihomoZip = "$env:TEMP\mihomo-$([guid]::NewGuid()).zip"
Invoke-WebRequest -Uri $mihomoUrl -OutFile $mihomoZip
Expand-Archive -Path $mihomoZip -DestinationPath "$InstallDir\bin" -Force
Remove-Item $mihomoZip -Force

# Переименовать распакованный файл в mihomo.exe (в zip имя с версией)
$extracted = Get-ChildItem "$InstallDir\bin" -Filter "mihomo*.exe" | Select-Object -First 1
if ($extracted.Name -ne "mihomo.exe") {
    Move-Item $extracted.FullName "$InstallDir\bin\mihomo.exe" -Force
}

Write-Host "[3/6] Загрузка конфигурации..." -ForegroundColor Cyan
$configPath = "$InstallDir\configs\config.yaml"
Invoke-WebRequest -Uri $ConfigUrl -OutFile $configPath

Write-Host "[4/6] Валидация конфигурации..." -ForegroundColor Cyan
$validateResult = & "$InstallDir\bin\mihomo.exe" -t -d "$InstallDir\configs" -f $configPath 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Конфигурация невалидна:`n$validateResult"
    exit 1
}

Write-Host "[5/6] Загрузка WinSW для службы..." -ForegroundColor Cyan
if (-not $SkipService) {
    $winswUrl = "https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe"
    $winswPath = "$InstallDir\mihomo-service.exe"
    Invoke-WebRequest -Uri $winswUrl -OutFile $winswPath

    $serviceXml = @"
<service>
  <id>MihomoProxy</id>
  <name>Mihomo Proxy Service</name>
  <description>Mihomo rule-based proxy core</description>
  <executable>$InstallDir\bin\mihomo.exe</executable>
  <arguments>-d "$InstallDir\configs"</arguments>
  <logpath>$InstallDir\logs</logpath>
  <log mode="roll-by-size-time">
    <sizeThreshold>10240</sizeThreshold>
    <pattern>yyyyMMdd</pattern>
  </log>
  <onfailure action="restart" delay="5 sec"/>
  <stoptimeout>15 sec</stoptimeout>
</service>
"@
    $serviceXml | Out-File -FilePath "$InstallDir\mihomo-service.xml" -Encoding UTF8

    & $winswPath install
    & $winswPath start
    Write-Host "  Служба MihomoProxy установлена и запущена." -ForegroundColor Green
} else {
    Write-Host "  Служба пропущена (-SkipService)." -ForegroundColor Yellow
}

Write-Host "[6/6] Настройка TUN..." -ForegroundColor Cyan
if (-not $SkipTun) {
    # Установка Wintun (драйвер TUN для Windows)
    $wintunUrl = "https://www.wintun.net/builds/wintun-0.14.1.zip"
    $wintunZip = "$env:TEMP\wintun.zip"
    Invoke-WebRequest -Uri $wintunUrl -OutFile $wintunZip
    Expand-Archive -Path $wintunZip -DestinationPath "$env:TEMP\wintun" -Force
    $wintunDll = Get-ChildItem "$env:TEMP\wintun" -Recurse -Filter "wintun.dll" |
                 Where-Object { $_.FullName -match "amd64" } | Select-Object -First 1
    Copy-Item $wintunDll.FullName "$InstallDir\bin\wintun.dll" -Force
    Remove-Item $wintunZip, "$env:TEMP\wintun" -Recurse -Force

    Write-Host "  Wintun установлен. Включите TUN в config.yaml:" -ForegroundColor Yellow
    Write-Host "    tun:" -ForegroundColor Yellow
    Write-Host "      enable: true" -ForegroundColor Yellow
    Write-Host "      stack: gvisor" -ForegroundColor Yellow
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host " Установка завершена!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host " Каталог:      $InstallDir"
Write-Host " Конфигурация: $configPath"
Write-Host " Веб-панель:   http://127.0.0.1:9090/ui"
Write-Host " Прокси:       HTTP/SOCKS5 на порту 7890"
Write-Host ""
Write-Host " Управление службой:" -ForegroundColor Cyan
Write-Host "   & '$InstallDir\mihomo-service.exe' [start|stop|restart|status|uninstall]"
Write-Host ""
Write-Host " Удаление:" -ForegroundColor Cyan
Write-Host "   .\uninstall.ps1 -InstallDir '$InstallDir'"