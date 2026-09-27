param(
    [string]$Version,
    [string]$InstallRoot = "$env:LOCALAPPDATA\Programs\julia.swift",
    [string]$CommandDirectory = "$env:LOCALAPPDATA\Programs\julia.swift\bin"
)

$ErrorActionPreference = 'Stop'
$repository = 'eastriverlee/julia.swift'
if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'Julia requires 64-bit Windows.'
}
if (-not $Version) {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repository/releases/latest"
    $Version = $release.tag_name
    if (-not $Version) { throw 'Could not read the latest release.' }
}

$platform = 'windows-x86_64'
$archiveName = "julia-$Version-$platform.zip"
$installation = Join-Path $InstallRoot "$Version\$platform"
$temporary = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $temporary | Out-Null

try {
    $releaseUrl = "https://github.com/$repository/releases/download/$Version"
    Invoke-WebRequest -Uri "$releaseUrl/SHA256SUMS" -OutFile (Join-Path $temporary 'SHA256SUMS') -UseBasicParsing
    $cliArchive = Join-Path $temporary $archiveName
    $checksums = @{}
    foreach ($line in Get-Content (Join-Path $temporary 'SHA256SUMS')) {
        if ($line -match '^([0-9a-f]{64})\s+\*?(.+)$') { $checksums[$Matches[2]] = $Matches[1] }
    }
    $modelNames = @($checksums.Keys | Where-Object { $_ -match '^julia-1-model-[A-Za-z0-9]+\.zip$' })
    if ($modelNames.Count -ne 1) { throw 'Expected one model archive in SHA256SUMS.' }
    $modelArchive = Join-Path $temporary $modelNames[0]
    Invoke-WebRequest -Uri "$releaseUrl/$archiveName" -OutFile $cliArchive -UseBasicParsing
    Invoke-WebRequest -Uri "$releaseUrl/$($modelNames[0])" -OutFile $modelArchive -UseBasicParsing

    foreach ($archive in @($cliArchive, $modelArchive)) {
        $name = Split-Path $archive -Leaf
        $actual = (Get-FileHash -Algorithm SHA256 $archive).Hash
        if (-not $checksums.ContainsKey($name) -or $actual -ne $checksums[$name]) {
            throw "Checksum mismatch or missing checksum: $name"
        }
    }

    $unpacked = Join-Path $temporary 'unpacked'
    Expand-Archive $cliArchive -DestinationPath $unpacked
    $packageRoot = Join-Path $unpacked "julia-$Version-$platform"
    Expand-Archive $modelArchive -DestinationPath $packageRoot
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
