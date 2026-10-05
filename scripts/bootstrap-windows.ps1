#Requires -Version 5.1
# Fetch the pinned sources and build the sibling dependencies that fritzing-app/pri/*detect.pri
# expect next to the fritzing-app checkout. Idempotent: existing directories are reused.
$ErrorActionPreference = 'Stop'
if (-not $env:QT_ROOT) { throw 'Set QT_ROOT to the Qt installation root' }
$Root = if ($args[0]) { $args[0] } else { Join-Path $env:RUNNER_TEMP 'fritzing' }
$Kit = Split-Path $PSScriptRoot
$Lock = Get-Content -Raw (Join-Path $Kit 'versions.lock.json') | ConvertFrom-Json
$Dep = $Lock.dependencies
$Src = $Lock.sources
. (Join-Path $PSScriptRoot 'msvc-env.ps1')
New-Item -ItemType Directory -Force $Root | Out-Null

function Invoke-Native([scriptblock]$Command) {
  & $Command
  if ($LASTEXITCODE -ne 0) { throw "Command failed with exit code ${LASTEXITCODE}: $Command" }
}

function Get-PinnedCheckout($Url, $Dir, $Commit, $Branch) {
  # Shallow but complete tree, HEAD on a named branch that tracks origin. Fritzing opens this
  # repository with libgit2 1.7.1, which rejects partial clones (extensions.partialclone), and
  # its parts checker compares the HEAD branch name with the remote branches.
  $Path = Join-Path $Root $Dir
  if (-not (Test-Path (Join-Path $Path '.git'))) {
    Invoke-Native { git init -q $Path }
    Invoke-Native { git -C $Path remote add origin $Url }
  }
  Invoke-Native { git -C $Path fetch --depth 1 origin $Commit }
  Invoke-Native { git -C $Path checkout -q -B $Branch FETCH_HEAD }
  Invoke-Native { git -C $Path config "branch.$Branch.remote" origin }
  Invoke-Native { git -C $Path config "branch.$Branch.merge" "refs/heads/$Branch" }
  $Head = (git -C $Path rev-parse HEAD).Trim()
  if ($Head -ne $Commit) { throw "$Dir is at $Head, expected $Commit" }
}

function Expand-Tarball($Url, $Dir, [switch]$ExcludeLibgit2TestSymlink) {
  $Path = Join-Path $Root $Dir
  if (Test-Path $Path) { return }
  $Archive = Join-Path $env:RUNNER_TEMP "$Dir.tar.gz"
  $Partial = "$Archive.partial"
  $Unpack = Join-Path $env:RUNNER_TEMP "$Dir-unpack"
  $SevenZip = (Get-Command 7z.exe -ErrorAction Stop).Source

  # Never let an interrupted curl leave a file that looks reusable. Reuse an existing archive only
  # after 7-Zip has verified its gzip stream; this makes reruns cheap and rejects truncated downloads.
  $ArchiveOk = $false
  if (Test-Path -LiteralPath $Archive) {
    & $SevenZip t -bd -bso0 $Archive
    $ArchiveOk = ($LASTEXITCODE -eq 0)
    if (-not $ArchiveOk) { Remove-Item -LiteralPath $Archive -Force }
  }
  if (-not $ArchiveOk) {
    Remove-Item -LiteralPath $Partial -Force -ErrorAction Ignore
    Invoke-Native { curl.exe --fail --location --retry 3 --retry-all-errors --silent --show-error --output $Partial $Url }
    Invoke-Native { & $SevenZip t -bd -bso0 $Partial }
    Move-Item -LiteralPath $Partial -Destination $Archive -Force
  }

  # Windows' bundled tar.exe has produced "Truncated tar archive" for a valid zlib archive on a
  # real host. Use 7-Zip for both layers instead, then strip the single top-level source directory.
  Remove-Item -LiteralPath $Unpack -Recurse -Force -ErrorAction Ignore
  New-Item -ItemType Directory -Force $Unpack | Out-Null
  try {
    Invoke-Native { & $SevenZip x -y -bd -bso0 "-o$Unpack" $Archive }
    $TarFile = @(Get-ChildItem -LiteralPath $Unpack -Filter '*.tar')
    if ($TarFile.Count -ne 1) { throw "Expected one .tar inside $Archive, found $($TarFile.Count)" }
    $Tree = Join-Path $Unpack 'tree'
    New-Item -ItemType Directory -Force $Tree | Out-Null
    $ExtractArguments = @('x', '-y', '-bd', '-bso0', "-o$Tree")
    if ($ExcludeLibgit2TestSymlink) {
      # The pinned libgit2 archive contains one symlink, only in disabled test data. Creating it on
      # Windows requires Developer Mode or an elevated token; omit that single unused entry instead.
      $ExtractArguments += '-xr!link_to_new.txt'
    }
    $ExtractArguments += $TarFile[0].FullName
    Invoke-Native { & $SevenZip @ExtractArguments }
    $Top = @(Get-ChildItem -LiteralPath $Tree -Force)
    if ($Top.Count -ne 1 -or -not $Top[0].PSIsContainer) {
      throw "Expected one top-level directory in $Archive"
    }
    New-Item -ItemType Directory -Force $Path | Out-Null
    Get-ChildItem -LiteralPath $Top[0].FullName -Force | Move-Item -Destination $Path
  }
  catch {
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Ignore
    throw
  }
  finally { Remove-Item -LiteralPath $Unpack -Recurse -Force -ErrorAction Ignore }
}

function Expand-NgspiceRuntime($Runtime) {
  $Path = Join-Path $Root "ngspice-$($Dep.ngspice)-runtime"
  $Required = @('dll-vs\ngspice.dll', 'dll-vs\libomp140.x86_64.dll', 'lib\ngspice\analog.cm')
  if (@($Required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Path $_)) }).Count -eq 0) { return }

  $Archive = Join-Path $env:RUNNER_TEMP "ngspice-$($Dep.ngspice)_dll_64.7z"
  $Partial = "$Archive.partial"
  $Unpack = Join-Path $env:RUNNER_TEMP "ngspice-$($Dep.ngspice)-runtime-unpack"
  $SevenZip = (Get-Command 7z.exe -ErrorAction Stop).Source
  $ExpectedHash = $Runtime.sha256.ToLowerInvariant()

  $ArchiveOk = $false
  if (Test-Path -LiteralPath $Archive) {
    $ArchiveOk = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant() -eq $ExpectedHash
    if ($ArchiveOk) {
      & $SevenZip t -bd -bso0 $Archive
      $ArchiveOk = ($LASTEXITCODE -eq 0)
    }
    if (-not $ArchiveOk) { Remove-Item -LiteralPath $Archive -Force }
  }
  if (-not $ArchiveOk) {
    Remove-Item -LiteralPath $Partial -Force -ErrorAction Ignore
    Invoke-Native { curl.exe --fail --location --retry 3 --retry-all-errors --silent --show-error --output $Partial $Runtime.url }
    $ActualHash = (Get-FileHash -LiteralPath $Partial -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ActualHash -ne $ExpectedHash) { throw "ngspice runtime SHA-256 is $ActualHash, expected $ExpectedHash" }
    Invoke-Native { & $SevenZip t -bd -bso0 $Partial }
    Move-Item -LiteralPath $Partial -Destination $Archive -Force
  }

  Remove-Item -LiteralPath $Unpack -Recurse -Force -ErrorAction Ignore
  New-Item -ItemType Directory -Force $Unpack | Out-Null
  try {
    Invoke-Native { & $SevenZip x -y -bd -bso0 "-o$Unpack" $Archive }
    $Source = Join-Path $Unpack 'Spice64_dll'
    foreach ($File in $Required) {
      if (-not (Test-Path -LiteralPath (Join-Path $Source $File))) { throw "ngspice runtime is missing $File" }
    }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Ignore
    Move-Item -LiteralPath $Source -Destination $Path
  }
  catch {
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Ignore
    throw
  }
  finally { Remove-Item -LiteralPath $Unpack -Recurse -Force -ErrorAction Ignore }
}

Get-PinnedCheckout -Url $Lock.fritzing_app.repository -Dir 'fritzing-app' -Commit $Lock.fritzing_app.commit -Branch $Lock.fritzing_app.branch
Get-PinnedCheckout -Url $Lock.fritzing_parts.repository -Dir 'fritzing-parts' -Commit $Lock.fritzing_parts.commit -Branch $Lock.fritzing_parts.branch

# Header-only dependencies (boostdetect.pri, svgppdetect.pri, spicedetect.pri).
Expand-Tarball $Src.boost "boost_$($Dep.boost -replace '\.', '_')"
Expand-Tarball $Src.svgpp "svgpp-$($Dep.svgpp)"
Expand-Tarball $Src.ngspice "ngspice-$($Dep.ngspice)"
$NgInclude = Join-Path $Root "ngspice-$($Dep.ngspice)/include/ngspice"
if (-not (Test-Path $NgInclude)) {
  New-Item -ItemType Directory -Force (Split-Path $NgInclude) | Out-Null
  Copy-Item -Recurse (Join-Path $Root "ngspice-$($Dep.ngspice)/src/include/ngspice") $NgInclude
}
Expand-NgspiceRuntime $Lock.windows_runtime.ngspice

# zlib: the runner has no system zlib and QuaZip's CMake requires one (static, /MD like Qt).
$Zlib = Join-Path $Root "zlib-$($Dep.zlib)"
Expand-Tarball $Src.zlib 'zlib-src'
if (-not (Test-Path "$Zlib/lib/zlibstatic.lib")) {
  Invoke-Native { cmake -S "$Root/zlib-src" -B "$Root/zlib-build" -A x64 -DCMAKE_INSTALL_PREFIX="$Zlib" -DZLIB_BUILD_EXAMPLES=OFF }
  Invoke-Native { cmake --build "$Root/zlib-build" --config Release --parallel }
  Invoke-Native { cmake --install "$Root/zlib-build" --config Release }
}

# libgit2 as a DLL with the default WinHTTP backend, like the upstream Windows release that ships
# git2.dll (libgit2detect.pri only links -lgit2, so a static WinHTTP build would not link).
$Libgit2 = Join-Path $Root "libgit2-$($Dep.libgit2)"
Expand-Tarball $Src.libgit2 'libgit2-src' -ExcludeLibgit2TestSymlink
if (-not (Test-Path "$Libgit2/lib/git2.lib")) {
  Invoke-Native { cmake -S "$Root/libgit2-src" -B "$Root/libgit2-build" -A x64 -DCMAKE_INSTALL_PREFIX="$Libgit2" -DBUILD_SHARED_LIBS=ON -DBUILD_TESTS=OFF -DBUILD_CLI=OFF -DUSE_SSH=OFF }
  Invoke-Native { cmake --build "$Root/libgit2-build" --config Release --parallel }
  Invoke-Native { cmake --install "$Root/libgit2-build" --config Release }
}

# QuaZip 1.4 for Qt 6 (needs Core5Compat). The install prefix is the exact path expected by
# pri/quazipdetect.pri of the pinned commit: quazip-<Qt version>-<QuaZip version>intuisphere.
$Quazip = Join-Path $Root "quazip-$($Lock.qt.version)-$($Dep.quazip)intuisphere"
Expand-Tarball $Src.quazip 'quazip-src'
if (-not (Test-Path "$Quazip/lib/quazip1-qt6.lib")) {
  Invoke-Native { cmake -S "$Root/quazip-src" -B "$Root/quazip-build" -A x64 -DCMAKE_PREFIX_PATH="$env:QT_ROOT" -DCMAKE_INSTALL_PREFIX="$Quazip" -DQUAZIP_QT_MAJOR_VERSION=6 -DQUAZIP_BZIP2=OFF -DQUAZIP_ENABLE_TESTS=OFF -DZLIB_ROOT="$Zlib" -DZLIB_USE_STATIC_LIBS=ON }
  Invoke-Native { cmake --build "$Root/quazip-build" --config Release --parallel }
  Invoke-Native { cmake --install "$Root/quazip-build" --config Release }
}

# Clipper1 (clipper1detect.pri): one translation unit, compiled with /MD to match Qt's runtime.
$Clip = Join-Path $Root "Clipper1-$($Dep.clipper1)"
Expand-Tarball $Src.clipper1 'clipper-source'
if (-not (Test-Path "$Clip/lib/polyclipping.lib")) {
  New-Item -ItemType Directory -Force "$Clip/include/polyclipping", "$Clip/lib" | Out-Null
  $Cpp = Get-ChildItem (Join-Path $Root 'clipper-source') -Recurse -Filter clipper.cpp | Select-Object -First 1
  if (-not $Cpp) { throw 'clipper.cpp not found in the Clipper source tree' }
  Copy-Item (Join-Path $Cpp.DirectoryName 'clipper.hpp') "$Clip/include/polyclipping/clipper.hpp"
  Invoke-Native { cl.exe /nologo /EHsc /O2 /MD /c $Cpp.FullName /Fo"$Clip/clipper.obj" }
  Invoke-Native { lib.exe /nologo /OUT:"$Clip/lib/polyclipping.lib" "$Clip/clipper.obj" }
}
Write-Output "Dependencies ready at $Root"
