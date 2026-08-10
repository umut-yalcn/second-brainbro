[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VaultPath,

    [Parameter(Mandatory = $true)]
    [string]$OsName,

    [Parameter(Mandatory = $true)]
    [string]$UserName,

    [Parameter(Mandatory = $true)]
    [string]$UserBio,

    [Parameter(Mandatory = $true)]
    [string]$Companion,

    [ValidateSet('Disabled', 'Enabled')]
    [string]$Hooks = 'Disabled',

    [ValidateSet('Goals', 'Private', 'Body', 'Mind')]
    [string[]]$OptionalArea = @(),

    [switch]$InstallPrerequisites,
    [switch]$DryRun,

    [ValidatePattern('^\d{4}-\d{2}-\d{2}$')]
    [string]$Today = (Get-Date -Format 'yyyy-MM-dd')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host ('[second-brainbro] ' + $Message)
}

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) {
        return $full.TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    }
    return $full
}

function Test-PathInside {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$AllowEqual
    )

    $candidateFull = Get-FullPath -Path $Candidate
    $rootFull = Get-FullPath -Path $Root
    if ($AllowEqual -and [string]::Equals($candidateFull, $rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    return $candidateFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-SafeLeafName {
    param([Parameter(Mandatory = $true)][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -eq '.' -or $Name -eq '..') {
        throw 'Target directory name is empty or unsafe.'
    }
    if ($Name.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $Name -match '[ .]$') {
        throw ('Target directory name is not valid on Windows: ' + $Name)
    }
    if ($Name -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') {
        throw ('Windows reserved device name is not allowed: ' + $Name)
    }
}

function Assert-NoReparseAncestor {
    param([Parameter(Mandatory = $true)][string]$ExistingPath)

    $cursor = Get-Item -LiteralPath $ExistingPath -Force
    while ($null -ne $cursor) {
        if (($cursor.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw ('Reparse point, junction, or symbolic-link ancestor is unsupported: ' + $cursor.FullName)
        }
        $cursor = $cursor.Parent
    }
}

function Get-LocalVolumeInfo {
    param([Parameter(Mandatory = $true)][string]$Path)

    $root = [System.IO.Path]::GetPathRoot($Path)
    if ([string]::IsNullOrWhiteSpace($root) -or $root.StartsWith('\\')) {
        throw ('UNC and network paths are unsupported: ' + $Path)
    }
    $disk = New-Object System.IO.DriveInfo $root
    if ($disk.DriveType -ne [System.IO.DriveType]::Fixed) {
        throw ('Target must be on a local fixed drive: ' + $Path)
    }
    if (-not [string]::Equals([string]$disk.DriveFormat, 'NTFS', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ('Target volume must use NTFS. Detected: ' + [string]$disk.DriveFormat)
    }
    return $disk
}

function Assert-SafeTarget {
    param([Parameter(Mandatory = $true)][string]$RequestedPath)

    if (-not [System.IO.Path]::IsPathRooted($RequestedPath)) {
        throw ('VaultPath must be absolute: ' + $RequestedPath)
    }
    if ($RequestedPath.StartsWith('\\')) {
        throw ('UNC and network paths are unsupported: ' + $RequestedPath)
    }

    $target = Get-FullPath -Path $RequestedPath
    $root = Get-FullPath -Path ([System.IO.Path]::GetPathRoot($target))
    if ([string]::Equals($target, $root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ('A drive root cannot be used as the vault: ' + $target)
    }

    Assert-SafeLeafName -Name ([System.IO.Path]::GetFileName($target))
    if (Test-Path -LiteralPath $target) {
        throw ('Target already exists; overwrite and merge are forbidden: ' + $target)
    }

    $parent = [System.IO.Path]::GetDirectoryName($target)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw ('Target parent must already exist: ' + $parent)
    }
    $parent = (Get-Item -LiteralPath $parent -Force).FullName
    Assert-NoReparseAncestor -ExistingPath $parent
    $null = Get-LocalVolumeInfo -Path $target

    $forbiddenExact = @($env:USERPROFILE)
    foreach ($forbidden in $forbiddenExact) {
        if ($forbidden -and [string]::Equals($target, (Get-FullPath -Path $forbidden), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw ('Protected root cannot be used as the vault: ' + $target)
        }
    }

    $forbiddenTrees = @($env:WINDIR, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)
    foreach ($forbidden in $forbiddenTrees) {
        if ($forbidden -and (Test-PathInside -Candidate $target -Root $forbidden -AllowEqual)) {
            throw ('System-managed location is forbidden: ' + $target)
        }
    }

    $oneDriveRoots = @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
    foreach ($oneDriveRoot in $oneDriveRoots) {
        if (Test-PathInside -Candidate $target -Root $oneDriveRoot -AllowEqual) {
            throw ('OneDrive-hosted vaults are unsupported: ' + $target)
        }
    }

    return $target
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

function Assert-PersonalizationInputs {
    param(
        [Parameter(Mandatory = $true)][string]$SystemName,
        [Parameter(Mandatory = $true)][string]$PersonName,
        [Parameter(Mandatory = $true)][string]$Biography,
        [Parameter(Mandatory = $true)][string]$CompanionName,
        [Parameter(Mandatory = $true)][string]$CreatedDate
    )

    # Built from code points, never written as literals: this file is BOM-less UTF-8 and
    # Windows PowerShell 5.1 decodes such a file with the ANSI code page. Written literally,
    # the Turkish letters below were corrupted on 5.1 and every Turkish name was rejected,
    # while PowerShell 7 accepted the same input. The set must stay identical to NAME_RE in
    # personalize.mjs, which validates the same values again on the Node side.
    $turkishLetters = -join (@(
        0x00C7, 0x011E, 0x0130, 0x00D6, 0x015E, 0x00DC,
        0x00E7, 0x011F, 0x0131, 0x00F6, 0x015F, 0x00FC
    ) | ForEach-Object { [char]$_ })
    $namePattern = '^[A-Za-z' + $turkishLetters + '0-9 .''_-]{1,64}$'
    foreach ($field in @(
        [pscustomobject]@{ Name = 'OsName'; Value = $SystemName },
        [pscustomobject]@{ Name = 'UserName'; Value = $PersonName },
        [pscustomobject]@{ Name = 'Companion'; Value = $CompanionName }
    )) {
        if ([string]::IsNullOrWhiteSpace($field.Value) -or $field.Value -notmatch $namePattern) {
            throw ($field.Name + ' must contain only reviewed name characters and be 1-64 characters long.')
        }
    }

    if ($SystemName -eq '.' -or $SystemName -eq '..' -or $SystemName -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$' -or
        $SystemName -match '[ .]$') {
        throw 'OsName is not a safe Windows name.'
    }
    if ([string]::IsNullOrEmpty($Biography) -or $Biography.Length -gt 500 -or
        $Biography.Contains("`r") -or $Biography.Contains("`n") -or
        $Biography.Contains('{{') -or $Biography.Contains('}}') -or
        $Biography.IndexOf([char]0x60) -ge 0 -or $Biography.Contains('$(')) {
        throw 'UserBio is empty, too long, multiline, or contains prohibited template/shell syntax.'
    }

    $parsedDate = [datetime]::MinValue
    if (-not [datetime]::TryParseExact(
        $CreatedDate,
        'yyyy-MM-dd',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None,
        [ref]$parsedDate
    )) {
        throw 'Today must be a valid calendar date in yyyy-MM-dd format.'
    }
}

function Get-TrustedObsidianMetadata {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw ('Obsidian executable is not a normal file: ' + $Path)
    }
    Assert-NoReparseAncestor -ExistingPath ([IO.Path]::GetDirectoryName($item.FullName))
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
        Path = [IO.Path]::GetFullPath($item.FullName)
        Version = $versionText
        Publisher = 'Dynalist Inc'
    }
}

function Get-PrerequisiteState {
    $nodeCommand = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $wingetCommand = Get-Command winget -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $nodeVersion = $null
    $nodeSupported = $false
    if ($nodeCommand) {
        $rawVersion = (& $nodeCommand.Path --version 2>$null)
        if ($LASTEXITCODE -eq 0) {
            $nodeVersion = $rawVersion
            $nodeSupported = Test-SupportedNodeVersion -VersionText ([string]$rawVersion).Trim()
        }
    }

    $obsidianCandidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $obsidianCandidates += Join-Path $env:LOCALAPPDATA 'Programs\Obsidian\Obsidian.exe'
        $obsidianCandidates += Join-Path $env:LOCALAPPDATA 'Obsidian\Obsidian.exe'
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $obsidianCandidates += Join-Path $env:ProgramFiles 'Obsidian\Obsidian.exe'
    }
    $obsidian = $null
    $obsidianProblems = @()
    foreach ($candidate in @($obsidianCandidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            $obsidian = Get-TrustedObsidianMetadata -Path $candidate
            break
        } catch {
            $obsidianProblems += $_.Exception.Message
        }
    }

    return [pscustomobject]@{
        NodeVersion = if ($nodeVersion) { [string]$nodeVersion } else { 'missing' }
        NodePath = if ($nodeCommand) { [string]$nodeCommand.Path } else { $null }
        NodeSupported = $nodeSupported
        ObsidianPath = if ($obsidian) { [string]$obsidian.Path } else { 'missing or untrusted' }
        ObsidianVersion = if ($obsidian) { [string]$obsidian.Version } else { 'missing' }
        ObsidianPublisher = if ($obsidian) { [string]$obsidian.Publisher } else { 'unverified' }
        ObsidianProblem = $obsidianProblems -join '; '
        ObsidianInstalled = [bool]$obsidian
        WinGetPath = if ($wingetCommand) { [string]$wingetCommand.Path } else { $null }
    }
}

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = $machinePath + [System.IO.Path]::PathSeparator + $userPath
}

function Install-MissingPrerequisites {
    param([Parameter(Mandatory = $true)]$State)

    if (-not $InstallPrerequisites) {
        if (-not $State.NodeSupported) { throw 'Patched Node.js 22 LTS (22.23.1+) or 24 LTS (24.18.0+) is required. Re-run with -InstallPrerequisites or install it manually.' }
        if (-not $State.ObsidianInstalled) { throw 'Obsidian is required. Re-run with -InstallPrerequisites or install it manually.' }
        return $State
    }
    $packages = @()
    if (-not $State.NodeSupported) {
        $packages += [pscustomobject]@{ Id = 'OpenJS.NodeJS.LTS'; Name = 'Node.js LTS'; Version = '24.18.0' }
    }
    if (-not $State.ObsidianInstalled) {
        $packages += [pscustomobject]@{ Id = 'Obsidian.Obsidian'; Name = 'Obsidian'; Version = '1.12.7' }
    }
    if ($packages.Count -gt 0 -and [string]::IsNullOrWhiteSpace($State.WinGetPath)) {
        throw 'WinGet is required for requested prerequisite installation.'
    }
    foreach ($package in $packages) {
        Write-Host ('Package install requested: ' + $package.Name + ' ' + $package.Version + ' [' + $package.Id + ']')
        $answer = Read-Host 'Type INSTALL to authorize this package change'
        if ($answer -cne 'INSTALL') { throw ('Package installation was not authorized: ' + $package.Name) }
        $packageOutput = @(& $State.WinGetPath install --id $package.Id -e --version $package.Version `
            --source winget --accept-source-agreements --accept-package-agreements 2>&1)
        $packageExitCode = $LASTEXITCODE
        foreach ($line in $packageOutput) { Write-Host ([string]$line) }
        if ($packageExitCode -ne 0) { throw ('WinGet installation failed: ' + $package.Id) }
        Refresh-ProcessPath
    }

    $verified = Get-PrerequisiteState
    if (-not $verified.NodeSupported) { throw 'A supported patched Node.js LTS is still unavailable after installation. Open a new terminal and retry.' }
    if (-not $verified.ObsidianInstalled) {
        throw ('Obsidian could not be verified after installation. ' + $verified.ObsidianProblem)
    }
    return $verified
}

function Assert-CleanTemplate {
    param([Parameter(Mandatory = $true)][string]$TemplatePath)

    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Container)) {
        throw ('Template directory is missing: ' + $TemplatePath)
    }
    $templateItem = Get-Item -LiteralPath $TemplatePath -Force
    if (($templateItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw ('Template directory cannot be a reparse point: ' + $TemplatePath)
    }
    $reparseItems = Get-ChildItem -LiteralPath $TemplatePath -Force -Recurse |
        Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 }
    if ($reparseItems) {
        throw ('Template contains a reparse point: ' + ($reparseItems | Select-Object -First 1).FullName)
    }
    if (Test-Path -LiteralPath (Join-Path $TemplatePath '.second-brainbro-installer-owner')) {
        throw 'Template contains the installer-reserved ownership marker.'
    }

    $required = @(
        'CLAUDE.md',
        'Open-SecondBrain.ps1',
        '.claude\hook-manifest.json',
        '.claude\settings.permissions.example.json',
        '.claude\settings.hooks.example.json',
        '.claude\hooks\hooks.mjs'
    )
    foreach ($relative in $required) {
        $full = Join-Path $TemplatePath $relative
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw ('Template marker is missing: ' + $relative)
        }
    }
}

function Get-OptionalFolderMap {
    $sword = [char]::ConvertFromUtf32(0x2694) + [char]::ConvertFromUtf32(0xFE0F)
    $lock = [char]::ConvertFromUtf32(0x1F510)
    $muscle = [char]::ConvertFromUtf32(0x1F4AA)
    $meditation = [char]::ConvertFromUtf32(0x1F9D8)
    return @{
        Goals = $sword + ' 200-Goals'
        Private = $lock + ' 400-Vault'
        Body = $muscle + ' 700-Body'
        Mind = $meditation + ' 800-Mind'
    }
}

function Assert-StagingOwned {
    param(
        [Parameter(Mandatory = $true)][string]$StagingPath,
        [Parameter(Mandatory = $true)][string]$TargetParent
    )

    $stagingFull = Get-FullPath -Path $StagingPath
    $parentFull = Get-FullPath -Path ([System.IO.Path]::GetDirectoryName($stagingFull))
    $leaf = [System.IO.Path]::GetFileName($stagingFull)
    if (-not [string]::Equals($parentFull, (Get-FullPath -Path $TargetParent), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ('Refusing cleanup outside the target parent: ' + $stagingFull)
    }
    if (-not $leaf.StartsWith('.second-brainbro-staging-', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ('Refusing cleanup of an unowned directory: ' + $stagingFull)
    }
    $ownerMarker = Join-Path $stagingFull '.second-brainbro-installer-owner'
    if (-not (Test-Path -LiteralPath $ownerMarker -PathType Leaf)) {
        throw ('Refusing cleanup without installer ownership marker: ' + $stagingFull)
    }
}

function Protect-PrivateDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $systemSid = New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'
    $administratorsSid = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    $security = New-Object Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner($currentSid)
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagation = [Security.AccessControl.PropagationFlags]::None
    foreach ($sid in @($currentSid, $systemSid, $administratorsSid)) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $propagation,
            [Security.AccessControl.AccessControlType]::Allow
        )
        $null = $security.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $security
    Assert-PrivateDirectoryAcl -Path $Path
}

function Assert-PrivateDirectoryAcl {
    param([Parameter(Mandatory = $true)][string]$Path)

    $allowed = @(
        [Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
        'S-1-5-18',
        'S-1-5-32-544'
    )
    $security = Get-Acl -LiteralPath $Path
    if (-not $security.AreAccessRulesProtected) {
        throw ('Vault ACL inheritance is not protected: ' + $Path)
    }
    if ($security.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $allowed[0]) {
        throw ('Vault ACL owner is not the current user: ' + $Path)
    }
    $rules = $security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
    foreach ($rule in $rules) {
        if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $allowed -notcontains $rule.IdentityReference.Value) {
            throw ('Vault ACL grants access to an unexpected principal: ' + $rule.IdentityReference.Value)
        }
    }
    foreach ($sid in $allowed) {
        if (-not @($rules | Where-Object {
            $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $_.IdentityReference.Value -eq $sid -and
            ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq
                [Security.AccessControl.FileSystemRights]::FullControl
        }).Count) {
            throw ('Vault ACL is missing required full control: ' + $sid)
        }
    }
}

function Set-OptionalFolderDocumentation {
    param(
        [Parameter(Mandatory = $true)][string]$StagingPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$FolderNames
    )

    $claudePath = Join-Path $StagingPath 'CLAUDE.md'
    $text = [System.IO.File]::ReadAllText($claudePath, [System.Text.Encoding]::UTF8)
    $marker = '<!-- SETUP: add lines for any optional scope folders you created (Goals, Vault, Body, Mind). -->'
    if ($text.IndexOf($marker, [System.StringComparison]::Ordinal) -lt 0) {
        throw 'Optional-folder documentation marker is missing from CLAUDE.md.'
    }
    $lines = @($FolderNames | ForEach-Object { '- `' + $_ + '/` - optional user-selected scope' })
    $replacement = $lines -join [Environment]::NewLine
    $next = $text.Replace($marker, $replacement)
    [System.IO.File]::WriteAllText($claudePath, $next, (New-Object System.Text.UTF8Encoding($false)))
}

function Set-OptionalNavigation {
    param(
        [Parameter(Mandatory = $true)][string]$StagingPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Areas,
        [Parameter(Mandatory = $true)][hashtable]$FolderMap,
        [Parameter(Mandatory = $true)][string]$CreatedDate
    )

    $dashboardFolder = [char]::ConvertFromUtf32(0x1F3AF) + ' 100-Command-Center'
    $dashboardPath = Join-Path $StagingPath (Join-Path $dashboardFolder 'Dashboard.md')
    $marker = '<!-- SECOND_BRAINBRO_OPTIONAL_NAVIGATION -->'
    $dashboard = [System.IO.File]::ReadAllText($dashboardPath, [System.Text.Encoding]::UTF8)
    if ($dashboard.IndexOf($marker, [System.StringComparison]::Ordinal) -lt 0) {
        throw 'Optional navigation marker is missing from Dashboard.md.'
    }

    $links = @()
    foreach ($area in $Areas) {
        $folder = $FolderMap[$area]
        $indexName = switch ($area) {
            'Goals' { 'Goals.md' }
            'Private' { 'Vault.md' }
            'Body' { 'Body.md' }
            'Mind' { 'Mind.md' }
            default { throw ('Unsupported optional area: ' + $area) }
        }
        $title = [System.IO.Path]::GetFileNameWithoutExtension($indexName)
        $indexPath = Join-Path $StagingPath (Join-Path $folder $indexName)
        if (Test-Path -LiteralPath $indexPath) {
            throw ('Optional navigation note unexpectedly exists: ' + $indexPath)
        }
        $indexText = '---' + [Environment]::NewLine +
            ('title: ' + $title) + [Environment]::NewLine +
            ('created: ' + $CreatedDate) + [Environment]::NewLine +
            ('modified: ' + $CreatedDate) + [Environment]::NewLine +
            'type: index' + [Environment]::NewLine +
            'status: active' + [Environment]::NewLine +
            'tags: [navigation]' + [Environment]::NewLine +
            '---' + [Environment]::NewLine +
            '# ' + $title + [Environment]::NewLine + [Environment]::NewLine +
            'Optional area selected during setup.' + [Environment]::NewLine + [Environment]::NewLine +
            ('Back to [[' + $dashboardFolder + '/Dashboard|Dashboard]].') + [Environment]::NewLine
        [System.IO.File]::WriteAllText($indexPath, $indexText, (New-Object System.Text.UTF8Encoding($false)))
        $links += ('- [[' + $folder + '/' + $title + '|' + $title + ']]')
    }

    $replacement = $links -join [Environment]::NewLine
    [System.IO.File]::WriteAllText(
        $dashboardPath,
        $dashboard.Replace($marker, $replacement),
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Test-Scaffold {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$HookMode,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$OptionalAreas,
        [Parameter(Mandatory = $true)][hashtable]$FolderMap,
        [Parameter(Mandatory = $true)][string]$LauncherSha256,
        [Parameter(Mandatory = $true)][string]$NodePath
    )

    $requiredFiles = @(
        'CLAUDE.md',
        'Open-SecondBrain.ps1',
        '.claude\hook-manifest.json',
        '.claude\settings.permissions.example.json',
        '.claude\settings.hooks.example.json',
        '.claude\hooks\hooks.mjs'
    )
    foreach ($relative in $requiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $relative) -PathType Leaf)) {
            throw ('Staged verification failed; missing: ' + $relative)
        }
    }

    $stagedLauncherHash = (Get-FileHash -LiteralPath (Join-Path $Path 'Open-SecondBrain.ps1') -Algorithm SHA256).Hash
    if (-not [string]::Equals($stagedLauncherHash, $LauncherSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Staged launcher differs from the reviewed source bytes.'
    }

    $personalizedFiles = @(
        'CLAUDE.md',
        ([char]::ConvertFromUtf32(0x1F3AF) + ' 100-Command-Center\Dashboard.md'),
        ([char]::ConvertFromUtf32(0x1F4CB) + ' Templates\Note.md'),
        ([char]::ConvertFromUtf32(0x1F52E) + ' 850-Companion\Core.md'),
        ([char]::ConvertFromUtf32(0x1F52E) + ' 850-Companion\Journal.md'),
        ([char]::ConvertFromUtf32(0x1F52E) + ' 850-Companion\Last-Session.md'),
        ([char]::ConvertFromUtf32(0x1F52E) + ' 850-Companion\Threads.md')
    )
    foreach ($relative in $personalizedFiles) {
        $full = Join-Path $Path $relative
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw ('Personalized file is missing: ' + $relative)
        }
        $content = [System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8)
        if ($content -match '\{\{[^}]*\}\}') {
            throw ('Unresolved placeholder remains: ' + $relative)
        }
        if ($relative -eq 'CLAUDE.md' -and $content -match '<!-- SETUP:') {
            throw 'Installer-only documentation marker remains in CLAUDE.md.'
        }
    }


    $dashboardPath = Join-Path $Path ([char]::ConvertFromUtf32(0x1F3AF) + ' 100-Command-Center\Dashboard.md')
    $dashboard = [System.IO.File]::ReadAllText($dashboardPath, [System.Text.Encoding]::UTF8)
    if ($dashboard.Contains('<!-- SECOND_BRAINBRO_OPTIONAL_NAVIGATION -->')) {
        throw 'Installer-only optional navigation marker remains in Dashboard.md.'
    }
    foreach ($area in $OptionalAreas) {
        $indexName = switch ($area) {
            'Goals' { 'Goals.md' }
            'Private' { 'Vault.md' }
            'Body' { 'Body.md' }
            'Mind' { 'Mind.md' }
            default { throw ('Unsupported optional area: ' + $area) }
        }
        $relative = Join-Path $FolderMap[$area] $indexName
        if (-not (Test-Path -LiteralPath (Join-Path $Path $relative) -PathType Leaf)) {
            throw ('Optional navigation note is missing: ' + $relative)
        }
    }

    $trackedSettings = Join-Path $Path '.claude\settings.json'
    $localSettings = Join-Path $Path '.claude\settings.local.json'
    if (Test-Path -LiteralPath $trackedSettings) {
        throw 'Tracked .claude/settings.json must not exist.'
    }
    if (-not (Test-Path -LiteralPath $localSettings -PathType Leaf)) {
        throw 'Local Claude permission settings are missing.'
    }
    $expectedSettings = if ($HookMode -eq 'Enabled') {
        Join-Path $Path '.claude\settings.hooks.example.json'
    } else {
        Join-Path $Path '.claude\settings.permissions.example.json'
    }
    $expectedSettingsHash = (Get-FileHash -LiteralPath $expectedSettings -Algorithm SHA256).Hash
    $localSettingsHash = (Get-FileHash -LiteralPath $localSettings -Algorithm SHA256).Hash
    if (-not [string]::Equals($expectedSettingsHash, $localSettingsHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Installed local Claude settings differ from the reviewed mode-specific example.'
    }
    if ($HookMode -eq 'Enabled') {
        & $NodePath (Join-Path $Path '.claude\hooks\hooks.mjs') verify-integrity
        if ($LASTEXITCODE -ne 0) { throw 'Hook integrity verification failed.' }
    }
}

$sourceRoot = $PSScriptRoot
$template = Join-Path $sourceRoot 'template'
$personalizer = Join-Path $sourceRoot 'personalize.mjs'
$null = Assert-PersonalizationInputs -SystemName $OsName -PersonName $UserName -Biography $UserBio `
    -CompanionName $Companion -CreatedDate $Today
$target = Assert-SafeTarget -RequestedPath $VaultPath
Assert-CleanTemplate -TemplatePath $template
if (-not (Test-Path -LiteralPath $personalizer -PathType Leaf)) {
    throw ('Personalization script is missing: ' + $personalizer)
}
$launcherSha256 = (Get-FileHash -LiteralPath (Join-Path $template 'Open-SecondBrain.ps1') -Algorithm SHA256).Hash

$prerequisites = Get-PrerequisiteState
$folderMap = Get-OptionalFolderMap
$selectedAreas = @($OptionalArea | Select-Object -Unique)
$optionalFolders = @($selectedAreas | ForEach-Object { $folderMap[$_] })

Write-Host ''
Write-Step 'Validated installation plan'
Write-Host ('  Target: ' + $target)
Write-Host ('  Source: ' + $template)
Write-Host ('  Node: ' + $prerequisites.NodeVersion)
Write-Host ('  Obsidian: ' + $prerequisites.ObsidianPath)
Write-Host ('  Obsidian version/publisher: ' + $prerequisites.ObsidianVersion + ' / ' + $prerequisites.ObsidianPublisher)
if (-not [string]::IsNullOrWhiteSpace($prerequisites.ObsidianProblem)) {
    Write-Host ('  Obsidian trust issue: ' + $prerequisites.ObsidianProblem)
}
Write-Host ('  Hooks: ' + $Hooks)
Write-Host ('  Optional folders: ' + $(if ($optionalFolders.Count) { $optionalFolders -join ', ' } else { 'none' }))
Write-Host '  Existing target content: never overwritten or merged'
Write-Host '  Commit method: same-volume directory rename after all checks pass'
Write-Host '  User bio: supplied but intentionally not printed'

if ($DryRun) {
    if (-not $prerequisites.NodeSupported -and -not $InstallPrerequisites) {
        throw 'Dry-run cannot validate installation: supported Node.js is missing. Install it or include -InstallPrerequisites to review the pinned package plan.'
    }
    if (-not $prerequisites.ObsidianInstalled -and -not $InstallPrerequisites) {
        throw 'Dry-run cannot validate installation: Obsidian is missing. Install it or include -InstallPrerequisites to review the pinned package plan.'
    }
    if ($InstallPrerequisites -and [string]::IsNullOrWhiteSpace($prerequisites.WinGetPath) -and
        (-not $prerequisites.NodeSupported -or -not $prerequisites.ObsidianInstalled)) {
        throw 'Dry-run cannot validate the requested package plan because WinGet is unavailable.'
    }
    if (-not $prerequisites.NodeSupported) { Write-Host '  Planned package: Node.js LTS 24.18.0 [OpenJS.NodeJS.LTS]' }
    if (-not $prerequisites.ObsidianInstalled) { Write-Host '  Planned package: Obsidian 1.12.7 [Obsidian.Obsidian]' }
    Write-Step 'Dry-run complete. No package, lock, staging, or target filesystem change was made.'
    return
}

$prerequisites = Install-MissingPrerequisites -State $prerequisites

Write-Host ''
$confirmation = Read-Host 'Type CREATE to authorize the displayed filesystem plan'
if ($confirmation -cne 'CREATE') {
    throw 'Filesystem installation was not authorized.'
}

$parent = [System.IO.Path]::GetDirectoryName($target)
$targetLeaf = [System.IO.Path]::GetFileName($target)
$lockPath = Join-Path $parent ('.' + $targetLeaf + '.second-brainbro.lock')
$staging = Join-Path $parent ('.second-brainbro-staging-' + [guid]::NewGuid().ToString('N'))
$lockStream = $null
$lockAcquired = $false
$stagingCreated = $false
$committed = $false

try {
    try {
        $lockStream = New-Object System.IO.FileStream(
            $lockPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        $lockAcquired = $true
    } catch [System.IO.IOException] {
        throw ('Another installation may own this target lock, or a stale lock exists: ' + $lockPath)
    }

    if (Test-Path -LiteralPath $target) {
        throw ('Target appeared after confirmation; refusing to overwrite: ' + $target)
    }

    $null = [System.IO.Directory]::CreateDirectory($staging)
    $stagingCreated = $true
    Protect-PrivateDirectory -Path $staging
    [System.IO.File]::WriteAllText(
        (Join-Path $staging '.second-brainbro-installer-owner'),
        'second-brainbro transactional installer',
        (New-Object System.Text.UTF8Encoding($false))
    )
    $unexpectedStagingItems = @(Get-ChildItem -LiteralPath $staging -Force | Where-Object {
        $_.Name -ne '.second-brainbro-installer-owner'
    })
    if ($unexpectedStagingItems.Count -gt 0) {
        throw 'Private staging was modified before template copy; refusing installation.'
    }

    Write-Step 'Copying the reviewed template into private staging.'
    Get-ChildItem -LiteralPath $template -Force | Copy-Item -Destination $staging -Recurse -Force

    foreach ($folder in $optionalFolders) {
        $optionalPath = Join-Path $staging $folder
        if (Test-Path -LiteralPath $optionalPath) {
            throw ('Optional folder unexpectedly exists in the reviewed template: ' + $folder)
        }
        $null = [System.IO.Directory]::CreateDirectory($optionalPath)
    }

    Write-Step 'Personalizing the staged scaffold.'
    $nodeArguments = @(
        $personalizer,
        '--vault', $staging,
        '--os-name', $OsName,
        '--user-name', $UserName,
        '--user-bio', $UserBio,
        '--companion', $Companion,
        '--today', $Today
    )
    & $prerequisites.NodePath $nodeArguments
    if ($LASTEXITCODE -ne 0) { throw 'Personalization failed.' }

    Set-OptionalFolderDocumentation -StagingPath $staging -FolderNames $optionalFolders
    Set-OptionalNavigation -StagingPath $staging -Areas $selectedAreas -FolderMap $folderMap -CreatedDate $Today

    $settingsExample = if ($Hooks -eq 'Enabled') {
        Write-Step 'Activating reviewed hooks and restrictive permissions in staged local settings.'
        Join-Path $staging '.claude\settings.hooks.example.json'
    } else {
        Write-Step 'Activating restrictive Claude permissions with project hooks disabled.'
        Join-Path $staging '.claude\settings.permissions.example.json'
    }
    $localSettings = Join-Path $staging '.claude\settings.local.json'
    Copy-Item -LiteralPath $settingsExample -Destination $localSettings

    Write-Step 'Verifying staged files, placeholders, and hook state.'
    Test-Scaffold -Path $staging -HookMode $Hooks -OptionalAreas $selectedAreas -FolderMap $folderMap `
        -LauncherSha256 $launcherSha256 -NodePath $prerequisites.NodePath

    $ownerMarker = Join-Path $staging '.second-brainbro-installer-owner'
    Remove-Item -LiteralPath $ownerMarker -Force
    if (Test-Path -LiteralPath $target) {
        [System.IO.File]::WriteAllText(
            $ownerMarker,
            'second-brainbro transactional installer',
            (New-Object System.Text.UTF8Encoding($false))
        )
        throw ('Target appeared before commit; refusing to overwrite: ' + $target)
    }

    Write-Step 'Committing the verified vault with one same-volume directory rename.'
    try {
        [System.IO.Directory]::Move($staging, $target)
    } catch {
        if (Test-Path -LiteralPath $staging -PathType Container) {
            [System.IO.File]::WriteAllText(
                $ownerMarker,
                'second-brainbro transactional installer',
                (New-Object System.Text.UTF8Encoding($false))
            )
        }
        throw
    }
    $committed = $true
    $stagingCreated = $false
    Assert-PrivateDirectoryAcl -Path $target
} finally {
    if ($stagingCreated -and (Test-Path -LiteralPath $staging)) {
        Assert-StagingOwned -StagingPath $staging -TargetParent $parent
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
    if ($null -ne $lockStream) {
        $lockStream.Dispose()
    }
    if ($lockAcquired -and (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        Remove-Item -LiteralPath $lockPath -Force
    }
}

if (-not $committed) { throw 'Installation did not commit.' }

Write-Host ''
Write-Step 'Installation completed and verified.'
$finalPrerequisites = Get-PrerequisiteState
[pscustomobject]@{
    VaultPath = $target
    Hooks = $Hooks
    OptionalFolders = $optionalFolders
    NodeVersion = $finalPrerequisites.NodeVersion
    ObsidianVersion = $finalPrerequisites.ObsidianVersion
    ObsidianPublisher = $finalPrerequisites.ObsidianPublisher
    ObsidianVerified = $true
    ExistingContentOverwritten = $false
    OneDriveSupported = $false
    UnattendedSetupSupported = $false
}
