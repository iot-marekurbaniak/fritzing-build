# Dot-source this file to get the MSVC x64 toolchain (cl.exe, lib.exe, nmake.exe, rc.exe) and
# VCINSTALLDIR (needed by "windeployqt --compiler-runtime") in the current PowerShell session.
# GitHub-hosted Windows runners do not initialise the Visual Studio environment by themselves.
# Qt's prebuilt msvc2022_64 package requires the VS 2022 (17.x) toolchain. Do not silently accept
# an older Developer PowerShell merely because cl.exe already happens to be on PATH.
if ((Get-Command cl.exe -ErrorAction SilentlyContinue) -and $env:VisualStudioVersion -like '17.*') { return }

$VsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $VsWhere)) { throw "vswhere.exe not found at $VsWhere; install Visual Studio 2022 with the C++ workload" }
$VsPath = & $VsWhere -latest -version '[17.0,18.0)' -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $VsPath) { throw 'No Visual Studio 2022 (17.x) installation with the C++ x64 toolset was found' }

Import-Module (Join-Path $VsPath 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $VsPath -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'

foreach ($Tool in 'cl.exe', 'lib.exe', 'nmake.exe', 'rc.exe') {
  if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) { throw "$Tool is not on PATH after Enter-VsDevShell" }
}
if (-not $env:VCINSTALLDIR) { throw 'VCINSTALLDIR is not set after Enter-VsDevShell' }
Write-Output "MSVC environment: $VsPath"
