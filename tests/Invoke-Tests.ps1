[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Passed = 0
$script:Failures = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if (-not [object]::Equals($Actual, $Expected)) {
        throw ($Message + ' (expected=' + [string]$Expected + ', actual=' + [string]$Actual + ')')
    }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Passed++
        Write-Host ('[PASS] ' + $Name)
    } catch {
        $script:Failures.Add($Name + ': ' + $_.Exception.Message)
        Write-Host ('[FAIL] ' + $Name + ': ' + $_.Exception.Message) -ForegroundColor Red
    }
}

function ConvertTo-PsLiteral {
    param([string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function ConvertTo-NativeArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    if ($Value.IndexOf([char]0) -ge 0) { throw 'Native test arguments cannot contain NUL.' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }

    $builder = New-Object Text.StringBuilder
    [void]$builder.Append([char]0x22)
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]0x5C) {
            $backslashes++
            continue
        }
        if ($character -eq [char]0x22) {
            if ($backslashes -gt 0) { [void]$builder.Append(([string][char]0x5C) * ($backslashes * 2)) }
            [void]$builder.Append([char]0x5C)
            [void]$builder.Append([char]0x22)
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(([string][char]0x5C) * $backslashes)
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) { [void]$builder.Append(([string][char]0x5C) * ($backslashes * 2)) }
    [void]$builder.Append([char]0x22)
    return $builder.ToString()
}

function Invoke-NodeCapture {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$InputText
    )

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:NodeExecutable
    $startInfo.Arguments = (@($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $PSBoundParameters.ContainsKey('InputText')
    $startInfo.CreateNoWindow = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    $inputWriter = $null
    $originalInputEncoding = $null
    if ($startInfo.RedirectStandardInput) {
        $originalInputEncoding = [Console]::InputEncoding
        [Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
    }
    try {
        $null = $process.Start()
        if ($startInfo.RedirectStandardInput) { $inputWriter = $process.StandardInput }
    } finally {
        if ($null -ne $originalInputEncoding) { [Console]::InputEncoding = $originalInputEncoding }
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if ($PSBoundParameters.ContainsKey('InputText')) {
        $inputWriter.Write($InputText)
        $inputWriter.Flush()
        $inputWriter.Close()
    }
    if (-not $process.WaitForExit(30000)) {
        try { $process.Kill() } catch { }
        try { $process.WaitForExit(5000) | Out-Null } catch { }
        $process.Dispose()
        throw ('Node test process timed out: ' + ($Arguments -join ' '))
    }
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $exitCode = $process.ExitCode
    $process.Dispose()
    $output = @($stdout, $stderr) | Where-Object { -not [string]::IsNullOrEmpty($_) }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = ($output -join [Environment]::NewLine)
    }
}

function Invoke-SetupProcess {
    param(
        [Parameter(Mandatory = $true)][string]$SetupPath,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [ValidateSet('Disabled', 'Enabled')][string]$Hooks = 'Disabled',
        [string[]]$Areas = @(),
        [string]$SystemName = 'TestOS',
        [string]$Confirmation = '',
        [switch]$DryRun,
        [switch]$MockTrustedObsidian
    )

    $command = '& ' + (ConvertTo-PsLiteral $SetupPath) +
        ' -VaultPath ' + (ConvertTo-PsLiteral $TargetPath) +
        ' -OsName ' + (ConvertTo-PsLiteral $SystemName) + " -UserName 'TestUser'" +
        " -UserBio 'Automated Windows security test' -Companion 'Atlas'" +
        ' -Hooks ' + $Hooks + " -Today '2026-08-01'"
    if ($Areas.Count -gt 0) {
        $areaLiterals = @($Areas | ForEach-Object { ConvertTo-PsLiteral $_ })
        $command += ' -OptionalArea @(' + ($areaLiterals -join ',') + ')'
    }
    if ($DryRun) { $command += ' -DryRun' }
    if (-not [string]::IsNullOrEmpty($Confirmation)) {
        $readHostMock = 'function global:Read-Host { param([string]$Prompt) return ' +
            (ConvertTo-PsLiteral $Confirmation) + ' }; '
        $command = $readHostMock + $command
    }
    if ($MockTrustedObsidian) {
        $trustMocks = @'
function global:Get-Item {
    [CmdletBinding()]
    param([string[]]$Path, [string[]]$LiteralPath, [switch]$Force)
    $selected = @(if ($PSBoundParameters.ContainsKey('LiteralPath')) { $LiteralPath } else { $Path })
    if ($selected.Count -eq 1 -and $selected[0] -like '*\Obsidian.exe') {
        $real = Microsoft.PowerShell.Management\Get-Item -LiteralPath $selected[0] -Force:$Force
        return [pscustomobject]@{
            FullName = $real.FullName
            PSIsContainer = $false
            Attributes = $real.Attributes
            VersionInfo = [pscustomobject]@{
                ProductVersion = '1.12.7.0'
                ProductName = 'Obsidian'
                CompanyName = 'Obsidian'
            }
        }
    }
    if ($PSBoundParameters.ContainsKey('LiteralPath')) {
        return Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -Force:$Force
    }
    return Microsoft.PowerShell.Management\Get-Item -Path $Path -Force:$Force
}
function global:Get-AuthenticodeSignature {
    param([string]$LiteralPath)
    return [pscustomobject]@{
        Status = [System.Management.Automation.SignatureStatus]::Valid
        SignerCertificate = [pscustomobject]@{ Subject = 'CN=Dynalist Inc, O=Dynalist Inc, C=CA' }
    }
}
'@
        $command = $trustMocks + $command
    }

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $hostPath = (Get-Process -Id $PID).Path
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $hostPath
    $startInfo.Arguments = '-NoProfile -EncodedCommand ' + $encoded
    $startInfo.WorkingDirectory = [IO.Path]::GetDirectoryName($SetupPath)
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $null = $process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) {
        try { $process.Kill() } catch { }
        try { $process.WaitForExit(5000) | Out-Null } catch { }
        $process.Dispose()
        throw ('Installer test process timed out: ' + $TargetPath)
    }
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $exitCode = $process.ExitCode
    $process.Dispose()
    return [pscustomobject]@{ ExitCode = $exitCode; Stdout = $stdout; Stderr = $stderr }
}

function Get-TextSha256 {
    param([string]$Value)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { $bytes = $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)) }
    finally { $algorithm.Dispose() }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-FileSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$templateRoot = Join-Path $repoRoot 'template'
$setupPath = Join-Path $repoRoot 'setup.ps1'
$launcherPath = Join-Path $templateRoot 'Open-SecondBrain.ps1'
$personalizerPath = Join-Path $repoRoot 'personalize.mjs'
$hookPath = Join-Path $templateRoot '.claude\hooks\hooks.mjs'
$workflowPath = Join-Path $repoRoot '.github\workflows\windows-ci.yml'
$acceptancePath = Join-Path $repoRoot 'tests\Invoke-Acceptance.ps1'
$script:NodeExecutable = (Get-Command node -CommandType Application | Select-Object -First 1).Path
if ([string]::IsNullOrWhiteSpace($script:NodeExecutable)) { throw 'Node.js executable is unavailable.' }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('second-brainbro-ci-' + [guid]::NewGuid().ToString('N'))
$originalLocalAppData = $env:LOCALAPPDATA
$originalPath = $env:Path

try {
    $null = [IO.Directory]::CreateDirectory($testRoot)

    Test-Case 'PowerShell and Node syntax' {
        foreach ($path in @($setupPath, $launcherPath, $acceptancePath, $PSCommandPath)) {
            $errors = $null
            $tokens = $null
            [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
            Assert-Equal $errors.Count 0 ('PowerShell parse errors: ' + $path)
        }
        foreach ($path in @($personalizerPath, $hookPath)) {
            $result = Invoke-NodeCapture -Arguments @('--check', $path)
            Assert-Equal $result.ExitCode 0 ('Node syntax failed: ' + $path + ' ' + $result.Output)
        }
        $version = Invoke-NodeCapture -Arguments @('--version')
        Assert-Equal $version.ExitCode 0 'Node.js is unavailable'
        Assert-True ($version.Output -match '^v(\d+)\.') 'Node.js version is not parseable'

        $utf8ProbeText = 'Istanbul-' + [char]::ConvertFromUtf32(0x1F510)
        $utf8Probe = Invoke-NodeCapture -Arguments @(
            '-e', "const chunks=[];process.stdin.on('data',(chunk)=>chunks.push(chunk));process.stdin.on('end',()=>process.stdout.write(Buffer.concat(chunks).toString('hex')));"
        ) -InputText $utf8ProbeText
        $expectedUtf8Hex = (([Text.Encoding]::UTF8.GetBytes($utf8ProbeText) | ForEach-Object { $_.ToString('x2') }) -join '')
        Assert-Equal $utf8Probe.ExitCode 0 ('Explicit UTF-8 stdin probe failed: ' + $utf8Probe.Output)
        Assert-Equal $utf8Probe.Output $expectedUtf8Hex 'Node stdin was not sent as exact BOM-less UTF-8 bytes'

        $setupErrors = $null
        $setupTokens = $null
        $setupAst = [Management.Automation.Language.Parser]::ParseFile($setupPath, [ref]$setupTokens, [ref]$setupErrors)
        $versionFunction = $setupAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-SupportedNodeVersion'
        }, $true) | Select-Object -First 1
        Assert-True ($null -ne $versionFunction) 'Node.js support policy function is missing'
        Invoke-Expression $versionFunction.Extent.Text
        foreach ($supported in @('v22.23.1', '22.99.0', 'v24.18.0', '24.99.0')) {
            Assert-True (Test-SupportedNodeVersion $supported) ('Supported Node.js was rejected: ' + $supported)
        }
        foreach ($unsupported in @('v18.20.8', 'v20.20.2', 'v22.23.0', 'v23.11.1', 'v24.17.0', 'v25.2.1', 'v26.5.0', 'invalid')) {
            Assert-True (-not (Test-SupportedNodeVersion $unsupported)) ('Unsupported Node.js was accepted: ' + $unsupported)
        }
        Assert-True (Test-SupportedNodeVersion $version.Output.Trim()) `
            ('Test suite is running on an unsupported Node.js line: ' + $version.Output)
    }

    Test-Case 'Packaged hook manifest and disabled defaults' {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $templateRoot '.claude\settings.json'))) 'Tracked settings.json must be absent'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $templateRoot '.claude\settings.local.json'))) 'Hooks must be disabled in the template'
        $permissionExamplePath = Join-Path $templateRoot '.claude\settings.permissions.example.json'
        $hookExamplePath = Join-Path $templateRoot '.claude\settings.hooks.example.json'
        $permissionExample = [IO.File]::ReadAllText($permissionExamplePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $hookExample = [IO.File]::ReadAllText($hookExamplePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        Assert-True ($permissionExample.PSObject.Properties.Name -notcontains 'hooks') 'Permission-only example activates hooks'
        Assert-Equal ($permissionExample.permissions.deny -join "`n") ($hookExample.permissions.deny -join "`n") 'Permission and hook modes have different deny rules'
        $privateReadRule = 'Read(//**/' + [char]::ConvertFromUtf32(0x1F510) + ' 400-Vault/**)'
        $privateEditRule = 'Edit(//**/' + [char]::ConvertFromUtf32(0x1F510) + ' 400-Vault/**)'
        foreach ($rule in @('Bash', 'PowerShell', $privateReadRule, $privateEditRule, 'Read(//**/.env)', 'Edit(//**/.env)')) {
            Assert-True ($permissionExample.permissions.deny -contains $rule) ('Required Claude deny rule is missing: ' + $rule)
        }
        Assert-True (-not @($permissionExample.permissions.deny | Where-Object { $_ -match '^(Read|Edit)\(/(?!/)' }).Count) `
            'Working-directory-relative sensitive path rule remains'
        $manifestPath = Join-Path $templateRoot '.claude\hook-manifest.json'
        $manifest = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        Assert-Equal ([int]$manifest.schemaVersion) 1 'Unexpected manifest schema'
        Assert-Equal ([string]$manifest.control) 'drift-detection' 'Unexpected manifest control'
        Assert-True ($manifest.files.PSObject.Properties.Name -notcontains '.claude/settings.local.json') `
            'User-editable local settings must not be pinned by the drift manifest'
        foreach ($entry in $manifest.files.PSObject.Properties) {
            $source = Join-Path $templateRoot ($entry.Name.Replace('/', '\'))
            Assert-Equal (Get-FileSha256 $source) ([string]$entry.Value) ('Manifest drift: ' + $entry.Name)
        }
    }

    Test-Case 'Personalization preflight and fixed write set' {
        $vault = Join-Path $testRoot "Personalize O'Brien & Safe"
        Copy-Item -LiteralPath $templateRoot -Destination $vault -Recurse
        $claudePath = Join-Path $vault 'CLAUDE.md'
        $before = Get-FileSha256 $claudePath
        $invalid = Invoke-NodeCapture -Arguments @(
            $personalizerPath, '--vault', $vault, '--os-name', 'TestOS', '--user-name', 'TestUser',
            '--user-bio', 'bad {{token}}', '--companion', 'Atlas', '--today', '2026-08-01'
        )
        Assert-True ($invalid.ExitCode -ne 0) 'Invalid personalization input was accepted'
        Assert-Equal (Get-FileSha256 $claudePath) $before 'Invalid preflight modified a file'

        $unknownFlag = Invoke-NodeCapture -Arguments @(
            $personalizerPath, '--vault', $vault, '--os-name', 'TestOS', '--user-name', 'TestUser',
            '--user-bio', 'Automated local vault', '--companion', 'Atlas', '--unknown', 'value'
        )
        Assert-True ($unknownFlag.ExitCode -ne 0) 'Unknown personalization flag was accepted'
        $duplicateFlag = Invoke-NodeCapture -Arguments @(
            $personalizerPath, '--vault', $vault, '--vault', $vault, '--os-name', 'TestOS',
            '--user-name', 'TestUser', '--user-bio', 'Automated local vault', '--companion', 'Atlas'
        )
        Assert-True ($duplicateFlag.ExitCode -ne 0) 'Duplicate personalization flag was accepted'

        $valid = Invoke-NodeCapture -Arguments @(
            $personalizerPath, '--vault', $vault, '--os-name', 'TestOS', '--user-name', 'TestUser',
            '--user-bio', 'Automated local vault', '--companion', 'Atlas', '--today', '2026-08-01'
        )
        Assert-Equal $valid.ExitCode 0 ('Valid personalization failed: ' + $valid.Output)
        $leftovers = @()
        foreach ($file in Get-ChildItem -LiteralPath $vault -Recurse -File) {
            $text = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
            if ($text -match '\{\{[^}]*\}\}') { $leftovers += $file.FullName }
        }
        Assert-Equal $leftovers.Count 0 'Personalization placeholders remain'
    }

    Test-Case 'Launcher allowlist and fail-closed handler selection' {
        $errors = $null
        $tokens = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($launcherPath, [ref]$tokens, [ref]$errors)
        $definitions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)
        foreach ($name in @('Get-FullPath', 'Assert-NormalFile', 'Assert-NoReparseAncestor', 'Test-SupportedObsidianVersion',
            'Get-TrustedObsidianMetadata', 'Resolve-ObsidianExecutable', 'Test-SupportedClaudeVersion', 'Resolve-PowerShellHost')) {
            $definition = $definitions | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            Assert-True ($null -ne $definition) ('Launcher function missing: ' + $name)
            Invoke-Expression $definition.Extent.Text
        }

        $candidateRoot = Join-Path $testRoot 'launcher-candidates'
        $paths = @(
            (Join-Path $candidateRoot 'local\Programs\Obsidian\Obsidian.exe'),
            (Join-Path $candidateRoot 'local\Obsidian\Obsidian.exe'),
            (Join-Path $candidateRoot 'program-files\Obsidian\Obsidian.exe')
        )
        foreach ($path in $paths) {
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
            [IO.File]::WriteAllBytes($path, [byte[]](1, 2, 3))
        }
        $script:MockObsidianSubject = 'CN=Dynalist Inc, O=Dynalist Inc, C=CA'
        Assert-True (Test-SupportedClaudeVersion '2.1.211 (Claude Code)') 'Minimum Claude Code version was rejected'
        Assert-True (Test-SupportedClaudeVersion '3.0.0') 'Newer Claude Code version was rejected'
        Assert-True (-not (Test-SupportedClaudeVersion '2.1.210 (Claude Code)')) 'Outdated Claude Code version was accepted'
        function Get-Item {
            [CmdletBinding()]
            param([string[]]$Path, [string[]]$LiteralPath, [switch]$Force)
            $selected = @(if ($PSBoundParameters.ContainsKey('LiteralPath')) { $LiteralPath } else { $Path })
            if ($selected.Count -eq 1 -and $selected[0] -like '*\Obsidian.exe') {
                $real = Microsoft.PowerShell.Management\Get-Item -LiteralPath $selected[0] -Force:$Force
                return [pscustomobject]@{
                    FullName = $real.FullName
                    PSIsContainer = $false
                    Attributes = $real.Attributes
                    VersionInfo = [pscustomobject]@{
                        ProductVersion = '1.12.7.0'
                        ProductName = 'Obsidian'
                        CompanyName = 'Obsidian'
                    }
                }
            }
            if ($PSBoundParameters.ContainsKey('LiteralPath')) {
                return Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -Force:$Force
            }
            return Microsoft.PowerShell.Management\Get-Item -Path $Path -Force:$Force
        }
        function Get-AuthenticodeSignature {
            param([string]$LiteralPath)
            return [pscustomobject]@{
                Status = [System.Management.Automation.SignatureStatus]::Valid
                SignerCertificate = [pscustomobject]@{ Subject = $script:MockObsidianSubject }
            }
        }
        foreach ($path in $paths) {
            $registered = '"' + $path + '" "%1"'
            $resolved = Resolve-ObsidianExecutable -CandidatePaths $paths -RegisteredCommand $registered
            Assert-Equal $resolved.Path $path 'Wrong Obsidian candidate selected'
            Assert-Equal $resolved.Version '1.12.7.0' 'Obsidian version was not retained'
        }
        $script:MockObsidianSubject = 'CN=Unexpected Publisher, O=Unexpected Publisher, C=US'
        $rejected = $false
        try { $null = Resolve-ObsidianExecutable -CandidatePaths $paths -RegisteredCommand ('"' + $paths[0] + '" "%1"') }
        catch { $rejected = $true }
        Assert-True $rejected 'Unexpected Obsidian Authenticode publisher was accepted'
        $script:MockObsidianSubject = 'CN=Dynalist Inc, O=Dynalist Inc, C=CA'
        $rejected = $false
        try { $null = Resolve-ObsidianExecutable -CandidatePaths $paths -RegisteredCommand '"C:\malicious.exe" "%1"' }
        catch { $rejected = $true }
        Assert-True $rejected 'Unsupported protocol handler was accepted'
        $rejected = $false
        try { $null = Resolve-ObsidianExecutable -CandidatePaths $paths -RegisteredCommand ('"' + $paths[0] + '" "%1" --extra') }
        catch { $rejected = $true }
        Assert-True $rejected 'Protocol handler with extra arguments was accepted'

        $desktopHome = Join-Path $candidateRoot 'windows-powershell'
        $coreHome = Join-Path $candidateRoot 'powershell-7'
        $null = [IO.Directory]::CreateDirectory($desktopHome)
        $null = [IO.Directory]::CreateDirectory($coreHome)
        $desktopHost = Join-Path $desktopHome 'powershell.exe'
        $coreHost = Join-Path $coreHome 'pwsh.exe'
        [IO.File]::WriteAllBytes($desktopHost, [byte[]](1, 2, 3))
        [IO.File]::WriteAllBytes($coreHost, [byte[]](1, 2, 3))
        Assert-Equal (Resolve-PowerShellHost -PowerShellHome $desktopHome -Edition Desktop) $desktopHost 'Windows PowerShell host selection failed'
        Assert-Equal (Resolve-PowerShellHost -PowerShellHome $coreHome -Edition Core) $coreHost 'PowerShell 7 host selection failed'

        $source = [IO.File]::ReadAllText($launcherPath, [Text.Encoding]::UTF8)
        Assert-True ($source -notmatch 'Invoke-Expression|\biex\b|ScriptBlock::Create|cmd\.exe') 'Forbidden launcher execution primitive found'
        Assert-True ($source.Contains('-EncodedCommand')) 'Encoded Claude command control is missing'
        Assert-True ($source.Contains('Open folder as vault')) 'Obsidian first-vault guard is missing'
        Assert-True ($source.Contains('Start-Process -FilePath $obsidianExe')) 'Validated Obsidian executable is not launched directly'
        Assert-True ($source.IndexOf('if ($DryRun)') -lt $source.IndexOf('Start-Process')) 'Dry-run guard occurs after process launch'
        Assert-True ($source.IndexOf("Read-Host 'Type CLAUDE") -lt $source.IndexOf('Get-ValidatedClaudeVersion -Path $claudePath')) `
            'Claude version process runs before explicit consent'
        Assert-True ($source.IndexOf('Get-ValidatedClaudeVersion -Path $claudePath') -lt $source.IndexOf('Start-Process -FilePath $obsidianExe')) `
            'Applications start before Claude version validation'
    }

    Test-Case 'Transactional installer and hook lifecycle' {
        $actualNode = $script:NodeExecutable
        Assert-True (-not [string]::IsNullOrWhiteSpace($actualNode)) 'Real Node.js executable is unavailable'
        $shimDirectory = Join-Path $testRoot 'node-shim'
        $null = [IO.Directory]::CreateDirectory($shimDirectory)
        $shimPath = Join-Path $shimDirectory 'node.cmd'
        $shim = '@echo off' + "`r`n" +
            'if "%~1"=="--version" (' + "`r`n" +
            '  echo v22.23.1' + "`r`n" +
            '  exit /b 0' + "`r`n" +
            ')' + "`r`n" +
            '"' + $actualNode + '" %*' + "`r`n"
        [IO.File]::WriteAllText($shimPath, $shim, [Text.Encoding]::ASCII)
        $env:Path = $shimDirectory + [IO.Path]::PathSeparator + $originalPath

        $fakeLocal = Join-Path $testRoot 'fake-local-app-data'
        $fakeObsidian = Join-Path $fakeLocal 'Programs\Obsidian\Obsidian.exe'
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fakeObsidian))
        [IO.File]::WriteAllBytes($fakeObsidian, [byte[]](1, 2, 3))
        $env:LOCALAPPDATA = $fakeLocal

        $deniedTarget = Join-Path $testRoot 'DeniedVault'
        $denied = Invoke-SetupProcess -SetupPath $setupPath -TargetPath $deniedTarget -Confirmation 'DENY' -MockTrustedObsidian
        Assert-True ($denied.ExitCode -ne 0) 'Invalid CREATE confirmation was accepted'
        Assert-True (-not (Test-Path -LiteralPath $deniedTarget)) 'Denied install created a target'

        $dryTarget = Join-Path $testRoot 'DryVault'
        $dry = Invoke-SetupProcess -SetupPath $setupPath -TargetPath $dryTarget -DryRun -MockTrustedObsidian
        Assert-Equal $dry.ExitCode 0 ('Installer dry-run failed: ' + $dry.Stderr)
        Assert-True (-not (Test-Path -LiteralPath $dryTarget)) 'Dry-run created a target'

        $invalidDryTarget = Join-Path $testRoot 'InvalidDryVault'
        $invalidDry = Invoke-SetupProcess -SetupPath $setupPath -TargetPath $invalidDryTarget -SystemName 'CON' `
            -DryRun -MockTrustedObsidian
        Assert-True ($invalidDry.ExitCode -ne 0) 'Dry-run accepted invalid personalization input'
        Assert-True (-not (Test-Path -LiteralPath $invalidDryTarget)) 'Invalid dry-run created a target'

        $defaultTarget = Join-Path $testRoot 'Installed Default Permissions'
        $defaultInstall = Invoke-SetupProcess -SetupPath $setupPath -TargetPath $defaultTarget -Confirmation 'CREATE' -MockTrustedObsidian
        Assert-Equal $defaultInstall.ExitCode 0 ('Default permission install failed: ' + $defaultInstall.Stderr)
        $defaultSettingsPath = Join-Path $defaultTarget '.claude\settings.local.json'
        Assert-True (Test-Path -LiteralPath $defaultSettingsPath -PathType Leaf) 'Default local permissions are absent'
        Assert-Equal (Get-FileSha256 $defaultSettingsPath) `
            (Get-FileSha256 (Join-Path $templateRoot '.claude\settings.permissions.example.json')) `
            'Default settings differ from the reviewed permission-only example'
        $defaultSettings = [IO.File]::ReadAllText($defaultSettingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        Assert-True ($defaultSettings.PSObject.Properties.Name -notcontains 'hooks') 'Default install activated project hooks'

        $target = Join-Path $testRoot "Installed O'Brien & Safe"
        $installed = Invoke-SetupProcess -SetupPath $setupPath -TargetPath $target -Hooks Enabled `
            -Areas @('Goals', 'Goals', 'Private') -Confirmation 'CREATE' -MockTrustedObsidian
        Assert-Equal $installed.ExitCode 0 ('Transactional install failed: ' + $installed.Stderr)
        Assert-True (Test-Path -LiteralPath $target -PathType Container) 'Installed vault is absent'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $target '.claude\settings.json'))) 'Tracked settings.json was created'
        Assert-True (Test-Path -LiteralPath (Join-Path $target '.claude\settings.local.json') -PathType Leaf) 'Opt-in hook settings are absent'
        Assert-Equal (Get-FileSha256 $launcherPath) (Get-FileSha256 (Join-Path $target 'Open-SecondBrain.ps1')) 'Installed launcher hash mismatch'
        $vaultAcl = Get-Acl -LiteralPath $target
        Assert-True $vaultAcl.AreAccessRulesProtected 'Installed vault inherits parent ACL entries'
        $allowedAclSids = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')
        Assert-Equal $vaultAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value $allowedAclSids[0] 'Installed vault owner is not the current user'
        $unexpectedAclRules = @($vaultAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object {
            $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $allowedAclSids -notcontains $_.IdentityReference.Value
        })
        Assert-Equal $unexpectedAclRules.Count 0 'Installed vault grants an unexpected principal access'

        $goalFolder = [char]::ConvertFromUtf32(0x2694) + [char]::ConvertFromUtf32(0xFE0F) + ' 200-Goals'
        $vaultFolder = [char]::ConvertFromUtf32(0x1F510) + ' 400-Vault'
        Assert-True (Test-Path -LiteralPath (Join-Path $target (Join-Path $goalFolder 'Goals.md')) -PathType Leaf) 'Goals index is absent'
        Assert-True (Test-Path -LiteralPath (Join-Path $target (Join-Path $vaultFolder 'Vault.md')) -PathType Leaf) 'Private index is absent'

        $markerHits = @()
        foreach ($file in Get-ChildItem -LiteralPath $target -Recurse -File) {
            $text = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
            if ($text -match '\{\{[^}]*\}\}|SECOND_BRAINBRO_OPTIONAL_NAVIGATION|<!-- SETUP:') {
                $markerHits += $file.FullName
            }
        }
        Assert-Equal $markerHits.Count 0 'Installer markers remain'

        $installedHook = Join-Path $target '.claude\hooks\hooks.mjs'
        $verify = Invoke-NodeCapture -Arguments @($installedHook, 'verify-integrity')
        Assert-Equal $verify.ExitCode 0 ('Installed hook integrity failed: ' + $verify.Output)

        $manifestPrivacyVault = Join-Path $testRoot 'Oversized Manifest Privacy'
        Copy-Item -LiteralPath $templateRoot -Destination $manifestPrivacyVault -Recurse
        Copy-Item -LiteralPath (Join-Path $manifestPrivacyVault '.claude\settings.hooks.example.json') `
            -Destination (Join-Path $manifestPrivacyVault '.claude\settings.local.json')
        [IO.File]::WriteAllText((Join-Path $manifestPrivacyVault '.claude\hook-manifest.json'), ('x' * 70000), [Text.Encoding]::UTF8)
        $manifestPrivacyHook = Join-Path $manifestPrivacyVault '.claude\hooks\hooks.mjs'
        $manifestPrivacy = Invoke-NodeCapture -Arguments @($manifestPrivacyHook, 'verify-integrity')
        Assert-True ($manifestPrivacy.ExitCode -ne 0) 'Oversized hook manifest was accepted'
        Assert-True (-not $manifestPrivacy.Output.Contains($manifestPrivacyVault)) 'Hook error exposed the absolute vault path'

        $sessionId = 'RAW-SESSION-ID-DO-NOT-STORE'
        $invalidJson = @{ session_id = $sessionId; hook_event_name = 'SessionEnd' } | ConvertTo-Json -Compress
        $invalid = Invoke-NodeCapture -Arguments @($installedHook, 'session-start') -InputText $invalidJson
        Assert-Equal $invalid.ExitCode 0 'Invalid hook input blocked the client session'

        $startJson = @{ session_id = $sessionId; hook_event_name = 'SessionStart' } | ConvertTo-Json -Compress
        $start = Invoke-NodeCapture -Arguments @($installedHook, 'session-start') -InputText $startJson
        Assert-Equal $start.ExitCode 0 ('SessionStart failed: ' + $start.Output)
        Assert-True ($start.Output.Contains('"hookEventName":"SessionStart"')) 'SessionStart output contract is missing'
        $startResult = (($start.Output -split '\r?\n')[0] | ConvertFrom-Json)
        $startContext = [string]$startResult.hookSpecificOutput.additionalContext
        Assert-True (-not $startContext.Contains('Core.md')) 'SessionStart emitted an out-of-band Core.md instruction'
        Assert-Equal ([regex]::Matches($startContext, '\[UNTRUSTED MEMORY DATA').Count) 2 `
            'SessionStart did not emit exactly two bounded memory blocks'
        Assert-Equal ([regex]::Matches($startContext, '\[/UNTRUSTED MEMORY DATA\]').Count) 2 `
            'SessionStart memory block delimiters are unbalanced'
        $sessionKey = Get-TextSha256 $sessionId
        $stateRoot = Join-Path $target '.claude\hooks\.state'
        $sessionDir = Join-Path $stateRoot (Join-Path 'sessions' $sessionKey)
        Assert-True (Test-Path -LiteralPath $sessionDir -PathType Container) 'Hashed session directory is absent'

        $promptJson = @{ session_id = $sessionId; hook_event_name = 'UserPromptSubmit' } | ConvertTo-Json -Compress
        for ($i = 0; $i -lt 5; $i++) {
            $prompt = Invoke-NodeCapture -Arguments @($installedHook, 'prompt-counter') -InputText $promptJson
            Assert-Equal $prompt.ExitCode 0 'Prompt counter failed'
        }
        Assert-Equal @(Get-ChildItem -LiteralPath $sessionDir -File -Filter 'prompt-*.marker').Count 5 'Prompt markers are not session scoped'

        $endJson = @{ session_id = $sessionId; hook_event_name = 'SessionEnd' } | ConvertTo-Json -Compress
        $end = Invoke-NodeCapture -Arguments @($installedHook, 'session-end') -InputText $endJson
        Assert-Equal $end.ExitCode 0 'SessionEnd failed'
        Assert-True (-not (Test-Path -LiteralPath $sessionDir)) 'Ended session state remains'
        Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'pending-reflections') -File).Count 1 'Reflection notice was not queued'

        $secondId = 'SECOND-SESSION-ID'
        $secondStart = @{ session_id = $secondId; hook_event_name = 'SessionStart' } | ConvertTo-Json -Compress
        $claim = Invoke-NodeCapture -Arguments @($installedHook, 'session-start') -InputText $secondStart
        Assert-Equal $claim.ExitCode 0 'Second session failed to claim reflection'
        Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'pending-reflections') -File).Count 0 'Claimed reflection remains pending'

        foreach ($file in Get-ChildItem -LiteralPath $stateRoot -Recurse -File) {
            $stateText = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
            Assert-True (-not $stateText.Contains($sessionId)) 'Raw session ID leaked into state'
        }

        # A user editing their own permission rules must not trip drift detection.
        [IO.File]::AppendAllText((Join-Path $target '.claude\settings.local.json'), ' ', [Text.Encoding]::UTF8)
        $settingsEditId = 'SETTINGS-EDIT-SESSION-ID'
        $settingsEditJson = @{ session_id = $settingsEditId; hook_event_name = 'SessionStart' } | ConvertTo-Json -Compress
        $settingsEdit = Invoke-NodeCapture -Arguments @($installedHook, 'session-start') -InputText $settingsEditJson
        Assert-Equal $settingsEdit.ExitCode 0 'Local settings edit blocked the client session'
        Assert-True (-not $settingsEdit.Output.Contains('systemMessage')) 'Local settings edit produced a spurious drift warning'
        Assert-True (Test-Path -LiteralPath (Join-Path $stateRoot (Join-Path 'sessions' (Get-TextSha256 $settingsEditId))) -PathType Container) `
            'Local settings edit suppressed legitimate session state'

        # Tampering with packaged hook bytes must still fail closed.
        [IO.File]::AppendAllText($installedHook, "`n", [Text.Encoding]::UTF8)
        $driftId = 'DRIFT-SESSION-ID'
        $driftJson = @{ session_id = $driftId; hook_event_name = 'SessionStart' } | ConvertTo-Json -Compress
        $drift = Invoke-NodeCapture -Arguments @($installedHook, 'session-start') -InputText $driftJson
        Assert-Equal $drift.ExitCode 0 'Drift warning blocked the client session'
        Assert-True ($drift.Output.Contains('systemMessage')) 'Drift warning was not user visible'
        $driftDir = Join-Path $stateRoot (Join-Path 'sessions' (Get-TextSha256 $driftId))
        Assert-True (-not (Test-Path -LiteralPath $driftDir)) 'Manifest drift mutated session state'

        $leftovers = @(Get-ChildItem -LiteralPath $testRoot -Force | Where-Object {
            $_.Name -like '.second-brainbro-staging-*' -or $_.Name -like '*.second-brainbro.lock'
        })
        Assert-Equal $leftovers.Count 0 'Installer staging or lock residue remains'
    }

    Test-Case 'Obsidian navigation integrity' {
        $files = @(Get-ChildItem -LiteralPath $templateRoot -Recurse -File -Filter '*.md')
        $paths = @{}
        $bases = @{}
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($templateRoot.Length + 1).Replace('\', '/')
            $paths[$relative] = $true
            $base = [IO.Path]::GetFileNameWithoutExtension($file.Name)
            if (-not $bases.ContainsKey($base)) { $bases[$base] = 0 }
            $bases[$base]++
        }
        $problems = @()
        foreach ($file in $files) {
            $text = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
            foreach ($match in [regex]::Matches($text, '\[\[([^\]]+)\]\]')) {
                $target = ($match.Groups[1].Value -split '\|', 2)[0]
                $target = ($target -split '#', 2)[0]
                if ([string]::IsNullOrWhiteSpace($target)) { continue }
                if ($target.Contains('/')) {
                    $candidate = $target.TrimStart('/')
                    if (-not $candidate.EndsWith('.md')) { $candidate += '.md' }
                    if (-not $paths.ContainsKey($candidate)) { $problems += $file.FullName + ' -> ' + $target }
                } else {
                    $base = [IO.Path]::GetFileNameWithoutExtension($target)
                    if (-not $bases.ContainsKey($base) -or $bases[$base] -ne 1) {
                        $problems += $file.FullName + ' -> ' + $target
                    }
                }
            }
        }
        Assert-Equal $problems.Count 0 ('Broken or ambiguous wikilinks: ' + ($problems -join '; '))
    }

    Test-Case 'Tracked text encoding and secret patterns' {
        $tracked = @(& git -c core.quotePath=false -C $repoRoot ls-files --cached --others --exclude-standard)
        Assert-Equal $LASTEXITCODE 0 'git ls-files failed'
        Assert-True ($tracked.Count -gt 0) 'No tracked files were found'
        Assert-Equal @($tracked | Where-Object { $_ -like '*/settings.local.json' }).Count 0 'settings.local.json is tracked'
        $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
        $secretPattern = '(?i)(sk-ant-[A-Za-z0-9_-]{16,}|github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----)'
        $textExtensions = @('.ps1', '.mjs', '.json', '.md', '.yml', '.yaml', '.gitignore')
        foreach ($relative in $tracked) {
            $path = Join-Path $repoRoot $relative
            $bytes = [IO.File]::ReadAllBytes($path)
            try { $text = $strictUtf8.GetString($bytes) }
            catch { throw ('Tracked file is not strict UTF-8: ' + $relative) }
            Assert-True (-not $text.Contains([char]0xFFFD)) ('Replacement character found: ' + $relative)
            Assert-True (-not ($text -match $secretPattern)) ('Secret pattern found: ' + $relative)
            $extension = [IO.Path]::GetExtension($relative).ToLowerInvariant()
            if ($textExtensions -contains $extension -or $relative.EndsWith('.gitignore')) {
                $attribute = [string](& git -C $repoRoot check-attr eol -- $relative)
                Assert-True ($attribute.EndsWith('eol: lf')) ('Git LF policy is missing: ' + $relative)
            }
        }
    }

    Test-Case 'Documentation contract and local links' {
        $requiredDocs = @(
            'README.md', 'SETUP.md', 'ARCHITECTURE.md', 'PRIVACY.md', 'THREAT_MODEL.md',
            'TROUBLESHOOTING.md', 'SECURITY.md', 'PROVENANCE.md', 'ACCEPTANCE.md', 'CONTRIBUTING.md', 'LICENSE'
        )
        $docText = @{}
        foreach ($relative in $requiredDocs) {
            $path = Join-Path $repoRoot $relative
            Assert-True (Test-Path -LiteralPath $path -PathType Leaf) ('Required document is missing: ' + $relative)
            $docText[$relative] = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
        }

        foreach ($relative in $requiredDocs | Where-Object { $_ -ne 'README.md' }) {
            $link = '](' + $relative + ')'
            Assert-True ($docText['README.md'].Contains($link)) ('README does not link required document: ' + $relative)
        }

        $trackedMarkdown = @(& git -c core.quotePath=false -C $repoRoot ls-files --cached --others --exclude-standard '*.md')
        Assert-Equal $LASTEXITCODE 0 'git markdown inventory failed'
        $repoPrefix = $repoRoot.TrimEnd('\') + '\'
        $linkProblems = @()
        foreach ($relative in $trackedMarkdown) {
            $sourcePath = Join-Path $repoRoot $relative
            $sourceText = [IO.File]::ReadAllText($sourcePath, [Text.Encoding]::UTF8)
            foreach ($match in [regex]::Matches($sourceText, '\[[^\]]+\]\(([^)]+)\)')) {
                $target = $match.Groups[1].Value.Trim().Trim('<', '>')
                if ([string]::IsNullOrWhiteSpace($target) -or $target.StartsWith('#')) { continue }
                $absoluteUri = $null
                if ([Uri]::TryCreate($target, [UriKind]::Absolute, [ref]$absoluteUri)) {
                    if ($absoluteUri.Scheme -ne 'https') { $linkProblems += $relative + ' -> ' + $target }
                    continue
                }
                $pathPart = ($target -split '[?#]', 2)[0]
                try {
                    $decoded = [Uri]::UnescapeDataString($pathPart).Replace('/', '\')
                    $resolved = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($sourcePath)) $decoded))
                    $inside = $resolved.Equals($repoRoot, [StringComparison]::OrdinalIgnoreCase) -or
                        $resolved.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)
                    if (-not $inside -or -not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
                        $linkProblems += $relative + ' -> ' + $target
                    }
                } catch {
                    $linkProblems += $relative + ' -> ' + $target
                }
            }
        }
        Assert-Equal $linkProblems.Count 0 ('Invalid, insecure, or broken Markdown links: ' + ($linkProblems -join '; '))

        $setupErrors = $null
        $setupTokens = $null
        $setupAst = [Management.Automation.Language.Parser]::ParseFile($setupPath, [ref]$setupTokens, [ref]$setupErrors)
        Assert-Equal $setupErrors.Count 0 'setup.ps1 cannot be parsed for documentation coverage'
        $actualParameters = @($setupAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath } | Sort-Object)
        $documentedParameters = @('VaultPath', 'OsName', 'UserName', 'UserBio', 'Companion', 'Hooks', 'OptionalArea', 'InstallPrerequisites', 'DryRun', 'Today') | Sort-Object
        Assert-Equal ($actualParameters -join ',') ($documentedParameters -join ',') 'Installer parameter contract changed'
        foreach ($name in $actualParameters) {
            Assert-True ($docText['SETUP.md'].Contains('`' + $name + '`')) ('SETUP parameter is undocumented: ' + $name)
        }

        foreach ($relative in @('README.md', 'SETUP.md', 'THREAT_MODEL.md')) {
            Assert-True ($docText[$relative].Contains('22.23.1+') -and $docText[$relative].Contains('24.18.0+')) ('Node.js policy drift: ' + $relative)
            foreach ($unsupported in @('OneDrive', 'WSL', 'WebDAV', 'network')) {
                Assert-True ($docText[$relative].Contains($unsupported)) ('Unsupported deployment is undocumented in ' + $relative + ': ' + $unsupported)
            }
        }

        Assert-True ($docText['SECURITY.md'] -match '(?i)private vulnerability reporting') 'Private vulnerability reporting is undocumented'
        Assert-True ($docText['SECURITY.md'] -match '(?is)do not.*(secret|sensitive).*(issue|public)') 'Public issue redaction guidance is missing'
        Assert-True ($docText['PROVENANCE.md'].Contains('https://github.com/avenoxai/avenoxbeyin')) 'Upstream repository provenance is missing'
        Assert-True ($docText['PROVENANCE.md'].Contains('3961c0cb5afb5a4803b2ce19e2464c093ba934a6')) 'Upstream commit provenance is missing'
        Assert-True ($docText['README.md'].Contains('public source preview (alpha), not a release')) 'Public source-preview status is missing'
        Assert-True ($docText['PROVENANCE.md'].Contains('clean root')) 'Clean public-root provenance is missing'
        Assert-True ($docText.ContainsKey('CONTRIBUTING.md')) 'Public contribution policy is missing'
        Assert-True ($docText['README.md'].Contains('Phase 6:') -and $docText['THREAT_MODEL.md'].Contains('Phase 0') -and $docText['THREAT_MODEL.md'].Contains('6 hardening baseline')) 'Phase 6 status is inconsistent'

        $readme = $docText['README.md']
        Assert-True ($readme.Contains('<VaultPath>/')) 'README scaffold root is not tied to VaultPath'
        Assert-True ($readme.Contains('default permissions, opt-in hooks')) `
            'README .claude layout omits the default permission layer'
        Assert-True ($readme.Contains("denied to Claude's built-in read and edit tools")) `
            'README understates the private-folder Read/Edit controls'
        Assert-True ($readme.Contains('required for installation and for') -and
            $docText['SETUP.md'].Contains('required while the installer personalizes')) `
            'Node.js installation/runtime roles are not documented consistently'
        Assert-True ($readme.Contains('not required for Obsidian-only use') -and
            $docText['SETUP.md'].Contains('optional for Obsidian-only use')) `
            'Claude Code optional Obsidian-only boundary is not documented consistently'

        $allDocs = ($docText.Values -join "`n")
        foreach ($stale in @('Node.js 18', 'Node.js 20', 'redirected installer confirmation', 'UmutOS', 'C:\Users\Umut', 'private hardening preview', 'upstream history retained')) {
            Assert-True (-not $allDocs.Contains($stale)) ('Stale or personal documentation text found: ' + $stale)
        }
        Assert-True (-not ($allDocs -match '(?is)(Invoke-WebRequest|\birm\b|\bcurl\b).*?\|\s*(iex\b|Invoke-Expression\b|powershell\b|pwsh\b|sh\b|bash\b)')) 'Mutable download-and-execute instruction found'
    }

    Test-Case 'Clean-machine acceptance verifier contract' {
        $source = [IO.File]::ReadAllText($acceptancePath, [Text.Encoding]::UTF8)
        $setupSource = [IO.File]::ReadAllText($setupPath, [Text.Encoding]::UTF8)
        foreach ($required in @(
            "'PreInstall'", "'InstalledVault'", "'Disabled'", "'Enabled'", 'ExpectedCommit',
            '22.23.1', '24.18.0', '2.1.211', 'standard-user', 'OneDrive', 'verify-integrity', '-DryRun'
        )) {
            Assert-True ($source.Contains($required)) ('Acceptance verifier contract is missing: ' + $required)
        }
        foreach ($requiredRule in @('Read(//**/', 'Edit(//**/', 'Read(//**/.env)', 'Edit(//**/.env)')) {
            Assert-True ($source.Contains($requiredRule)) ('Acceptance verifier permission contract is missing: ' + $requiredRule)
        }
        Assert-True (-not $source.Contains("'Read(/' + [char]::ConvertFromUtf32")) `
            'Acceptance verifier still constructs a working-directory-relative private read rule'
        Assert-True ($source.Contains("ValidatePattern('^[a-f0-9]{40}$')")) 'Acceptance commit must be a full lowercase SHA'
        Assert-True (-not ($source -match 'Start-Process|Read-Host|Remove-Item|Invoke-Expression|Invoke-WebRequest|\biex\b')) 'Acceptance verifier contains a mutating or unsafe primitive'
        Assert-True ($setupSource.Contains('--version $package.Version') -and $setupSource.Contains('--source winget')) 'Prerequisite versions or source are not pinned'
        Assert-True ($setupSource.Contains("Version = '24.18.0'") -and $setupSource.Contains("Version = '1.12.7'")) 'Reviewed package versions are missing'

        $errors = $null
        $tokens = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($acceptancePath, [ref]$tokens, [ref]$errors)
        Assert-Equal $errors.Count 0 'Acceptance verifier cannot be parsed'
        $actual = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath } | Sort-Object)
        $expected = @('Mode', 'VaultPath', 'ExpectedCommit', 'ExpectedOrigin', 'Hooks', 'RequireClaude', 'Json') | Sort-Object
        Assert-Equal ($actual -join ',') ($expected -join ',') 'Acceptance verifier parameter contract changed'

        # A pending gate must stay non-passing: it is excluded from Passed and it must
        # still produce a nonzero exit, otherwise an unreached gate could read as verified.
        Assert-True ($source.Contains('Pending = $pending.Count')) 'Pending gates are not reported'
        Assert-True ($source.Contains('$passed = $script:Results.Count - $failures.Count - $pending.Count')) `
            'Pending gates are counted as passed'
        Assert-True ($source.Contains('if ($pending.Count -gt 0) { exit 2 }')) 'A pending acceptance run exits successfully'
        Assert-True ($source.Contains("[regex]::Escape(`$ExpectedOrigin)")) 'Expected origin is not matched as a literal'
        Assert-True (-not ($source -match "github\\\.com\[:/\]umutyalcin-pen")) 'Acceptance verifier still hardcodes the origin'
    }

    Test-Case 'GitHub Actions least-privilege policy' {
        $workflow = [IO.File]::ReadAllText($workflowPath, [Text.Encoding]::UTF8)
        Assert-True ($workflow.Contains('pull_request:')) 'pull_request trigger is missing'
        Assert-True (-not $workflow.Contains('pull_request_target')) 'Unsafe pull_request_target trigger is present'
        Assert-True ($workflow.Contains('permissions:') -and $workflow.Contains('contents: read')) 'Read-only permissions are missing'
        Assert-True (-not ($workflow -match '(?m)^\s+[A-Za-z-]+:\s+write\s*$')) 'Write permission is present'
        Assert-True ($workflow.Contains('persist-credentials: false')) 'Checkout credentials are persisted'
        Assert-True ($workflow.Contains('timeout-minutes: 15')) 'Job timeout is missing'
        Assert-True ($workflow.Contains('shell: powershell') -and $workflow.Contains('shell: pwsh')) 'PowerShell matrix is incomplete'
        Assert-True (-not $workflow.Contains('shell: ${{ matrix.shell }}')) 'Dynamic matrix context is not valid in a step shell field'
        Assert-True ($workflow.Contains('node: 22.23.1') -and $workflow.Contains('node: 24.18.0')) 'Pinned Node LTS matrix is incomplete'
        Assert-True (-not $workflow.Contains('check-latest: true')) 'Moving Node.js patch selection is enabled'
        $uses = [regex]::Matches($workflow, 'uses:\s+[^@\s]+@([a-f0-9]{40})')
        Assert-Equal $uses.Count 2 'Every external action must use a full commit SHA'
    }
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:Path = $originalPath
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        [IO.Directory]::Delete($testRoot, $true)
    }
}

Write-Host ''
Write-Host ('Passed: ' + $script:Passed)
Write-Host ('Failed: ' + $script:Failures.Count)
foreach ($failure in $script:Failures) { Write-Host ('  - ' + $failure) -ForegroundColor Red }
if ($script:Failures.Count -gt 0) { exit 1 }
