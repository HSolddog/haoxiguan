$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$pubspecPath = Join-Path $projectRoot 'pubspec.yaml'
$pubspec = [System.IO.File]::ReadAllText($pubspecPath)
$versionMatch = [regex]::Match(
    $pubspec,
    '(?m)^version:[ \t]*(\d+)\.(\d+)\.(\d+)\+(\d+)[ \t]*$'
)

if (-not $versionMatch.Success) {
    throw 'Cannot find a valid version: x.y.z+n in pubspec.yaml.'
}

$major = [int]$versionMatch.Groups[1].Value
$minor = [int]$versionMatch.Groups[2].Value
$patch = [int]$versionMatch.Groups[3].Value + 1
$build = [int]$versionMatch.Groups[4].Value + 1
$versionName = "$major.$minor.$patch"
$fullVersion = "$versionName+$build"

$localFlutter = Join-Path $projectRoot '.tooling\flutter\bin\flutter.bat'
if (Test-Path -LiteralPath $localFlutter) {
    $flutter = $localFlutter
    $env:PUB_CACHE = Join-Path $projectRoot '.tooling\pub-cache'
    $env:APPDATA = Join-Path $projectRoot '.tooling\appdata'
    $env:LOCALAPPDATA = Join-Path $projectRoot '.tooling\localappdata'
    $env:ANDROID_HOME = Join-Path $projectRoot '.tooling\android-sdk'
    $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
    $env:GRADLE_USER_HOME = Join-Path $projectRoot '.tooling\gradle-cache'
} else {
    $flutter = (Get-Command flutter -ErrorAction Stop).Source
}

if (-not $env:JAVA_HOME) {
    $androidStudioJbr = 'C:\Program Files\Android\Android Studio\jbr'
    if (Test-Path -LiteralPath (Join-Path $androidStudioJbr 'bin\java.exe')) {
        $env:JAVA_HOME = $androidStudioJbr
    }
}

$expectedUpdateCertSha256 = 'AF7E2D6497746AD29960EBC3BC6097781B6F4D42E22D6CE330E8A52636848EBD'
# The operator selects a known keystore explicitly. Never search other users'
# private directories or silently substitute a newly generated debug key.
foreach ($variable in @('HAOXIGUAN_UPDATE_KEYSTORE', 'HAOXIGUAN_UPDATE_STORE_PASSWORD',
                        'HAOXIGUAN_UPDATE_KEY_ALIAS', 'HAOXIGUAN_UPDATE_KEY_PASSWORD')) {
    if (-not [Environment]::GetEnvironmentVariable($variable)) {
        throw "Missing release signing setting: $variable"
    }
}
$matchingKeystore = Get-Item -LiteralPath $env:HAOXIGUAN_UPDATE_KEYSTORE -ErrorAction Stop
$keytool = Join-Path $env:JAVA_HOME 'bin\keytool.exe'
$certificateInfo = & $keytool -list -v -keystore $matchingKeystore.FullName `
    -alias $env:HAOXIGUAN_UPDATE_KEY_ALIAS `
    -storepass:env HAOXIGUAN_UPDATE_STORE_PASSWORD 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the explicitly selected update certificate.' }
$fingerprintMatch = [regex]::Match(($certificateInfo -join "`n"), 'SHA256:\s*([0-9A-F:]+)')
if (-not $fingerprintMatch.Success -or
    $fingerprintMatch.Groups[1].Value.Replace(':', '') -ne $expectedUpdateCertSha256) {
    throw 'Selected certificate does not match the established internal-test update certificate.'
}

$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
Push-Location $projectRoot
try {
    & $flutter build apk --release --build-name $versionName --build-number $build
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter APK build failed. Version remains $($versionMatch.Value.Trim())."
    }

    $nextVersionLine = "version: $fullVersion"
    $updatedPubspec = $pubspec.Remove(
        $versionMatch.Index,
        $versionMatch.Length
    ).Insert($versionMatch.Index, $nextVersionLine)
    [System.IO.File]::WriteAllText(
        $pubspecPath,
        $updatedPubspec,
        [System.Text.UTF8Encoding]::new($false)
    )

    $distDirectory = Join-Path $projectRoot 'dist'
    [System.IO.Directory]::CreateDirectory($distDirectory) | Out-Null
    $sourceApk = Join-Path $projectRoot 'build\app\outputs\flutter-apk\app-release.apk'
    $targetApk = Join-Path $distDirectory "haoxiguan-v$fullVersion.apk"
    Copy-Item -LiteralPath $sourceApk -Destination $targetApk -Force

    Write-Host "APK exported: $targetApk"
    Write-Host "Version updated: $fullVersion"
} finally {
    Pop-Location
}
