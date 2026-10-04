$ErrorActionPreference = 'Stop'

# This is a process-boundary test with fake tools and synthetic credentials.
# It does not build an Android APK or read a real keystore.
$scriptUnderTest = Join-Path (Split-Path -Parent $PSScriptRoot) 'build_release_apk.ps1'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
    throw 'These Windows-only mock tests require the .NET Framework C# compiler.'
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('haoxiguan-signing-mock-' + [guid]::NewGuid().ToString('N'))
$javaHome = Join-Path $testRoot 'Mock Java Home'
$toolBin = Join-Path $javaHome 'bin'
$sdkRoot = Join-Path $testRoot 'Mock Android SDK'
$jarDirectory = Join-Path $sdkRoot 'build-tools\34.0.0\lib'
New-Item -ItemType Directory -Path $toolBin, $jarDirectory | Out-Null
[IO.File]::WriteAllText((Join-Path $jarDirectory 'apksigner.jar'), 'mock jar')
$sourcePath = Join-Path $testRoot 'FakeTool.cs'
[IO.File]::WriteAllText($sourcePath, @'
using System;
using System.IO;
using System.Reflection;
class FakeTool {
    static int Main(string[] args) {
        string tool = Path.GetFileNameWithoutExtension(Assembly.GetExecutingAssembly().Location);
        if (tool == "keytool") {
            if (Array.IndexOf(args, "-J-Duser.language=en") < 0 ||
                Array.IndexOf(args, "-J-Duser.country=US") < 0) return 7;
            Console.WriteLine("SHA256: " + Environment.GetEnvironmentVariable("MOCK_KEYSTORE_SHA256"));
            return 0;
        }
        if (tool == "java") {
            if (args.Length < 6 || args[0] != "-jar" || args[2] != "verify" ||
                !File.Exists(args[1]) || !File.Exists(args[args.Length - 1])) return 4;
            Console.WriteLine("Signer #1 certificate SHA-256 digest: " + Environment.GetEnvironmentVariable("MOCK_APK_SHA256"));
            return Environment.GetEnvironmentVariable("MOCK_APK_VERIFY_FAIL") == "1" ? 1 : 0;
        }
        if (tool == "flutter") {
            string opts = Environment.GetEnvironmentVariable("GRADLE_OPTS") ?? "";
            if (!opts.Contains("-Dorg.gradle.daemon=false") ||
                !opts.Contains("-Dorg.gradle.configuration-cache=false")) return 5;
            string output = Path.Combine(Environment.CurrentDirectory, "build", "app", "outputs", "flutter-apk");
            Directory.CreateDirectory(output);
            File.WriteAllText(Path.Combine(output, "app-release.apk"), "MOCK ONLY - not an APK");
            File.WriteAllText(Path.Combine(Environment.CurrentDirectory, "flutter-ran.marker"), "mock");
            return 0;
        }
        return 6;
    }
}
'@)
$toolExecutable = Join-Path $toolBin 'keytool.exe'
$compilerOutput = & $compiler /nologo /target:exe "/out:$toolExecutable" $sourcePath 2>&1
if ($LASTEXITCODE -ne 0) { throw ('Cannot compile mock tools: ' + ($compilerOutput -join "`n")) }
Copy-Item -LiteralPath $toolExecutable -Destination (Join-Path $toolBin 'java.exe')
Copy-Item -LiteralPath $toolExecutable -Destination (Join-Path $toolBin 'flutter.exe')

$names = @('PATH', 'JAVA_HOME', 'ANDROID_HOME', 'ANDROID_SDK_ROOT', 'GRADLE_OPTS',
    'FLUTTER_SUPPRESS_ANALYTICS', 'HAOXIGUAN_UPDATE_KEYSTORE',
    'HAOXIGUAN_UPDATE_STORE_PASSWORD', 'HAOXIGUAN_UPDATE_KEY_ALIAS',
    'HAOXIGUAN_UPDATE_KEY_PASSWORD', 'MOCK_KEYSTORE_SHA256', 'MOCK_APK_SHA256', 'MOCK_APK_VERIFY_FAIL')
$saved = @{}
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$pin = 'D675D16E4C0CC72C862DB337E2A6B2D7D92AFDF61135B014B95B44A016FC5ABC'
$wrongPin = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
try {
    $env:PATH = "$toolBin;$env:PATH"
    $env:JAVA_HOME = $javaHome
    $env:ANDROID_HOME = $sdkRoot
    $env:ANDROID_SDK_ROOT = $sdkRoot
    $env:GRADLE_OPTS = '-Dmock.original=true'
    $env:HAOXIGUAN_UPDATE_STORE_PASSWORD = 'MOCK_ONLY_NOT_A_SECRET'
    $env:HAOXIGUAN_UPDATE_KEY_PASSWORD = 'MOCK_ONLY_NOT_A_SECRET'
    $env:HAOXIGUAN_UPDATE_KEY_ALIAS = 'haoxiguan-release'
    $cases = @(
        @{ Name = 'keystore-mismatch'; Key = $wrongPin; Apk = $pin; VerifyFail = '0'; Success = $false; BuildRuns = $false },
        @{ Name = 'apk-mismatch'; Key = $pin; Apk = $wrongPin; VerifyFail = '0'; Success = $false; BuildRuns = $true },
        @{ Name = 'apk-invalid-signature'; Key = $pin; Apk = $pin; VerifyFail = '1'; Success = $false; BuildRuns = $true },
        @{ Name = 'matching-signature'; Key = $pin; Apk = $pin.ToLowerInvariant(); VerifyFail = '0'; Success = $true; BuildRuns = $true },
        @{ Name = 'export-failure'; Key = $pin; Apk = $pin; VerifyFail = '0'; Success = $false; BuildRuns = $true; BlockExport = $true }
    )
    foreach ($case in $cases) {
        $caseRoot = Join-Path $testRoot $case.Name
        $caseScripts = Join-Path $caseRoot 'scripts'
        New-Item -ItemType Directory -Path $caseScripts | Out-Null
        $caseScript = Join-Path $caseScripts 'build_release_apk.ps1'
        Copy-Item -LiteralPath $scriptUnderTest -Destination $caseScript
        $pubspec = Join-Path $caseRoot 'pubspec.yaml'
        [IO.File]::WriteAllText($pubspec, "name: mock`nversion: 1.1.0+5`n")
        $before = [IO.File]::ReadAllText($pubspec)
        $env:HAOXIGUAN_UPDATE_KEYSTORE = Join-Path $caseRoot 'fake-keystore.test-fixture'
        [IO.File]::WriteAllText($env:HAOXIGUAN_UPDATE_KEYSTORE, 'mock keystore - no key')
        $env:MOCK_KEYSTORE_SHA256 = $case.Key
        $env:MOCK_APK_SHA256 = $case.Apk
        $env:MOCK_APK_VERIFY_FAIL = $case.VerifyFail
        $distPath = Join-Path $caseRoot 'dist'
        if ($case.BlockExport) {
            [IO.File]::WriteAllText($distPath, 'mock file blocking the export directory')
        }
        $failed = $false
        try { & $caseScript *> $null } catch { $failed = $true }
        if ($failed -eq $case.Success) { throw "$($case.Name): unexpected success/failure outcome." }
        $after = [IO.File]::ReadAllText($pubspec)
        $export = Join-Path $caseRoot 'dist\haoxiguan-v1.1.1+6.apk'
        if ($case.Success) {
            if ($after -notmatch 'version: 1\.1\.1\+6' -or -not (Test-Path -LiteralPath $export)) {
                throw "$($case.Name): expected version update and mock artifact export."
            }
        } else {
            if ($after -cne $before -or (Test-Path -LiteralPath $export)) {
                throw "$($case.Name): a failed check changed the version or exported an artifact."
            }
            if ($case.BlockExport) {
                if (-not (Test-Path -LiteralPath $distPath -PathType Leaf) -or
                    [IO.File]::ReadAllText($distPath) -cne 'mock file blocking the export directory') {
                    throw "$($case.Name): the pre-existing export blocker changed."
                }
            } elseif (Test-Path -LiteralPath $distPath) {
                throw "$($case.Name): a failed signature check created an export directory."
            }
        }
        if ((Test-Path -LiteralPath (Join-Path $caseRoot 'flutter-ran.marker')) -ne $case.BuildRuns) {
            throw "$($case.Name): unexpected mock build invocation."
        }
        if ($env:GRADLE_OPTS -ne '-Dmock.original=true') {
            throw "$($case.Name): GRADLE_OPTS was not restored."
        }
        Write-Host "PASS (mock only): $($case.Name)"
    }
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    # Delete only the unique test directory whose resolved parent is the temp root.
    $resolvedTest = [IO.Path]::GetFullPath($testRoot)
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($resolvedTest) -eq $resolvedTemp -and
        [IO.Path]::GetFileName($resolvedTest) -like 'haoxiguan-signing-mock-*') {
        Remove-Item -LiteralPath $resolvedTest -Recurse -Force
    } else {
        throw 'Refusing cleanup because the test path is outside the temp directory.'
    }
}
