[CmdletBinding()]
param(
    [switch]$Claude,
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { return $full.TrimEnd([IO.Path]::DirectorySeparatorChar) }
    return $full
}

function Assert-NormalFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw ('Unsafe launcher marker file: ' + $Path)
    }
}

function Assert-NormalDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw ('Unsafe vault directory: ' + $Path)
    }
}

function Assert-NoReparseAncestor {
    param([Parameter(Mandatory = $true)][string]$Path)
    $cursor = Get-Item -LiteralPath $Path -Force
    while ($null -ne $cursor) {
        if (($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw ('Reparse point, junction, or symbolic-link path is unsupported: ' + $cursor.FullName)
        }
        $cursor = $cursor.Parent
    }
}

function Assert-LocalNtfs {
    param([Parameter(Mandatory = $true)][string]$Path)
    $root = [IO.Path]::GetPathRoot($Path)
    if ([string]::IsNullOrWhiteSpace($root) -or $root.StartsWith('\\')) {
        throw ('UNC and network vaults are unsupported: ' + $Path)
    }
    $disk = New-Object IO.DriveInfo $root
    if ($disk.DriveType -ne [IO.DriveType]::Fixed -or
        -not [string]::Equals([string]$disk.DriveFormat, 'NTFS', [StringComparison]::OrdinalIgnoreCase)) {
        throw ('Vault must be on a local fixed NTFS volume: ' + $Path)
    }
}

function Assert-NotOneDrive {
    param([Parameter(Mandatory = $true)][string]$Path)
    $candidate = Get-FullPath -Path $Path
    $roots = @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
    foreach ($root in $roots) {
        $rootFull = Get-FullPath -Path $root
        if ([string]::Equals($candidate, $rootFull, [StringComparison]::OrdinalIgnoreCase) -or
            $candidate.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw ('OneDrive-hosted vaults are unsupported: ' + $candidate)
        }
    }
}

function ConvertTo-PsLiteral {
    param([Parameter(Mandatory = $true)][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Test-SupportedObsidianVersion {
    param([Parameter(Mandatory = $true)][string]$VersionText)

    if ($VersionText -notmatch '^(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?(?:[-+].*)?$') { return $false }
    $revision = if ([string]::IsNullOrWhiteSpace($Matches[4])) { 0 } else { [int]$Matches[4] }
    $version = New-Object Version ([int]$Matches[1]), ([int]$Matches[2]), ([int]$Matches[3]), $revision
    return $version.Major -eq 1 -and $version -ge [version]'1.12.7.0'
}

function Get-TrustedObsidianMetadata {
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-NormalFile -Path $Path
    Assert-NoReparseAncestor -Path ([IO.Path]::GetDirectoryName($Path))
    $item = Get-Item -LiteralPath $Path -Force
    $versionText = [string]$item.VersionInfo.ProductVersion
    if (-not (Test-SupportedObsidianVersion -VersionText $versionText)) {
        throw ('Obsidian 1.x version 1.12.7 or newer is required. Detected: ' + $versionText)
    }
    if (-not [string]::Equals([string]$item.VersionInfo.ProductName, 'Obsidian', [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$item.VersionInfo.CompanyName, 'Obsidian', [StringComparison]::OrdinalIgnoreCase)) {
        throw ('Unexpected Obsidian executable metadata: ' + $Path)
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $subject = if ($signature.SignerCertificate) { [string]$signature.SignerCertificate.Subject } else { '' }
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
        $subject -notmatch '(?:^|,\s)(?:CN|O)=Dynalist Inc(?:,|$)') {
        throw ('Obsidian Authenticode publisher is not trusted: ' + [string]$signature.Status)
    }
    return [pscustomobject]@{
        Path = Get-FullPath -Path $item.FullName
        Version = $versionText
        Publisher = 'Dynalist Inc'
    }
}

function Resolve-ObsidianExecutable {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$CandidatePaths,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RegisteredCommand
    )

    $existing = @()
    foreach ($candidate in $CandidatePaths) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or
            -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }

        $path = Get-FullPath -Path $candidate
        $existing += $path
        $expectedCommand = '"' + $path + '" "%1"'
        if ([string]::Equals($RegisteredCommand.Trim(), $expectedCommand, [StringComparison]::OrdinalIgnoreCase)) {
            return Get-TrustedObsidianMetadata -Path $path
        }
    }

    if ($existing.Count -eq 0) {
        throw ('Obsidian executable was not found in a supported location: ' + ($CandidatePaths -join ', '))
    }
    throw ('The obsidian:// protocol handler does not match a supported Obsidian executable: ' + $RegisteredCommand)
}

function Resolve-ClaudeCommand {
    $command = Get-Command claude -CommandType Application,ExternalScript -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $command -or [string]::IsNullOrWhiteSpace($command.Path)) {
        throw 'Claude Code command was not found on PATH.'
    }
    $path = Get-FullPath -Path $command.Path
    Assert-NormalFile -Path $path
    Assert-NoReparseAncestor -Path ([IO.Path]::GetDirectoryName($path))
    $extension = [IO.Path]::GetExtension($path).ToLowerInvariant()
    if (@('.exe', '.com', '.cmd', '.bat', '.ps1') -notcontains $extension) {
        throw ('Unsupported Claude command type: ' + $path)
    }
    return $path
}

function Test-SupportedClaudeVersion {
    param([Parameter(Mandatory = $true)][string]$VersionText)

    if ($VersionText -notmatch '(?m)^(\d+)\.(\d+)\.(\d+)(?:[-+\s]|$)') { return $false }
    $version = New-Object Version ([int]$Matches[1]), ([int]$Matches[2]), ([int]$Matches[3])
    return $version -ge [version]'2.1.211'
}

function Get-ValidatedClaudeVersion {
    param([Parameter(Mandatory = $true)][string]$Path)

    $output = @(& $Path --version 2>&1) -join ' '
    if ($LASTEXITCODE -ne 0 -or -not (Test-SupportedClaudeVersion -VersionText $output.Trim())) {
        throw ('Claude Code 2.1.211 or newer is required. Detected: ' + $output.Trim())
    }
    if ($output -match '(?m)^(\d+\.\d+\.\d+)') { return $Matches[1] }
    throw 'Claude Code version output could not be parsed.'
}

function Resolve-PowerShellHost {
    param(
        [Parameter(Mandatory = $true)][string]$PowerShellHome,
        [Parameter(Mandatory = $true)][ValidateSet('Desktop', 'Core')][string]$Edition
    )
    $executableName = if ($Edition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $path = Get-FullPath -Path (Join-Path $PowerShellHome $executableName)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw ('The expected PowerShell host is missing: ' + $path)
    }
    Assert-NormalFile -Path $path
    Assert-NoReparseAncestor -Path ([IO.Path]::GetDirectoryName($path))
    return $path
}

$vault = Get-FullPath -Path $PSScriptRoot
Assert-NoReparseAncestor -Path $vault
Assert-LocalNtfs -Path $vault
Assert-NotOneDrive -Path $vault

$targetEmoji = [char]::ConvertFromUtf32(0x1F3AF)
$dashboard = Join-Path $vault ($targetEmoji + ' 100-Command-Center\Dashboard.md')
$required = @(
    (Join-Path $vault 'CLAUDE.md'),
    $dashboard,
    (Join-Path $vault '.claude\hook-manifest.json'),
    (Join-Path $vault '.claude\hooks\hooks.mjs')
)
foreach ($marker in $required) {
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        throw ('This directory is not a complete second-brainbro vault; missing: ' + $marker)
    }
    Assert-NormalFile -Path $marker
}

$obsidianVaultConfig = Join-Path $vault '.obsidian'
if (-not (Test-Path -LiteralPath $obsidianVaultConfig -PathType Container)) {
    throw ('Obsidian has not initialized this folder as a vault. In Obsidian choose "Open folder as vault", select: ' + $vault)
}
Assert-NormalDirectory -Path $obsidianVaultConfig
Assert-NoReparseAncestor -Path $obsidianVaultConfig

$encodedDashboard = [Uri]::EscapeDataString($dashboard.Replace('\', '/'))
$obsidianUri = 'obsidian://open?path=' + $encodedDashboard
$obsidianProtocolKey = 'Registry::HKEY_CLASSES_ROOT\obsidian\shell\open\command'
if (-not (Test-Path -LiteralPath $obsidianProtocolKey)) {
    throw 'The obsidian:// protocol is not registered. Start Obsidian once, then retry.'
}
$registeredCommand = [string](Get-Item -LiteralPath $obsidianProtocolKey).GetValue('')
$obsidianCandidates = @()
if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    $obsidianCandidates += Join-Path $env:LOCALAPPDATA 'Programs\Obsidian\Obsidian.exe'
    $obsidianCandidates += Join-Path $env:LOCALAPPDATA 'Obsidian\Obsidian.exe'
}
if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
    $obsidianCandidates += Join-Path $env:ProgramFiles 'Obsidian\Obsidian.exe'
}
$obsidian = Resolve-ObsidianExecutable `
    -CandidatePaths @($obsidianCandidates | Select-Object -Unique) `
    -RegisteredCommand $registeredCommand
$obsidianExe = $obsidian.Path

$claudePath = $null
$encodedClaudeCommand = $null
$claudeVersion = $null
if ($Claude) {
    $claudePath = Resolve-ClaudeCommand
    $commandText = 'Set-Location -LiteralPath ' + (ConvertTo-PsLiteral -Value $vault) +
        '; & ' + (ConvertTo-PsLiteral -Value $claudePath)
    $encodedClaudeCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($commandText))
}

Write-Host '[second-brainbro] Validated launch plan'
Write-Host ('  Vault: ' + $vault)
Write-Host ('  Dashboard: ' + $dashboard)
Write-Host ('  Obsidian: ' + $obsidianExe)
Write-Host ('  Obsidian version/publisher: ' + $obsidian.Version + ' / ' + $obsidian.Publisher)
Write-Host ('  Claude: ' + $(if ($Claude) { $claudePath } else { 'disabled' }))
Write-Host ('  Claude version: ' + $(if ($Claude) { 'checked after explicit consent; requires 2.1.211+' } else { 'not applicable' }))
Write-Host '  Shell interpolation: none; Claude command is encoded after literal-path validation'

if ($DryRun) {
    Write-Host '[second-brainbro] Dry-run complete. No process was started.'
    [pscustomobject]@{
        VaultPath = $vault
        DashboardPath = $dashboard
        ObsidianUri = $obsidianUri
        ObsidianPath = $obsidianExe
        ObsidianVersion = $obsidian.Version
        ObsidianPublisher = $obsidian.Publisher
        ClaudeRequested = [bool]$Claude
        ClaudePath = $claudePath
        ClaudeVersion = 'not probed in dry-run'
        ProcessesStarted = 0
    }
    return
}

if ($Claude) {
    Write-Host ''
    Write-Host 'Claude Code is a networked AI client. Vault content added to its context may leave this device.'
    $answer = Read-Host 'Type CLAUDE to authorize starting Claude Code in this vault'
    if ($answer -cne 'CLAUDE') { throw 'Claude Code launch was not authorized; no process was started.' }
    $claudeVersion = Get-ValidatedClaudeVersion -Path $claudePath
    Write-Host ('[second-brainbro] Validated Claude Code version: ' + $claudeVersion)
}

Start-Process -FilePath $obsidianExe -ArgumentList $obsidianUri
if ($Claude) {
    $powerShellExe = Resolve-PowerShellHost -PowerShellHome $PSHOME -Edition $PSEdition
    Start-Process -FilePath $powerShellExe -WorkingDirectory $vault `
        -ArgumentList ('-NoExit -NoProfile -EncodedCommand ' + $encodedClaudeCommand)
}

[pscustomobject]@{
    VaultPath = $vault
    DashboardOpened = $true
    ClaudeStarted = [bool]$Claude
    ClaudeVersion = $claudeVersion
}
