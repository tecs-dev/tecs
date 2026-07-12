# Windows entry point: cache LÖVE 12 and run the CLI payload through lovec.exe.
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$payload = if ($env:TECS_CLI_LOVE) { $env:TECS_CLI_LOVE } else { Join-Path $scriptDir "tecs-cli.love" }
$cacheRoot = if ($env:TECS_CACHE_DIR) { $env:TECS_CACHE_DIR } else { Join-Path $env:LOCALAPPDATA "tecs" }
$cache = Join-Path $cacheRoot "love12-main"
$love = Join-Path $cache "lovec.exe"
$marker = Join-Path $cache "runtime.txt"
$base = "https://nightly.link/love2d/love/workflows/main/main"

if (Test-Path $marker) {
    $love = Get-Content $marker -Raw
}

if (-not (Test-Path $payload)) {
    Write-Error "tecs: CLI payload not found: $payload"
    exit 1
}

if (-not (Test-Path $love)) {
    Write-Host "Downloading LÖVE 12 runtime..." -ForegroundColor DarkGray
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $cache
    New-Item -ItemType Directory -Force -Path $cache | Out-Null
    $outer = Join-Path $cache "outer.zip"
    Invoke-WebRequest "$base/love-windows-x64.zip" -OutFile $outer
    Expand-Archive -Force $outer $cache
    Remove-Item $outer
    # Nightly artifacts include the version in the inner archive name.
    $inner = Get-ChildItem $cache -File -Filter "*.zip" | Select-Object -First 1 -ExpandProperty FullName
    if (-not $inner) {
        throw "tecs: LÖVE download did not contain a Windows runtime archive"
    }
    Expand-Archive -Force $inner $cache
    Remove-Item $inner
}

if (-not (Test-Path $love)) {
    $love = Get-ChildItem $cache -Recurse -Filter lovec.exe | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $love -or -not (Test-Path $love)) {
    Write-Error "tecs: LÖVE archive did not contain lovec.exe"
    exit 1
}
Set-Content -Path $marker -Value $love -NoNewline

$env:TECS_LOVE_BIN = $love
$env:SDL_VIDEODRIVER = "dummy"
$env:SDL_AUDIODRIVER = "dummy"
& $love $payload --tecs-project (Get-Location).Path @args
exit $LASTEXITCODE
