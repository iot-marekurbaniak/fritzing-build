#Requires -Version 5.1
# Build Fritzing with qmake/nmake, stage a self-contained folder like tools/release_fritzing.bat
# upstream, generate the parts database and zip everything as one unsigned artifact.
$ErrorActionPreference = 'Stop'
if (-not $env:QT_ROOT) { throw 'Set QT_ROOT to the Qt installation root' }
$Root = if ($args[0]) { $args[0] } else { Join-Path $env:RUNNER_TEMP 'fritzing' }
$Out = if ($args[1]) { $args[1] } else { Join-Path (Get-Location) 'out' }
$Kit = Split-Path $PSScriptRoot
$Lock = Get-Content -Raw (Join-Path $Kit 'versions.lock.json') | ConvertFrom-Json
. (Join-Path $PSScriptRoot 'msvc-env.ps1')

$App = Join-Path $Root 'fritzing-app'
$Parts = Join-Path $Root 'fritzing-parts'
$Quazip = Join-Path $Root "quazip-$($Lock.qt.version)-$($Lock.dependencies.quazip)intuisphere"
$Libgit2 = Join-Path $Root "libgit2-$($Lock.dependencies.libgit2)"
$Ngspice = Join-Path $Root "ngspice-$($Lock.dependencies.ngspice)-runtime"

function Invoke-Native([scriptblock]$Command) {
  & $Command
  if ($LASTEXITCODE -ne 0) { throw "Command failed with exit code ${LASTEXITCODE}: $Command" }
}

Push-Location $App
try {
  # The repository only tracks .ts sources; the release procedure compiles them to .qm.
  Invoke-Native { & "$env:QT_ROOT/bin/lrelease.exe" (Get-ChildItem (Join-Path $App 'translations/*.ts')).FullName }
  Invoke-Native { & "$env:QT_ROOT/bin/qmake.exe" phoenix.pro CONFIG+=release 'QMAKE_TARGET.arch=x86_64' }
  Invoke-Native { nmake.exe /NOLOGO release }
}
finally { Pop-Location }

$Exe = Join-Path $Root 'release64/Fritzing.exe'
if (-not (Test-Path $Exe)) { throw "Missing $Exe" }
$Stage = Join-Path $Root 'stage-windows-x64'
Remove-Item -Recurse -Force -ErrorAction Ignore $Stage
New-Item -ItemType Directory $Stage | Out-Null
Copy-Item $Exe $Stage
# Runtime libraries that windeployqt does not know about.
Copy-Item (Join-Path $Quazip 'bin/quazip1-qt6.dll') $Stage
Copy-Item (Join-Path $Libgit2 'bin/git2.dll') $Stage
# Fritzing loads ngspice dynamically at simulation start. The DLL and OpenMP runtime must sit in
# the application directory; code models are loaded from the adjacent ngspice/ directory.
Copy-Item (Join-Path $Ngspice 'dll-vs/ngspice.dll'), (Join-Path $Ngspice 'dll-vs/libomp140.x86_64.dll') $Stage
Copy-Item -Recurse (Join-Path $Ngspice 'lib/ngspice') $Stage
# quazip1-qt6.dll is passed too so that its Qt dependency (Qt6Core5Compat) is deployed as well.
Invoke-Native { & "$env:QT_ROOT/bin/windeployqt.exe" --release --compiler-runtime --no-translations (Join-Path $Stage 'Fritzing.exe') (Join-Path $Stage 'quazip1-qt6.dll') }

Copy-Item -Recurse (Join-Path $App 'sketches'), (Join-Path $App 'help') $Stage
New-Item -ItemType Directory (Join-Path $Stage 'translations') | Out-Null
Get-ChildItem (Join-Path $App 'translations/*.qm') | Where-Object Length -ge 128 | Copy-Item -Destination (Join-Path $Stage 'translations')
foreach ($File in 'INSTALL.txt', 'README.md', 'LICENSE.CC-BY-SA', 'LICENSE.GPL2', 'LICENSE.GPL3') { Copy-Item (Join-Path $App $File) $Stage }
# The .git directory is part of the product: Fritzing reads the parts commit with libgit2 at start-up.
Copy-Item -Recurse $Parts (Join-Path $Stage 'fritzing-parts')

# Parts database, as in the upstream release script. FMessageBox is muted in this mode, but a
# plain QMessageBox on failure would block forever, hence the timeout.
$PartsDir = Join-Path $Stage 'fritzing-parts'
$Db = Join-Path $PartsDir 'parts.db'
$Proc = Start-Process -FilePath (Join-Path $Stage 'Fritzing.exe') -ArgumentList "-pp `"$PartsDir`" -db `"$Db`"" -PassThru -NoNewWindow
if (-not $Proc.WaitForExit(1200000)) { $Proc.Kill(); throw 'Fritzing -db did not finish within 20 minutes' }
if ($Proc.ExitCode -ne 0) { throw "Fritzing -db exited with $($Proc.ExitCode)" }
if (-not (Test-Path $Db) -or (Get-Item $Db).Length -lt 1MB) { throw "parts.db was not generated at $Db" }
foreach ($RuntimeFile in 'ngspice.dll', 'libomp140.x86_64.dll', 'ngspice\analog.cm') {
  if (-not (Test-Path -LiteralPath (Join-Path $Stage $RuntimeFile))) { throw "Missing simulation runtime: $RuntimeFile" }
}

New-Item -ItemType Directory -Force $Out | Out-Null
$Zip = Join-Path $Out 'fritzing-windows-x64-unsigned.zip'
Remove-Item -Force -ErrorAction Ignore $Zip
# 7-Zip writes portable zip entries; Compress-Archive of PowerShell 7.x still uses backslashes.
Push-Location $Stage
try { Invoke-Native { 7z a -tzip -bd -bso0 $Zip '*' } }
finally { Pop-Location }
Write-Output "Unsigned artifact: $Zip"
