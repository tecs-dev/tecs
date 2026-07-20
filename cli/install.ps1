# Install the released Windows launchers and CLI payload into the user profile.
$ErrorActionPreference = "Stop"

$base = if ($env:TECS_RELEASE_BASE) { $env:TECS_RELEASE_BASE } else { "https://github.com/tecs-dev/tecs/releases/latest/download" }
$binDir = if ($env:TECS_BIN_DIR) { $env:TECS_BIN_DIR } else { Join-Path $env:LOCALAPPDATA "tecs\bin" }

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("tecs-install-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $temp | Out-Null
try {
    Invoke-WebRequest "$base/tecs.cmd" -OutFile (Join-Path $temp "tecs.cmd")
    Invoke-WebRequest "$base/tecs.ps1" -OutFile (Join-Path $temp "tecs.ps1")
    Invoke-WebRequest "$base/tecs-cli.love" -OutFile (Join-Path $temp "tecs-cli.love")
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    Copy-Item -Force (Join-Path $temp "tecs.cmd") (Join-Path $binDir "tecs.cmd")
    Copy-Item -Force (Join-Path $temp "tecs.ps1") (Join-Path $binDir "tecs.ps1")
    Copy-Item -Force (Join-Path $temp "tecs-cli.love") (Join-Path $binDir "tecs-cli.love")
} finally {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $temp
}

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (($userPath -split ";") -notcontains $binDir) {
    $newPath = if ([string]::IsNullOrWhiteSpace($userPath)) { $binDir } else { $userPath.TrimEnd(";") + ";" + $binDir }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
}

Write-Host "Installed tecs to $binDir"
Write-Host "Open a new terminal, then run: tecs --version"
