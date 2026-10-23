# Isolated filesystem checks; never install/uninstall shared tools or change HKCU.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path $PSScriptRoot
$scriptPath = Join-Path $projectRoot 'scripts\zephyr-manager.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
# Load the actual functions without executing the script's dispatch/exit block.
$functions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
. ([scriptblock]::Create(($functions | ForEach-Object { $_.Extent.Text }) -join "`n"))
$toolsAssignment = $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$Tools' }
. ([scriptblock]::Create($toolsAssignment.Extent.Text))
$Root = Join-Path $projectRoot ('offline_bundle\test-' + [guid]::NewGuid().ToString('N'))
$fixtureRoot = $Root
$Workspace = Join-Path $Root 'zephyrproject'
$Cache = Join-Path $Root 'zephyr_installers'
$Board = $Qualifier = $Toolchain = ''
$junctionPath = Join-Path $Workspace 'linked-module'
$script:registrationCalls = 0
function Clear-Registration { $script:registrationCalls++ }
function Read-Host([string]$Prompt) { return $script:answers.Dequeue() }
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Expect-Failure([scriptblock]$Action, [string]$Pattern) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    Assert ($null -ne $caught -and $caught -like $Pattern) "Expected failure '$Pattern', got '$caught'."
}
function Set-Answers([string[]]$Values) {
    $script:answers = New-Object 'System.Collections.Generic.Queue[string]'
    foreach ($value in $Values) { $script:answers.Enqueue($value) }
}

try {
    New-Item -ItemType Directory -Path "$Workspace\app", "$Workspace\.venv", "$Workspace\.west", "$Workspace\zephyr\scripts", "$Workspace\zephyr-sdk-0.17.0", "$Cache\wheels", "$Root\tools", "$Root\unrelated" -Force | Out-Null
    Set-Content -LiteralPath "$Workspace\app\user.c" -Value 'keep this source'
    Set-Content -LiteralPath "$Workspace\.venv\sentinel" -Value 'venv'
    Set-Content -LiteralPath "$Workspace\.west\config" -Value 'west config'
    Set-Content -LiteralPath "$Workspace\zephyr\scripts\requirements.txt" -Value 'west==1.0'
    Set-Content -LiteralPath "$Root\unrelated\sentinel" -Value 'unrelated source'
    Set-Content -LiteralPath "$Cache\requirements-frozen.txt" -Value 'west==1.0'
    Set-Content -LiteralPath "$Cache\wheels\dummy.whl" -Value 'fixture only'
    Set-Content -LiteralPath "$Workspace\zephyr-sdk-0.17.0\sdk_version" -Value '0.17.0'
    $originalHash = (Get-FileHash -LiteralPath "$Workspace\app\user.c").Hash
    $null = Assert-Within "$Workspace\app" $Root
    Expect-Failure { Assert-Within "$Root\..\outside" $Root } '*outside the expected*'
    Expect-Failure { Assert-Within ($Root + '-other\file') $Root } '*outside the expected*'
    Expect-Failure { Invoke-Checked 'cmd.exe' @('/c', 'exit', '7') } '*exit 7*'
    Write-Host '[PASS] Native errors propagate and deletion paths stay within their parent.'

    # A leftover portable CMake ZIP must not satisfy the MSI offline installer requirement.
    $cmakeTool = @($Tools | Where-Object { $_.Id -eq 'Kitware.CMake' })[0]
    $cmakeCache = Join-Path $Root 'cmake-cache'
    New-Item -ItemType Directory -Path $cmakeCache -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $cmakeCache 'CMake_portable.zip') -Value 'portable fixture'
    $checkedFunction = ${function:Invoke-Checked}
    try {
        $script:installerDownloadCalls = 0
        function Invoke-Checked([string]$Exe, [string[]]$Arguments) {
            $script:installerDownloadCalls++
            Assert ($Exe -eq 'winget.exe' -and $Arguments -contains 'download') 'Installer acquisition ran an unexpected command.'
            $typeIndex = [Array]::IndexOf($Arguments, '--installer-type')
            Assert ($typeIndex -ge 0 -and $Arguments[$typeIndex + 1] -eq 'wix') 'CMake download did not request its WiX MSI installer.'
            $directoryIndex = [Array]::IndexOf($Arguments, '--download-directory')
            Set-Content -LiteralPath (Join-Path $Arguments[$directoryIndex + 1] 'CMake_installer.msi') -Value 'MSI fixture'
        }
        Expect-Failure { Get-HostInstaller $cmakeTool $cmakeCache -CacheOnly } '*Missing cached installer: Kitware.CMake*'
        Assert ($script:installerDownloadCalls -eq 0) 'CacheOnly downloaded an installer.'
        $installer = Get-HostInstaller $cmakeTool $cmakeCache
        Assert ($installer.Extension -eq '.msi' -and $script:installerDownloadCalls -eq 1) 'Portable ZIP prevented acquisition of the required MSI.'
        $cachedInstaller = Get-HostInstaller $cmakeTool $cmakeCache -CacheOnly
        Assert ($cachedInstaller.FullName -eq $installer.FullName -and $script:installerDownloadCalls -eq 1) 'Cached MSI was not reused alongside a ZIP.'
        Assert (Test-Path -LiteralPath (Join-Path $cmakeCache 'CMake_portable.zip')) 'Existing portable ZIP was removed.'
        Set-Content -LiteralPath (Join-Path $cmakeCache 'second.msi') -Value 'ambiguous fixture'
        Expect-Failure { Get-HostInstaller $cmakeTool $cmakeCache } '*found 2*'
    } finally { ${function:Invoke-Checked} = $checkedFunction }
    Write-Host '[PASS] CMake acquisition selects WiX MSI, handles a leftover ZIP, and reuses the matching cache.'

    # Verify every host download requests a format compatible with its offline install path.
    $installerFormats = @(
        @{ Id = 'Python.Python.3.12'; Type = 'burn'; Extension = '.exe' },
        @{ Id = 'Git.Git'; Type = 'inno'; Extension = '.exe' },
        @{ Id = 'Kitware.CMake'; Type = 'wix'; Extension = '.msi' },
        @{ Id = '7zip.7zip'; Type = 'exe'; Extension = '.exe' },
        @{ Id = 'Ninja-build.Ninja'; Type = 'zip'; Extension = '.zip' },
        @{ Id = 'oss-winget.gperf'; Type = 'zip'; Extension = '.zip' },
        @{ Id = 'oss-winget.dtc'; Type = 'zip'; Extension = '.zip' }
    )
    $checkedFunction = ${function:Invoke-Checked}
    try {
        function Invoke-Checked([string]$Exe, [string[]]$Arguments) {
            $script:installerDownloadCalls++
            $typeIndex = [Array]::IndexOf($Arguments, '--installer-type')
            $idIndex = [Array]::IndexOf($Arguments, '--id')
            Assert ($Exe -eq 'winget.exe' -and $Arguments[$idIndex + 1] -eq $script:expectedFormat.Id) 'Unexpected host installer download.'
            Assert ($typeIndex -ge 0 -and $Arguments[$typeIndex + 1] -eq $script:expectedFormat.Type) 'Host download requested an incompatible installer type.'
            $directoryIndex = [Array]::IndexOf($Arguments, '--download-directory')
            Set-Content -LiteralPath (Join-Path $Arguments[$directoryIndex + 1] ('installer' + $script:expectedFormat.Extension)) -Value 'host installer fixture'
        }
        foreach ($format in $installerFormats) {
            $script:expectedFormat = $format
            $script:installerDownloadCalls = 0
            $tool = @($Tools | Where-Object { $_.Id -eq $format.Id })[0]
            $toolCache = Join-Path $Root ('format-cache\' + $format.Id)
            New-Item -ItemType Directory -Path $toolCache -Force | Out-Null
            # Reproduce 7-Zip's leftover MSI while its offline flow requires an EXE.
            if ($format.Id -eq '7zip.7zip') { Set-Content -LiteralPath (Join-Path $toolCache '7-Zip_previous.msi') -Value 'MSI fixture' }
            $installer = Get-HostInstaller $tool $toolCache
            Assert ($installer.Extension -eq $format.Extension -and $script:installerDownloadCalls -eq 1) 'Host installer extension does not match offline installation.'
            $cached = Get-HostInstaller $tool $toolCache -CacheOnly
            Assert ($cached.FullName -eq $installer.FullName -and $script:installerDownloadCalls -eq 1) 'Matching host installer was not reused.'
        }
    } finally { ${function:Invoke-Checked} = $checkedFunction }
    Write-Host '[PASS] All seven host tools use explicit compatible installer formats; 7-Zip EXE is selected alongside a cached MSI.'

    # Reproduce the URL freeze entry that used to be mistaken for a local install.
    $script:freezeFixture = @('west==1.5.0', 'reuse @ https://example.invalid/reuse.tar.gz#sha256=abc')
    $script:metadataVersion = '6.2.0'
    function Invoke-FrozenPython {
        $global:LASTEXITCODE = 0
        if ($args -contains 'freeze') { $script:freezeFixture }
        elseif ($args -contains '-c') { $script:metadataVersion }
        else { throw 'Unexpected Python fixture invocation.' }
    }
    $pinned = @(ConvertTo-OfflineRequirements 'Invoke-FrozenPython' $script:freezeFixture)
    Assert ($pinned.Count -eq 2 -and $pinned[1] -eq 'reuse==6.2.0') 'Remote dependency did not retain its installed version.'
    $remoteRequirements = Join-Path $Workspace 'zephyr\scripts\remote.txt'
    $includedRequirements = Join-Path $Workspace 'zephyr\scripts\compliance.txt'
    Set-Content -LiteralPath $remoteRequirements -Value '-r compliance.txt'
    $remoteLine = 'reuse @ https://example.invalid/reuse.tar.gz; sys_platform == "win32"'
    Set-Content -LiteralPath $includedRequirements -Value $remoteLine
    $offlineRequirements = Copy-OfflineRequirements $remoteRequirements $Workspace (Join-Path $Root 'requirements-test') $script:freezeFixture $pinned
    $offlineIncluded = Join-Path $Root 'requirements-test\zephyr\scripts\compliance.txt'
    Assert ((Get-Content -LiteralPath $offlineIncluded) -eq 'reuse==6.2.0; sys_platform == "win32"') 'Included remote requirement or environment marker was not normalized.'
    Assert ((Get-Content -LiteralPath $offlineRequirements) -eq ('-r "' + $offlineIncluded + '"')) 'Requirement include did not point to staging.'
    Assert ((Get-Content -LiteralPath $includedRequirements) -eq $remoteLine) 'Original requirements were edited.'
    Set-Content -LiteralPath $includedRequirements -Value 'reuse @ https://example.invalid/different.tar.gz'
    Expect-Failure { Copy-OfflineRequirements $includedRequirements $Workspace (Join-Path $Root 'requirements-mismatch') $script:freezeFixture $pinned } '*does not match the installed source*'
    # A normal index installation has a version pin, without direct_url metadata.
    # Reproduce that installed snapshot even if upstream now requests an archive.
    Set-Content -LiteralPath $includedRequirements -Value $remoteLine
    $indexFrozen = @('west==1.5.0', 'reuse==6.2.0')
    $indexCopy = Copy-OfflineRequirements $includedRequirements $Workspace (Join-Path $Root 'requirements-index') $indexFrozen $pinned
    Assert ((Get-Content -LiteralPath $indexCopy) -eq 'reuse==6.2.0; sys_platform == "win32"') 'A pinned index installation could not replace the upstream archive requirement.'
    Assert ((Get-Content -LiteralPath $includedRequirements) -eq $remoteLine) 'Index normalization edited the original requirements.'
    Expect-Failure { Copy-OfflineRequirements $includedRequirements $Workspace (Join-Path $Root 'requirements-pin-mismatch') @('reuse==6.1.0') $pinned } '*does not match the installed source*'
    Expect-Failure { Copy-OfflineRequirements $includedRequirements $Workspace (Join-Path $Root 'requirements-not-installed') @('west==1.5.0') $pinned } '*does not match the installed source*'
    foreach ($line in @('-e D:\local-package', 'reuse @ file:///D:/local-package', 'reuse @ git+https://example.invalid/reuse.git')) {
        Expect-Failure { ConvertTo-OfflineRequirements 'Invoke-FrozenPython' @($line) } '*local/editable or unsupported*'
    }
    $script:metadataVersion = ''
    Expect-Failure { ConvertTo-OfflineRequirements 'Invoke-FrozenPython' $script:freezeFixture } '*Cannot determine installed version*'
    $script:metadataVersion = '6.2.0'
    $checkedFunction = ${function:Invoke-Checked}
    try {
        $script:wheelCalls = @()
        function Invoke-Checked([string]$Exe, [string[]]$Arguments) { $script:wheelCalls += ,$Arguments }
        $pythonCache = Join-Path $Root 'python-cache'
        $requirements = Save-PythonWheelCache 'Invoke-FrozenPython' $pythonCache
        Assert ((Get-Content -LiteralPath $requirements) -contains 'reuse==6.2.0') 'Offline requirements lost the version pin.'
        Assert ((Get-Content -LiteralPath (Join-Path $pythonCache 'requirements-source.txt')) -contains $script:freezeFixture[1]) 'Original URL or hash was lost.'
        Assert ($script:wheelCalls.Count -eq 2 -and $script:wheelCalls[0] -contains 'wheel' -and $script:wheelCalls[0] -contains (Join-Path $pythonCache 'requirements-source.txt')) 'Online packaging did not build from the original requirements.'
        Assert ($script:wheelCalls[1] -contains '--no-index' -and $script:wheelCalls[1] -contains $requirements) 'Wheel validation is not offline.'
        $script:wheelCalls = @()
        $null = Save-PythonWheelCache 'Invoke-FrozenPython' $pythonCache -CacheOnly
        Assert ($script:wheelCalls.Count -eq 1 -and $script:wheelCalls[0] -contains 'download' -and $script:wheelCalls[0] -contains '--no-index' -and $script:wheelCalls[0] -contains $requirements) 'CacheOnly attempted a remote wheel build.'
        $script:freezeFixture = @('reuse==6.2.0')
        Expect-Failure { Save-PythonWheelCache 'Invoke-FrozenPython' $pythonCache } '*west is not installed*'
    } finally { ${function:Invoke-Checked} = $checkedFunction }
    Write-Host '[PASS] Remote Python sources become pinned wheels; cache-only avoids URLs and local/editable installs remain rejected.'

    $settings = Get-Settings $Workspace
    Assert ($settings.Board -eq 'it51xxx_evb') 'Default board lost.'
    $Board = 'stm32f4_disco'; $Toolchain = 'arm-zephyr-eabi'
    $settings = Get-Settings $Workspace
    Assert ($settings.Qualifier -eq '' -and $settings.Toolchain -eq 'arm-zephyr-eabi') 'Custom board inherited ITE qualifier.'
    Save-Json $settings "$Workspace\.zephyr-setup.json"
    $Board = $Toolchain = ''
    Assert ((Get-Settings $Workspace).Board -eq 'stm32f4_disco') 'Stored board was not reused.'
    Write-Host '[PASS] Board/toolchain settings survive save and reload.'

    $copyTarget = Join-Path $Root 'copy'
    Copy-Tree $Workspace $copyTarget @("$Workspace\.venv")
    Assert (Test-Path -LiteralPath "$Workspace\.venv\sentinel") 'Copy removed source data.'
    Assert (Test-Path -LiteralPath "$copyTarget\.west\config") 'Copy omitted hidden west metadata.'
    Assert (-not (Test-Path -LiteralPath "$copyTarget\.venv")) 'Copy included virtual environment.'
    $copyWithSpaces = Join-Path $Root 'copy with spaces'
    Copy-Tree ($copyTarget + '\') $copyWithSpaces
    Assert ((Get-FileHash -LiteralPath (Join-Path $copyWithSpaces 'app\user.c')).Hash -eq $originalHash) 'Native copy argument quoting lost data in a path with spaces or a trailing separator.'
    Expect-Failure { Copy-Tree $copyTarget "$Root\unrelated\sentinel" } '*robocopy exit*'
    Write-Host '[PASS] Staging preserves source and hidden west metadata, excluding .venv.'

    $entries = @()
    foreach ($tool in $Tools) {
        $directory = Join-Path $Cache ('tools\' + $tool.Id)
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $installer = Join-Path $directory ('installer' + $tool.Extension)
        Set-Content -LiteralPath $installer -Value ('dummy ' + $tool.Id)
        $entries += @{ Id = $tool.Id; Path = $installer.Substring($Root.Length + 1); Sha256 = (Get-FileHash -LiteralPath $installer).Hash }
    }
    $payloadPath = 'zephyrproject\app\user.c'
    $manifest = @{ Format = 1; Python = '3.12'; Architecture = 'x64'; Sdk = 'zephyrproject\zephyr-sdk-0.17.0'; HostTools = $entries; Files = @(@{ Path = $payloadPath; Sha256 = $originalHash }) }
    Save-Json $manifest "$Root\bundle-manifest.json"
    $null = Test-Bundle
    Set-Content -LiteralPath "$Workspace\app\user.c" -Value 'tampered'
    Expect-Failure { Test-Bundle } '*damaged or modified*'
    Set-Content -LiteralPath "$Workspace\app\user.c" -Value 'keep this source'
    $manifest.HostTools = @($entries | Select-Object -Skip 1)
    Save-Json $manifest "$Root\bundle-manifest.json"
    Expect-Failure { Test-Bundle } '*missing installer metadata*'
    $manifest.HostTools = $entries
    $manifest.Files = @(@{ Path = '..\outside'; Sha256 = 'bad' })
    Save-Json $manifest "$Root\bundle-manifest.json"
    Expect-Failure { Test-Bundle } '*outside the expected*'
    Write-Host '[PASS] Bundle validation rejects tampering, missing installers and escaping paths.'

    foreach ($answer in @('', 'n', 'yes')) {
        Set-Answers @($answer)
        Uninstall-Zephyr
        Assert (Test-Path -LiteralPath "$Workspace\.venv\sentinel") 'Cancelled uninstall deleted files.'
        Assert ($script:registrationCalls -eq 0) 'Cancelled uninstall changed registration.'
    }
    Write-Host '[PASS] Enter/N/other answers cancel before any change.'

    New-Item -ItemType Junction -Path $junctionPath -Target "$Root\unrelated" | Out-Null
    Set-Answers @('y', 'n')
    Expect-Failure { Uninstall-Zephyr } '*Linked path is not supported*'
    Assert (Test-Path -LiteralPath "$Workspace\.venv\sentinel") 'Junction rejection happened after deletion.'
    [IO.Directory]::Delete($junctionPath)
    Set-Answers @('Y', 'n')
    Uninstall-Zephyr
    Assert ((Get-FileHash -LiteralPath "$Workspace\app\user.c").Hash -eq $originalHash) 'Application changed during uninstall.'
    Assert (-not (Test-Path -LiteralPath "$Workspace\.venv")) 'venv was not removed.'
    Assert (-not (Test-Path -LiteralPath "$Root\tools")) 'Local portable tools were not removed.'
    Assert (Test-Path -LiteralPath "$Root\unrelated\sentinel") 'Unrelated workspace was removed.'
    Assert (Test-Path -LiteralPath "$Cache\requirements-frozen.txt") 'Offline cache was removed.'
    Assert ($script:registrationCalls -eq 1) 'Registration cleanup was not called once.'
    Assert (-not (Test-Path -LiteralPath "$Root\bundle-manifest.json")) 'Uninstall left the old bundle manifest behind.'
    Write-Host '[PASS] Confirmed uninstall preserves app, unrelated data and offline cache.'

    # Real batch wrappers propagate errors; no system installers are invoked.
    New-Item -ItemType Directory -Path "$Root\scripts" -Force | Out-Null
    Copy-Item -LiteralPath $scriptPath -Destination "$Root\scripts"
    foreach ($wrapper in @('zephyr-pack-offline.bat', 'zephyr-offline-install.bat')) { Copy-Item -LiteralPath (Join-Path $projectRoot $wrapper) -Destination $Root }
    Remove-Local "$Root\bundle-manifest.json" $Root
    $env:ZEPHYR_NO_PAUSE = '1'
    & cmd.exe /c "$Root\zephyr-offline-install.bat" -CheckOnly | Out-Host
    Assert ($LASTEXITCODE -eq 1) 'Offline wrapper lost error exit code.'
    & cmd.exe /c "$Root\zephyr-pack-offline.bat" -CacheOnly | Out-Host
    Assert ($LASTEXITCODE -eq 1) 'Pack wrapper lost error exit code.'
    $selectedData = Join-Path $Root 'selected-data'
    $output = @(& cmd.exe /c "$Root\zephyr-offline-install.bat" -InstallDir $selectedData -CheckOnly)
    Assert ($LASTEXITCODE -eq 1 -and ($output -join "`n").Contains((Join-Path $selectedData 'bundle-manifest.json'))) 'Offline wrapper did not read the selected data directory.'
    $output = @(& cmd.exe /c "$Root\zephyr-pack-offline.bat" -InstallDir $selectedData -CacheOnly)
    Assert ($LASTEXITCODE -eq 1 -and ($output -join "`n").Contains((Join-Path $selectedData 'zephyrproject'))) 'Pack wrapper did not select the requested workspace.'
    Copy-Item -LiteralPath (Join-Path $projectRoot 'zephyr-uninstall.bat') -Destination $Root
    $output = @('n' | & cmd.exe /c "$Root\zephyr-uninstall.bat" -InstallDir $selectedData)
    Assert ($LASTEXITCODE -eq 0 -and ($output -join "`n").Contains('Cancelled. No changes made.')) 'Uninstall wrapper did not accept the selected directory and cancellation.'
    Assert (-not (Test-Path -LiteralPath $selectedData)) 'Selected data directory was created during read-only checks.'
    Copy-Tree $copyTarget (Join-Path $selectedData 'zephyrproject')
    Copy-Tree $Cache (Join-Path $selectedData 'zephyr_installers')
    $manifest.Files = @(@{ Path = $payloadPath; Sha256 = $originalHash })
    Save-Json $manifest (Join-Path $selectedData 'bundle-manifest.json')
    $output = @(& cmd.exe /c "$Root\zephyr-offline-install.bat" -InstallDir $selectedData -CheckOnly)
    Assert ($LASTEXITCODE -eq 0 -and ($output -join "`n").Contains('[OK] Bundle checksums and installer inventory verified.')) 'Offline wrapper did not validate a data-only bundle in the selected directory.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $selectedData 'scripts'))) 'Data-only bundle unexpectedly contains manager scripts.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $selectedData 'zephyrproject\.venv'))) 'Offline CheckOnly created a virtual environment.'
    $zipPlaceholder = Join-Path $Root 'bundle.zip'
    Set-Content -LiteralPath $zipPlaceholder -Value 'No extraction should be attempted during CheckOnly.'
    $output = @(& cmd.exe /c "$Root\zephyr-offline-install.bat" $zipPlaceholder $selectedData -CheckOnly)
    Assert ($LASTEXITCODE -eq 0 -and ($output -join "`n").Contains('[OK] Bundle checksums and installer inventory verified.')) 'Positional Offline CheckOnly did not validate the already extracted bundle.'
    Write-Host '[PASS] Batch entry points return exit 1 for incomplete environments.'

    # Use the real parameter declaration to check offline positional and named binding.
    $probeBody = @'
@{ Mode=$Mode; BundlePath=$BundlePath; InstallDir=$InstallDir; Board=$Board; Toolchain=$Toolchain; CheckOnly=[bool]$CheckOnly } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'arguments.json')
exit 9
'@
    Set-Content -LiteralPath "$Root\scripts\zephyr-manager.ps1" -Value ($ast.ParamBlock.Extent.Text + "`n" + $probeBody) -Encoding UTF8
    $offlineCases = @(
        @{ Args = @('D:\zephyr-offline-bundle.zip', 'D:\'); Zip = 'D:\zephyr-offline-bundle.zip'; Install = 'D:\'; Check = $false; Board = ''; Toolchain = '' },
        @{ Args = @('"D:\offline media\zephyr-offline-bundle.zip"', 'D:\', '-CheckOnly'); Zip = 'D:\offline media\zephyr-offline-bundle.zip'; Install = 'D:\'; Check = $true; Board = ''; Toolchain = '' },
        @{ Args = @('D:\bundle.zip', 'D:\zephyr', '-Board', 'stm32f4_disco', '-Toolchain', 'arm-zephyr-eabi'); Zip = 'D:\bundle.zip'; Install = 'D:\zephyr'; Check = $false; Board = 'stm32f4_disco'; Toolchain = 'arm-zephyr-eabi' },
        @{ Args = @('-BundlePath', 'D:\bundle.zip', '-InstallDir', 'D:\', '-CheckOnly'); Zip = 'D:\bundle.zip'; Install = 'D:\'; Check = $true; Board = ''; Toolchain = '' }
    )
    foreach ($case in $offlineCases) {
        $caseArgs = $case.Args
        $output = @(& cmd.exe /c "$Root\zephyr-offline-install.bat" @caseArgs)
        Assert ($LASTEXITCODE -eq 9) 'Offline argument binding or timing changed the helper exit code.'
        $arguments = Get-Content -LiteralPath "$Root\scripts\arguments.json" -Raw | ConvertFrom-Json
        Assert ($arguments.Mode -eq 'Offline' -and $arguments.BundlePath -eq $case.Zip -and $arguments.InstallDir -eq $case.Install) 'Offline ZIP or install directory was bound to the wrong parameter.'
        Assert ($arguments.CheckOnly -eq $case.Check -and $arguments.Board -eq $case.Board -and $arguments.Toolchain -eq $case.Toolchain) 'Offline trailing options changed.'
        Assert (@($output | Where-Object { $_ -like '[[]TIME]*' }).Count -eq 1) 'Offline positional invocation lost elapsed time reporting.'
    }
    Write-Host '[PASS] Offline ZIP/destination positional arguments preserve drive roots, quoted ZIP paths, trailing options and named syntax.'

    # Verify legacy online positional parameters without running installers.
    Copy-Item -LiteralPath (Join-Path $projectRoot 'zephyr-easy-setup.bat') -Destination $Root
    @'
param([string]$Mode, [string]$Board, [string]$Qualifier, [string]$Toolchain, [string]$Revision, [string]$InstallDir, [switch]$CheckOnly)
@{Mode=$Mode;Board=$Board;Qualifier=$Qualifier;Toolchain=$Toolchain;Revision=$Revision;InstallDir=$InstallDir;CheckOnly=[bool]$CheckOnly} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'arguments.json')
exit 9
'@ | Set-Content -LiteralPath "$Root\scripts\zephyr-manager.ps1" -Encoding ASCII
    & cmd.exe /c "$Root\zephyr-easy-setup.bat" | Out-Host
    Assert ($LASTEXITCODE -eq 9) 'Default online wrapper lost exit status or empty parameters.'
    & cmd.exe /c "$Root\zephyr-easy-setup.bat" stm32f4_disco '""' arm-zephyr-eabi v4.1.0 | Out-Host
    Assert ($LASTEXITCODE -eq 9) 'Custom online wrapper lost exit status.'
    $arguments = Get-Content -LiteralPath "$Root\scripts\arguments.json" -Raw | ConvertFrom-Json
    Assert ($arguments.Board -eq 'stm32f4_disco' -and $arguments.Qualifier -eq '' -and $arguments.Toolchain -eq 'arm-zephyr-eabi' -and $arguments.Revision -eq 'v4.1.0') 'Positional arguments changed.'
    & cmd.exe /c "$Root\zephyr-easy-setup.bat" -InstallDir "$Root\custom-install" -Board stm32f4_disco -Toolchain arm-zephyr-eabi -CheckOnly | Out-Host
    Assert ($LASTEXITCODE -eq 9) 'Named online wrapper lost exit status.'
    $arguments = Get-Content -LiteralPath "$Root\scripts\arguments.json" -Raw | ConvertFrom-Json
    Assert ($arguments.InstallDir -eq "$Root\custom-install" -and $arguments.Board -eq 'stm32f4_disco' -and $arguments.CheckOnly) 'Named directory arguments changed.'
    Write-Host '[PASS] Online batch wrapper preserves defaults and custom positional arguments.'

    # A native stub verifies build exit-code handling, not Zephyr compilation.
    New-Item -ItemType Directory -Path "$Workspace\.venv\Scripts" -Force | Out-Null
    Add-Type -TypeDefinition @'
public static class BuildExitStub {
    public static int Main(string[] args) {
        if (args.Length > 0 && args[0] == "--utf8-output") {
            byte[] bytes = System.Text.Encoding.UTF8.GetBytes("\u6b63\u5728\u5b89\u88dd\n");
            System.Console.OpenStandardOutput().Write(bytes, 0, bytes.Length);
            return 0;
        }
        return System.Environment.GetEnvironmentVariable("ZEPHYR_TEST_BUILD_SUCCESS") == "1" ? 0 : 8;
    }
}
'@ -OutputAssembly "$Workspace\.venv\Scripts\python.exe" -OutputType ConsoleApplication
    $savedOutputEncoding = [Console]::OutputEncoding
    $savedPipeEncoding = $OutputEncoding
    try {
        $expectedText = -join ([char[]]@(0x6b63, 0x5728, 0x5b89, 0x88dd))
        [Console]::OutputEncoding = [Text.Encoding]::GetEncoding(950)
        $garbled = @(& "$Workspace\.venv\Scripts\python.exe" --utf8-output)
        Assert ($garbled.Count -eq 1 -and $garbled[0] -cne $expectedText) 'Legacy-code-page reproduction did not corrupt native UTF-8 output.'
        Set-ConsoleUtf8
        Assert ([Console]::OutputEncoding.CodePage -eq 65001 -and $OutputEncoding.CodePage -eq 65001) 'Console and pipe encodings do not agree.'
        $decoded = @(& "$Workspace\.venv\Scripts\python.exe" --utf8-output)
        Assert ($LASTEXITCODE -eq 0 -and $decoded.Count -eq 1 -and $decoded[0] -ceq $expectedText) 'Native Chinese UTF-8 output is still garbled.'
    } finally {
        [Console]::OutputEncoding = $savedOutputEncoding
        $OutputEncoding = $savedPipeEncoding
    }
    Write-Host '[PASS] Native Chinese UTF-8 output is decoded correctly after legacy-code-page reproduction.'
    function Invoke-Checked([string]$Exe, [string[]]$Arguments) { }
    $settings = [pscustomobject]@{ Board = 'it51xxx_evb'; Qualifier = 'it51xxx_evb/it51526aw'; Toolchain = 'riscv64-zephyr-elf' }
    New-Item -ItemType Directory -Path "$Workspace\app\blinky" -Force | Out-Null
    Expect-Failure { Complete-Setup $settings "$Workspace\zephyr-sdk-0.17.0" } '*Sample build failed*'
    $env:ZEPHYR_TEST_BUILD_SUCCESS = '1'
    Complete-Setup $settings "$Workspace\zephyr-sdk-0.17.0"
    Assert ((Get-Settings $Workspace).SdkDirectory -eq 'zephyr-sdk-0.17.0') 'Relocated SDK settings became absolute.'
    Write-Host '[PASS] Failed builds stop setup; saved SDK path remains relocatable.'

    $fixtureRoot = $Root
    $PackageRoot = $projectRoot
    $InstallDir = ''
    Set-Answers @('')
    Select-InstallDirectory
    Assert ($Root -eq $projectRoot) 'Enter did not select the installer directory.'
    Set-Answers @("$fixtureRoot\prompt-install")
    Select-InstallDirectory
    Assert ($Workspace -eq "$fixtureRoot\prompt-install\zephyrproject") 'Prompt did not select the requested workspace.'
    $InstallDir = "$fixtureRoot\chosen-install"
    $CheckOnly = $true
    Install-Online
    Assert (-not (Test-Path -LiteralPath $Root)) 'Online path check wrote files.'
    $CheckOnly = $false
    # Selecting a drive root is read-only here; never install or uninstall there.
    $driveRoot = [IO.Path]::GetPathRoot($fixtureRoot)
    $InstallDir = $driveRoot
    Select-InstallDirectory
    Assert ($Root -eq $driveRoot) 'Drive root lost its absolute-path separator.'
    Assert ($Workspace -eq (Join-Path $driveRoot 'zephyrproject')) 'Drive-root workspace is incorrect.'
    Assert ($Cache -eq (Join-Path $driveRoot 'zephyr_installers')) 'Drive-root cache is incorrect.'
    Assert ((Get-ToolsDirectory) -eq (Join-Path $Workspace '.host-tools')) 'Drive-root tools escaped the workspace.'
    Assert ((Get-RelativeBundlePath (Join-Path $Cache 'tools\installer.zip') $Root) -eq 'zephyr_installers\tools\installer.zip') 'Drive-root bundle path lost a character.'
    Expect-Failure { Remove-Local $driveRoot $driveRoot } '*outside the expected*'
    $InstallDir = ''
    Set-Answers @($driveRoot)
    Select-InstallDirectory
    Assert ($Root -eq $driveRoot) 'Prompt rejected the drive root.'
    $PackageRoot = $driveRoot
    Set-Answers @('')
    Select-InstallDirectory
    Assert ($Root -eq $driveRoot) 'Installer at drive root changed its default installation path.'
    $PackageRoot = $projectRoot
    $output = @(& cmd.exe /c (Join-Path $projectRoot 'zephyr-easy-setup.bat') -InstallDir $driveRoot -CheckOnly)
    Assert ($LASTEXITCODE -eq 0) 'Actual launcher rejected the drive-root installation path.'
    Assert (($output -join "`n").Contains("Zephyr workspace:       $Workspace")) 'Actual launcher reported a wrong drive-root workspace.'
    Write-Host '[PASS] Drive-root selection keeps absolute paths, owned tools and complete bundle paths.'
    $InstallDir = "$fixtureRoot\path with spaces"
    Expect-Failure { Select-InstallDirectory } '*must not contain spaces*'
    $InstallDir = "$fixtureRoot\unrelated\sentinel"
    Expect-Failure { Select-InstallDirectory } '*is a file*'
    $InstallDir = "$fixtureRoot\install-link\new-child"
    New-Item -ItemType Junction -Path "$fixtureRoot\install-link" -Target "$fixtureRoot\unrelated" | Out-Null
    try { Expect-Failure { Select-InstallDirectory } '*Linked installation path*' }
    finally { [IO.Directory]::Delete("$fixtureRoot\install-link") }
    $Root = $fixtureRoot
    $Workspace = Join-Path $Root 'zephyrproject'
    $Cache = Join-Path $Root 'zephyr_installers'
    Write-Host '[PASS] Install-directory prompt, named selection and path validation work.'

    $missing = Join-Path $fixtureRoot 'missing-helper'
    New-Item -ItemType Directory -Path $missing -Force | Out-Null
    foreach ($wrapper in @('zephyr-easy-setup.bat', 'zephyr-pack-offline.bat', 'zephyr-offline-install.bat', 'zephyr-uninstall.bat')) {
        $destination = Join-Path $missing $wrapper
        Copy-Item -LiteralPath (Join-Path $projectRoot $wrapper) -Destination $destination
        $output = @(& cmd.exe /c $destination)
        Assert ($LASTEXITCODE -eq 1) 'Missing helper did not return exit 1.'
        Assert (($output -join "`n") -like '*Required helper script is missing*') 'Missing-helper guidance was not shown.'
        Assert (($output -join "`n") -notlike '*Windows PowerShell*') 'Missing helper launched PowerShell.'
    }
    Write-Host '[PASS] All launchers stop with guidance when the shared helper is missing.'
    Write-Host 'All isolated workflow checks passed.'
} finally {
    if (Test-Path -LiteralPath $junctionPath) { [IO.Directory]::Delete($junctionPath) }
    Remove-Local $fixtureRoot (Join-Path $projectRoot 'offline_bundle')
}
