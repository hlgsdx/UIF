# Install VS 2017 v141_xp into GitHub's VS 2022 instance.
# Does not change the modern x86/x64 matrix jobs.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$installerDir = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'
$vswhere = Join-Path $installerDir 'vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw "vswhere.exe not found: $vswhere" }

# Query the actual installed edition/channel rather than assuming an Enterprise layout.
$instance = & $vswhere -latest -products '*' -version '[17.0,18.0)' -format json |
    ConvertFrom-Json | Select-Object -First 1
if ($null -eq $instance) { throw 'Visual Studio 2022 instance not found' }
$vsPath = [string]$instance.installationPath
$productId = [string]$instance.productId
$channelId = [string]$instance.channelId
if ([string]::IsNullOrWhiteSpace($vsPath) -or [string]::IsNullOrWhiteSpace($productId) -or
    [string]::IsNullOrWhiteSpace($channelId)) {
    throw 'vswhere did not return installationPath/productId/channelId for VS 2022'
}

$toolsetDir = Join-Path $vsPath 'MSBuild\Microsoft\VC\v170\Platforms\Win32\PlatformToolsets\v141_xp'
$toolsDir = Join-Path $vsPath 'VC\Tools\MSVC'

function Test-XpToolset {
    if (-not (Test-Path -LiteralPath (Join-Path $toolsetDir 'Toolset.props'))) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $toolsetDir 'Toolset.targets'))) { return $false }
    if (-not (Test-Path -LiteralPath $toolsDir)) { return $false }
    $v141 = @(Get-ChildItem -LiteralPath $toolsDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^14\.1\d\.' })
    return ($v141.Count -gt 0)
}

function Show-InstallerDiagnostics {
    Write-Host 'VS install diagnostic details:'
    & $vswhere -latest -products '*' -version '[17.0,18.0)' -format json | Out-Host
    if (Test-Path -LiteralPath $toolsDir) {
        Get-ChildItem -LiteralPath $toolsDir -Directory | Select-Object -ExpandProperty Name | Out-Host
    }
    # Installer error logs are typically under runneradmin's TEMP directory.
    $logs = @(Get-ChildItem -LiteralPath $env:TEMP -Filter 'dd_*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 5)
    foreach ($log in $logs) {
        Write-Host "--- $($log.FullName) (last 50 lines) ---"
        Get-Content -LiteralPath $log.FullName -Tail 50 -ErrorAction SilentlyContinue | Out-Host
    }
}

if (-not (Test-XpToolset)) {
    # vs_installer.exe is the actual installer executable; setup.exe is its CLI alternative.
    $installer = Join-Path $installerDir 'vs_installer.exe'
    if (-not (Test-Path -LiteralPath $installer)) {
        $installer = Join-Path $installerDir 'setup.exe'
    }
    if (-not (Test-Path -LiteralPath $installer)) {
        throw 'Neither vs_installer.exe nor setup.exe was found in the Visual Studio Installer directory'
    }

    # XP support and its VS 2017 x86/x64 compiler are separate component IDs.
    $arguments = 'modify --installPath "{0}" --productId {1} --channelId {2} --add Microsoft.VisualStudio.Component.WinXP --add Microsoft.VisualStudio.Component.VC.v141.x86.x64 --quiet --norestart' -f $vsPath, $productId, $channelId
    Write-Host "Installing v141_xp into: $vsPath"
    Write-Host "Installer: $installer"
    Write-Host "Arguments: $arguments"
    $result = Start-Process -FilePath $installer -ArgumentList $arguments `
        -WorkingDirectory $env:TEMP -Wait -PassThru
    Write-Host "Visual Studio Installer exit code: $($result.ExitCode)"
    if ($result.ExitCode -ne 0) {
        Show-InstallerDiagnostics
        throw "v141_xp installation failed with exit code $($result.ExitCode)"
    }

    # Do not interpret exit code 0 as proof of installation: verify actual MSBuild files.
    for ($attempt = 0; $attempt -lt 12 -and -not (Test-XpToolset); $attempt++) {
        Start-Sleep -Seconds 5
    }
}

if (-not (Test-XpToolset)) {
    Show-InstallerDiagnostics
    throw "v141_xp is still missing or incomplete after installation: $toolsetDir"
}

Write-Host "v141_xp verified: $toolsetDir"
$componentMatches = @(& $vswhere -latest -products '*' -version '[17.0,18.0)' `
    -requires Microsoft.VisualStudio.Component.WinXP Microsoft.VisualStudio.Component.VC.v141.x86.x64 `
    -property installationPath)
if ($componentMatches.Count -eq 0) {
    Write-Warning 'vswhere component metadata has not yet reflected the toolset; verified on-disk files instead.'
} else {
    Write-Host ('vswhere component verification: ' + ($componentMatches -join ', '))
}
