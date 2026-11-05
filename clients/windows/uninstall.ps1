# =============================================================================
# win/uninstall.ps1 — Удаление Mihomo с Windows
# Версия: 1.0.0
# Требуется: PowerShell 7.4+, права администратора
# Использование:
#   .\uninstall.ps1
#   .\uninstall.ps1 -InstallDir "D:\mihomo"
#   .\uninstall.ps1 -KeepConfig   # сохранить configs/config.yaml
# =============================================================================

param(
    [string]$InstallDir = "C:\ProgramData\mihomo",
    [switch]$KeepConfig,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# --- Проверка прав администратора ---
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Требуются права администратора."
    exit 1
}

if (-not (Test-Path $InstallDir)) {
    Write-Host "Каталог не найден: $InstallDir" -ForegroundColor Yellow
    exit 0
}

# --- Подтверждение ---
if (-not $Force) {
    Write-Host "Будет удалён Mihomo из: $InstallDir" -ForegroundColor Yellow
    if ($KeepConfig) {
        Write-Host "  (config.yaml будет сохранён)" -ForegroundColor Yellow
    }
    $confirm = Read-Host "Продолжить? [y/N]"
    if ($confirm -notmatch '^[Yy]$') {
        Write-Host "Отменено."
        exit 0
    }
}

# --- Остановка и удаление службы ---
$winswPath = "$InstallDir\mihomo-service.exe"
if (Test-Path $winswPath) {
    Write-Host "[1/3] Остановка службы..." -ForegroundColor Cyan
    & $winswPath stop 2>$null | Out-Null
    & $winswPath uninstall 2>$null | Out-Null
    Write-Host "  Служба MihomoProxy удалена." -ForegroundColor Green
} else {
    # Fallback: удаление через sc.exe
    $svc = Get-Service -Name "MihomoProxy" -ErrorAction SilentlyContinue
    if ($svc) {
        Stop-Service -Name "MihomoProxy" -Force -ErrorAction SilentlyContinue
        sc.exe delete "MihomoProxy" | Out-Null
        Write-Host "  Служба MihomoProxy удалена через sc.exe." -ForegroundColor Green
    }
}

# --- Сброс системного прокси ---
Write-Host "[2/3] Сброс системного прокси..." -ForegroundColor Cyan
$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 0 -ErrorAction SilentlyContinue
Write-Host "  Системный прокси отключён." -ForegroundColor Green

# --- Удаление файлов ---
Write-Host "[3/3] Удаление файлов..." -ForegroundColor Cyan
if ($KeepConfig) {
    $backup = "$env:USERPROFILE\mihomo-config-backup.yaml"
    Copy-Item "$InstallDir\configs\config.yaml" $backup -Force -ErrorAction SilentlyContinue
    Write-Host "  Конфиг сохранён: $backup" -ForegroundColor Yellow
}
Remove-Item -Recurse -Force $InstallDir
Write-Host "  Каталог удалён: $InstallDir" -ForegroundColor Green

Write-Host "`nУдаление завершено." -ForegroundColor Green