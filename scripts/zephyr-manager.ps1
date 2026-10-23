[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateSet('Online', 'Pack', 'Offline', 'Uninstall')][string]$Mode,
    [string]$SourceWorkspace, [string]$SdkPath,
    [Parameter(Position = 1)][string]$InstallDir,
    [Parameter(Position = 0)][string]$BundlePath,
    [string]$Board, [string]$Qualifier, [string]$Toolchain, [string]$Revision,
    [ValidateSet('Ite', 'Full')][string]$BundleProfile = 'Ite',
    [switch]$CacheOnly, [switch]$CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DirectoryPath([string]$Path) {
    # Keep logical paths canonical and prefix-free for containment checks and
    # portable manifests. Extended paths suppress Win32 dot normalization.
    if ($Path.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) { $Path = '\\' + $Path.Substring(8) }
    elseif ($Path.StartsWith('\\?\')) { $Path = $Path.Substring(4) }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -eq [IO.Path]::GetPathRoot($full)) { return $full }
    return $full.TrimEnd('\')
}

function Get-LongPath([string]$Path) {
    # PS 5.1/.NET Framework enumeration needs the extended prefix even when
    # the directory is <260 chars: appending a child or wildcard can exceed it.
    $full = Get-DirectoryPath $Path
    if ($full.StartsWith('\\')) { return '\\?\UNC\' + $full.Substring(2) }
    return '\\?\' + $full
}

$PackageRoot = Get-DirectoryPath (Join-Path $PSScriptRoot '..')
$Root = $PackageRoot
$Workspace = Join-Path $Root 'zephyrproject'
$Cache = Join-Path $Root 'zephyr_installers'
$Tools = @(
    @{ Id = 'Python.Python.3.12'; Name = 'python'; Extension = '.exe'; Type = 'burn' },
    @{ Id = 'Git.Git'; Name = 'git'; Extension = '.exe'; Type = 'inno' },
    @{ Id = 'Kitware.CMake'; Name = 'cmake'; Extension = '.msi'; Type = 'wix' },
    @{ Id = '7zip.7zip'; Name = '7z'; Extension = '.exe'; Type = 'exe' },
    @{ Id = 'Ninja-build.Ninja'; Name = 'ninja'; Extension = '.zip'; Type = 'zip' },
    @{ Id = 'oss-winget.gperf'; Name = 'gperf'; Extension = '.zip'; Type = 'zip' },
    @{ Id = 'oss-winget.dtc'; Name = 'dtc'; Extension = '.zip'; Type = 'zip' }
)

function Set-ConsoleUtf8 {
    # Native UTF-8 output (including WinGet) must be decoded with UTF-8 in PS 5.1.
    $utf8 = New-Object Text.UTF8Encoding($false)
    [Console]::OutputEncoding = $utf8
    $script:OutputEncoding = $utf8
}

function Invoke-Checked([string]$Exe, [string[]]$Arguments) {
    & $Exe @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Exe failed (exit $LASTEXITCODE)." }
}

function Assert-Within([string]$Path, [string]$Parent) {
    $full = (Get-DirectoryPath $Path).TrimEnd('\')
    $base = (Get-DirectoryPath $Parent).TrimEnd('\')
    if (-not $full.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the expected directory: $full"
    }
    return $full
}

function Get-RelativeBundlePath([string]$Path, [string]$Parent) {
    $checked = Assert-Within $Path $Parent
    $prefix = (Get-DirectoryPath $Parent).TrimEnd('\') + '\'
    return $checked.Substring($prefix.Length)
}

function Get-ToolsDirectory {
    # Keep portable tools owned by this workspace when the base is a drive root.
    if ($Root -eq [IO.Path]::GetPathRoot($Root)) { return Join-Path $Workspace '.host-tools' }
    return Join-Path $Root 'tools'
}

function Assert-NoLinks([string]$Path, [switch]$ShowProgress) {
    $longPath = Get-LongPath $Path
    if (-not (Test-Path -LiteralPath $longPath)) { return }
    $item = Get-Item -LiteralPath $longPath -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked path is not supported: $Path" }
    if (-not $item.PSIsContainer) { return }
    # Enumerate with .NET instead of invoking PowerShell cmdlets for every directory.
    $pending = New-Object 'System.Collections.Generic.Stack[IO.DirectoryInfo]'
    $pending.Push((New-Object IO.DirectoryInfo($item.FullName)))
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $count = 0
    $nextUpdate = 0.0
    try {
        while ($pending.Count) {
            $directory = $pending.Pop()
            foreach ($child in $directory.GetFileSystemInfos()) {
                if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked path is not supported: $($child.FullName)" }
                if ($child -is [IO.DirectoryInfo]) { $pending.Push($child) }
                $count++
                if ($ShowProgress -and $timer.Elapsed.TotalSeconds -ge $nextUpdate) {
                    Write-PackProgress -Activity 'Check existing paths' -Status ("{0:N0} entries; {1:N0}s" -f $count, $timer.Elapsed.TotalSeconds)
                    $nextUpdate = $timer.Elapsed.TotalSeconds + 1
                }
            }
        }
    } finally { if ($ShowProgress) { Write-PackProgress -Completed } }
}

function Remove-Local([string]$Path, [string]$Parent) {
    $checked = Assert-Within $Path $Parent
    $longPath = Get-LongPath $checked
    if (Test-Path -LiteralPath $longPath) {
        Assert-NoLinks $checked
        Remove-Item -LiteralPath $longPath -Recurse -Force
    }
}

function Save-Json($Value, [string]$Path) {
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-Settings([string]$Source) {
    $path = Join-Path $Source '.zephyr-setup.json'
    $settings = [pscustomobject]@{ Board = 'it51xxx_evb'; Qualifier = 'it51xxx_evb/it51526aw'; Toolchain = 'riscv64-zephyr-elf' }
    if (Test-Path -LiteralPath $path) { $settings = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
    if ($Board) { $settings.Board = $Board; $settings.Qualifier = '' }
    if ($Qualifier) { $settings.Qualifier = $Qualifier }
    if ($Toolchain) { $settings.Toolchain = $Toolchain }
    return $settings
}

function Refresh-Path {
    $env:Path += ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    $known = @(
        "$env:ProgramFiles\CMake\bin", "$env:ProgramFiles\Git\cmd", "$env:ProgramFiles\7-Zip",
        "$env:LOCALAPPDATA\Programs\Git\cmd", "$env:LOCALAPPDATA\Programs\Python\Python312",
        "$env:ProgramFiles\Python312", "$env:LOCALAPPDATA\Microsoft\WinGet\Links", "$env:ProgramFiles\WinGet\Links"
    )
    foreach ($path in $known) { if (Test-Path -LiteralPath $path) { $env:Path = $path + ';' + $env:Path } }
    foreach ($parent in @("$env:LOCALAPPDATA\Microsoft\WinGet\Packages", "$env:ProgramFiles\WinGet\Packages", (Get-ToolsDirectory))) {
        if (Test-Path -LiteralPath $parent) {
            foreach ($exe in Get-ChildItem -LiteralPath $parent -Filter '*.exe' -Recurse -File) {
                if ($exe.BaseName -in @('ninja', 'dtc', 'gperf')) { $env:Path += ';' + $exe.DirectoryName }
            }
        }
    }
    $env:Path = (@($env:Path -split ';' | Where-Object { $_ } | Select-Object -Unique) -join ';')
}

function Get-Python312 {
    foreach ($python in @("$env:LOCALAPPDATA\Programs\Python\Python312\python.exe", "$env:ProgramFiles\Python312\python.exe")) {
        if (Test-Path -LiteralPath $python) {
            & $python -c "import sys,struct; sys.exit(0 if sys.version_info[:2] == (3,12) and struct.calcsize('P') == 8 else 1)" 2>$null
            if ($LASTEXITCODE -eq 0) { return $python }
        }
    }
    $launcher = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($launcher) {
        $path = & $launcher.Source -3.12 -c "import sys,struct; assert struct.calcsize('P') == 8; print(sys.executable)" 2>$null
        if ($LASTEXITCODE -eq 0) { return [string]$path }
    }
    throw 'Python 3.12 x64 is required. Check its installation.'
}

function Test-HostTools {
    $python = Get-Python312
    $env:Path = (Split-Path $python) + ';' + $env:Path
    foreach ($tool in $Tools) {
        $command = Get-Command ($tool.Name + '.exe') -ErrorAction SilentlyContinue
        if (-not $command) { throw "Missing host tool: $($tool.Name)" }
        $argument = '--version'
        if ($tool.Name -eq '7z') { $argument = 'i' }
        Invoke-Checked $command.Source @($argument)
    }
}

function Save-HostPaths {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $known = @(([Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + $userPath) -split ';' | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') })
    $updated = $userPath
    foreach ($tool in $Tools) {
        $directory = Split-Path (Get-Command ($tool.Name + '.exe') -ErrorAction Stop).Source
        if ($known -notcontains $directory) {
            $updated = ($updated + ';' + $directory).Trim(';')
            $known += $directory
        }
    }
    if ($updated -cne $userPath) { [Environment]::SetEnvironmentVariable('Path', $updated, 'User') }
}

function Find-Sdk([string]$Source, [string]$Explicit, [string]$TargetToolchain) {
    $candidates = @()
    if ($Explicit) { $candidates = @((Get-Item -LiteralPath $Explicit).FullName) }
    else {
        $candidates = @(Get-ChildItem -LiteralPath $Source -Directory -Filter 'zephyr-sdk-*' | Select-Object -ExpandProperty FullName)
        if ($candidates.Count -eq 0) {
            if ($env:ZEPHYR_SDK_INSTALL_DIR) { $candidates += $env:ZEPHYR_SDK_INSTALL_DIR }
            $stored = Get-Settings $Source
            if ($stored.PSObject.Properties.Name -contains 'SdkDirectory') {
                $storedSdk = $stored.SdkDirectory
                if (-not [IO.Path]::IsPathRooted($storedSdk)) { $storedSdk = Join-Path $Source $storedSdk }
                $candidates += $storedSdk
            }
            $registryPath = 'HKCU:\Software\Kitware\CMake\Packages\Zephyr-sdk'
            if (Test-Path -LiteralPath $registryPath) {
                $key = Get-Item -LiteralPath $registryPath
                foreach ($name in $key.GetValueNames()) {
                    $path = [string]$key.GetValue($name)
                    if ($path) { $candidates += $path; $candidates += Split-Path $path }
                }
            }
            $candidates += @(Get-ChildItem -LiteralPath $env:USERPROFILE -Directory -Filter 'zephyr-sdk-*' | Select-Object -ExpandProperty FullName)
        }
    }
    $valid = @($candidates | Select-Object -Unique | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'sdk_version') })
    $requiredVersionFile = Join-Path $Source 'zephyr\SDK_VERSION'
    if (-not $Explicit -and $valid.Count -gt 1 -and (Test-Path -LiteralPath $requiredVersionFile)) {
        $requiredVersion = (Get-Content -LiteralPath $requiredVersionFile -Raw).Trim()
        $matching = @($valid | Where-Object { (Get-Content -LiteralPath (Join-Path $_ 'sdk_version') -Raw).Trim() -eq $requiredVersion })
        if ($matching.Count -eq 1) { $valid = $matching }
    }
    if ($valid.Count -ne 1) { throw 'Specify exactly one installed SDK using -SdkPath; no complete SDK or multiple SDKs found.' }
    $sdk = [IO.Path]::GetFullPath($valid[0]).TrimEnd('\')
    $compilers = @(Get-ChildItem -LiteralPath $sdk -Filter ($TargetToolchain + '-gcc.exe') -File -Recurse)
    if ($compilers.Count -eq 0) { throw "SDK does not contain the $TargetToolchain compiler." }
    Invoke-Checked $compilers[0].FullName @('--version')
    if (-not (Test-Path -LiteralPath (Join-Path $sdk 'cmake\zephyr_sdk_export.cmake'))) { throw 'SDK CMake export script is missing.' }
    return $sdk
}

function Use-Workspace([string]$Source) {
    $env:Path = (Join-Path $Source '.venv\Scripts') + ';' + $env:Path
    $env:VIRTUAL_ENV = Join-Path $Source '.venv'
    $env:ZEPHYR_BASE = Join-Path $Source 'zephyr'
    $env:ZEPHYR_TOOLCHAIN_VARIANT = 'zephyr'
    Set-Location -LiteralPath $Source
}

function Complete-Setup($Settings, [string]$Sdk) {
    $python = Join-Path $Workspace '.venv\Scripts\python.exe'
    $env:ZEPHYR_SDK_INSTALL_DIR = $Sdk
    Invoke-Checked $python @('-m', 'pip', 'check')
    Invoke-Checked $python @('-m', 'west', 'zephyr-export')
    Invoke-Checked 'cmake.exe' @('-P', (Join-Path $Sdk 'cmake\zephyr_sdk_export.cmake'))
    $savedSdk = $Sdk
    if ($Sdk.StartsWith($Workspace + '\', [StringComparison]::OrdinalIgnoreCase)) { $savedSdk = $Sdk.Substring($Workspace.Length + 1) }
    $Settings | Add-Member -NotePropertyName SdkDirectory -NotePropertyValue $savedSdk -Force
    Save-Json $Settings (Join-Path $Workspace '.zephyr-setup.json')
    $sample = Join-Path $Workspace 'app\blinky'
    if (-not (Test-Path -LiteralPath $sample)) {
        New-Item -ItemType Directory -Path (Split-Path $sample) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $Workspace 'zephyr\samples\basic\blinky') -Destination $sample -Recurse
    }
    Assert-NoLinks $sample
    $build = Assert-Within (Join-Path $sample 'build') $sample
    & $python -m west build -p always -b $Settings.Board -d $build $sample | Out-Host
    if ($LASTEXITCODE -ne 0 -and $Settings.Qualifier) {
        & $python -m west build -p always -b $Settings.Qualifier -d $build $sample | Out-Host
    }
    if ($LASTEXITCODE -ne 0) { throw 'Sample build failed. Setup verification is incomplete.' }
    Write-Host "[SUCCESS] Setup and sample build completed: $build\zephyr"
}

function Select-InstallDirectory {
    $destination = $InstallDir
    if (-not $destination) {
        $default = $PackageRoot
        $answer = Read-Host "Installation directory [$default]"
        $destination = $answer.Trim().Trim('"')
        if (-not $destination) { $destination = $default }
    }
    $selected = Get-DirectoryPath $destination
    if ($selected -match '\s') { throw 'The installation directory must not contain spaces.' }
    if (Test-Path -LiteralPath $selected -PathType Leaf) { throw "Installation directory is a file: $selected" }
    # Inspect existing ancestors before writing through the selected path.
    $ancestor = $selected
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked installation path is not supported: $ancestor" }
        }
        $ancestor = Split-Path $ancestor -Parent
    }
    $script:Root = $selected
    $script:Workspace = Join-Path $selected 'zephyrproject'
    $script:Cache = Join-Path $selected 'zephyr_installers'
    Write-Host "Installation directory: $Root"
    Write-Host "Zephyr workspace:       $Workspace"
}

function Install-Online {
    Select-InstallDirectory
    if ($CheckOnly) { Write-Host '[OK] Installation path check complete; no installation performed.'; return }
    $settings = Get-Settings $Workspace
    Refresh-Path
    foreach ($tool in $Tools) {
        Write-Host "Installing/checking $($tool.Id)..."
        & winget.exe install --id $tool.Id -e --source winget --architecture x64 --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Host
        # winget also returns nonzero when an installed package has no upgrade.
        Refresh-Path
        if (-not (Get-Command ($tool.Name + '.exe') -ErrorAction SilentlyContinue)) { throw "Installation failed: $($tool.Id)" }
    }
    Test-HostTools
    Save-HostPaths
    Invoke-Checked 'git.exe' @('config', '--global', 'core.longpaths', 'true')
    $python = Get-Python312
    New-Item -ItemType Directory -Path $Workspace -Force | Out-Null
    $venvPython = Join-Path $Workspace '.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $venvPython)) { Invoke-Checked $python @('-m', 'venv', (Join-Path $Workspace '.venv')) }
    Invoke-Checked $venvPython @('-c', "import sys,struct; assert sys.version_info[:2] == (3,12) and struct.calcsize('P') == 8")
    Use-Workspace $Workspace
    Invoke-Checked $venvPython @('-m', 'pip', 'install', '--upgrade', 'pip', 'west')
    if (-not (Test-Path -LiteralPath (Join-Path $Workspace '.west'))) {
        $initArgs = @('-m', 'west', 'init', '-m', 'https://github.com/zephyrproject-rtos/zephyr')
        if ($Revision) { $initArgs += @('--mr', $Revision) }
        Invoke-Checked $venvPython ($initArgs + @('.'))
    } elseif ($Revision) { throw 'Revision applies to a new workspace only. Existing workspace was preserved.' }
    Invoke-Checked $venvPython @('-m', 'west', 'update')
    $packagesWrapper = Join-Path $Workspace 'zephyr\scripts\utils\west-packages-pip-install.cmd'
    if (Test-Path -LiteralPath $packagesWrapper) {
        Invoke-Checked 'cmd.exe' @('/c', $packagesWrapper)
    } elseif (Test-Path -LiteralPath (Join-Path $Workspace 'zephyr\scripts\west_commands\packages.py')) {
        Invoke-Checked $venvPython @('-m', 'west', 'packages', 'pip', '--install')
    } else {
        Invoke-Checked $venvPython @('-m', 'pip', 'install', '-r', (Join-Path $Workspace 'zephyr\scripts\requirements.txt'))
    }
    # -b is the base directory; -d would rename the SDK to the workspace itself.
    if ($SdkPath) { $sdk = Find-Sdk $Workspace $SdkPath $settings.Toolchain }
    else {
        Invoke-Checked $venvPython @('-m', 'west', 'sdk', 'install', '-b', $Workspace, '-t', $settings.Toolchain)
        $sdk = Find-Sdk $Workspace '' $settings.Toolchain
    }
    Complete-Setup $settings $sdk
}

function Get-PackConsoleWidth {
    # Use the visible width only to shorten progress messages; never rewrite console rows.
    if ($Host.Name -ne 'ConsoleHost' -or [Console]::IsOutputRedirected) { return 0 }
    try { return [Math]::Max(0, [Math]::Min([Console]::WindowWidth, [Console]::BufferWidth) - 1) }
    catch { return 0 }
}

function Get-PackProgressText([string]$Activity, [string]$Status, [int]$PercentComplete, [int]$Width) {
    $barWidth = if ($Width -ge 100) { 20 } else { 10 }
    $label = '--%'
    $bar = '.' * $barWidth
    if ($PercentComplete -ge 0) {
        $percent = [Math]::Min(100, $PercentComplete)
        $filled = [int][Math]::Floor($barWidth * $percent / 100)
        $bar = ('#' * $filled) + ('-' * ($barWidth - $filled))
        $label = "$percent%"
    }
    $line = ("$label [$bar] $Activity | $Status" -replace '[\x00-\x1f\x7f]', ' ')
    if ($Width -gt 0 -and $line.Length -gt $Width) { $line = $line.Substring(0, $Width) }
    return $line
}

function Write-PackProgress {
    param([string]$Activity, [string]$Status, [int]$PercentComplete = -1, [switch]$Completed)
    if (-not (Get-Variable -Name PackProgressState -Scope Script -ErrorAction SilentlyContinue)) {
        $script:PackProgressState = @{ Activity = ''; LastLog = [datetime]::MinValue; LastPercent = -1 }
    }
    $state = $script:PackProgressState
    if ($Completed) {
        $state.Activity = ''
        $state.LastPercent = -1
        return
    }
    $now = [datetime]::UtcNow
    $finished = $PercentComplete -ge 100 -and $state.LastPercent -lt 100
    if ($state.Activity -ne $Activity -or ($now - $state.LastLog).TotalSeconds -ge 10 -or $finished) {
        # Complete log lines survive terminal reflow and cannot overwrite native output.
        $line = Get-PackProgressText $Activity $Status $PercentComplete (Get-PackConsoleWidth)
        Write-Host $line
        $state.LastLog = $now
        $state.LastPercent = $PercentComplete
    }
    $state.Activity = $Activity
}

function Read-CopyCancellation {
    try {
        if (-not [Console]::IsInputRedirected) {
            while ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.KeyChar -eq [char]3 -or ($key.Key -eq [ConsoleKey]::C -and ($key.Modifiers -band [ConsoleModifiers]::Control))) {
                    throw (New-Object OperationCanceledException('Packaging cancelled by Ctrl+C.'))
                }
            }
        }
    } catch [InvalidOperationException] { }
}

function Measure-CopySource([string]$Source, [string[]]$Excluded) {
    $longSource = Get-LongPath $Source
    if (-not (Test-Path -LiteralPath $longSource -PathType Container)) { throw "Missing copy source directory: $Source" }
    $stack = New-Object 'System.Collections.Generic.Stack[IO.DirectoryInfo]'
    $stack.Push((New-Object IO.DirectoryInfo($longSource)))
    $excludedPaths = @($Excluded | ForEach-Object { (Get-LongPath $_).TrimEnd('\') })
    $bytes = [long]0
    $count = 0
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $nextUpdate = 0.0
    try {
        while ($stack.Count) {
            $directory = $stack.Pop()
            if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked path is not supported: $($directory.FullName)" }
            foreach ($item in $directory.GetFileSystemInfos()) {
                # Excluded directories are never copied. Do not descend into
                # historical build trees or follow links inside omitted content.
                if ($excludedPaths -contains $item.FullName.TrimEnd('\')) { continue }
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked path is not supported: $($item.FullName)" }
                if ($item -is [IO.DirectoryInfo]) {
                    $stack.Push($item)
                } else { $bytes += $item.Length; $count++ }
            }
            if ($timer.Elapsed.TotalSeconds -ge $nextUpdate) {
                Read-CopyCancellation
                Write-PackProgress -Activity 'Scanning copy source' -Status ("{0:N0} files; {1:N1} MiB; {2:N0}s" -f $count, ($bytes / 1MB), $timer.Elapsed.TotalSeconds)
                $nextUpdate = $timer.Elapsed.TotalSeconds + 0.5
            }
        }
        return [pscustomobject]@{ Bytes = $bytes; Files = $count }
    } finally { Write-PackProgress -Completed }
}

function Copy-Tree([string]$Source, [string]$Destination, [string[]]$Excluded = @()) {
    Write-Host "[COPY] $Source -> $Destination"
    $size = Measure-CopySource $Source $Excluded
    $copyArgs = @($Source, $Destination, '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    if ($Excluded.Count) { $copyArgs += @('/XD') + $Excluded }
    $process = New-Object Diagnostics.Process
    $process.StartInfo.FileName = (Get-Command 'robocopy.exe' -ErrorAction Stop).Source
    # Windows command-line quoting: double trailing slashes inside a quoted argument.
    $process.StartInfo.Arguments = ($copyArgs | ForEach-Object { '"' + ($_ -replace '(\\+)$', '$1$1') + '"' }) -join ' '
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.StandardOutputEncoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    $process.StartInfo.StandardErrorEncoding = $process.StartInfo.StandardOutputEncoding
    $started = $false
    $controlInputChanged = $false
    $originalControlInput = $false
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not [Console]::IsInputRedirected) {
            $originalControlInput = [Console]::TreatControlCAsInput
            [Console]::TreatControlCAsInput = $true
            $controlInputChanged = $true
        }
        Write-PackProgress -Activity 'Copying files' -Status ("Starting: {0:N0} files, {1:N1} MiB" -f $size.Files, ($size.Bytes / 1MB)) -PercentComplete 0
        $started = $process.Start()
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        while (-not $process.WaitForExit(1000)) {
            Read-CopyCancellation
            # Use the owned process's I/O counters; avoid rescanning a large destination every second.
            $io = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $process.Id) -ErrorAction SilentlyContinue
            $percent = -1
            $status = "Copying; elapsed $([int]$timer.Elapsed.TotalSeconds)s"
            if ($io -and $size.Bytes -gt 0) {
                $written = [double]$io.WriteTransferCount
                $percent = [int][Math]::Min(99, [Math]::Floor(100 * $written / $size.Bytes))
                $status = "{0:N1}/{1:N1} MiB; {2:N0}s (estimated)" -f ($written / 1MB), ($size.Bytes / 1MB), $timer.Elapsed.TotalSeconds
            }
            Write-PackProgress -Activity 'Copying files' -Status $status -PercentComplete $percent
        }
        $process.WaitForExit()
        Write-PackProgress -Completed
        if ($output.Result.Trim()) { Write-Host $output.Result.Trim() }
        if ($errors.Result.Trim()) { Write-Host $errors.Result.Trim() }
        if ($process.ExitCode -lt 0 -or $process.ExitCode -ge 8) { throw "Copy failed: $Source (robocopy exit $($process.ExitCode))" }
        Write-Host ("[COPY] Completed: {0:N0} files, {1:N1} MiB, {2:N0}s" -f $size.Files, ($size.Bytes / 1MB), $timer.Elapsed.TotalSeconds)
    } finally {
        if ($started -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
        if ($controlInputChanged) { [Console]::TreatControlCAsInput = $originalControlInput }
        Write-PackProgress -Completed
    }
}

function Invoke-PackArchive([string]$Exe, [string[]]$Arguments, [string]$Activity) {
    $process = New-Object Diagnostics.Process
    $process.StartInfo.FileName = $Exe
    # 7-Zip includes filenames in its progress stream even at log level zero.
    # Read that stream privately and log only its percentage and elapsed time.
    $nativeArgs = $Arguments + @('-bb0', '-bso0', '-bsp1', '-bse2', '-sccUTF-8')
    $process.StartInfo.Arguments = ($nativeArgs | ForEach-Object { '"' + ($_ -replace '(\\+)$', '$1$1') + '"' }) -join ' '
    $process.StartInfo.WorkingDirectory = (Get-Location).ProviderPath
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $process.StartInfo.StandardErrorEncoding = $process.StartInfo.StandardOutputEncoding
    $started = $false
    $controlInputChanged = $false
    $originalControlInput = $false
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not [Console]::IsInputRedirected) {
            $originalControlInput = [Console]::TreatControlCAsInput
            [Console]::TreatControlCAsInput = $true
            $controlInputChanged = $true
        }
        Write-PackProgress -Activity $Activity -Status 'Starting' -PercentComplete -1
        $started = $process.Start()
        $errors = $process.StandardError.ReadToEndAsync()
        # Read the pipe directly: StreamReader.ReadAsync can wait to fill its whole buffer.
        $buffer = New-Object byte[] 4096
        $read = $process.StandardOutput.BaseStream.ReadAsync($buffer, 0, $buffer.Length)
        $tail = ''
        $percent = -1
        $lastUpdate = -1.0
        while ($true) {
            Read-CopyCancellation
            if ($read.IsCompleted) {
                $count = $read.GetAwaiter().GetResult()
                if ($count -eq 0) { break }
                $text = $tail + [Text.Encoding]::UTF8.GetString($buffer, 0, $count)
                $matches = [regex]::Matches($text, '(?:^|[\r\n])\s*(\d{1,3})%')
                if ($matches.Count) { $percent = [Math]::Min(99, [int]$matches[$matches.Count - 1].Groups[1].Value) }
                # Keep enough context for a percentage split across reads, without retaining filenames.
                $tail = $text.Substring([Math]::Max(0, $text.Length - 16))
                $read = $process.StandardOutput.BaseStream.ReadAsync($buffer, 0, $buffer.Length)
            }
            if ($timer.Elapsed.TotalSeconds - $lastUpdate -ge 0.5) {
                Write-PackProgress -Activity $Activity -Status ("Elapsed {0:N0}s" -f $timer.Elapsed.TotalSeconds) -PercentComplete $percent
                $lastUpdate = $timer.Elapsed.TotalSeconds
            }
            Start-Sleep -Milliseconds 100
        }
        while (-not $process.WaitForExit(100)) { Read-CopyCancellation }
        $diagnostics = $errors.GetAwaiter().GetResult().Trim()
        if ($process.ExitCode -eq 0) {
            Write-PackProgress -Activity $Activity -Status ("Completed in {0:N0}s" -f $timer.Elapsed.TotalSeconds) -PercentComplete 100
        }
        Write-PackProgress -Completed
        if ($diagnostics) { Write-Host $diagnostics }
        if ($process.ExitCode -ne 0) { throw "$Exe failed (exit $($process.ExitCode))." }
    } finally {
        if ($started -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
        if ($controlInputChanged) { [Console]::TreatControlCAsInput = $originalControlInput }
        Write-PackProgress -Completed
    }
}

function Set-PackStage([int]$Step, [string]$Status) {
    Write-PackProgress -Completed
    $percent = [int](100 * ($Step - 1) / 9)
    Write-Host "[PACK $Step/9] $percent% | $Status"
}

function Get-BundleFileHashes([string]$Bundle) {
    Write-PackProgress -Activity 'Computing SHA-256' -Status 'Collecting bundle files'
    try {
        $inventory = @(Get-ChildItem -LiteralPath (Get-LongPath $Bundle) -Recurse -Force -File)
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $nextUpdate = 0.0
        for ($i = 0; $i -lt $inventory.Count; $i++) {
            $file = $inventory[$i]
            if ($timer.Elapsed.TotalSeconds -ge $nextUpdate -or $file.Length -ge 100MB) {
                Read-CopyCancellation
                Write-PackProgress -Activity 'Computing SHA-256' -Status ("{0:N0} / {1:N0} files; {2:N0}s" -f $i, $inventory.Count, $timer.Elapsed.TotalSeconds) -PercentComplete ([int][Math]::Floor(100 * $i / $inventory.Count))
                $nextUpdate = $timer.Elapsed.TotalSeconds + 0.5
            }
            @{ Path = (Get-RelativeBundlePath $file.FullName $Bundle); Sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash }
        }
    } finally { Write-PackProgress -Completed }
}

function Get-Installer([string]$Directory, [string]$Extension) {
    $files = @(Get-ChildItem -LiteralPath $Directory -File -Recurse | Where-Object { $_.Extension -eq $Extension })
    if ($files.Count -ne 1) { throw "Expected one $Extension installer in $Directory; found $($files.Count)." }
    return $files[0]
}

function Get-HostInstaller($Tool, [string]$Directory, [switch]$CacheOnly) {
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $existing = @(Get-ChildItem -LiteralPath $Directory -File -Recurse | Where-Object { $_.Extension -eq $Tool.Extension })
    if ($existing.Count -eq 0) {
        if ($CacheOnly) { throw "Missing cached installer: $($Tool.Id). Run packaging with network once." }
        # Match the offline installer's format; EXE may be classified as burn/inno/exe, MSI as wix.
        $downloadArgs = @('download', '--id', $Tool.Id, '-e', '--source', 'winget', '--architecture', 'x64', '--download-directory', $Directory, '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
        if ($Tool.Type) { $downloadArgs += @('--installer-type', $Tool.Type) }
        Invoke-Checked 'winget.exe' $downloadArgs
    }
    return Get-Installer $Directory $Tool.Extension
}

function Save-OfflineBootstrap([string]$Installer, [string]$Directory, [switch]$Flat) {
    if ($Flat) {
        # Do not traverse an unrelated working tree just to publish two files.
        if ((Test-Path -LiteralPath $Directory) -and ((Get-Item -LiteralPath $Directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Linked path is not supported: $Directory" }
    } else { Assert-NoLinks $Directory }
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $destination = Join-Path $Directory '7zip-x64.exe'
    Assert-NoLinks $destination
    Copy-Item -LiteralPath $Installer -Destination $destination -Force
    $metadataName = if ($Flat) { '7zip-x64.json' } else { 'bootstrap-manifest.json' }
    Assert-NoLinks (Join-Path $Directory $metadataName)
    Save-Json @{ Format = 1; Installer = '7zip-x64.exe'; Sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash } (Join-Path $Directory $metadataName)
}

function Get-OfflineBootstrapInstaller([string]$Archive) {
    # The launcher directory carries the exact installer selected during packaging.
    foreach ($localDirectory in @($PackageRoot, (Split-Path $Archive -Parent)) | Select-Object -Unique) {
        $localInstaller = Join-Path $localDirectory '7zip-x64.exe'
        $localMetadata = Join-Path $localDirectory '7zip-x64.json'
        if (Test-Path -LiteralPath $localInstaller -PathType Leaf) {
            Assert-NoLinks $localInstaller
            Assert-NoLinks $localMetadata
            if (-not (Test-Path -LiteralPath $localMetadata -PathType Leaf)) { throw "Missing 7-Zip installer metadata: $localMetadata" }
            $metadata = Get-Content -LiteralPath $localMetadata -Raw | ConvertFrom-Json
            if ($metadata.Format -ne 1 -or $metadata.Installer -ne '7zip-x64.exe') { throw 'Unsupported 7-Zip bootstrap metadata.' }
            if ((Get-FileHash -LiteralPath $localInstaller -Algorithm SHA256).Hash -ne $metadata.Sha256) { throw '7-Zip bootstrap installer checksum failed.' }
            return $localInstaller
        }
    }
    $directory = Join-Path (Split-Path $Archive -Parent) 'zephyr-offline-bootstrap'
    Assert-NoLinks $directory
    $metadataPath = Join-Path $directory 'bootstrap-manifest.json'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw "7-Zip is not installed. Copy 7zip-x64.exe and 7zip-x64.json to $PackageRoot, or copy zephyr-offline-bootstrap beside the archive: $directory"
    }
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    if ($metadata.Format -ne 1 -or $metadata.Installer -ne '7zip-x64.exe') { throw 'Unsupported 7-Zip bootstrap metadata.' }
    $installer = Assert-Within (Join-Path $directory $metadata.Installer) $directory
    if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -ne $metadata.Sha256) { throw '7-Zip bootstrap installer checksum failed.' }
    return $installer
}

function Use-OfflineSevenZip([string]$Installer, [string]$Archive) {
    Refresh-Path
    $command = Get-Command '7z.exe' -ErrorAction SilentlyContinue
    if (-not $command) {
        if (-not $Installer) { $Installer = Get-OfflineBootstrapInstaller $Archive }
        if ($Archive -and [IO.Path]::GetExtension($Archive) -ieq '.zip') { Assert-ArchiveInstaller $Archive '' $Installer }
        Write-Host '[OFFLINE] Installing 7-Zip before extraction and other packages...'
        Start-Installer $Installer '/S'
        Refresh-Path
        $command = Get-Command '7z.exe' -ErrorAction SilentlyContinue
        if (-not $command) { throw '7-Zip installation completed, but 7z.exe was not found.' }
    }
    # The info command can print format/codec lists even with -bso0.
    & $command.Source i | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "$($command.Source) failed (exit $LASTEXITCODE)." }
    if ($Archive -and $Installer) { Assert-ArchiveInstaller $Archive $command.Source $Installer }
    return $command.Source
}

function Get-BundleManifestJson([string]$Archive, [string]$SevenZip) {
    if ([IO.Path]::GetExtension($Archive) -ieq '.zip') {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
        try {
            $entry = $zip.GetEntry('bundle-manifest.json')
            if (-not $entry) { throw 'Archive does not contain bundle-manifest.json at its root.' }
            $reader = New-Object IO.StreamReader($entry.Open())
            try { $json = $reader.ReadToEnd() } finally { $reader.Dispose() }
        } finally { $zip.Dispose() }
    } else {
        $json = @(& $SevenZip e -so -spd -sccUTF-8 -- $Archive 'bundle-manifest.json') -join "`n"
        if ($LASTEXITCODE -ne 0) { throw 'Cannot read archive manifest.' }
    }
    return $json
}

function Save-BundleManifest([string]$Json, [string]$Directory) {
    $path = Assert-Within (Join-Path $Directory 'bundle-manifest.json') $Directory
    Assert-NoLinks $path
    [IO.File]::WriteAllText($path, $Json, (New-Object Text.UTF8Encoding($true)))
}

function Assert-ArchiveInstaller([string]$Archive, [string]$SevenZip, [string]$Installer) {
    $json = Get-BundleManifestJson $Archive $SevenZip
    $manifest = $json | ConvertFrom-Json
    if ($manifest.Format -ne 1 -or $manifest.Architecture -ne 'x64') { throw 'Unsupported bundle format/platform.' }
    $entry = @($manifest.HostTools | Where-Object { $_.Id -eq '7zip.7zip' })
    if ($entry.Count -ne 1) { throw 'Bundle is missing installer metadata: 7zip.7zip' }
    if ((Get-FileHash -LiteralPath $Installer -Algorithm SHA256).Hash -ne $entry[0].Sha256) {
        throw '7-Zip installer does not match the version bundled in the archive. Copy the installer and metadata from the same packaging run.'
    }
}

function Assert-BundleArchive([string]$Archive, [string]$SevenZip, [switch]$SkipDestinationChecks) {
    # Inspect archive entries without writing any archive contents.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = $null
    try {
        if ([IO.Path]::GetExtension($Archive) -ieq '.7z') {
            $listing = @(& $SevenZip l -slt -ba -sccUTF-8 -- $Archive)
            if ($LASTEXITCODE -ne 0) { throw 'Cannot list bundle archive.' }
            $entries = New-Object 'System.Collections.Generic.List[object]'
            $record = $null
            foreach ($line in $listing) {
                if ($line.StartsWith('Path = ')) {
                    $record = [pscustomobject]@{ FullName = $line.Substring(7); ExternalAttributes = 0 }
                    $entries.Add($record)
                } elseif ($record -and ($line -match '^(Symbolic Link|Hard Link|Reparse) = ' -or $line -match '^Attributes = .*\bl[rwx-]')) {
                    throw "Linked archive entry is not supported: $($record.FullName)"
                }
            }
        } else {
            $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
            $entries = $zip.Entries
        }
        $hasManifest = $false
        foreach ($entry in $entries) {
            $name = $entry.FullName.Replace('/', '\')
            if ([IO.Path]::IsPathRooted($name) -or $name.Contains(':') -or @($name -split '\\') -contains '..') {
                throw "Unsupported bundle archive path: $name"
            }
            $path = Assert-Within ([IO.Path]::Combine($Root, $name)) $Root
            $isManifest = $path -ieq (Join-Path $Root 'bundle-manifest.json')
            $isWorkspace = $path -ieq $Workspace -or $path.StartsWith($Workspace + '\', [StringComparison]::OrdinalIgnoreCase)
            $isCache = $path -ieq $Cache -or $path.StartsWith($Cache + '\', [StringComparison]::OrdinalIgnoreCase)
            if (-not ($isManifest -or $isWorkspace -or $isCache)) { throw "Unexpected bundle archive path: $name" }
            if ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000 -or ($entry.ExternalAttributes -band 0x400)) {
                throw "Linked archive entry is not supported: $name"
            }
            if ($isManifest -and -not $name.EndsWith('\')) { $hasManifest = $true }
        }
        if (-not $hasManifest) { throw 'Archive does not contain bundle-manifest.json at its root.' }
    } finally { if ($zip) { $zip.Dispose() } }
    if (-not $SkipDestinationChecks) {
        Assert-NoLinks $Workspace -ShowProgress
        Assert-NoLinks $Cache -ShowProgress
        Assert-NoLinks (Join-Path $Root 'bundle-manifest.json')
    }
}

function Expand-OfflineBundle {
    $script:OfflineValidatedManifest = $null
    $archive = $BundlePath
    if (-not $archive) {
        # An extracted bundle takes precedence, so reruns do not overwrite development files.
        if (Test-Path -LiteralPath (Join-Path $Root 'bundle-manifest.json') -PathType Leaf) { return }
        foreach ($candidate in @((Join-Path $Root 'zephyr-offline-bundle.7z'), (Join-Path $PackageRoot 'zephyr-offline-bundle.7z'), (Join-Path $Root 'zephyr-offline-bundle.zip'), (Join-Path $PackageRoot 'zephyr-offline-bundle.zip'))) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $archive = $candidate; break }
        }
        if (-not $archive) { throw "Missing $(Join-Path $Root 'bundle-manifest.json'). Copy zephyr-offline-bundle.7z and its 7-Zip installer, or specify -BundlePath." }
    }
    $archive = Get-DirectoryPath $archive
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw "Missing bundle archive: $archive" }
    if ([IO.Path]::GetExtension($archive) -notin @('.zip', '.7z')) { throw 'Bundle must be a .7z or .zip archive.' }
    if ($CheckOnly) {
        if (Test-Path -LiteralPath (Join-Path $Root 'bundle-manifest.json') -PathType Leaf) { return }
        throw '-CheckOnly requires an extracted bundle; no tools were installed and no archive was extracted. Run offline installation without -CheckOnly first.'
    }
    # ZIP can be inspected before installation; 7z needs the bootstrapped executable.
    Write-Host '[OFFLINE] Checking existing destination paths...'
    if ([IO.Path]::GetExtension($archive) -ieq '.zip') { Assert-BundleArchive $archive }
    else {
        Assert-NoLinks $Workspace -ShowProgress
        Assert-NoLinks $Cache -ShowProgress
        Assert-NoLinks (Join-Path $Root 'bundle-manifest.json')
    }
    Write-Host '[OFFLINE] Finding or installing 7-Zip...'
    $sevenZip = Use-OfflineSevenZip '' $archive
    Write-Host '[OFFLINE] Reading bundle manifest from archive...'
    $manifestJson = Get-BundleManifestJson $archive $sevenZip
    if ((Test-Path -LiteralPath (Join-Path $Root 'bundle-manifest.json') -PathType Leaf) -or
        (Test-Path -LiteralPath (Join-Path $Workspace '.west\config') -PathType Leaf)) {
        try {
            Write-Host '[OFFLINE] Checking whether the destination already contains the complete bundle...'
            $currentManifest = $manifestJson | ConvertFrom-Json
            $script:OfflineValidatedManifest = Test-Bundle -Manifest $currentManifest
        } catch {
            # A partial extraction can be resumed; changed files must remain untouched.
            if ($_.Exception.Message -notlike 'Missing bundle file:*' -and $_.Exception.Message -notlike 'Incomplete bundle:*' -and $_.Exception.Message -notlike '*SDK version file is missing*' -and $_.Exception.Message -notlike '*contains no Python wheels*') { throw }
        }
        if ($script:OfflineValidatedManifest) {
            Save-BundleManifest $manifestJson $Root
            Write-Host '[OFFLINE] Destination already contains this complete bundle; skipping extraction.'
            return
        }
    }
    if ([IO.Path]::GetExtension($archive) -ieq '.7z') {
        Write-Host '[OFFLINE] Checking archive paths before extraction...'
        Assert-BundleArchive $archive $sevenZip -SkipDestinationChecks
    }
    Write-Host "[OFFLINE] Extracting $archive to $Root (existing files are preserved)..."
    # PowerShell 5.1 rejects New-Item on an existing drive root such as D:\.
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
    }
    Invoke-PackArchive $sevenZip @('x', '-aos', ('-o' + $Root), $archive) 'Extract offline archive'
    # Existing sources/apps stay protected by -aos; metadata must describe this archive.
    Save-BundleManifest $manifestJson $Root
}

function ConvertTo-OfflineRequirements([string]$Python, [string[]]$Frozen) {
    foreach ($line in $Frozen) {
        if ($line -match '^[A-Za-z0-9_.-]+==[^\s]+$') { $line; continue }
        if ($line -match '^([A-Za-z0-9_.-]+)\s+@\s+https?://\S+$') {
            $name = $Matches[1]
            # Freeze preserves remote origins; offline installs need the installed version.
            $version = & $Python -c 'import importlib.metadata as m, sys; print(m.version(sys.argv[1]))' $name
            if ($LASTEXITCODE -ne 0 -or @($version).Count -ne 1 -or $version -notmatch '^[A-Za-z0-9_.+!-]+$') {
                throw "Cannot determine installed version of remote dependency: $name"
            }
            "$name==$version"
            continue
        }
        throw "Cannot reproduce local/editable or unsupported dependency offline: $line"
    }
}

function Save-PythonWheelCache([string]$Python, [string]$Directory, [switch]$CacheOnly) {
    $wheels = Join-Path $Directory 'wheels'
    New-Item -ItemType Directory -Path $wheels -Force | Out-Null
    $frozen = @(& $Python -m pip freeze --all)
    if ($LASTEXITCODE -ne 0) { throw 'pip freeze failed.' }
    $pinned = @(ConvertTo-OfflineRequirements $Python $frozen)
    if (-not ($pinned -match '^west==')) { throw 'west is not installed in the source environment.' }
    $requirements = Join-Path $Directory 'requirements-frozen.txt'
    $sourceRequirements = Join-Path $Directory 'requirements-source.txt'
    $pinned | Set-Content -LiteralPath $requirements -Encoding ASCII
    $frozen | Set-Content -LiteralPath $sourceRequirements -Encoding UTF8
    if (-not $CacheOnly) {
        # Build from the original URL (including its hash), never a same-version index substitute.
        # Source-only packages also become wheels before the offline validation.
        Invoke-Checked $Python @('-m', 'pip', 'wheel', '--no-deps', '--find-links', $wheels, '--wheel-dir', $wheels, '-r', $sourceRequirements)
    }
    # Cache-only mode must never pass remote URLs to pip: --no-index alone does not block them.
    Invoke-Checked $Python @('-m', 'pip', '--isolated', 'download', '--no-index', '--only-binary=:all:', '--find-links', $wheels, '-d', $wheels, '-r', $requirements)
    return $requirements
}

function Copy-OfflineRequirements([string]$Path, [string]$Source, [string]$Destination, [string[]]$Frozen, [string[]]$Pinned) {
    # Mirror included requirements into staging; never edit the source checkout.
    $relative = Get-RelativeBundlePath $Path $Source
    $target = Assert-Within (Join-Path $Destination $relative) $Destination
    if (Test-Path -LiteralPath $target) { return $target }
    New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
    $includes = @()
    $lines = @(foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*(-r|--requirement|-c|--constraint)\s+(.+?)\s*$') {
            $option = $Matches[1]
            $include = $Matches[2].Trim('"', "'")
            if (-not [IO.Path]::IsPathRooted($include)) { $include = Join-Path (Split-Path $Path) $include }
            $include = [IO.Path]::GetFullPath($include)
            $includeRelative = Get-RelativeBundlePath $include $Source
            $includes += $include
            $option + ' "' + (Join-Path $Destination $includeRelative) + '"'
        } elseif ($line -match '^\s*([A-Za-z0-9_.-]+)(\[[^\]]+\])?\s+@\s+(https?://[^\s;]+)(.*)$') {
            $name, $extras, $url, $suffix = $Matches[1], $Matches[2], $Matches[3], $Matches[4]
            $origin = @($Frozen | Where-Object { $_ -match ('^' + [regex]::Escape($name) + '\s+@\s+') })
            $pin = @($Pinned | Where-Object { $_ -match ('^' + [regex]::Escape($name) + '==') })
            $installedPin = @($Frozen | Where-Object { $_ -match ('^' + [regex]::Escape($name) + '==') })
            $matchesOrigin = $origin.Count -eq 1 -and ($origin[0] -replace '^.*?\s+@\s+', '' -replace '#.*$', '') -ceq ($url -replace '#.*$', '')
            # Index installations have no recorded archive origin. Reproduce the
            # source freeze pin instead of claiming it came from the upstream URL.
            $matchesPin = $origin.Count -eq 0 -and $installedPin.Count -eq 1 -and $pin.Count -eq 1 -and $installedPin[0] -ceq $pin[0]
            if ($pin.Count -ne 1 -or (-not $matchesOrigin -and -not $matchesPin)) {
                throw "Requirement URL does not match the installed source: $line"
            }
            if ($suffix -match '--hash|\\\s*$') { throw "Unsupported hash/continuation on remote requirement: $line" }
            if ($matchesPin) { Write-Host "[PACK] Offline requirements use installed $($pin[0]); the source environment has no recorded URL origin." }
            $name + $extras + '==' + ($pin[0] -split '==', 2)[1] + $suffix
        } else { $line }
    })
    $lines | Set-Content -LiteralPath $target -Encoding UTF8
    foreach ($include in $includes) { $null = Copy-OfflineRequirements $include $Source $Destination $Frozen $Pinned }
    return $target
}

function Remove-PackInputs($Files, [string]$SevenZipHash, [switch]$CheckOnly) {
    # Only remove cache files that were included unchanged in the published archive.
    $inventory = @{}
    foreach ($entry in $Files) {
        if ($entry.Path.StartsWith('zephyr_installers\', [StringComparison]::OrdinalIgnoreCase)) { $inventory[$entry.Path] = $entry.Sha256 }
    }
    $null = Assert-Within $Cache $Root
    Assert-NoLinks $Cache
    if (Test-Path -LiteralPath $Cache) {
        foreach ($file in Get-ChildItem -LiteralPath $Cache -File -Recurse -Force) {
            $relative = Get-RelativeBundlePath $file.FullName $Root
            if (-not $inventory.ContainsKey($relative) -or (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne $inventory[$relative]) {
                throw "Cache changed after packaging; preserved for review: $($file.FullName)"
            }
        }
    }
    $bootstrap = Join-Path $Root 'zephyr-offline-bootstrap'
    $null = Assert-Within $bootstrap $Root
    Assert-NoLinks $bootstrap
    if (Test-Path -LiteralPath $bootstrap) {
        $children = @(Get-ChildItem -LiteralPath $bootstrap -Force)
        if (@($children | Where-Object { $_.PSIsContainer -or $_.Name -notin @('7zip-x64.exe', 'bootstrap-manifest.json') }).Count) {
            throw "Bootstrap contains unrelated files; preserved for review: $bootstrap"
        }
        $installer = Join-Path $bootstrap '7zip-x64.exe'
        if ((Test-Path -LiteralPath $installer) -and (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -ne $SevenZipHash) {
            throw "Bootstrap installer differs from this archive; preserved for review: $bootstrap"
        }
    }
    if ($CheckOnly) { Write-Host '[OK] Packaging inputs match the published archive and can be removed.'; return }
    foreach ($directory in @($Cache, $bootstrap)) {
        if (Test-Path -LiteralPath $directory) {
            Write-Host "[CLEANUP] Removing published packaging inputs: $directory"
            Remove-Local $directory $Root
        }
    }
}

function New-Bundle {
    Set-PackStage 1 'Verify source workspace and SDK'
    if (-not $SourceWorkspace) { $SourceWorkspace = $Workspace }
    $source = (Resolve-Path -LiteralPath $SourceWorkspace).Path.TrimEnd('\')
    if ($source -match '\s') { throw 'The source workspace path must not contain spaces.' }
    if (($Root.TrimEnd('\') + '\').StartsWith($source + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Source workspace cannot contain the packaging project.' }
    $settings = Get-Settings $source
    $python = Join-Path $source '.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $python)) { throw "Missing source virtual environment: $python" }
    if (-not (Test-Path -LiteralPath (Join-Path $source '.west\config'))) { throw 'Source is not an initialized west workspace.' }
    Refresh-Path
    Use-Workspace $source
    Invoke-Checked $python @('-c', "import sys,struct; assert sys.version_info[:2] == (3,12) and struct.calcsize('P') == 8")
    Invoke-Checked $python @('-m', 'pip', 'check')
    Invoke-Checked $python @('-m', 'west', 'list')
    # Verify every repository retained by the selected profile.
    $projectPaths = @(& $python -m west list -f '{abspath}')
    if ($LASTEXITCODE -ne 0) { throw 'Cannot list west project paths.' }
    $itePlan = $null
    if ($BundleProfile -eq 'Ite') {
        if ($settings.Board -notmatch '^it(51|8)' -or $settings.Toolchain -ne 'riscv64-zephyr-elf') {
            throw 'The Ite bundle profile requires an ITE RISC-V target. Use -BundleProfile Full for other platforms.'
        }
        $profileScript = Join-Path $PSScriptRoot 'ite-bundle.py'
        $planJson = @(& $python $profileScript --source $source --toolchain $settings.Toolchain) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw 'Cannot plan the ITE bundle profile.' }
        $itePlan = $planJson | ConvertFrom-Json
        $projectPaths = @($itePlan.ProjectPaths)
        Write-Host ("[PACK] ITE platforms and {0} shared projects; other platform repositories are excluded." -f $itePlan.Projects.Count)
    }
    foreach ($projectPath in $projectPaths) {
        $null = Assert-Within $projectPath $source
        $gitPath = Join-Path $projectPath '.git'
        if (-not (Test-Path -LiteralPath $gitPath -PathType Container)) { throw "Missing repository or nonportable Git worktree: $projectPath. Use standalone clones and run west update first." }
        if (Test-Path -LiteralPath (Join-Path $gitPath 'objects\info\alternates')) { throw "External Git objects cannot be bundled: $projectPath" }
    }
    $sdk = Find-Sdk $source $SdkPath $settings.Toolchain
    $sevenZip = (Get-Command '7z.exe' -ErrorAction Stop).Source
    $wheels = Join-Path $Cache 'wheels'
    Set-PackStage 2 'Prepare Python wheels'
    $requirements = Save-PythonWheelCache $python $Cache -CacheOnly:$CacheOnly
    Set-PackStage 3 'Prepare host tool installers'
    $hostEntries = @()
    foreach ($tool in $Tools) {
        $directory = Join-Path $Cache ('tools\' + $tool.Id)
        $installer = Get-HostInstaller $tool $directory -CacheOnly:$CacheOnly
        $hostEntries += @{ Id = $tool.Id; Name = $tool.Name; Path = (Get-RelativeBundlePath $installer.FullName $Root); Sha256 = (Get-FileHash -LiteralPath $installer.FullName -Algorithm SHA256).Hash }
    }
    # A clean venv proves wheel closure without contacting PyPI.
    $stage = Join-Path $Root ('offline_bundle\' + [guid]::NewGuid().ToString('N'))
    $stageParent = Split-Path $stage -Parent
    $stageParentExisted = Test-Path -LiteralPath $stageParent
    $testVenv = Join-Path $stage 'wheel-test'
    $bundle = Join-Path $stage 'bundle'
    $partial = Join-Path $stage 'zephyr-offline-bundle.7z'
    try {
        # Use the binaries in the bundled installer, so pack and offline extraction agree.
        $packTools = Join-Path $stage '7zip'
        $sevenZipEntry = @($hostEntries | Where-Object { $_.Id -eq '7zip.7zip' })[0]
        Invoke-PackArchive $sevenZip @('e', '-y', '-spd', '-r-', ('-o' + $packTools), '--', (Join-Path $Root $sevenZipEntry.Path), '7z.exe', '7z.dll') 'Prepare matching 7-Zip'
        $sevenZip = Join-Path $packTools '7z.exe'
        Set-PackStage 4 'Validate Python dependencies offline'
        New-Item -ItemType Directory -Path $bundle -Force | Out-Null
        Invoke-Checked $python @('-m', 'venv', $testVenv)
        $testPython = Join-Path $testVenv 'Scripts\python.exe'
        Invoke-Checked $testPython @('-m', 'pip', '--isolated', 'install', '--no-index', '--find-links', $wheels, '-r', $requirements)
        Invoke-Checked $testPython @('-m', 'pip', 'check')
        if (Test-Path -LiteralPath (Join-Path $source 'zephyr\scripts\west_commands\packages.py')) {
            $requirementLines = @(& $python -m west packages pip)
            if ($LASTEXITCODE -ne 0) { throw 'Cannot collect Zephyr/module requirements.' }
            $requiredArgs = @()
            foreach ($line in $requirementLines) {
                if ($line -match '^\s*-r\s+(.+?)\s*$') {
                    $requirementPath = $Matches[1].Trim('"', "'")
                    $null = Assert-Within $requirementPath $source
                    $requiredArgs += @('-r', $requirementPath)
                } elseif ($line.Trim()) { throw "Unexpected west packages output: $line" }
            }
            if (-not $requiredArgs.Count) { throw 'No Zephyr requirements were found.' }
        } else { $requiredArgs = @('-r', (Join-Path $source 'zephyr\scripts\requirements.txt')) }
        $sourceFrozen = @(Get-Content -LiteralPath (Join-Path $Cache 'requirements-source.txt'))
        $pinned = @(Get-Content -LiteralPath $requirements)
        for ($i = 1; $i -lt $requiredArgs.Count; $i += 2) {
            $requiredArgs[$i] = Copy-OfflineRequirements $requiredArgs[$i] $source (Join-Path $stage 'requirements') $sourceFrozen $pinned
        }
        Invoke-Checked $testPython (@('-m', 'pip', '--isolated', 'install', '--dry-run', '--no-index', '--find-links', $wheels, '-c', $requirements) + $requiredArgs)
        Set-PackStage 5 'Copy installers, workspace and SDK'
        Copy-Tree $Cache (Join-Path $bundle 'zephyr_installers')
        $targetWorkspace = Join-Path $bundle 'zephyrproject'
        # Omit app as a whole so private applications and historical junction
        # trees are neither scanned nor copied. Add only the sample below.
        $excluded = @((Join-Path $source '.venv'), (Join-Path $source 'app'))
        if ($itePlan) { $excluded += @($itePlan.ExcludedDirectories) }
        Copy-Tree $source $targetWorkspace $excluded
        $sample = Join-Path $source 'app\blinky'
        if (Test-Path -LiteralPath $sample -PathType Container) {
            if ((Get-Item -LiteralPath (Join-Path $source 'app') -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Linked app directory is not supported.'
            }
            Write-Host '[PACK] Applications: blinky sample only; build output is excluded.'
            Copy-Tree $sample (Join-Path $targetWorkspace 'app\blinky') @((Join-Path $sample 'build'))
        }
        if ($itePlan) {
            $selectionPath = Join-Path $stage 'ite-selection.json'
            Save-Json $itePlan $selectionPath
            Invoke-Checked $python @($profileScript, '--source', $source, '--destination', $targetWorkspace, '--selection', $selectionPath)
        }
        $sdkName = 'zephyr-sdk-' + (Get-Content -LiteralPath (Join-Path $sdk 'sdk_version') -Raw).Trim()
        if ($sdkName -notmatch '^zephyr-sdk-[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9_.-]*$') { throw 'Invalid SDK version.' }
        $targetSdk = Join-Path $targetWorkspace $sdkName
        if (Test-Path -LiteralPath $targetSdk) { Remove-Local $targetSdk $targetWorkspace }
        $excludedSdk = @()
        if ($itePlan) {
            # SDK <=0.17 keeps toolchains at its root; SDK 1.x uses gnu/.
            foreach ($sdkRoot in @($sdk, (Join-Path $sdk 'gnu'))) {
                if (Test-Path -LiteralPath $sdkRoot) {
                    $excludedSdk += @(Get-ChildItem -LiteralPath $sdkRoot -Directory |
                        Where-Object { $_.Name -match '-zephyr-' -and $_.Name -ne $settings.Toolchain } |
                        Select-Object -ExpandProperty FullName)
                }
            }
        }
        Copy-Tree $sdk $targetSdk $excludedSdk
        $settings | Add-Member -NotePropertyName BundleProfile -NotePropertyValue $BundleProfile -Force
        $settings | Add-Member -NotePropertyName SdkDirectory -NotePropertyValue $sdkName -Force
        Save-Json $settings (Join-Path $targetWorkspace '.zephyr-setup.json')
        Set-PackStage 6 'Compute bundle checksums'
        $files = @(Get-BundleFileHashes $bundle)
        Save-Json @{ Format = 1; Python = '3.12'; Architecture = 'x64'; Profile = $BundleProfile; Sdk = 'zephyrproject\' + $sdkName; Settings = $settings; HostTools = $hostEntries; Files = $files } (Join-Path $bundle 'bundle-manifest.json')
        Push-Location -LiteralPath $bundle
        try {
            Set-PackStage 7 'Create 7z archive'
            # Keep the existing speed-first policy, now using the 7z format.
            Invoke-PackArchive $sevenZip @('a', '-t7z', '-mx=0', $partial, '.\*') 'Create 7z archive'
            Set-PackStage 8 'Test 7z integrity'
            Invoke-PackArchive $sevenZip @('t', $partial) 'Test 7z integrity'
        }
        finally { Pop-Location }
        Set-PackStage 9 'Publish 7z archive and clean staging files'
        $sevenZipEntry = @($hostEntries | Where-Object { $_.Id -eq '7zip.7zip' })[0]
        Save-OfflineBootstrap (Join-Path $Root $sevenZipEntry.Path) $PackageRoot -Flat
        Move-Item -LiteralPath $partial -Destination (Join-Path $Root 'zephyr-offline-bundle.7z') -Force
        Remove-PackInputs $files $sevenZipEntry.Sha256
    } finally {
        try {
            if (Test-Path -LiteralPath $stage) {
                Write-Host "[CLEANUP] Removing temporary files: $stage"
                Remove-Local $stage (Join-Path $Root 'offline_bundle')
            }
            if (-not $stageParentExisted -and (Test-Path -LiteralPath $stageParent) -and @(Get-ChildItem -LiteralPath $stageParent -Force).Count -eq 0) {
                $null = Assert-Within $stageParent $Root
                Assert-NoLinks $stageParent
                Remove-Item -LiteralPath $stageParent -Force
            }
        }
        finally { Write-PackProgress -Completed }
    }
    Write-Host "[SUCCESS] Created $Root\zephyr-offline-bundle.7z"
    Write-Host "[SUCCESS] Matching 7-Zip installer: $PackageRoot\7zip-x64.exe and 7zip-x64.json"
}

function Test-Bundle($Manifest) {
    if (-not $Manifest) { $Manifest = Get-Content -LiteralPath (Join-Path $Root 'bundle-manifest.json') -Raw | ConvertFrom-Json }
    if ($manifest.Format -ne 1 -or $manifest.Python -ne '3.12' -or $manifest.Architecture -ne 'x64') { throw 'Unsupported bundle format/platform.' }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $nextUpdate = 0.0
    $count = 0
    try {
        foreach ($entry in $manifest.Files) {
            if ($timer.Elapsed.TotalSeconds -ge $nextUpdate) {
                Write-PackProgress -Activity 'Verify offline bundle' -Status ("{0:N0}/{1:N0} files; {2:N0}s" -f $count, $manifest.Files.Count, $timer.Elapsed.TotalSeconds) -PercentComplete ([int][Math]::Floor(100 * $count / [Math]::Max(1, $manifest.Files.Count)))
                $nextUpdate = $timer.Elapsed.TotalSeconds + 1
            }
            $path = Assert-Within (Join-Path $Root $entry.Path) $Root
            $longPath = Get-LongPath $path
            if (-not [IO.File]::Exists($longPath)) { throw "Missing bundle file: $($entry.Path)" }
            if ((Get-FileHash -LiteralPath $longPath -Algorithm SHA256).Hash -ne $entry.Sha256) { throw "Bundle file is damaged or modified: $($entry.Path)" }
            $count++
        }
    } finally { Write-PackProgress -Completed }
    foreach ($required in @('zephyrproject\.west\config', 'zephyrproject\zephyr\scripts\requirements.txt', 'zephyr_installers\requirements-frozen.txt')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $required))) { throw "Incomplete bundle: $required" }
    }
    $null = Assert-Within (Join-Path $Root $manifest.Sdk) $Workspace
    if (-not (Test-Path -LiteralPath (Join-Path $Root ($manifest.Sdk + '\sdk_version')))) { throw 'Bundle SDK version file is missing.' }
    if (@(Get-ChildItem -LiteralPath (Join-Path $Cache 'wheels') -Filter '*.whl' -File).Count -eq 0) { throw 'Bundle contains no Python wheels.' }
    foreach ($tool in $Tools) {
        $entry = @($manifest.HostTools | Where-Object { $_.Id -eq $tool.Id })
        if ($entry.Count -ne 1) { throw "Bundle is missing installer metadata: $($tool.Id)" }
        $path = Assert-Within (Join-Path $Root $entry[0].Path) $Cache
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry[0].Sha256) { throw "Installer checksum failed: $($tool.Id)" }
    }
    Write-Host '[OK] Bundle checksums and installer inventory verified.'
    return $manifest
}

function Start-Installer([string]$Path, [string]$Arguments, [switch]$Msi) {
    $exe = $Path
    if ($Msi) { $exe = 'msiexec.exe'; $Arguments = '/i "' + $Path + '" ' + $Arguments }
    Write-Host "[INSTALL] Starting $(Split-Path $Path -Leaf); waiting for the installer to finish..."
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $exe -ArgumentList $Arguments -WindowStyle Hidden -Wait -PassThru
    Write-Host ("[INSTALL] Finished {0}; exit {1}; elapsed {2:N0}s" -f (Split-Path $Path -Leaf), $process.ExitCode, $timer.Elapsed.TotalSeconds)
    if ($process.ExitCode -eq 3010) { throw 'Installer requires a Windows restart. Restart and run offline installation again.' }
    if ($process.ExitCode -ne 0) { throw "Installer failed: $Path (exit $($process.ExitCode))" }
}

function Install-Offline {
    Expand-OfflineBundle
    $manifest = $script:OfflineValidatedManifest
    if (-not $manifest) { $manifest = Test-Bundle }
    if ($CheckOnly) { return }
    $sevenZipEntry = @($manifest.HostTools | Where-Object { $_.Id -eq '7zip.7zip' })[0]
    $sevenZip = Use-OfflineSevenZip (Join-Path $Root $sevenZipEntry.Path) ''
    Refresh-Path
    foreach ($tool in $Tools) {
        if ($tool.Name -eq '7z') { continue }
        Write-Host "[OFFLINE] Checking or installing host tool: $($tool.Id)"
        $entry = @($manifest.HostTools | Where-Object { $_.Id -eq $tool.Id })[0]
        $installer = Join-Path $Root $entry.Path
        if ($tool.Extension -eq '.zip') {
            $destination = Join-Path (Get-ToolsDirectory) $tool.Name
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            Invoke-Checked $sevenZip @('x', '-y', ('-o' + $destination), $installer)
        } elseif ($tool.Name -eq 'python') {
            try { $null = Get-Python312 } catch { Start-Installer $installer '/quiet InstallAllUsers=0 PrependPath=1 Include_pip=1 Include_launcher=1' }
        } elseif (-not (Get-Command ($tool.Name + '.exe') -ErrorAction SilentlyContinue)) {
            switch ($tool.Name) {
                'git' { Start-Installer $installer '/VERYSILENT /NORESTART /SP-' }
                'cmake' { Start-Installer $installer '/qn /norestart ADD_CMAKE_TO_PATH=System' -Msi }
            }
        }
        Refresh-Path
    }
    Write-Host '[OFFLINE] Verifying host tools and saving PATH...'
    Test-HostTools
    Save-HostPaths
    Invoke-Checked 'git.exe' @('config', '--global', 'core.longpaths', 'true')
    $python = Get-Python312
    $venvPython = Join-Path $Workspace '.venv\Scripts\python.exe'
    Write-Host '[OFFLINE] Preparing the workspace Python environment...'
    if (-not (Test-Path -LiteralPath $venvPython)) { Invoke-Checked $python @('-m', 'venv', (Join-Path $Workspace '.venv')) }
    Invoke-Checked $venvPython @('-c', "import sys,struct; assert sys.version_info[:2] == (3,12) and struct.calcsize('P') == 8")
    Use-Workspace $Workspace
    Write-Host '[OFFLINE] Installing Python packages from local wheels...'
    Invoke-Checked $venvPython @('-m', 'pip', '--isolated', 'install', '--no-index', '--find-links', (Join-Path $Cache 'wheels'), '-r', (Join-Path $Cache 'requirements-frozen.txt'))
    $settings = Get-Settings $Workspace
    $sdk = Find-Sdk $Workspace (Assert-Within (Join-Path $Root $manifest.Sdk) $Workspace) $settings.Toolchain
    Write-Host '[OFFLINE] Configuring the SDK and building Blinky...'
    Complete-Setup $settings $sdk
}

function Clear-Registration {
    foreach ($package in @('Zephyr', 'Zephyr-sdk')) {
        $keyPath = 'HKCU:\Software\Kitware\CMake\Packages\' + $package
        if (Test-Path -LiteralPath $keyPath) {
            $key = Get-Item -LiteralPath $keyPath
            foreach ($name in $key.GetValueNames()) {
                $value = [string]$key.GetValue($name)
                if ($value.Replace('/', '\').StartsWith($Workspace + '\', [StringComparison]::OrdinalIgnoreCase)) {
                    Remove-ItemProperty -LiteralPath $keyPath -Name $name
                }
            }
        }
    }
    $sdkVariable = [Environment]::GetEnvironmentVariable('ZEPHYR_SDK_INSTALL_DIR', 'User')
    foreach ($name in @('ZEPHYR_BASE', 'ZEPHYR_SDK_INSTALL_DIR')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'User')
        if ($value -and $value.Replace('/', '\').StartsWith($Workspace + '\', [StringComparison]::OrdinalIgnoreCase)) {
            [Environment]::SetEnvironmentVariable($name, $null, 'User')
        }
    }
    if ($sdkVariable -and $sdkVariable.Replace('/', '\').StartsWith($Workspace + '\', [StringComparison]::OrdinalIgnoreCase)) {
        [Environment]::SetEnvironmentVariable('ZEPHYR_TOOLCHAIN_VARIANT', $null, 'User')
    }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath) {
        $toolsPrefix = (Get-ToolsDirectory).TrimEnd('\') + '\'
        $kept = @($userPath -split ';' | Where-Object {
            $expanded = [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\')
            -not ($expanded.StartsWith($Workspace + '\', [StringComparison]::OrdinalIgnoreCase) -or $expanded.StartsWith($toolsPrefix, [StringComparison]::OrdinalIgnoreCase))
        })
        if (($kept -join ';') -cne $userPath) { [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User') }
    }
}

function Uninstall-Zephyr {
    Write-Host "Remove sources, modules, SDK and .venv ONLY from: $Workspace"
    Write-Host "Preserve applications in: $Workspace\app"
    Write-Host 'Offline installers and bundle archives are retained. Close build tools before continuing.'
    if ((Read-Host 'Remove this Zephyr installation? (y/N)').Trim() -ine 'y') { Write-Host 'Cancelled. No changes made.'; return }
    $removeTools = (Read-Host 'Also uninstall shared Python, Git, CMake, Ninja, dtc, gperf and 7-Zip? (y/N)').Trim() -ieq 'y'
    $project = Assert-Within $Workspace $Root
    $localTools = Get-ToolsDirectory
    Assert-NoLinks $project
    Assert-NoLinks $localTools
    Assert-NoLinks (Join-Path $Root 'bundle-manifest.json')
    if (Test-Path -LiteralPath $project) {
        foreach ($child in Get-ChildItem -LiteralPath $project -Force) {
            if ($child.Name -ine 'app') { Remove-Local $child.FullName $project }
        }
    }
    Remove-Local $localTools $Root
    Remove-Local (Join-Path $Root 'bundle-manifest.json') $Root
    Clear-Registration
    if ($removeTools) {
        Refresh-Path
        $winget = (Get-Command winget.exe -ErrorAction Stop).Source
        $failed = @()
        foreach ($tool in $Tools) {
            & $winget uninstall --id $tool.Id -e --silent --accept-source-agreements --disable-interactivity | Out-Host
            # NO_APPLICATIONS_FOUND (0x8A150014): WinGet has no matching installed package.
            # This does not prove that manually installed/portable executables are absent.
            if ($LASTEXITCODE -eq -1978335212) {
                Write-Host "[SKIP] $($tool.Id): no matching installed package found by WinGet."
            } elseif ($LASTEXITCODE -ne 0) { $failed += $tool.Id }
        }
        if ($failed.Count) { throw "Workspace removed, but shared tool removal failed: $($failed -join ', ')" }
    }
    Write-Host '[SUCCESS] Zephyr removed; app and offline installation cache preserved.'
}

$originalOutputEncoding = [Console]::OutputEncoding
try {
    Set-ConsoleUtf8
    if (-not [Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { throw 'Run on Windows x64 using 64-bit PowerShell.' }
    if ($InstallDir -and $Mode -ne 'Online') { Select-InstallDirectory }
    if ($Mode -notin @('Uninstall', 'Online') -and $Root -match '\s') { throw 'Move this project to a path without spaces before installation or packaging.' }
    switch ($Mode) {
        'Online' { Install-Online }
        'Pack' { New-Bundle }
        'Offline' { Install-Offline }
        'Uninstall' { Uninstall-Zephyr }
        default { throw 'Specify -Mode Online, Pack, Offline or Uninstall.' }
    }
    exit 0
} catch [OperationCanceledException] { Write-Host "[CANCELLED] $($_.Exception.Message)" -ForegroundColor Yellow; exit 130 }
catch { Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
finally {
    if ($Mode -in @('Pack', 'Offline')) {
        Write-PackProgress -Completed
    }
    [Console]::OutputEncoding = $originalOutputEncoding
}
