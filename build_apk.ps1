# Build a self-signed sideload APK for the PornShop player.
$ErrorActionPreference = "Stop"
$AndroidDir = $PSScriptRoot
$SdkCandidates = @(
    "D:\MCP\reverse-engineering-workspace\players\pektino\android-sdk",
    "D:\MCP\reverse-engineering-workspace\pektino\android-sdk",
    "D:\MCP\reverse-engineering-workspace\tools\android-sdk",
    (Join-Path (Resolve-Path (Join-Path $AndroidDir "..\..")).Path "pektino\android-sdk")
)
if ($env:ANDROID_HOME) { $SdkCandidates = @($env:ANDROID_HOME) + $SdkCandidates }
$Sdk = $SdkCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Sdk) { throw "Android SDK not found. Set ANDROID_HOME." }

$JavaHome = $env:JAVA_HOME
if (-not $JavaHome -or -not (Test-Path (Join-Path $JavaHome "bin\keytool.exe"))) {
    $JavaHome = "C:\Program Files\Microsoft\jdk-21.0.11.10-hotspot"
}
if (-not (Test-Path (Join-Path $JavaHome "bin\keytool.exe"))) {
    throw "JDK not found. Set JAVA_HOME to JDK 17+."
}

$env:ANDROID_HOME = $Sdk
$env:ANDROID_SDK_ROOT = $Sdk
$env:JAVA_HOME = $JavaHome
$env:PATH = "$(Join-Path $JavaHome "bin");$env:PATH"

$sdkProp = ($Sdk -replace '\\', '/')
Set-Content -Path (Join-Path $AndroidDir "local.properties") -Value "sdk.dir=$sdkProp" -Encoding ascii
Write-Host "sdk.dir=$sdkProp"

$ksDir = Join-Path $AndroidDir "keystore"
New-Item -ItemType Directory -Force -Path $ksDir | Out-Null
$ks = Join-Path $ksDir "pornshop-release.jks"
if (-not (Test-Path $ks)) {
    & keytool -genkeypair -keystore $ks -alias pornshop -keyalg RSA -keysize 2048 -validity 3650 `
        -storepass pornshop123 -keypass pornshop123 `
        -dname "CN=PornShop Player, OU=SelfUse, O=Local, L=Local, ST=Local, C=CN"
}

Push-Location $AndroidDir
try {
    & .\gradlew.bat --no-daemon assembleRelease
    if ($LASTEXITCODE -ne 0) { throw "gradle failed: $LASTEXITCODE" }
} finally {
    Pop-Location
}

$apk = Join-Path $AndroidDir "app\build\outputs\apk\release\app-release.apk"
if (-not (Test-Path $apk)) { throw "APK missing: $apk" }
$releaseDir = Join-Path $AndroidDir "release"
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null
$gradleFile = Join-Path $AndroidDir "app\build.gradle.kts"
$gradleText = Get-Content $gradleFile -Raw
if ($gradleText -notmatch 'versionName\s*=\s*"([^"]+)"') { throw "versionName not found in app\build.gradle.kts" }
$version = $Matches[1]
# 用码位拼文件名，避免 Windows PowerShell 按系统代码页把 UTF-8 脚本读乱。
$label = -join (@(0x9752, 0x79BE, 0x5B66, 0x5802) | ForEach-Object { [char]$_ })
$out = Join-Path $releaseDir "$label-$version.apk"
Copy-Item $apk $out -Force
$codes = ($label.ToCharArray() | ForEach-Object { [int]$_ }) -join ","
Write-Host "OK name-codes=$codes version=$version"
Get-Item $apk, $out | Select-Object FullName, Length
