$ErrorActionPreference = "Stop"

$base = if ($env:TECS_RELEASE_BASE) { $env:TECS_RELEASE_BASE } else { "https://github.com/tecs-dev/tecs-cli/releases/latest/download" }
$binDir = if ($env:TECS_BIN_DIR) { $env:TECS_BIN_DIR } else { Join-Path $env:LOCALAPPDATA "tecs\bin" }

New-Item -ItemType Directory -Force -Path $binDir | Out-Null
Invoke-WebRequest "$base/tecs.cmd" -OutFile (Join-Path $binDir "tecs.cmd")
Invoke-WebRequest "$base/tecs.ps1" -OutFile (Join-Path $binDir "tecs.ps1")
Invoke-WebRequest "$base/tecs-cli.love" -OutFile (Join-Path $binDir "tecs-cli.love")

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (($userPath -split ";") -notcontains $binDir) {
    [Environment]::SetEnvironmentVariable("Path", (($userPath.TrimEnd(";") + ";" + $binDir).TrimStart(";")), "User")
}

Write-Host "Installed tecs to $binDir"
Write-Host "Open a new terminal, then run: tecs --version"
