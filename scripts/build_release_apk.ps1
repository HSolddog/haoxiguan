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
$keystoreCandidates = @()
if ($env:HAOXIGUAN_UPDATE_KEYSTORE) {
    $keystoreCandidates += Get-Item `
        -LiteralPath $env:HAOXIGUAN_UPDATE_KEYSTORE `
        -ErrorAction SilentlyContinue
}
$keystoreCandidates += Get-ChildItem `
    -Path 'C:\Users\*\.android\debug.keystore' `
    -File `
    -ErrorAction SilentlyContinue

$keytool = Join-Path $env:JAVA_HOME 'bin\keytool.exe'
$matchingKeystore = $null
foreach ($candidate in ($keystoreCandidates | Select-Object -Unique)) {
    $certificateInfo = & $keytool `
        -list `
        -v `
        -keystore $candidate.FullName `
        -alias androiddebugkey `
        -storepass android `
        -keypass android 2>$null
    $fingerprintMatch = [regex]::Match(
        ($certificateInfo -join "`n"),
        'SHA256:\s*([0-9A-F:]+)'
    )
    if ($fingerprintMatch.Success) {
        $fingerprint = $fingerprintMatch.Groups[1].Value.Replace(':', '')
        if ($fingerprint -eq $expectedUpdateCertSha256) {
            $matchingKeystore = $candidate
            break
        }
    }
}

if (-not $matchingKeystore) {
    throw 'Cannot find the established Android update signing certificate.'
}
$env:HAOXIGUAN_UPDATE_KEYSTORE = $matchingKeystore.FullName

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
