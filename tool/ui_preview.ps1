$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$buildDir = Join-Path $root 'build'
$sdkDir = Join-Path $buildDir 'flutter-sdk'
$flutter = Join-Path $sdkDir 'flutter\bin\flutter.bat'
$archive = Join-Path $buildDir 'flutter_windows_3.47.5-stable.zip'
$port = if ($env:PORT) { [int]$env:PORT } else { 8123 }
$python = (Get-Command python.exe -ErrorAction Stop).Source

$env:APPDATA = Join-Path $buildDir 'flutter_appdata'
$env:LOCALAPPDATA = Join-Path $buildDir 'flutter_localappdata'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
$env:HTTP_PROXY = 'http://127.0.0.1:7890'
$env:HTTPS_PROXY = $env:HTTP_PROXY

if (-not (Test-Path $flutter)) {
    if (-not (Test-Path $archive)) {
        $env:HTTP_PROXY = 'http://127.0.0.1:7890'
        $env:HTTPS_PROXY = $env:HTTP_PROXY
        Invoke-WebRequest `
            -Uri 'https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.47.5-stable.zip' `
            -OutFile $archive
    }
    Expand-Archive -LiteralPath $archive -DestinationPath $sdkDir
}

$sharedPubCache = Join-Path (Split-Path $root -Parent) 'MiriaGo\.devtools\pub-cache'
if (Test-Path $sharedPubCache) {
    $env:PUB_CACHE = $sharedPubCache
} else {
    $env:PUB_CACHE = Join-Path $buildDir 'pub-cache'
}

Push-Location $root
try {
    & $flutter pub get --offline
    if ($LASTEXITCODE -ne 0) {
        $env:HTTP_PROXY = 'http://127.0.0.1:7890'
        $env:HTTPS_PROXY = $env:HTTP_PROXY
        & $flutter pub get
        if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed.' }
    }

    & $flutter build web --release --pwa-strategy=none
    if ($LASTEXITCODE -ne 0) { throw 'Flutter web build failed.' }
} finally {
    Pop-Location
}

$url = "http://127.0.0.1:$port/"
$listener = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
if (-not $listener) {
    $server = Start-Process -FilePath $python `
        -ArgumentList @('-m', 'http.server', "$port", '--bind', '127.0.0.1', '--directory', (Join-Path $buildDir 'web')) `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $buildDir 'web-preview.log') `
        -RedirectStandardError (Join-Path $buildDir 'web-preview.err.log')
}

$ready = $false
for ($attempt = 0; $attempt -lt 20; $attempt++) {
    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2
        if ($response.StatusCode -eq 200 -and $response.Content.Contains('<title>跟焦器</title>')) {
            $ready = $true
            break
        }
    } catch {
        Start-Sleep -Milliseconds 500
    }
}
if (-not $ready) { throw "Web preview did not become ready at $url" }

Write-Output "Web preview: $url"
