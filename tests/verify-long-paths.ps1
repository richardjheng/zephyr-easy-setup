# Real long-path scanning, copy, checksums, 7z extraction and cleanup on PS 5.1.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path $PSScriptRoot
$tokens = $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'scripts\zephyr-manager.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$functions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
. ([scriptblock]::Create(($functions | ForEach-Object { $_.Extent.Text }) -join "`n"))
$fixtureParent = Join-Path $projectRoot 'offline_bundle'
$fixture = Join-Path $fixtureParent ('long-path-test-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $fixture 'source'
$copy = Join-Path $fixture 'copy'
$archive = Join-Path $fixture 'bundle.7z'
$history = Join-Path $source 'zephyrproject\app\firmware\build-history'
$fixtureLink = Join-Path $history 'linked-source'
$linkTarget = Join-Path $fixture 'linked-target'
$sevenZip = (Get-Command 7z.exe -ErrorAction Stop).Source
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Test-ExtendedPath([string]$Path) { '\\?\' + [IO.Path]::GetFullPath($Path) }
function Write-TestFile([string]$Path, [string]$Text) {
    $extended = Test-ExtendedPath $Path
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($extended)) | Out-Null
    [IO.File]::WriteAllText($extended, $Text)
}
try {
    $longRelative = 'zephyrproject\app\' + (('nested-directory-for-long-path-test\' * 8)) + 'firmware.c'
    $longFile = Join-Path $source $longRelative
    Assert ($longFile.Length -gt 350) 'Fixture did not exceed the Windows legacy path limit.'
    Write-TestFile $longFile 'long path firmware source'
    $excluded = Join-Path $source 'zephyrproject\.venv'
    Write-TestFile (Join-Path $excluded (($longRelative) + '.ignored')) 'excluded content'
    foreach ($relative in @('zephyrproject\.west\config', 'zephyrproject\zephyr\scripts\requirements.txt',
                            'zephyr_installers\requirements-frozen.txt', 'zephyr_installers\wheels\fixture.whl',
                            'zephyrproject\zephyr-sdk-0.17.0\sdk_version')) {
        Write-TestFile (Join-Path $source $relative) 'fixture'
    }
    Write-TestFile (Join-Path $history 'build.log') 'historical output'
    Write-TestFile (Join-Path $linkTarget 'sentinel.txt') 'keep linked target'
    New-Item -ItemType Junction -Path $fixtureLink -Target $linkTarget | Out-Null
    $failure = ''
    try { $null = Measure-CopySource $source @($excluded) } catch { $failure = $_.Exception.Message }
    Assert ($failure -like '*Linked path is not supported*') 'Retained source links were silently skipped or followed.'
    $exclusions = @($excluded, $history)
    $size = Measure-CopySource $source $exclusions
    Assert ($size.Files -eq 6) 'Long-path scan lost files or counted excluded content.'
    Copy-Tree $source $copy $exclusions
    $copiedLong = Join-Path $copy $longRelative
    Assert ([IO.File]::ReadAllText((Test-ExtendedPath $copiedLong)) -eq 'long path firmware source') 'Robocopy lost long-path source contents.'
    Assert (-not [IO.Directory]::Exists((Test-ExtendedPath (Join-Path $copy 'zephyrproject\.venv')))) 'Copy included excluded content.'
    Assert (-not [IO.Directory]::Exists((Test-ExtendedPath (Join-Path $copy 'zephyrproject\app\firmware\build-history')))) 'Copy followed junctions inside an excluded app directory.'
    Assert-NoLinks $copy
    $files = @(Get-BundleFileHashes $copy)
    Assert ($files.Count -eq 6) 'Checksum inventory omitted long paths.'
    $entry = @($files | Where-Object { $_.Path -eq $longRelative })
    Assert ($entry.Count -eq 1) 'Manifest path retained a device prefix or changed the relative path.'
    Assert ($entry[0].Sha256 -eq (Get-FileHash -LiteralPath (Test-ExtendedPath $longFile)).Hash) 'Long-path SHA-256 changed.'
    $manifest = @{ Format = 1; Python = '3.12'; Architecture = 'x64'; Sdk = 'zephyrproject\zephyr-sdk-0.17.0'; Files = $files; HostTools = @() }
    Save-Json $manifest (Join-Path $copy 'bundle-manifest.json')
    $Tools = @()
    $Root = $copy
    $Workspace = Join-Path $Root 'zephyrproject'
    $Cache = Join-Path $Root 'zephyr_installers'
    $null = Test-Bundle
    Push-Location -LiteralPath $copy
    try { Invoke-PackArchive $sevenZip @('a', '-t7z', '-mx=0', $archive, '.\*') 'Archive long paths' }
    finally { Pop-Location }
    Invoke-PackArchive $sevenZip @('t', $archive) 'Check long-path archive'
    $Root = Join-Path $fixture 'extracted'
    $Workspace = Join-Path $Root 'zephyrproject'
    $Cache = Join-Path $Root 'zephyr_installers'
    Assert-BundleArchive $archive $sevenZip
    Invoke-PackArchive $sevenZip @('x', '-y', ('-o' + $Root), $archive) 'Extract long paths'
    Assert-BundleArchive $archive $sevenZip
    $null = Test-Bundle $manifest
    $extractedLong = Join-Path $Root $longRelative
    Write-TestFile $extractedLong 'tampered'
    $failure = ''
    try { $null = Test-Bundle $manifest } catch { $failure = $_.Exception.Message }
    Assert ($failure -like '*damaged or modified*') 'Long-path tampering was not detected.'
    Write-TestFile $extractedLong 'long path firmware source'
    [IO.File]::SetAttributes((Test-ExtendedPath $extractedLong), [IO.FileAttributes]::ReadOnly)
    Remove-Local $Root $fixture
    Assert (-not [IO.Directory]::Exists((Test-ExtendedPath $Root))) 'Cleanup left long-path/read-only files.'
    Assert ([IO.File]::ReadAllText((Test-ExtendedPath $longFile)) -eq 'long path firmware source') 'Validation changed the original source.'
    Assert ([IO.File]::ReadAllText((Test-ExtendedPath (Join-Path $linkTarget 'sentinel.txt'))) -eq 'keep linked target') 'Copy or cleanup modified a linked target.'
    Assert ([IO.File]::Exists((Test-ExtendedPath (Join-Path $history 'build.log')))) 'Exclusion removed historical source data.'
    $outsideRejected = $false
    try { $null = Assert-Within ('\\?\' + $fixture + '\..\outside') $fixture } catch { $outsideRejected = $true }
    Assert $outsideRejected 'Extended prefix bypassed path traversal validation.'
    Write-Host '[PASS] Long paths survive scan/exclusions, real copy, checksums, 7z round-trip, tamper detection and read-only cleanup; explicit app exclusions skip junction trees while preserving source and linked targets.'
} finally {
    # Cleanup also works before the production long-path fix, so regression failures
    # do not leave a deep fixture behind. Only remove this verified fixture child.
    $checked = Assert-Within $fixture $fixtureParent
    $extended = Test-ExtendedPath $checked
    if ([IO.Directory]::Exists((Test-ExtendedPath $fixtureLink))) {
        # Unlink this fixture junction without recursing into its target.
        [IO.Directory]::Delete((Test-ExtendedPath $fixtureLink))
    }
    if ([IO.Directory]::Exists($extended)) {
        foreach ($file in [IO.Directory]::GetFiles($extended, '*', [IO.SearchOption]::AllDirectories)) {
            [IO.File]::SetAttributes($file, [IO.FileAttributes]::Normal)
        }
        [IO.Directory]::Delete($extended, $true)
    }
}
