param(
  [string]$ToolRoot = "D:\DevTools\foreverhealth",
  [switch]$InstallAndroidToolchain,
  [switch]$SkipVSCodeExtensions
)

$ErrorActionPreference = "Stop"

$DartSdkPackageId = "Google.DartSDK"
$FvmVersion = "4.0.5"
$FlutterVersion = "3.41.7"
$PythonVersion = "3.12.9"
$GitHubCliVersion = "2.91.0"

$DartSdkRoot = Join-Path $ToolRoot "dart-sdk"
$DartSdkBin = Join-Path $DartSdkRoot "bin"
$PubCacheRoot = Join-Path $ToolRoot "pub-cache"
$PubCacheBin = Join-Path $PubCacheRoot "bin"
$FvmCachePath = Join-Path $ToolRoot "fvm"
$UvPythonInstallDir = Join-Path $ToolRoot "uv-python"

function Write-Section {
  param([string]$Message)
  Write-Host ""
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Test-Command {
  param([string]$Name)
  return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Add-UserPathEntry {
  param([string]$PathEntry)

  if (-not (Test-Path $PathEntry)) {
    return
  }

  $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
  $parts = @()
  if ($userPath) {
    $parts = $userPath -split ";" | Where-Object { $_ }
  }

  if ($parts -notcontains $PathEntry) {
    $parts += $PathEntry
    [System.Environment]::SetEnvironmentVariable("Path", ($parts -join ";"), "User")
  }
}

function Refresh-CurrentPath {
  $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
  $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
  $env:Path = "$DartSdkBin;$PubCacheBin;$machinePath;$userPath"
}

function Invoke-WingetInstall {
  param(
    [string]$Id,
    [string]$Name
  )

  Write-Section "Installing $Name"
  winget install --id $Id --exact --accept-package-agreements --accept-source-agreements
}

Write-Section "Checking winget"
$HasWinget = Test-Command "winget"
if (-not $HasWinget) {
  Write-Warning "winget was not found. Continuing with direct Dart/FVM/Flutter setup and skipping optional winget-managed tools."
}

Write-Section "Preparing D: tool root"
New-Item -ItemType Directory -Force -Path $ToolRoot, $PubCacheRoot, $FvmCachePath, $UvPythonInstallDir | Out-Null
$env:PUB_CACHE = $PubCacheRoot
$env:FVM_CACHE_PATH = $FvmCachePath
$env:UV_PYTHON_INSTALL_DIR = $UvPythonInstallDir
[System.Environment]::SetEnvironmentVariable("PUB_CACHE", $PubCacheRoot, "User")
[System.Environment]::SetEnvironmentVariable("FVM_CACHE_PATH", $FvmCachePath, "User")
[System.Environment]::SetEnvironmentVariable("UV_PYTHON_INSTALL_DIR", $UvPythonInstallDir, "User")
[System.Environment]::SetEnvironmentVariable("FOREVERHEALTH_TOOL_ROOT", $ToolRoot, "User")

Write-Section "Installing Dart SDK to $DartSdkRoot"
if (-not (Test-Path (Join-Path $DartSdkBin "dart.exe"))) {
  $dartZip = Join-Path $ToolRoot "dart-sdk.zip"
  $dartUrl = "https://storage.googleapis.com/dart-archive/channels/stable/release/latest/sdk/dartsdk-windows-x64-release.zip"
  Invoke-WebRequest -Uri $dartUrl -OutFile $dartZip
  Expand-Archive -LiteralPath $dartZip -DestinationPath $ToolRoot -Force
  Remove-Item -LiteralPath $dartZip -Force
  if (-not (Test-Path (Join-Path $DartSdkBin "dart.exe"))) {
    throw "Dart SDK install failed. Expected dart.exe at $DartSdkBin"
  }
} else {
  Write-Host "Dart SDK already exists at $DartSdkBin"
}

Add-UserPathEntry -PathEntry $DartSdkBin
Add-UserPathEntry -PathEntry $PubCacheBin
Refresh-CurrentPath

Write-Section "Installing FVM"
if (-not (Test-Path (Join-Path $PubCacheBin "fvm.bat"))) {
  & (Join-Path $DartSdkBin "dart.exe") pub global activate fvm $FvmVersion
} else {
  Write-Host "FVM already exists at $PubCacheBin"
}

Refresh-CurrentPath

Write-Section "Installing Flutter $FlutterVersion via FVM"
& (Join-Path $PubCacheBin "fvm.bat") install $FlutterVersion
try {
  & (Join-Path $PubCacheBin "fvm.bat") use $FlutterVersion --force --skip-pub-get --skip-setup
} catch {
  Write-Warning "FVM could not create the project .fvm symlink. This is common on Windows without Developer Mode/admin symlink privilege."
  Write-Warning "The SDK is still installed in $FvmCachePath and project.ps1 can run through fvm.bat."
}

$InstalledFlutterSdk = Join-Path $FvmCachePath "versions\$FlutterVersion"
$ProjectFvmDir = Join-Path (Get-Location) ".fvm"
$ProjectFvmVersionsDir = Join-Path $ProjectFvmDir "versions"
$ProjectFlutterSdkLink = Join-Path $ProjectFvmDir "flutter_sdk"
$ProjectVersionLink = Join-Path $ProjectFvmVersionsDir $FlutterVersion
if ((Test-Path $InstalledFlutterSdk) -and -not (Test-Path $ProjectFlutterSdkLink)) {
  New-Item -ItemType Directory -Force -Path $ProjectFvmVersionsDir | Out-Null
  try {
    New-Item -ItemType Junction -Path $ProjectFlutterSdkLink -Target $InstalledFlutterSdk | Out-Null
    if (-not (Test-Path $ProjectVersionLink)) {
      New-Item -ItemType Junction -Path $ProjectVersionLink -Target $InstalledFlutterSdk | Out-Null
    }
    Write-Host "Created .fvm junctions for VS Code without requiring symlink privilege."
  } catch {
    Write-Warning "Could not create .fvm junctions. Use fvm flutter from the terminal, or enable Windows Developer Mode for symlinks."
  }
}

Write-Section "Installing GitHub CLI"
if (-not $HasWinget) {
  Write-Warning "Skipping GitHub CLI installation because winget is unavailable."
} elseif (-not (Test-Command "gh") -and -not (Test-Path "C:\Program Files\GitHub CLI\gh.exe")) {
  winget install --id GitHub.cli --exact --version $GitHubCliVersion --accept-package-agreements --accept-source-agreements
} else {
  Write-Host "GitHub CLI already installed"
}

Write-Section "Installing uv and Python 3.12"
if (-not $HasWinget) {
  Write-Warning "Skipping uv installation because winget is unavailable."
} elseif (-not (Test-Command "uv")) {
  try {
    Invoke-WingetInstall -Id "astral-sh.uv" -Name "uv"
  } catch {
    Write-Warning "Could not install uv via winget. Install uv manually from https://docs.astral.sh/uv/"
  }
}

if (Test-Command "uv") {
  uv python install $PythonVersion
} else {
  Write-Warning "uv is not available, skipping Python 3.12 installation."
}

if (-not $SkipVSCodeExtensions) {
  Write-Section "Installing VS Code extensions"
  if (Test-Command "code") {
    code --install-extension Dart-Code.dart-code --force
    code --install-extension Dart-Code.flutter --force
  } else {
    Write-Warning "VS Code command 'code' was not found. Install VS Code or enable the shell command manually."
  }
}

if ($InstallAndroidToolchain) {
  Write-Section "Installing Android Studio"
  if (-not $HasWinget) {
    throw "Android Studio installation requires winget in this setup script."
  }
  Invoke-WingetInstall -Id "Google.AndroidStudio" -Name "Android Studio"
  Write-Warning "Open Android Studio once after installation to install Android SDK and command-line tools."
}

Write-Section "Flutter doctor"
& (Join-Path $PubCacheBin "fvm.bat") flutter doctor

Write-Host ""
Write-Host "Windows setup complete." -ForegroundColor Green
Write-Host "Open a new PowerShell window so PATH changes are picked up."
Write-Host "Use: fvm flutter doctor"
