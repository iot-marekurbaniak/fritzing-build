#Requires -Version 5.1
<#
.SYNOPSIS
    Local, GitHub-free build of the unsigned Fritzing Windows x64 distribution.

.DESCRIPTION
    One command that checks every prerequisite before the first heavy download, installs Qt with the
    aqtinstall version pinned in versions.lock.json when QT_ROOT does not point at a complete Qt,
    runs the validated bootstrap-windows.ps1 and build-windows.ps1 of this kit, adds the four part
    packages of parts/dist to the distribution as custom-parts/, writes the SHA-256 of the final ZIP
    and keeps a log.

    Nothing is uploaded and no toolchain is installed automatically. Visual Studio 2022 with the C++
    workload, CMake, Git, Python and 7-Zip have to be present already; a missing prerequisite is
    reported with the exact command that fixes it. Only the PATH of this process is extended, the
    system and user PATH are never modified.

    Re-running is safe and cheap: a complete Qt, the fetched sources, the built dependencies and an
    existing build output are reused instead of being downloaded or built again.

.PARAMETER WorkDir
    Working directory for Qt, sources, dependencies and object files (about 30 GB). Kept between
    runs so that a repeated run resumes. Default: <user profile>\fritzing-build.

.PARAMETER OutDir
    Directory for the final ZIP, its SHA-256 file and the logs. Default: <kit>\out.

.PARAMETER QtRoot
    Existing Qt installation to use, for example D:\Qt\6.8.3\msvc2022_64. Defaults to the QT_ROOT
    environment variable. When it is empty or incomplete, Qt is installed into WorkDir\Qt.

.PARAMETER ForceQtInstall
    Install Qt into WorkDir\Qt again even if a complete Qt is already there.

.PARAMETER SkipBootstrap
    Reuse the sources and dependencies already present in WorkDir without contacting the network.

.PARAMETER SkipBuild
    Reuse the ZIP produced by an earlier build and only repackage it with custom-parts/.

.EXAMPLE
    .\scripts\build-local-windows.ps1

.EXAMPLE
    .\scripts\build-local-windows.ps1 -WorkDir 'D:\fritzing build' -OutDir 'D:\fritzing out'

.NOTES
    Exit codes: 0 success, 1 failure, 2 not running on Windows, 3 missing prerequisite.
#>
[CmdletBinding()]
param(
  [ValidateNotNullOrEmpty()]
  [string]$WorkDir = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'fritzing-build'),
  [ValidateNotNullOrEmpty()]
  [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'out'),
  [string]$QtRoot = $env:QT_ROOT,
  [switch]$ForceQtInstall,
  [switch]$SkipBootstrap,
  [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PSHostPath = ''
$script:TranscriptStarted = $false
# Files that only exist in a complete Qt with the two modules from the lock (qt5compat, qtserialport).
$script:QtMarker = @(
  'bin\qmake.exe', 'bin\lrelease.exe', 'bin\windeployqt.exe', 'bin\Qt6Core.dll', 'bin\Qt6Svg.dll',
  'bin\Qt6Core5Compat.dll', 'bin\Qt6SerialPort.dll', 'lib\Qt6Core.lib', 'include\QtCore'
)

function Write-Step {
  # Progress lines go to the output stream so that the transcript log keeps them.
  param([Parameter(Mandatory)][string]$Message)
  Write-Output ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message)
}

function Get-FullPath {
  # Absolute path without a trailing separator, resolved against the location of the caller and
  # without requiring the path to exist. A trailing backslash would be escaped by the Windows
  # command line when the path is passed to a child process.
  param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path)
  $Combined = [System.IO.Path]::Combine((Get-Location).ProviderPath, $Path.Trim())
  $Full = [System.IO.Path]::GetFullPath($Combined)
  if ($Full.Length -gt 3) { $Full = $Full.TrimEnd('\', '/') }
  return $Full
}

function Get-PowerShellHostPath {
  # The kit scripts are started as child processes: that is how the GitHub workflow runs them, it
  # keeps Set-StrictMode of this orchestrator out of them and it isolates the MSVC environment.
  $Name = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
  $Candidate = Join-Path $PSHOME $Name
  if (Test-Path -LiteralPath $Candidate) { return $Candidate }
  $Command = @(Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue)
  if ($Command.Count -gt 0) { return $Command[0].Source }
  throw "Cannot locate $Name. Run this script from Windows PowerShell 5.1 or PowerShell 7."
}

function Invoke-Tool {
  # Run a program, stream its output into the console and the log, fail on a non-zero exit code.
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArgumentList,
    [Parameter(Mandatory)][string]$Stage
  )
  # Merging the error stream keeps the output of tools that log to stderr (aqt, cmake, curl) in the
  # transcript. Windows PowerShell 5.1 turns those lines into error records, which would abort the
  # pipeline while $ErrorActionPreference is 'Stop'; the function-scoped 'Continue' prevents that
  # and the exit code below is what decides about success.
  $ErrorActionPreference = 'Continue'
  & $FilePath @ArgumentList 2>&1 |
    ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { $_ } }
  $Code = $LASTEXITCODE
  if ($Code -ne 0) { throw ('{0} failed with exit code {1}' -f $Stage, $Code) }
}

function Invoke-KitScript {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArgumentList,
    [Parameter(Mandatory)][string]$Stage
  )
  $HostArgument = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Path)
  Invoke-Tool -FilePath $script:PSHostPath -ArgumentList ($HostArgument + $ArgumentList) -Stage $Stage
}

function Invoke-Capture {
  # Run a program and return its exit code and output instead of streaming it.
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArgumentList
  )
  $ErrorActionPreference = 'Continue'
  try {
    $Output = & $FilePath @ArgumentList 2>&1
    $Code = $LASTEXITCODE
    $Text = (@($Output) | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
  }
  catch {
    $Code = 1
    $Text = $_.Exception.Message
  }
  return [pscustomobject]@{ ExitCode = $Code; Output = $Text }
}

function Resolve-Tool {
  # Path of a program on PATH, or from a known installation directory. In the second case the
  # directory is prepended to the PATH of this process only (children inherit it); the system and
  # user PATH are not touched.
  param(
    [Parameter(Mandatory)][string]$Name,
    [AllowEmptyCollection()][string[]]$Candidate = @()
  )
  $Command = @(Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue)
  if ($Command.Count -gt 0) { return $Command[0].Source }
  foreach ($Pattern in $Candidate) {
    $Found = @(Get-Item -Path $Pattern -ErrorAction SilentlyContinue)
    if ($Found.Count -gt 0) {
      $env:PATH = '{0};{1}' -f $Found[0].DirectoryName, $env:PATH
      return $Found[0].FullName
    }
  }
  return ''
}

function Get-PythonInterpreter {
  # A real CPython 3.8+ that can create a virtual environment. The python.exe stub of the Microsoft
  # Store app execution alias is skipped: it only opens the Store and cannot run "-m venv".
  foreach ($Name in 'python.exe', 'python3.exe') {
    foreach ($Command in @(Get-Command -Name $Name -CommandType Application -All -ErrorAction SilentlyContinue)) {
      if ($Command.Source -like '*\WindowsApps\*') { continue }
      $Probe = Invoke-Capture -FilePath $Command.Source -ArgumentList @('-c', 'import sys;print(sys.version_info[0],sys.version_info[1])')
      if ($Probe.ExitCode -eq 0 -and $Probe.Output -match '(\d+)\s+(\d+)') {
        if ([int]$Matches[1] -eq 3 -and [int]$Matches[2] -ge 8) {
          return [pscustomobject]@{ FilePath = $Command.Source; Argument = @(); Version = "3.$($Matches[2])" }
        }
      }
    }
  }
  foreach ($Command in @(Get-Command -Name 'py.exe' -CommandType Application -ErrorAction SilentlyContinue)) {
    $Probe = Invoke-Capture -FilePath $Command.Source -ArgumentList @('-3', '-c', 'import sys;print(sys.version_info[0],sys.version_info[1])')
    if ($Probe.ExitCode -eq 0 -and $Probe.Output -match '(\d+)\s+(\d+)') {
      if ([int]$Matches[1] -eq 3 -and [int]$Matches[2] -ge 8) {
        return [pscustomobject]@{ FilePath = $Command.Source; Argument = @('-3'); Version = "3.$($Matches[2])" }
      }
    }
  }
  return $null
}

function Test-QtRoot {
  param([AllowEmptyString()][string]$Path)
  if (-not $Path) { return $false }
  foreach ($Marker in $script:QtMarker) {
    if (-not (Test-Path -LiteralPath (Join-Path $Path $Marker))) {
      Write-Verbose "Qt at '$Path' is incomplete: $Marker is missing"
      return $false
    }
  }
  return $true
}

function Get-PrerequisiteReport {
  # Everything is checked up front so that one run reports all missing prerequisites, each with the
  # command that installs it. Nothing here downloads or builds. Findings are returned instead of
  # printed, because the return value of this function is the report object.
  param(
    [Parameter(Mandatory)][string]$KitRoot,
    [Parameter(Mandatory)][string]$WorkDirectory,
    [Parameter(Mandatory)][bool]$NeedPython,
    [Parameter(Mandatory)][bool]$NeedToolchain,
    [Parameter(Mandatory)][bool]$NeedCompiler
  )
  $Problem = New-Object 'System.Collections.Generic.List[string]'
  $Note = New-Object 'System.Collections.Generic.List[string]'
  $Tool = @{}
  $Python = $null

  if (-not [Environment]::Is64BitOperatingSystem) {
    $Problem.Add('Fritzing is built here for x64 with a 64-bit Qt; this operating system is 32-bit.')
  }
  if ($WorkDirectory.Length -gt 60) {
    Write-Warning ("The working directory path is {0} characters long. MSVC, boost and nmake can hit the 260 character limit; consider -WorkDir C:\fritzing-build." -f $WorkDirectory.Length)
  }

  try {
    $Drive = New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot($WorkDirectory))
    $FreeGb = [math]::Round($Drive.AvailableFreeSpace / 1GB, 1)
    if ($FreeGb -lt 15) {
      $Problem.Add(("Only {0} GB free on {1}; the build needs about 30 GB. Free space or pass -WorkDir on another drive." -f $FreeGb, $Drive.Name))
    }
    elseif ($FreeGb -lt 30) {
      Write-Warning ("Only {0} GB free on {1}; about 30 GB is recommended." -f $FreeGb, $Drive.Name)
    }
    else {
      $Note.Add(("Free space on {0}: {1} GB" -f $Drive.Name, $FreeGb))
    }
  }
  catch {
    Write-Warning "Could not read the free space of the working directory: $($_.Exception.Message)"
  }

  foreach ($Relative in 'versions.lock.json', 'scripts\bootstrap-windows.ps1', 'scripts\build-windows.ps1',
    'scripts\msvc-env.ps1', 'parts\LICENSE.txt', 'parts\IMPORT-CUSTOM-PARTS.txt') {
    if (-not (Test-Path -LiteralPath (Join-Path $KitRoot $Relative))) {
      $Problem.Add("The build kit is incomplete: $Relative is missing. Extract the kit again.")
    }
  }
  $Package = @(Get-ChildItem -LiteralPath (Join-Path $KitRoot 'parts\dist') -Filter '*.fzpz' -ErrorAction SilentlyContinue)
  if ($Package.Count -eq 0) {
    $Problem.Add('No part packages in parts\dist. Extract the kit again or run "python scripts\package-parts.py".')
  }

  $Tool['7z'] = Resolve-Tool -Name '7z.exe' -Candidate @(
    "$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
    "$env:LOCALAPPDATA\Programs\7-Zip\7z.exe")
  if (-not $Tool['7z']) {
    $Problem.Add('7-Zip not found. Install it from https://www.7-zip.org/ or run: winget install --id 7zip.7zip')
  }

  if ($NeedToolchain) {
    $Tool['git'] = Resolve-Tool -Name 'git.exe' -Candidate @(
      "$env:ProgramFiles\Git\cmd\git.exe", "${env:ProgramFiles(x86)}\Git\cmd\git.exe",
      "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe")
    if (-not $Tool['git']) {
      $Problem.Add('Git not found. Install it from https://git-scm.com/download/win or run: winget install --id Git.Git')
    }
    $Tool['cmake'] = Resolve-Tool -Name 'cmake.exe' -Candidate @(
      "$env:ProgramFiles\CMake\bin\cmake.exe",
      "$env:ProgramFiles\Microsoft Visual Studio\2022\*\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
      "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\*\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe")
    if (-not $Tool['cmake']) {
      $Problem.Add('CMake not found. Install it from https://cmake.org/download/ or run: winget install --id Kitware.CMake')
    }
    foreach ($Name in 'curl.exe', 'tar.exe') {
      $Tool[$Name] = Resolve-Tool -Name $Name -Candidate @("$env:SystemRoot\System32\$Name")
      if (-not $Tool[$Name]) {
        $Problem.Add("$Name not found. It ships with Windows 10 1803 and newer; update Windows or add %SystemRoot%\System32 to PATH.")
      }
    }
  }

  if ($NeedCompiler) {
    # The MSVC check uses the kit script that the build itself uses, in a child process so that this
    # session keeps its own environment.
    $Probe = Invoke-Capture -FilePath $script:PSHostPath -ArgumentList @(
      '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $KitRoot 'scripts\msvc-env.ps1'))
    if ($Probe.ExitCode -ne 0) {
      $Problem.Add('Visual Studio 2022 with the C++ x64 toolset was not found (scripts\msvc-env.ps1: ' +
        ($Probe.Output -replace '\s+', ' ') + '). Install "Visual Studio 2022 Community" with the workload ' +
        '"Desktop development with C++", for example: winget install --id Microsoft.VisualStudio.2022.Community ' +
        '--override "--add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended"')
    }
    else {
      $Note.Add(('MSVC toolchain: {0}' -f ($Probe.Output -replace '\s+', ' ').Trim()))
    }
  }

  if ($NeedPython) {
    $Python = Get-PythonInterpreter
    if ($null -eq $Python) {
      $Problem.Add('Python 3.8+ not found (the Microsoft Store stub does not count). Install it from ' +
        'https://www.python.org/downloads/windows/ or run: winget install --id Python.Python.3.12')
    }
    else {
      $Note.Add(('Python {0}: {1}' -f $Python.Version, $Python.FilePath))
    }
  }
  foreach ($Key in ($Tool.Keys | Sort-Object)) {
    if ($Tool[$Key]) { $Note.Add(('{0}: {1}' -f $Key, $Tool[$Key])) }
  }

  return [pscustomobject]@{ Problem = $Problem.ToArray(); Note = $Note.ToArray(); Tool = $Tool; Python = $Python }
}

function Install-LocalQt {
  # Qt from the lock, installed with the pinned aqtinstall into a virtual environment inside the
  # working directory. Nothing is installed into the system Python.
  param(
    [Parameter(Mandatory)][pscustomobject]$Python,
    [Parameter(Mandatory)][string]$VenvDir,
    [Parameter(Mandatory)][string]$QtDir,
    [Parameter(Mandatory)][pscustomobject]$Qt
  )
  $VenvPython = Join-Path $VenvDir 'Scripts\python.exe'
  if (-not (Test-Path -LiteralPath $VenvPython)) {
    Write-Step "Creating the aqtinstall virtual environment in $VenvDir"
    Invoke-Tool -FilePath $Python.FilePath -ArgumentList ($Python.Argument + @('-m', 'venv', $VenvDir)) -Stage 'python -m venv'
  }
  if (-not (Test-Path -LiteralPath $VenvPython)) {
    throw "The virtual environment has no interpreter at $VenvPython. Delete $VenvDir and run again."
  }

  $Pinned = 'aqtinstall==' + $Qt.aqtinstall
  $Shown = Invoke-Capture -FilePath $VenvPython -ArgumentList @('-m', 'pip', 'show', 'aqtinstall')
  if ($Shown.ExitCode -ne 0 -or $Shown.Output -notmatch ('(?m)^Version:\s*' + [regex]::Escape($Qt.aqtinstall) + '\s*$')) {
    Write-Step "Installing $Pinned into the virtual environment"
    Invoke-Tool -FilePath $VenvPython -ArgumentList @('-m', 'pip', 'install', '--disable-pip-version-check', $Pinned) -Stage 'pip install aqtinstall'
  }
  else {
    Write-Step "$Pinned is already in the virtual environment"
  }

  Write-Step ("Installing Qt {0} {1} into {2} (several GB, this takes a while)" -f $Qt.version, $Qt.windows_arch, $QtDir)
  $Argument = @('-m', 'aqt', 'install-qt', 'windows', 'desktop', $Qt.version, $Qt.windows_arch,
    '--outputdir', $QtDir, '--modules') + [string[]]$Qt.modules
  Invoke-Tool -FilePath $VenvPython -ArgumentList $Argument -Stage 'aqt install-qt'
}

function Export-CustomPartFolder {
  # The four .fzpz packages of this kit plus their licence and import instructions, laid out as the
  # custom-parts folder that is added to the distribution.
  param(
    [Parameter(Mandatory)][string]$KitRoot,
    [Parameter(Mandatory)][string]$StageDir
  )
  $CustomDir = Join-Path $StageDir 'custom-parts'
  if (Test-Path -LiteralPath $StageDir) { Remove-Item -LiteralPath $StageDir -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $CustomDir | Out-Null
  $Package = @(Get-ChildItem -LiteralPath (Join-Path $KitRoot 'parts\dist') -Filter '*.fzpz' | Sort-Object Name)
  if ($Package.Count -eq 0) { throw "No .fzpz packages in $KitRoot\parts\dist" }
  foreach ($File in $Package) { Copy-Item -LiteralPath $File.FullName -Destination $CustomDir }
  Copy-Item -LiteralPath (Join-Path $KitRoot 'parts\IMPORT-CUSTOM-PARTS.txt') -Destination $CustomDir
  Copy-Item -LiteralPath (Join-Path $KitRoot 'parts\LICENSE.txt') -Destination $CustomDir
  return $Package.Name
}

function Test-FinalArchive {
  # Open the finished ZIP and confirm that the application, the parts database and every custom part
  # are really inside it.
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string[]]$PartName
  )
  if (-not ('System.IO.Compression.ZipFile' -as [type])) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
  }
  $Archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
  try { $Entry = @($Archive.Entries | ForEach-Object { $_.FullName -replace '\\', '/' }) }
  finally { $Archive.Dispose() }
  $Expected = @('Fritzing.exe', 'fritzing-parts/parts.db', 'ngspice.dll',
    'libomp140.x86_64.dll', 'ngspice/analog.cm', 'custom-parts/IMPORT-CUSTOM-PARTS.txt') +
  ($PartName | ForEach-Object { "custom-parts/$_" })
  $Missing = @($Expected | Where-Object { $Entry -notcontains $_ })
  if ($Missing.Count -gt 0) { throw ("The archive {0} does not contain: {1}" -f $Path, ($Missing -join ', ')) }
  return $Entry.Count
}

# --------------------------------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------------------------------
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
  Write-Error -ErrorAction Continue -Message ('This orchestrator builds Fritzing for Windows x64 with MSVC and has to run on Windows; this system is {0}. On macOS use scripts/bootstrap-macos.sh and scripts/build-macos.sh.' -f [Environment]::OSVersion.Platform)
  exit 2
}

$Started = [System.Diagnostics.Stopwatch]::StartNew()
$KitRoot = Split-Path -Parent $PSScriptRoot
$LockPath = Join-Path $KitRoot 'versions.lock.json'
if (-not (Test-Path -LiteralPath $LockPath)) { throw "versions.lock.json not found at $LockPath" }
$Lock = Get-Content -Raw -LiteralPath $LockPath | ConvertFrom-Json
$Qt = $Lock.qt

$WorkDir = Get-FullPath -Path $WorkDir
$OutDir = Get-FullPath -Path $OutDir
$DownloadDir = Join-Path $WorkDir 'downloads'
$BuildOutDir = Join-Path $WorkDir 'build-out'
$VenvDir = Join-Path $WorkDir 'aqt-venv'
$QtDir = Join-Path $WorkDir 'Qt'
$StageDir = Join-Path $WorkDir 'dist-extra'
$LogDir = Join-Path $OutDir 'logs'
if ($OutDir -eq $BuildOutDir) { throw "-OutDir must not be the internal build output directory $BuildOutDir" }
foreach ($Dir in @($WorkDir, $DownloadDir, $BuildOutDir, $OutDir, $LogDir)) {
  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
}

$LogFile = Join-Path $LogDir ('build-local-windows-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
try {
  Start-Transcript -LiteralPath $LogFile | Out-Null
  $script:TranscriptStarted = $true
}
catch {
  Write-Warning "This host cannot write a transcript log: $($_.Exception.Message)"
}

try {
  $script:PSHostPath = Get-PowerShellHostPath
  $LocalQtRoot = Join-Path $QtDir ('{0}\{1}' -f $Qt.version, $Qt.windows_dir)
  $BaseZip = Join-Path $BuildOutDir 'fritzing-windows-x64-unsigned.zip'
  $FinalZip = Join-Path $OutDir 'fritzing-windows-x64-unsigned.zip'

  Write-Step ('Fritzing {0} local Windows x64 build, no GitHub Actions, nothing is uploaded' -f $Lock.fritzing_app.version)
  Write-Step "Kit         : $KitRoot"
  Write-Step "Work dir    : $WorkDir"
  Write-Step "Output dir  : $OutDir"
  Write-Step "Log         : $LogFile"
  Write-Step ('PowerShell  : {0} ({1})' -f $PSVersionTable.PSVersion, $script:PSHostPath)

  # Step 1: decide what this run has to do, then check only the prerequisites it needs.
  $QtRootInUse = ''
  if (-not $ForceQtInstall -and (Test-QtRoot -Path $QtRoot)) { $QtRootInUse = Get-FullPath -Path $QtRoot }
  elseif (-not $ForceQtInstall -and (Test-QtRoot -Path $LocalQtRoot)) { $QtRootInUse = $LocalQtRoot }
  $NeedQtInstall = -not $QtRootInUse
  if ($QtRoot -and $NeedQtInstall -and -not $ForceQtInstall) {
    Write-Warning "QT_ROOT '$QtRoot' is not a complete Qt $($Qt.version) $($Qt.windows_dir); Qt will be installed into $QtDir"
  }

  Write-Step 'Step 1/7: prerequisites'
  $Report = Get-PrerequisiteReport -KitRoot $KitRoot -WorkDirectory $WorkDir -NeedPython $NeedQtInstall `
    -NeedToolchain (-not $SkipBootstrap) -NeedCompiler (-not ($SkipBootstrap -and $SkipBuild))
  foreach ($Line in $Report.Note) { Write-Step $Line }
  if ($Report.Problem.Count -gt 0) {
    Write-Step ('{0} prerequisite(s) are missing; nothing was downloaded:' -f $Report.Problem.Count)
    foreach ($Item in $Report.Problem) { Write-Output "  - $Item" }
    Write-Output ''
    Write-Output 'Fix the items above and run the same command again; finished work is reused.'
    exit 3
  }
  Write-Step 'All prerequisites are present'

  # Step 2: Qt.
  Write-Step 'Step 2/7: Qt'
  if ($NeedQtInstall) {
    if ($ForceQtInstall -and (Test-Path -LiteralPath $LocalQtRoot)) {
      Write-Step "-ForceQtInstall: removing $LocalQtRoot"
      Remove-Item -LiteralPath $LocalQtRoot -Recurse -Force
    }
    Install-LocalQt -Python $Report.Python -VenvDir $VenvDir -QtDir $QtDir -Qt $Qt
    if (-not (Test-QtRoot -Path $LocalQtRoot)) {
      throw "Qt is still incomplete at $LocalQtRoot after aqt install-qt. Delete $QtDir and run again with -ForceQtInstall."
    }
    $QtRootInUse = $LocalQtRoot
  }
  else {
    Write-Step "Reusing the complete Qt at $QtRootInUse"
  }
  $env:QT_ROOT = $QtRootInUse
  Write-Step "QT_ROOT     : $env:QT_ROOT"

  # bootstrap-windows.ps1 keeps its downloaded tarballs in the directory named by the RUNNER_TEMP
  # variable. Setting it here is what makes that script work outside GitHub Actions; no other
  # variable of a CI environment is used or expected.
  $env:RUNNER_TEMP = $DownloadDir

  # Step 3: sources and dependencies. bootstrap-windows.ps1 is idempotent, it skips what exists.
  Write-Step 'Step 3/7: sources and dependencies'
  if ($SkipBootstrap) {
    foreach ($Required in 'fritzing-app\.git', 'fritzing-parts\.git') {
      if (-not (Test-Path -LiteralPath (Join-Path $WorkDir $Required))) {
        throw "-SkipBootstrap was used but $WorkDir\$Required does not exist. Run again without -SkipBootstrap."
      }
    }
    Write-Step 'Skipped on request (-SkipBootstrap); the network is not used'
  }
  else {
    Invoke-KitScript -Path (Join-Path $KitRoot 'scripts\bootstrap-windows.ps1') -ArgumentList @($WorkDir) -Stage 'bootstrap-windows.ps1'
  }

  # Step 4: the build itself.
  Write-Step 'Step 4/7: compiling Fritzing (this is the long part)'
  if ($SkipBuild) {
    if (-not (Test-Path -LiteralPath $BaseZip)) {
      throw "-SkipBuild was used but there is no earlier build at $BaseZip. Run again without -SkipBuild."
    }
    Write-Step "Skipped on request (-SkipBuild); reusing $BaseZip"
  }
  else {
    Invoke-KitScript -Path (Join-Path $KitRoot 'scripts\build-windows.ps1') -ArgumentList @($WorkDir, $BuildOutDir) -Stage 'build-windows.ps1'
    if (-not (Test-Path -LiteralPath $BaseZip)) { throw "build-windows.ps1 finished but $BaseZip is missing" }
  }

  # Step 5: the custom parts of this kit.
  Write-Step 'Step 5/7: custom-parts folder'
  $PartName = @(Export-CustomPartFolder -KitRoot $KitRoot -StageDir $StageDir)
  Write-Step ('Prepared {0} part package(s): {1}' -f $PartName.Count, ($PartName -join ', '))

  # Step 6: final archive.
  Write-Step 'Step 6/7: final archive'
  Remove-Item -LiteralPath $FinalZip -Force -ErrorAction Ignore
  Copy-Item -LiteralPath $BaseZip -Destination $FinalZip
  Push-Location -LiteralPath $StageDir
  try {
    Invoke-Tool -FilePath $Report.Tool['7z'] -ArgumentList @('a', '-tzip', '-bd', '-bso0', $FinalZip, 'custom-parts') -Stage '7z add custom-parts'
  }
  finally { Pop-Location }
  $EntryCount = Test-FinalArchive -Path $FinalZip -PartName $PartName
  $SizeMb = [math]::Round((Get-Item -LiteralPath $FinalZip).Length / 1MB, 1)
  Write-Step ('Archive verified: {0} entries, {1} MB' -f $EntryCount, $SizeMb)

  # Step 7: checksum.
  Write-Step 'Step 7/7: SHA-256'
  $Hash = (Get-FileHash -LiteralPath $FinalZip -Algorithm SHA256).Hash.ToLowerInvariant()
  $ShaFile = "$FinalZip.sha256"
  Set-Content -LiteralPath $ShaFile -Value ('{0} *{1}' -f $Hash, [System.IO.Path]::GetFileName($FinalZip)) -Encoding ASCII

  Write-Output ''
  Write-Output '=============================== BUILD FINISHED ==============================='
  Write-Output ("Artifact   : {0} ({1} MB)" -f $FinalZip, $SizeMb)
  Write-Output ("SHA-256    : {0}" -f $Hash)
  Write-Output ("             {0}" -f $ShaFile)
  Write-Output ("Custom part: custom-parts\ in the archive ({0} packages, IMPORT-CUSTOM-PARTS.txt)" -f $PartName.Count)
  Write-Output ("Log        : {0}" -f $LogFile)
  Write-Output ("Work dir   : {0}" -f $WorkDir)
  Write-Output ''
  Write-Output 'Unpack the archive anywhere and start Fritzing.exe. Import the parts in Fritzing with'
  Write-Output 'File > Open on a .fzpz file from custom-parts (see IMPORT-CUSTOM-PARTS.txt).'
  Write-Output 'Running the same command again reuses everything that is already in the work directory.'
  Write-Output ("Remove-Item -LiteralPath '{0}' -Recurse -Force   frees the work directory." -f $WorkDir)
  Write-Output ('Total time : {0:hh\:mm\:ss}' -f $Started.Elapsed)
}
catch {
  Write-Output ''
  Write-Output ('BUILD FAILED: {0}' -f $_.Exception.Message)
  Write-Output ("Log        : {0}" -f $LogFile)
  Write-Output ("Work dir   : {0} (kept, the next run continues from here)" -f $WorkDir)
  throw
}
finally {
  if ($script:TranscriptStarted) { Stop-Transcript | Out-Null }
}
