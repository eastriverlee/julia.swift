param(
    [string]$Version,
    [string]$InstallRoot = "$env:LOCALAPPDATA\Programs\julia.swift",
    [string]$CommandDirectory = "$env:LOCALAPPDATA\Programs\julia.swift\bin"
)

$ErrorActionPreference = 'Stop'
$repository = 'eastriverlee/julia.swift'
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) is required to install from the private repository.'
}
if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'Julia requires 64-bit Windows.'
}
if (-not $Version) {
    $Version = gh release view --repo $repository --json tagName --jq .tagName
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the latest release.' }
}

$platform = 'windows-x86_64'
$archiveName = "julia-$Version-$platform.zip"
$installation = Join-Path $InstallRoot "$Version\$platform"
$temporary = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $temporary | Out-Null

try {
    gh release download $Version --repo $repository --pattern $archiveName --pattern 'julia-1-model-*.zip' --pattern SHA256SUMS --dir $temporary
    if ($LASTEXITCODE -ne 0) { throw "Could not download release $Version." }

    $cliArchive = Join-Path $temporary $archiveName
    $modelArchive = Get-ChildItem $temporary -Filter 'julia-1-model-*.zip' | Select-Object -First 1
    if (-not (Test-Path $cliArchive) -or -not $modelArchive) { throw 'Release assets are missing.' }

    $checksums = @{}
    foreach ($line in Get-Content (Join-Path $temporary 'SHA256SUMS')) {
        if ($line -match '^([0-9a-f]{64})\s+\*?(.+)$') { $checksums[$Matches[2]] = $Matches[1] }
    }
    foreach ($archive in @($cliArchive, $modelArchive.FullName)) {
        $name = Split-Path $archive -Leaf
        $actual = (Get-FileHash -Algorithm SHA256 $archive).Hash
        if (-not $checksums.ContainsKey($name) -or $actual -ne $checksums[$name]) {
            throw "Checksum mismatch or missing checksum: $name"
        }
    }

    $unpacked = Join-Path $temporary 'unpacked'
    Expand-Archive $cliArchive -DestinationPath $unpacked
    $packageRoot = Join-Path $unpacked "julia-$Version-$platform"
    Expand-Archive $modelArchive.FullName -DestinationPath $packageRoot
    if (-not (Test-Path $installation)) {
        New-Item -ItemType Directory -Path (Split-Path $installation -Parent) -Force | Out-Null
        Move-Item $packageRoot $installation
    }

    New-Item -ItemType Directory -Path $CommandDirectory -Force | Out-Null
    $launcher = Join-Path $CommandDirectory 'julia.cmd'
    "@echo off`r`ncall `"$installation\julia.cmd`" %*`r`n" | Set-Content $launcher -Encoding Ascii
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($userPath -split ';') -notcontains $CommandDirectory) {
        [Environment]::SetEnvironmentVariable('Path', "$userPath;$CommandDirectory", 'User')
    }
    Write-Output "Installed Julia $Version to $installation"
    Write-Output "Open a new terminal and run julia.cmd, or run $launcher"
} finally {
    Remove-Item $temporary -Recurse -Force -ErrorAction SilentlyContinue
}
