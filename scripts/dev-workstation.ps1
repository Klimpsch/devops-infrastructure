#Requires -RunAsAdministrator
<#
    bootstrap-dev.ps1
    Installs Chocolatey + common dev tooling.
    Usage:  iex ((New-Object Net.WebClient).DownloadString('https://your-host/bootstrap-dev.ps1'))
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

# 1. Install Chocolatey
Write-Step "Installing Chocolatey"
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object Net.WebClient).DownloadString(
        'https://community.chocolatey.org/install.ps1'))
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path','User')
} else {
    Write-Host "Chocolatey already installed."
}

choco feature enable -n=allowGlobalConfirmation | Out-Null

# 2. Install packages
Write-Step "Installing developer packages"
$packages = @(
    'vscode',
    'git',
    'nodejs-lts',
    'dotnet-sdk',
    'docker-desktop'
)

foreach ($pkg in $packages) {
    Write-Host " - $pkg"
    choco install $pkg --limit-output --no-progress
}

Write-Step "Done"
Write-Host "Reboot recommended so Docker Desktop / WSL finish initialising."
