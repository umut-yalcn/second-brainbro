[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('PreInstall', 'InstalledVault')]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [string]$VaultPath,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-f0-9]{40}$')]
    [string]$ExpectedCommit,

    # Forks and review mirrors legitimately use a different origin. The value is an
    # exact owner/repository slug, never a substring, so a look-alike remote still fails.
    [ValidatePattern('^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?/[A-Za-z0-9._-]+$')]
    [string]$ExpectedOrigin = 'umutyalcin-pen/second-brainbro',

    [ValidateSet('Disabled', 'Enabled')]
    [string]$Hooks = 'Disabled',

    [switch]$RequireClaude,
    [switch]$Json
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Results = New-Object System.Collections.Generic.List[object]
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$setupPath = Join-Path $repoRoot 'setup.ps1'
$requestedVaultPath = $VaultPath
$target = [IO.Path]::GetFullPath($VaultPath)
$script:NodeExecutable = $null

function Add-GateResult {
    param([string]$Id, [string]$Status, [string]$Evidence)
    $script:Results.Add([pscustomobject]@{ Id = $Id; Status = $Status; Evidence = $Evidence })
}

function Invoke-Gate {
    param([string]$Id, [scriptblock]$Body, [scriptblock]$PendingIf)
    try {
        $evidence = @(& $Body) -join '; '
        if ([string]::IsNullOrWhiteSpace($evidence)) { $evidence = 'verified' }
        Add-GateResult -Id $Id -Status 'PASS' -Evidence $evidence
    } catch {
        $message = $_.Exception.Message
        # A gate blocked by a documented later acceptance step is recorded as PENDING,
        # never as PASS. PENDING keeps the run non-passing; it only separates "this step
        # has not happened yet" from "this control is broken".
        if ($PSBoundParameters.ContainsKey('PendingIf') -and (& $PendingIf $message)) {
            Add-GateResult -Id $Id -Status 'PENDING' -Evidence $message
            return
        }
        Add-GateResult -Id $Id -Status 'FAIL' -Evidence $message
    }
}

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$GitArguments)
    $output = @(& git -C $repoRoot @GitArguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw ('git failed: ' + ($output -join '; ')) }
    return ($output -join "`n").Trim()
}

function Test-SupportedNodeVersion {
    param([Parameter(Mandatory = $true)][string]$VersionText)
    if ($VersionText -notmatch '^v?(\d+)\.(\d+)\.(\d+)$') { return $false }
    $version = New-Object Version ([int]$Matches[1]), ([int]$Matches[2]), ([int]$Matches[3])
    if ($version.Major -eq 22) { return $version -ge [version]'22.23.1' }
    if ($version.Major -eq 24) { return $version -ge [version]'24.18.0' }
    return $false
}

function Test-SupportedObsidianVersion {
    param([Parameter(Mandatory = $true)][string]$VersionText)
    if ($VersionText -notmatch '^(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?(?:[-+].*)?$') { return $false }
    $revision = if ([string]::IsNullOrWhiteSpace($Matches[4])) { 0 } else { [int]$Matches[4] }
    $version = New-Object Version ([int]$Matches[1]), ([int]$Matches[2]), ([int]$Matches[3]), $revision
    return $version.Major -eq 1 -and $version -ge [version]'1.12.7.0'
}

function Test-SupportedClaudeVersion {
    param([Parameter(Mandatory = $true)][string]$VersionText)
    if ($VersionText -notmatch '(?m)^(\d+)\.(\d+)\.(\d+)(?:[-+\s]|$)') { return $false }
    $version = New-Object Version ([int]$Matches[1]), ([int]$Matches[2]), ([int]$Matches[3])
    return $version -ge [version]'2.1.211'
}

function Get-TrustedObsidianMetadata {
    $candidates = @()
    if ($env:LOCALAPPDATA) {
        $candidates += Join-Path $env:LOCALAPPDATA 'Programs\Obsidian\Obsidian.exe'
        $candidates += Join-Path $env:LOCALAPPDATA 'Obsidian\Obsidian.exe'
    }
    if ($env:ProgramFiles) { $candidates += Join-Path $env:ProgramFiles 'Obsidian\Obsidian.exe' }
    $problems = @()
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            $item = Get-Item -LiteralPath $candidate -Force
            if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                throw 'not a normal file'
            }
            $cursor = Get-Item -LiteralPath ([IO.Path]::GetDirectoryName($item.FullName)) -Force
            while ($null -ne $cursor) {
                if (($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw ('reparse-point executable ancestor ' + $cursor.FullName)
                }
                $cursor = $cursor.Parent
            }
            $versionText = [string]$item.VersionInfo.ProductVersion
            if (-not (Test-SupportedObsidianVersion -VersionText $versionText)) {
                throw ('unsupported version ' + $versionText)
            }
            if (-not [string]::Equals([string]$item.VersionInfo.ProductName, 'Obsidian', [StringComparison]::OrdinalIgnoreCase) -or
                -not [string]::Equals([string]$item.VersionInfo.CompanyName, 'Obsidian', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'unexpected executable metadata'
            }
            $signature = Get-AuthenticodeSignature -LiteralPath $candidate
            $subject = if ($signature.SignerCertificate) { [string]$signature.SignerCertificate.Subject } else { '' }
            if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
                $subject -notmatch '(?:^|,\s)(?:CN|O)=Dynalist Inc(?:,|$)') {
                throw ('untrusted Authenticode publisher ' + [string]$signature.Status)
            }
            return [pscustomobject]@{
                Path = [IO.Path]::GetFullPath($item.FullName)
                Version = $versionText
                Publisher = 'Dynalist Inc'
            }
        } catch {
            $problems += ([IO.Path]::GetFullPath($candidate) + ': ' + $_.Exception.Message)
        }
    }
    if ($problems.Count) { throw ($problems -join '; ') }
    throw 'Obsidian is absent from supported locations.'
}

function Assert-LocalTargetStorage {
    param([Parameter(Mandatory = $true)][string]$Path, [bool]$MustExist)
    if (-not [IO.Path]::IsPathRooted($Path) -or $Path.StartsWith('\\')) {
        throw 'VaultPath must be an absolute local path.'
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($MustExist -and -not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        throw ('Installed vault is absent: ' + $fullPath)
    }
    if (-not $MustExist -and (Test-Path -LiteralPath $fullPath)) {
        throw ('Pre-install target already exists: ' + $fullPath)
    }
    $existing = if ($MustExist) { $fullPath } else { [IO.Path]::GetDirectoryName($fullPath) }
    if (-not (Test-Path -LiteralPath $existing -PathType Container)) {
        throw ('Target parent is absent: ' + $existing)
    }
    $cursor = Get-Item -LiteralPath $existing -Force
    while ($null -ne $cursor) {
        if (($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw ('Reparse-point ancestor is unsupported: ' + $cursor.FullName)
        }
        $cursor = $cursor.Parent
    }
    $root = [IO.Path]::GetPathRoot($fullPath)
    $disk = New-Object IO.DriveInfo $root
    if ($disk.DriveType -ne [IO.DriveType]::Fixed -or [string]$disk.DriveFormat -ne 'NTFS') {
        throw 'VaultPath is not on a local fixed NTFS volume.'
    }
    foreach ($oneDrive in @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer)) {
        if ([string]::IsNullOrWhiteSpace($oneDrive)) { continue }
        $cloudRoot = [IO.Path]::GetFullPath($oneDrive).TrimEnd('\')
        if ($fullPath.Equals($cloudRoot, [StringComparison]::OrdinalIgnoreCase) -or
            $fullPath.StartsWith($cloudRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw ('OneDrive-hosted vault is unsupported: ' + $fullPath)
        }
    }
    return ($disk.Name + ' ' + $disk.DriveFormat + ' fixed')
}

Invoke-Gate 'host.windows11' {
    $currentVersion = Get-ItemProperty -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = [int]$currentVersion.CurrentBuildNumber
    if ([string]$currentVersion.InstallationType -ne 'Client' -or $build -lt 22000) {
        throw ('Windows 11 client is required; detected build ' + $build + ' type ' + [string]$currentVersion.InstallationType)
    }
    return ('Windows 11 ' + [string]$currentVersion.DisplayVersion + ' build ' + $build)
}

Invoke-Gate 'host.standard-user' {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Acceptance must run from a non-elevated standard-user shell.'
    }
    return 'non-elevated standard-user token'
}

Invoke-Gate 'source.reviewed-commit' {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git is unavailable.' }
    $head = Invoke-Git -GitArguments @('rev-parse', 'HEAD')
    if ($head -ne $ExpectedCommit) { throw ('HEAD mismatch: ' + $head) }
    $origin = Invoke-Git -GitArguments @('remote', 'get-url', 'origin')
    $originPattern = '(?i)github\.com[:/]' + [regex]::Escape($ExpectedOrigin) + '(?:\.git)?$'
    if ($origin -notmatch $originPattern) {
        throw ('Unexpected origin: ' + $origin + '; expected ' + $ExpectedOrigin)
    }
    return ('HEAD ' + $head)
}

Invoke-Gate 'source.clean-checkout' {
    $status = Invoke-Git -GitArguments @('status', '--porcelain=v1', '--untracked-files=all')
    if (-not [string]::IsNullOrEmpty($status)) { throw 'Reviewed checkout has local changes.' }
    return 'clean tracked and untracked state'
}

Invoke-Gate 'runtime.powershell' {
    if ($PSVersionTable.PSVersion -lt [version]'5.1') { throw 'PowerShell 5.1 or later is required.' }
    return ('PowerShell ' + $PSVersionTable.PSVersion.ToString())
}

Invoke-Gate 'runtime.node' {
    $node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $node) {
        throw 'Node.js is unavailable.'
    }
    $script:NodeExecutable = $node.Path
    $version = ([string](& $script:NodeExecutable --version 2>$null)).Trim()
    if ($LASTEXITCODE -ne 0 -or -not (Test-SupportedNodeVersion $version)) {
        throw ('Unsupported Node.js: ' + $version)
    }
    return $version
}

Invoke-Gate 'runtime.obsidian' {
    $obsidian = Get-TrustedObsidianMetadata
    return ($obsidian.Path + ' version ' + $obsidian.Version + ' publisher ' + $obsidian.Publisher)
}

Invoke-Gate 'runtime.claude' {
    $claude = Get-Command claude -CommandType Application,ExternalScript -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($RequireClaude -and $null -eq $claude) { throw 'Claude Code is required for this acceptance run.' }
    if ($null -eq $claude) { return 'not required for this run' }
    $version = @(& $claude.Source --version 2>$null) -join ' '
    if ($LASTEXITCODE -ne 0) { throw 'Claude Code version check failed.' }
    if ($RequireClaude -and -not (Test-SupportedClaudeVersion -VersionText $version.Trim())) {
        throw ('Claude Code 2.1.211 or newer is required: ' + $version.Trim())
    }
    return $version.Trim()
}

Invoke-Gate 'storage.local-fixed-ntfs' {
    return Assert-LocalTargetStorage -Path $requestedVaultPath -MustExist ($Mode -eq 'InstalledVault')
}

if ($Mode -eq 'PreInstall') {
    Invoke-Gate 'host.winget' {
        $winget = Get-Command winget -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $winget) { throw 'WinGet is unavailable.' }
        $version = @(& $winget.Source --version 2>$null) -join ' '
        if ($LASTEXITCODE -ne 0) { throw 'WinGet version check failed.' }
        return $version.Trim()
    }
    Invoke-Gate 'installer.dry-run' {
        $output = @(& $setupPath -VaultPath $target -OsName 'AcceptanceOS' -UserName 'Acceptance User' `
            -UserBio 'Synthetic clean-machine acceptance data' -Companion 'Guide' -Hooks $Hooks `
            -OptionalArea Goals,Private -Today '2030-01-02' -InstallPrerequisites -DryRun *>&1) -join "`n"
        if ($output -notmatch 'Dry-run complete') { throw ('Dry-run completion marker is absent. ' + $output) }
        if (Test-Path -LiteralPath $target) { throw 'Dry-run created the target.' }
        return 'canonical plan verified; target remains absent'
    }
} else {
    Invoke-Gate 'vault.required-files' {
        $dashboard = [char]::ConvertFromUtf32(0x1F3AF) + ' 100-Command-Center\Dashboard.md'
        foreach ($relative in @('CLAUDE.md', $dashboard, 'Open-SecondBrain.ps1', '.claude\hook-manifest.json', '.claude\settings.permissions.example.json')) {
            if (-not (Test-Path -LiteralPath (Join-Path $target $relative) -PathType Leaf)) {
                throw ('Installed file is absent: ' + $relative)
            }
        }
        return 'required installed files present'
    }
    Invoke-Gate 'vault.private-acl' {
        $security = Get-Acl -LiteralPath $target
        if (-not $security.AreAccessRulesProtected) { throw 'Vault ACL inheritance is not protected.' }
        $allowed = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')
        if ($security.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $allowed[0]) {
            throw 'Vault ACL owner is not the current user.'
        }
        $unexpected = @($security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object {
            $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $allowed -notcontains $_.IdentityReference.Value
        })
        if ($unexpected.Count -gt 0) { throw ('Unexpected vault ACL principal: ' + $unexpected[0].IdentityReference.Value) }
        return 'protected ACL; user, SYSTEM, and Administrators only'
    }
    Invoke-Gate 'vault.no-installer-markers' {
        $problems = @()
        foreach ($file in Get-ChildItem -LiteralPath $target -Recurse -File) {
            if (@('.md', '.json', '.ps1', '.mjs') -notcontains $file.Extension.ToLowerInvariant()) { continue }
            $text = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
            if ($text -match '\{\{[^}]*\}\}|SECOND_BRAINBRO_OPTIONAL_NAVIGATION|<!-- SETUP:') {
                $problems += $file.FullName
            }
        }
        if ($problems.Count -gt 0) { throw ('Installer marker remains: ' + ($problems -join ', ')) }
        return 'personalization and optional navigation complete'
    }
    Invoke-Gate 'vault.hook-mode' {
        $localSettings = Join-Path $target '.claude\settings.local.json'
        $trackedSettings = Join-Path $target '.claude\settings.json'
        if (Test-Path -LiteralPath $trackedSettings) { throw 'Tracked project settings are present.' }
        if (-not (Test-Path -LiteralPath $localSettings -PathType Leaf)) { throw 'Local restrictive permission settings are absent.' }
        if ($Hooks -eq 'Enabled') {
            $hook = Join-Path $target '.claude\hooks\hooks.mjs'
            $output = @(& $script:NodeExecutable $hook verify-integrity 2>&1) -join "`n"
            if ($LASTEXITCODE -ne 0) { throw ('Hook integrity failed: ' + $output) }
            return 'local settings present; manifest integrity verified'
        }
        $settings = [IO.File]::ReadAllText($localSettings, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($settings.PSObject.Properties.Name -contains 'hooks') { throw 'Hooks were activated in a disabled-mode vault.' }
        $privateReadRule = 'Read(//**/' + [char]::ConvertFromUtf32(0x1F510) + ' 400-Vault/**)'
        $privateEditRule = 'Edit(//**/' + [char]::ConvertFromUtf32(0x1F510) + ' 400-Vault/**)'
        foreach ($rule in @('Bash', 'PowerShell', $privateReadRule, $privateEditRule, 'Read(//**/.env)', 'Edit(//**/.env)')) {
            if ($settings.permissions.deny -notcontains $rule) { throw ('Restrictive permission rule is absent: ' + $rule) }
        }
        return 'restrictive local permissions present; hooks remain disabled'
    }
    Invoke-Gate 'launcher.dry-run' {
        $launcher = Join-Path $target 'Open-SecondBrain.ps1'
        $output = @(& $launcher -DryRun -Claude:$RequireClaude.IsPresent *>&1) -join "`n"
        if ($output -notmatch 'Dry-run complete') { throw ('Launcher dry-run marker is absent. ' + $output) }
        return 'validated without starting Obsidian or Claude'
    } -PendingIf {
        param([string]$Message)
        # ACCEPTANCE.md Gate C initializes the Obsidian vault marker after the first
        # installed-vault run, so an absent .obsidian means this gate has not been
        # reached yet. Both the launcher's own reason and the missing marker must agree;
        # any other launcher failure stays FAIL.
        $Message -match 'not initialized this folder as a vault' -and
            -not (Test-Path -LiteralPath (Join-Path $target '.obsidian') -PathType Container)
    }
}

$failures = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
$pending = @($script:Results | Where-Object { $_.Status -eq 'PENDING' })
$passed = $script:Results.Count - $failures.Count - $pending.Count
if ($Json) {
    [pscustomobject]@{
        SchemaVersion = 2
        Mode = $Mode
        ExpectedCommit = $ExpectedCommit
        ExpectedOrigin = $ExpectedOrigin
        Passed = $passed
        Failed = $failures.Count
        Pending = $pending.Count
        Results = $script:Results.ToArray()
    } | ConvertTo-Json -Depth 5
} else {
    $script:Results | Format-Table Id, Status, Evidence -AutoSize | Out-String | Write-Host
    Write-Host ('Passed: ' + $passed)
    Write-Host ('Failed: ' + $failures.Count)
    Write-Host ('Pending: ' + $pending.Count)
}
# Exit 1 is a defect, exit 2 is an incomplete run. Both are non-passing; only 0 is an
# acceptance pass, so no caller can read a pending gate as a satisfied one.
if ($failures.Count -gt 0) { exit 1 }
if ($pending.Count -gt 0) { exit 2 }
