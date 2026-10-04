$ErrorActionPreference = 'Stop'

trap {
    # The protected launcher captures output before returning it. Keep a useful
    # error even if it terminates before returning, never serializing env vars.
    $safeError = $_.Exception.Message + "`n" + $_.ScriptStackTrace
    foreach ($secretName in @('HAOXIGUAN_UPDATE_STORE_PASSWORD', 'HAOXIGUAN_UPDATE_KEY_PASSWORD')) {
        $secretValue = [Environment]::GetEnvironmentVariable($secretName)
        if ($secretValue) { $safeError = $safeError.Replace($secretValue, '[REDACTED]') }
    }
    $errorDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'build'
    [IO.Directory]::CreateDirectory($errorDirectory) | Out-Null
    [IO.File]::WriteAllText((Join-Path $errorDirectory 'release-build-error.txt'), $safeError)
    throw
}

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
    $localAndroidSdk = Join-Path $projectRoot '.tooling\android-sdk'
    if (Test-Path -LiteralPath $localAndroidSdk) {
        $env:ANDROID_HOME = $localAndroidSdk
        $env:ANDROID_SDK_ROOT = $localAndroidSdk
    }
    $env:GRADLE_USER_HOME = Join-Path $projectRoot '.tooling\gradle-cache'
} else {
    $flutter = (Get-Command flutter -ErrorAction Stop).Source
}

# Flutter keeps the selected project SDK in this ignored local file. Reuse it
# rather than letting the older local signing entry point select another SDK.
$localProperties = Join-Path $projectRoot 'android\local.properties'
if (Test-Path -LiteralPath $localProperties) {
    $sdkMatch = [regex]::Match([IO.File]::ReadAllText($localProperties), '(?m)^sdk\.dir=(.+)$')
    if ($sdkMatch.Success) {
        $projectAndroidSdk = $sdkMatch.Groups[1].Value.Trim().Replace('\\', '\').Replace('\:', ':')
        if (Test-Path -LiteralPath (Join-Path $projectAndroidSdk 'build-tools')) {
            $env:ANDROID_HOME = $projectAndroidSdk
            $env:ANDROID_SDK_ROOT = $projectAndroidSdk
        }
    }
}

if (-not $env:JAVA_HOME) {
    $androidStudioJbr = 'C:\Program Files\Android\Android Studio\jbr'
    if (Test-Path -LiteralPath (Join-Path $androidStudioJbr 'bin\java.exe')) {
        $env:JAVA_HOME = $androidStudioJbr
    }
}

$expectedUpdateCertSha256 = 'D675D16E4C0CC72C862DB337E2A6B2D7D92AFDF61135B014B95B44A016FC5ABC'
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
$certificateInfo = & $keytool '-J-Duser.language=en' '-J-Duser.country=US' `
    -list -v -keystore $matchingKeystore.FullName `
    -alias $env:HAOXIGUAN_UPDATE_KEY_ALIAS `
    -storepass:env HAOXIGUAN_UPDATE_STORE_PASSWORD 2>&1
if ($LASTEXITCODE -ne 0) {
    $safeCertificateError = ($certificateInfo -join "`n").Replace($env:HAOXIGUAN_UPDATE_STORE_PASSWORD, '[REDACTED]')
    throw ('Cannot inspect the explicitly selected update certificate. ' + $safeCertificateError)
}
$fingerprintMatch = [regex]::Match(($certificateInfo -join "`n"), 'SHA256:\s*([0-9A-F:]+)')
if (-not $fingerprintMatch.Success -or
    $fingerprintMatch.Groups[1].Value.Replace(':', '') -ne $expectedUpdateCertSha256) {
    throw 'Selected certificate does not match the fixed haoxiguan release certificate.'
}

# Resolve the JAR directly: Windows .bat wrappers can mishandle paths with spaces.
$java = Join-Path $env:JAVA_HOME 'bin\java.exe'
$androidSdk = @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME) |
    Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'build-tools')) } |
    Select-Object -First 1
if (-not $androidSdk) {
    throw 'Set ANDROID_SDK_ROOT or ANDROID_HOME to an SDK with Android build-tools.'
}
$buildTools = Get-ChildItem -LiteralPath (Join-Path $androidSdk 'build-tools') -Directory |
    Where-Object {
        $_.Name -match '^\d+\.\d+\.\d+(-.*)?$' -and
        (Test-Path -LiteralPath (Join-Path $_.FullName 'lib\apksigner.jar'))
    } |
    Sort-Object { [version]($_.Name -replace '-.*$', '') } -Descending |
    Select-Object -First 1
if (-not $buildTools) { throw 'Android build-tools with lib/apksigner.jar is required.' }
$apksignerJar = Join-Path $buildTools.FullName 'lib\apksigner.jar'

$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$previousGradleOpts = $env:GRADLE_OPTS
# Signing passwords stay in process environment only. Do not enable shell tracing.
$env:GRADLE_OPTS = "$previousGradleOpts -Dorg.gradle.daemon=false -Dorg.gradle.configuration-cache=false".Trim()
Push-Location $projectRoot
try {
    & $flutter build apk --release --no-pub --build-name $versionName --build-number $build
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter APK build failed. Version remains $($versionMatch.Value.Trim())."
    }

    $sourceApk = Join-Path $projectRoot 'build\app\outputs\flutter-apk\app-release.apk'
    if (-not (Test-Path -LiteralPath $sourceApk -PathType Leaf)) {
        throw 'Flutter did not produce the expected release APK. Version remains unchanged.'
    }
    $apkCertificateInfo = & $java -jar $apksignerJar verify --verbose --print-certs $sourceApk 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw 'APK signature verification failed. Version remains unchanged.'
    }
    $apkFingerprints = [regex]::Matches(
        ($apkCertificateInfo -join "`n"),
        '(?im)^Signer #\d+ certificate SHA-256 digest:\s*([0-9a-f]+)\s*$'
    )
    if ($apkFingerprints.Count -ne 1 -or
        $apkFingerprints[0].Groups[1].Value.ToUpperInvariant() -ne $expectedUpdateCertSha256) {
        throw 'APK signer does not match the fixed haoxiguan release certificate. Version remains unchanged.'
    }

    $nextVersionLine = "version: $fullVersion"
    $updatedPubspec = $pubspec.Remove(
        $versionMatch.Index,
        $versionMatch.Length
    ).Insert($versionMatch.Index, $nextVersionLine)
    $distDirectory = Join-Path $projectRoot 'dist'
    [System.IO.Directory]::CreateDirectory($distDirectory) | Out-Null
    $targetApk = Join-Path $distDirectory "haoxiguan-v$fullVersion.apk"
    Copy-Item -LiteralPath $sourceApk -Destination $targetApk -Force
    [System.IO.File]::WriteAllText(
        $pubspecPath,
        $updatedPubspec,
        [System.Text.UTF8Encoding]::new($false)
    )

    Write-Host "APK exported: $targetApk"
    Write-Host "Version updated: $fullVersion"
    Write-Host "Verified release certificate SHA256: $expectedUpdateCertSha256"
} finally {
    $env:GRADLE_OPTS = $previousGradleOpts
    Pop-Location
}
