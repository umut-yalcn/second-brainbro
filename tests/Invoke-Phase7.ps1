[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-f0-9]{40}$')]
    [string]$ExpectedCommit,

    # Written outside the checkout on purpose: ACCEPTANCE.md forbids committing raw evidence,
    # and a redacted report still names paths the reviewer should read before publishing.
    [Parameter(Mandatory = $true)]
    [string]$EvidencePath,

    [ValidatePattern('^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?/[A-Za-z0-9._-]+$')]
    [string]$ExpectedOrigin = 'umutyalcin-pen/second-brainbro',

    [string]$VaultRoot = [Environment]::GetFolderPath('MyDocuments'),

    # Accepts both an array and a single comma-joined value, because powershell.exe -File
    # passes -Gate A,B as one string and a ValidateSet would reject it with a confusing
    # message in the middle of an acceptance run.
    [ValidatePattern('(?i)^[A-E](\s*,\s*[A-E])*$')]
    [string[]]$Gate = @('A', 'B', 'C', 'D', 'E')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# This driver automates the mechanical parts of ACCEPTANCE.md on a fresh Windows 11 host and
# stops at the three steps that genuinely need a human: the Obsidian vault registration, the
# Claude Code installation and authentication, and the visual launcher confirmation.
#
# It never types the installer's CREATE authorization for you. Every run that can reach the
# prompt forwards the exact text you type, so the filesystem plan is still authorized by a
# person who read it. The only automated confirmations are deliberately wrong values used by
# the Gate E negative scenarios, where refusal is the property under test.

$Gate = @($Gate | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToUpperInvariant() } |
    Where-Object { -not [string]::IsNullOrEmpty($_) } | Select-Object -Unique)
if ($Gate.Count -eq 0) { throw 'At least one gate must be selected.' }

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$setupPath = Join-Path $repoRoot 'setup.ps1'
$testsPath = Join-Path $repoRoot 'tests\Invoke-Tests.ps1'
$acceptancePath = Join-Path $repoRoot 'tests\Invoke-Acceptance.ps1'
$script:HostExecutable = (Get-Process -Id $PID).Path
$script:Steps = New-Object System.Collections.Generic.List[object]
$script:Facts = New-Object System.Collections.Specialized.OrderedDictionary
$script:VaultDisabled = $null
$script:VaultEnabled = $null

# The scaffold uses emoji directory names and the installer echoes them. Without a pinned
# UTF-8 console the redirected child output is decoded with the local code page, which would
# put replacement characters into the evidence file.
$originalOutputEncoding = [Console]::OutputEncoding
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

# Longest first, so a user profile path is replaced before the bare user name inside it.
$script:Redactions = @(
    [pscustomobject]@{ Placeholder = '<USERPROFILE>'; Value = [string]$env:USERPROFILE }
    [pscustomobject]@{ Placeholder = '<HOST>'; Value = [string]$env:COMPUTERNAME }
    [pscustomobject]@{ Placeholder = '<USER>'; Value = [string]$env:USERNAME }
)

function Protect-Evidence {
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $result = $Text
    foreach ($redaction in $script:Redactions) {
        if ([string]::IsNullOrWhiteSpace($redaction.Value)) { continue }
        # Bounded on both sides: a short user or host name is a common substring, and an
        # unbounded replacement silently corrupts unrelated evidence such as an origin slug.
        $pattern = '(?<![A-Za-z0-9])' + [regex]::Escape($redaction.Value) + '(?![A-Za-z0-9])'
        $result = [regex]::Replace($result, $pattern, $redaction.Placeholder, 'IgnoreCase')
    }
    return $result
}

function Add-Step {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$GateId,
        [Parameter(Mandatory = $true)][ValidateSet('PASS', 'FAIL', 'SKIPPED', 'INCONCLUSIVE', 'RECORDED')][string]$Status,
        [ValidateSet('automated', 'manual')][string]$Kind = 'automated',
        [AllowEmptyString()][string]$Detail = ''
    )
    $trimmed = $Detail
    if ($trimmed.Length -gt 4000) { $trimmed = $trimmed.Substring(0, 4000) + ' [truncated]' }
    $script:Steps.Add([pscustomobject]@{
        Id = $Id
        Gate = $GateId
        Kind = $Kind
        Status = $Status
        Detail = (Protect-Evidence (($trimmed -replace '\s+', ' ').Trim()))
    })
    $colour = switch ($Status) {
        'PASS' { 'Green' }
        'FAIL' { 'Red' }
        'RECORDED' { 'Cyan' }
        default { 'Yellow' }
    }
    Write-Host ('[' + $Status.PadRight(12) + '] ' + $Id) -ForegroundColor $colour
}

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$GateId,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )
    Write-Host ''
    Write-Host ('Running ' + $Id) -ForegroundColor DarkGray
    try {
        $detail = @(& $Body) -join '; '
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = 'verified' }
        Add-Step -Id $Id -GateId $GateId -Status 'PASS' -Detail $detail
        return $true
    } catch {
        Add-Step -Id $Id -GateId $GateId -Status 'FAIL' -Detail $_.Exception.Message
        return $false
    }
}

function Add-SkippedStep {
    param([string]$Id, [string]$GateId, [string]$Reason, [string]$Kind = 'automated')
    Add-Step -Id $Id -GateId $GateId -Status 'SKIPPED' -Kind $Kind -Detail $Reason
}

function Confirm-Observation {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$GateId,
        [Parameter(Mandatory = $true)][string[]]$Instruction,
        [Parameter(Mandatory = $true)][string]$Expected
    )
    Write-Host ''
    Write-Host ('==== MANUAL STEP ' + $Id + ' ====') -ForegroundColor Yellow
    foreach ($line in $Instruction) { Write-Host ('  ' + $line) }
    Write-Host ('  Expected result: ' + $Expected) -ForegroundColor Yellow
    while ($true) {
        # Read-Host fails in a non-interactive host, so an unattended run stops here instead
        # of recording an observation nobody made.
        $answer = Read-Host 'Type YES if observed as expected, NO if not, or SKIP'
        if ($answer -ceq 'YES') {
            $note = Read-Host 'Optional short note (press Enter to skip)'
            $detail = if ([string]::IsNullOrWhiteSpace($note)) { 'observed as expected' } else { $note }
            Add-Step -Id $Id -GateId $GateId -Status 'PASS' -Kind 'manual' -Detail $detail
            return
        }
        if ($answer -ceq 'NO') {
            $note = Read-Host 'What happened instead'
            Add-Step -Id $Id -GateId $GateId -Status 'FAIL' -Kind 'manual' -Detail $note
            return
        }
        if ($answer -ceq 'SKIP') {
            $note = Read-Host 'Why is this observation skipped'
            Add-SkippedStep -Id $Id -GateId $GateId -Reason $note -Kind 'manual'
            return
        }
        Write-Host 'Answer exactly YES, NO, or SKIP.' -ForegroundColor Red
    }
}

function Invoke-Child {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [object[]]$Triggers = @(),
        # Read-Host writes its prompt to the console, not to a redirected stdout, so a prompt
        # cannot be detected by matching text. Instead the child is treated as waiting for
        # input once the arming line has been printed and it then falls silent while still
        # running. Every phase that is slow and silent happens before the arming line.
        [string]$InputArmText,
        [scriptblock]$InputAction,
        [int]$QuiescenceMilliseconds = 2500,
        [int]$TimeoutSeconds = 900,
        [switch]$Echo
    )

    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:HostExecutable
    $startInfo.Arguments = '-NoProfile -EncodedCommand ' + $encoded
    $startInfo.WorkingDirectory = $repoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.CreateNoWindow = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    $null = $process.Start()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $reader = $process.StandardOutput
    $writer = $process.StandardInput
    $collected = New-Object Text.StringBuilder
    $buffer = New-Object char[] 2048
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $readTask = $null
    $timedOut = $false
    $hasInputAction = $PSBoundParameters.ContainsKey('InputAction') -and $null -ne $InputAction
    $armed = $hasInputAction -and [string]::IsNullOrEmpty($InputArmText)
    $inputSent = $false
    $lastOutput = [DateTime]::UtcNow

    # Read incrementally rather than with ReadToEnd, because work has to happen while the
    # child is still running: the confirmation prompt blocks until stdin is written, and the
    # Gate E residue scenario has to act during the staging window.
    while ($true) {
        if ($null -eq $readTask) { $readTask = $reader.ReadAsync($buffer, 0, $buffer.Length) }
        if ($readTask.Wait(250)) {
            $count = $readTask.Result
            $readTask = $null
            if ($count -le 0) { break }
            $chunk = -join $buffer[0..($count - 1)]
            [void]$collected.Append($chunk)
            if ($Echo) { Write-Host -NoNewline $chunk }
            $lastOutput = [DateTime]::UtcNow
            $inputSent = $false
            $text = $collected.ToString()
            foreach ($trigger in $Triggers) {
                if ($trigger.Fired -or -not $text.Contains([string]$trigger.Text)) { continue }
                $trigger.Fired = $true
                & $trigger.Action $writer
            }
            if ($hasInputAction -and -not $armed -and $text.Contains($InputArmText)) { $armed = $true }
            continue
        }
        if ($armed -and -not $inputSent -and -not $process.HasExited -and
            ([DateTime]::UtcNow - $lastOutput).TotalMilliseconds -gt $QuiescenceMilliseconds) {
            $inputSent = $true
            & $InputAction $writer $collected.ToString()
            # The operator may take a while to answer, so the overall budget restarts here.
            $lastOutput = [DateTime]::UtcNow
            $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
            continue
        }
        if ([DateTime]::UtcNow -gt $deadline) { $timedOut = $true; break }
    }

    try { $writer.Close() } catch { }
    if (-not $timedOut -and -not $process.WaitForExit(30000)) { $timedOut = $true }
    if ($timedOut) {
        try { $process.Kill() } catch { }
        try { [void]$process.WaitForExit(5000) } catch { }
    }
    $stderr = ''
    try { $stderr = $stderrTask.Result } catch { }
    $exitCode = $process.ExitCode
    $process.Dispose()
    if ($timedOut) { throw 'Child process timed out.' }
    $parts = @($collected.ToString(), $stderr) | Where-Object { -not [string]::IsNullOrEmpty($_) }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = ($parts -join [Environment]::NewLine) }
}

function ConvertTo-PsLiteral {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

# Script scope rather than a closure: a trigger action runs while Invoke-Child is reading, and
# GetNewClosure would only capture the scope the script block was written in.
$script:AutomaticConfirmation = $null
$script:OccupiedTarget = $null

# The last line of the installer's validated plan. Everything after it either prints more
# output or waits for an authorization the operator has to give.
$script:PlanEndMarker = 'User bio: supplied but intentionally not printed'

$script:AnswerInstallerPrompt = {
    param($StdIn, $RecentOutput)
    if ($null -ne $script:AutomaticConfirmation) {
        Write-Host ''
        Write-Host ('  [negative scenario] sending a deliberately wrong confirmation: ' +
            $script:AutomaticConfirmation) -ForegroundColor DarkYellow
        $answer = $script:AutomaticConfirmation
    } else {
        Write-Host ''
        Write-Host '  The installer is waiting for an authorization.' -ForegroundColor Yellow
        Write-Host '  Read the output above. This driver does not authorize anything for you.' -ForegroundColor Yellow
        $answer = Read-Host '  Type the exact confirmation to send to the installer'
    }
    $StdIn.WriteLine($answer)
    $StdIn.Flush()
}

function Invoke-Installer {
    param(
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [ValidateSet('Disabled', 'Enabled')][string]$Hooks = 'Disabled',
        [string[]]$Areas = @(),
        [switch]$DryRun,
        [switch]$InstallPrerequisites,
        # Negative scenarios only. A value here is expected to be refused; the operator types
        # the authorization for every run that is meant to succeed.
        [string]$WrongConfirmation,
        [object[]]$ExtraTriggers = @()
    )

    $command = '& ' + (ConvertTo-PsLiteral $setupPath) +
        ' -VaultPath ' + (ConvertTo-PsLiteral $TargetPath) +
        " -OsName 'AcceptanceOS' -UserName 'Acceptance User'" +
        " -UserBio 'Synthetic clean-machine acceptance data' -Companion 'Guide'" +
        ' -Hooks ' + $Hooks + " -Today '2030-01-02'"
    if ($Areas.Count -gt 0) {
        $command += ' -OptionalArea @(' + ((@($Areas | ForEach-Object { ConvertTo-PsLiteral $_ })) -join ',') + ')'
    }
    if ($DryRun) { $command += ' -DryRun' }
    if ($InstallPrerequisites) { $command += ' -InstallPrerequisites' }

    $script:AutomaticConfirmation = if ($PSBoundParameters.ContainsKey('WrongConfirmation')) {
        $WrongConfirmation
    } else {
        $null
    }
    try {
        if ($DryRun) {
            # A dry run returns before any prompt, so it is never given an answering action.
            return Invoke-Child -Command $command -Triggers $ExtraTriggers -Echo -TimeoutSeconds 900
        }
        return Invoke-Child -Command $command -Triggers $ExtraTriggers -Echo -TimeoutSeconds 900 `
            -InputArmText $script:PlanEndMarker -InputAction $script:AnswerInstallerPrompt
    } finally {
        $script:AutomaticConfirmation = $null
    }
}

function Invoke-Verifier {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('PreInstall', 'InstalledVault')][string]$Mode,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [ValidateSet('Disabled', 'Enabled')][string]$Hooks = 'Disabled',
        [switch]$RequireClaude
    )
    $command = '& ' + (ConvertTo-PsLiteral $acceptancePath) +
        ' -Mode ' + $Mode +
        ' -VaultPath ' + (ConvertTo-PsLiteral $TargetPath) +
        ' -ExpectedCommit ' + (ConvertTo-PsLiteral $ExpectedCommit) +
        ' -ExpectedOrigin ' + (ConvertTo-PsLiteral $ExpectedOrigin) +
        ' -Hooks ' + $Hooks
    if ($RequireClaude) { $command += ' -RequireClaude' }
    $command += ' -Json'
    $result = Invoke-Child -Command $command -TimeoutSeconds 600
    $start = $result.Output.IndexOf('{')
    $end = $result.Output.LastIndexOf('}')
    if ($start -lt 0 -or $end -le $start) {
        throw ('Verifier produced no JSON report (exit ' + $result.ExitCode + '): ' + $result.Output)
    }
    $report = $result.Output.Substring($start, $end - $start + 1) | ConvertFrom-Json
    return [pscustomobject]@{
        ExitCode = $result.ExitCode
        Report = $report
        Summary = ('exit ' + $result.ExitCode + '; passed ' + $report.Passed +
            '; failed ' + $report.Failed + '; pending ' + $report.Pending)
        NonPassing = @($report.Results | Where-Object { $_.Status -ne 'PASS' } |
            ForEach-Object { $_.Id + '=' + $_.Status + ' (' + $_.Evidence + ')' })
    }
}

function Get-ResidueReport {
    param([Parameter(Mandatory = $true)][string]$TargetPath)
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($TargetPath))
    $leaf = [IO.Path]::GetFileName([IO.Path]::GetFullPath($TargetPath))
    $staging = @(Get-ChildItem -LiteralPath $parent -Force -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '.second-brainbro-staging-*' } | ForEach-Object { $_.Name })
    $lock = Join-Path $parent ('.' + $leaf + '.second-brainbro.lock')
    return [pscustomobject]@{
        Parent = $parent
        LockPath = $lock
        LockPresent = (Test-Path -LiteralPath $lock -PathType Leaf)
        StagingDirectories = $staging
    }
}

function Assert-NoResidue {
    param([Parameter(Mandatory = $true)][string]$TargetPath)
    $residue = Get-ResidueReport -TargetPath $TargetPath
    if ($residue.StagingDirectories.Count -gt 0) {
        throw ('Owned staging residue remains: ' + ($residue.StagingDirectories -join ', '))
    }
    if ($residue.LockPresent) { throw ('Owned lock residue remains: ' + $residue.LockPath) }
    return 'no staging or lock residue'
}

function Get-WatchedProcessIds {
    $ids = @()
    foreach ($name in @('Obsidian', 'claude', 'node')) {
        $ids += @(Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    }
    return @($ids | Sort-Object -Unique)
}

function Remove-SyntheticTarget {
    param([Parameter(Mandatory = $true)][string]$TargetPath)
    if (-not (Test-Path -LiteralPath $TargetPath)) { return }
    $full = [IO.Path]::GetFullPath($TargetPath)
    # Only ever removes a path this run created under the acceptance vault root.
    if (-not $full.StartsWith($script:VaultRootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFileName($full)).StartsWith('SecondBrainAcceptance', [StringComparison]::Ordinal)) {
        Write-Host ('  Refusing to remove an unexpected path: ' + $full) -ForegroundColor Red
        return
    }
    Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
}

try {
    $script:VaultRootFull = [IO.Path]::GetFullPath($VaultRoot)
    $evidenceFull = [IO.Path]::GetFullPath($EvidencePath)
    $repoPrefix = $repoRoot.TrimEnd('\') + '\'
    if ($evidenceFull.Equals($repoRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $evidenceFull.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'EvidencePath must be outside the reviewed checkout; raw acceptance evidence is never committed.'
    }
    $null = [IO.Directory]::CreateDirectory($evidenceFull)

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ((New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Phase 7 must be driven from a non-elevated standard-user shell.'
    }

    $targets = [pscustomobject]@{
        Disabled = Join-Path $script:VaultRootFull 'SecondBrainAcceptance'
        Enabled = Join-Path $script:VaultRootFull 'SecondBrainAcceptanceHooks'
        BadConfirm = Join-Path $script:VaultRootFull 'SecondBrainAcceptanceNegBadConfirm'
        Existing = Join-Path $script:VaultRootFull 'SecondBrainAcceptanceNegExisting'
        Residue = Join-Path $script:VaultRootFull 'SecondBrainAcceptanceNegResidue'
        ForeignLock = Join-Path $script:VaultRootFull 'SecondBrainAcceptanceNegLock'
    }

    Write-Host ''
    Write-Host 'second-brainbro Phase 7 clean-machine acceptance driver' -ForegroundColor Cyan
    Write-Host ('Reviewed commit: ' + $ExpectedCommit)
    Write-Host ('Expected origin: ' + $ExpectedOrigin)
    Write-Host ('Vault root:      ' + $script:VaultRootFull)
    Write-Host ('Evidence:        ' + $evidenceFull)
    Write-Host ('Gates:           ' + ($Gate -join ', '))
    Write-Host ''
    Write-Host 'This driver forwards the CREATE authorization you type; it never types it for you.'
    Write-Host ''

    # Seeded so the completion record shows every required row even when a gate was not run.
    # A missing row would otherwise read as an absent requirement rather than a gap.
    foreach ($required in @(
        'Commit', 'FreshEnvironment', 'Windows', 'Account', 'Storage', 'NodeVersion',
        'ObsidianVersion', 'ClaudeVersion', 'AutomatedSuite', 'PreInstallVerifier',
        'DisabledVaultVerifier', 'EnabledVaultVerifier', 'ExpectedOrigin', 'Reviewer', 'ReviewDate'
    )) {
        $script:Facts[$required] = 'not recorded in this run'
    }
    $script:Facts['Commit'] = $ExpectedCommit

    $environmentId = Read-Host 'VM snapshot or physical machine identifier for the record'
    $script:Facts['FreshEnvironment'] = $environmentId

    # ---------------------------------------------------------------- Gate A
    if ($Gate -contains 'A') {
        Invoke-Step -Id 'A.host-record' -GateId 'A' -Body {
            $key = Get-ItemProperty -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
            $build = [string]$key.CurrentBuildNumber
            if ($key.PSObject.Properties.Name -contains 'UBR') { $build += '.' + [string]$key.UBR }
            $installed = ([DateTimeOffset]::FromUnixTimeSeconds([int64]$key.InstallDate)).UtcDateTime.ToString('yyyy-MM-dd')
            # ProductName is deliberately not used: it still reads "Windows 10" on Windows 11,
            # which would put a plainly wrong edition line into signed acceptance evidence.
            # The build number is what actually establishes the release.
            $record = 'Windows 11 ' + [string]$key.EditionID + ' ' + [string]$key.DisplayVersion +
                ' build ' + $build + ' ' + [string]$env:PROCESSOR_ARCHITECTURE + '; installed ' + $installed
            if ([int]$key.CurrentBuildNumber -lt 22000 -or [string]$key.InstallationType -ne 'Client') {
                throw ('Not a Windows 11 client host: build ' + $build + ' type ' + [string]$key.InstallationType)
            }
            $script:Facts['Windows'] = $record
            $script:Facts['Account'] = 'standard, non-elevated'
            return $record
        } | Out-Null

        Invoke-Step -Id 'A.reviewed-checkout' -GateId 'A' -Body {
            if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git is unavailable.' }
            $head = (& git -C $repoRoot rev-parse HEAD 2>&1) -join ''
            if ($LASTEXITCODE -ne 0) { throw ('git rev-parse failed: ' + $head) }
            if ($head.Trim() -ne $ExpectedCommit) { throw ('HEAD mismatch: ' + $head.Trim()) }
            $status = @(& git -C $repoRoot status --porcelain=v1 --untracked-files=all 2>&1)
            if ($LASTEXITCODE -ne 0) { throw 'git status failed.' }
            if ($status.Count -gt 0) { throw ('Checkout is not clean: ' + ($status -join ', ')) }
            $script:Facts['Commit'] = $ExpectedCommit
            return ('HEAD ' + $ExpectedCommit + '; clean checkout')
        } | Out-Null

        Invoke-Step -Id 'A.test-suite' -GateId 'A' -Body {
            $result = Invoke-Child -Command ('& ' + (ConvertTo-PsLiteral $testsPath)) -Echo -TimeoutSeconds 1800
            $summary = @([regex]::Matches($result.Output, '(?m)^(Passed|Failed):.*$') | ForEach-Object { $_.Value.Trim() }) -join ' '
            $script:Facts['AutomatedSuite'] = ('exit ' + $result.ExitCode + '; ' + $summary)
            if ($result.ExitCode -ne 0) { throw ('Test suite failed: ' + $summary) }
            return $script:Facts['AutomatedSuite']
        } | Out-Null

        # On a genuinely fresh host this is expected to report missing prerequisites, so it is
        # RECORDED rather than PASS. Reporting a run whose own summary says "failed 1" as a
        # passed step would both mislead the reviewer and inflate the pass count; Gate B is
        # where the pre-install gates actually have to come out clean.
        try {
            $baseline = Invoke-Verifier -Mode 'PreInstall' -TargetPath $targets.Disabled
            $baselineDetail = $baseline.Summary
            if ($baseline.NonPassing.Count -gt 0) {
                $baselineDetail += '; non-passing: ' + ($baseline.NonPassing -join ' | ')
            }
            Add-Step -Id 'A.preinstall-baseline' -GateId 'A' -Status 'RECORDED' -Detail $baselineDetail
        } catch {
            # Being unable to run the verifier at all is a defect, not a baseline observation.
            Add-Step -Id 'A.preinstall-baseline' -GateId 'A' -Status 'FAIL' -Detail $_.Exception.Message
        }
    }

    # ---------------------------------------------------------------- Gate B
    if ($Gate -contains 'B') {
        Invoke-Step -Id 'B.dry-run-package-plan' -GateId 'B' -Body {
            $before = Get-WatchedProcessIds
            $result = Invoke-Installer -TargetPath $targets.Disabled -Hooks 'Disabled' `
                -Areas @('Goals', 'Private') -DryRun -InstallPrerequisites
            $after = Get-WatchedProcessIds
            $started = @($after | Where-Object { $before -notcontains $_ })
            if ($result.Output -notmatch 'Dry-run complete') {
                throw ('Dry-run completion marker is absent (exit ' + $result.ExitCode + ').')
            }
            if (Test-Path -LiteralPath $targets.Disabled) { throw 'Dry-run created the target.' }
            if ($started.Count -gt 0) { throw ('Dry-run started processes: ' + ($started -join ', ')) }
            $planned = @([regex]::Matches($result.Output, '(?m)^\s*Planned package:.*$') |
                ForEach-Object { $_.Value.Trim() })
            $null = Assert-NoResidue -TargetPath $targets.Disabled
            $detail = 'target absent; no residue; zero processes started'
            if ($planned.Count -gt 0) { $detail += '; ' + ($planned -join ' | ') }
            return $detail
        } | Out-Null

        $prerequisitesReady = Invoke-Step -Id 'B.preinstall-all-gates' -GateId 'B' -Body {
            $verifier = Invoke-Verifier -Mode 'PreInstall' -TargetPath $targets.Disabled
            $node = @($verifier.Report.Results | Where-Object { $_.Id -eq 'runtime.node' })
            $obsidian = @($verifier.Report.Results | Where-Object { $_.Id -eq 'runtime.obsidian' })
            if ($node.Count -eq 1) { $script:Facts['NodeVersion'] = $node[0].Evidence }
            if ($obsidian.Count -eq 1) { $script:Facts['ObsidianVersion'] = $obsidian[0].Evidence }
            $script:Facts['PreInstallVerifier'] = $verifier.Summary
            if ($verifier.ExitCode -ne 0) {
                throw ('Pre-install gates are not all passing: ' + ($verifier.NonPassing -join ' | '))
            }
            return $verifier.Summary
        }
    } else {
        $prerequisitesReady = $true
    }

    # ---------------------------------------------------------------- Gate C
    if ($Gate -contains 'C') {
        if (-not $prerequisitesReady) {
            Add-SkippedStep -Id 'C.install-disabled' -GateId 'C' -Reason 'Gate B pre-install gates did not all pass.'
        } else {
            $installed = Invoke-Step -Id 'C.install-disabled' -GateId 'C' -Body {
                if (Test-Path -LiteralPath $targets.Disabled) {
                    throw ('Target already exists; remove it or use a new name: ' + $targets.Disabled)
                }
                $result = Invoke-Installer -TargetPath $targets.Disabled -Hooks 'Disabled' -Areas @('Goals', 'Private')
                if ($result.ExitCode -ne 0) { throw ('Installer exited ' + $result.ExitCode) }
                if (-not (Test-Path -LiteralPath $targets.Disabled -PathType Container)) {
                    throw 'Installer reported success but the vault is absent.'
                }
                $null = Assert-NoResidue -TargetPath $targets.Disabled
                $script:VaultDisabled = $targets.Disabled
                return 'vault committed; no residue'
            }

            if (-not $installed) {
                Add-SkippedStep -Id 'C.verify-pending' -GateId 'C' -Reason 'The disabled-hook vault was not installed.'
                Add-SkippedStep -Id 'C.open-as-vault' -GateId 'C' -Reason 'The disabled-hook vault was not installed.' -Kind 'manual'
                Add-SkippedStep -Id 'C.verify-complete' -GateId 'C' -Reason 'The disabled-hook vault was not installed.'
                Add-SkippedStep -Id 'C.launcher-opens-dashboard' -GateId 'C' -Reason 'The disabled-hook vault was not installed.' -Kind 'manual'
            } else {
                Invoke-Step -Id 'C.verify-pending' -GateId 'C' -Body {
                    $verifier = Invoke-Verifier -Mode 'InstalledVault' -TargetPath $targets.Disabled -Hooks 'Disabled'
                    # Before Obsidian registers the vault, exactly one gate may be PENDING and
                    # nothing may be FAIL. Any other shape is a real defect.
                    if ($verifier.Report.Failed -ne 0) {
                        throw ('Unexpected failing gates: ' + ($verifier.NonPassing -join ' | '))
                    }
                    if ($verifier.ExitCode -ne 2 -or $verifier.Report.Pending -ne 1) {
                        throw ('Expected exit 2 with one pending gate, got ' + $verifier.Summary)
                    }
                    $pending = @($verifier.Report.Results | Where-Object { $_.Status -eq 'PENDING' })
                    if ($pending[0].Id -ne 'launcher.dry-run') {
                        throw ('Unexpected pending gate: ' + $pending[0].Id)
                    }
                    return $verifier.Summary
                } | Out-Null

                Confirm-Observation -Id 'C.open-as-vault' -GateId 'C' -Instruction @(
                    'Start Obsidian and choose "Open folder as vault".',
                    ('Select exactly this folder: ' + $targets.Disabled),
                    'Do not install any community plugin.'
                ) -Expected 'Obsidian opens the vault and creates its .obsidian folder.'

                Invoke-Step -Id 'C.verify-complete' -GateId 'C' -Body {
                    $verifier = Invoke-Verifier -Mode 'InstalledVault' -TargetPath $targets.Disabled -Hooks 'Disabled'
                    $script:Facts['DisabledVaultVerifier'] = $verifier.Summary
                    if ($verifier.ExitCode -ne 0) {
                        throw ('Expected a clean pass, got ' + $verifier.Summary + ': ' + ($verifier.NonPassing -join ' | '))
                    }
                    return $verifier.Summary
                } | Out-Null

                Confirm-Observation -Id 'C.launcher-opens-dashboard' -GateId 'C' -Instruction @(
                    ('In a new non-elevated terminal run: ' + (Join-Path $targets.Disabled 'Open-SecondBrain.ps1')),
                    'Run it without -Claude.'
                ) -Expected 'Obsidian opens the synthetic Dashboard note and Claude Code does not start.'
            }
        }
    }

    # ---------------------------------------------------------------- Gate D
    if ($Gate -contains 'D') {
        if (-not $prerequisitesReady) {
            Add-SkippedStep -Id 'D.install-enabled' -GateId 'D' -Reason 'Gate B pre-install gates did not all pass.'
        } else {
            Confirm-Observation -Id 'D.claude-installed' -GateId 'D' -Instruction @(
                'Install Claude Code through a separately reviewed method, for example:',
                '  winget install --id Anthropic.ClaudeCode -e --source winget',
                'Then authenticate interactively and confirm `claude --version` reports 2.1.211 or newer.',
                'Review the hook example, the hook source, and the manifest before continuing.'
            ) -Expected 'Claude Code is installed, authenticated, and on PATH.'

            $installedHooks = Invoke-Step -Id 'D.install-enabled' -GateId 'D' -Body {
                if (Test-Path -LiteralPath $targets.Enabled) {
                    throw ('Target already exists; remove it or use a new name: ' + $targets.Enabled)
                }
                $result = Invoke-Installer -TargetPath $targets.Enabled -Hooks 'Enabled'
                if ($result.ExitCode -ne 0) { throw ('Installer exited ' + $result.ExitCode) }
                if (-not (Test-Path -LiteralPath $targets.Enabled -PathType Container)) {
                    throw 'Installer reported success but the vault is absent.'
                }
                $null = Assert-NoResidue -TargetPath $targets.Enabled
                $script:VaultEnabled = $targets.Enabled
                return 'hook-enabled vault committed; no residue'
            }

            if (-not $installedHooks) {
                foreach ($id in @('D.verify', 'D.hook-drift-detected', 'D.local-settings-not-pinned')) {
                    Add-SkippedStep -Id $id -GateId 'D' -Reason 'The hook-enabled vault was not installed.'
                }
            } else {
                Invoke-Step -Id 'D.verify' -GateId 'D' -Body {
                    $verifier = Invoke-Verifier -Mode 'InstalledVault' -TargetPath $targets.Enabled `
                        -Hooks 'Enabled' -RequireClaude
                    $claude = @($verifier.Report.Results | Where-Object { $_.Id -eq 'runtime.claude' })
                    if ($claude.Count -eq 1) { $script:Facts['ClaudeVersion'] = $claude[0].Evidence }
                    $script:Facts['EnabledVaultVerifier'] = $verifier.Summary
                    if ($verifier.ExitCode -ne 0) {
                        throw ('Expected a clean pass, got ' + $verifier.Summary + ': ' + ($verifier.NonPassing -join ' | '))
                    }
                    return $verifier.Summary
                } | Out-Null

                Invoke-Step -Id 'D.hook-drift-detected' -GateId 'D' -Body {
                    $hook = Join-Path $targets.Enabled '.claude\hooks\hooks.mjs'
                    $node = (Get-Command node -CommandType Application | Select-Object -First 1).Path
                    $original = [IO.File]::ReadAllBytes($hook)
                    try {
                        # One appended comment byte sequence is enough: the manifest pins the
                        # exact packaged bytes, so any change at all must be detected.
                        [IO.File]::WriteAllBytes($hook, ($original + [Text.Encoding]::ASCII.GetBytes("`n// drift probe`n")))
                        $mutated = @(& $node $hook verify-integrity 2>&1) -join ' '
                        $mutatedExit = $LASTEXITCODE
                    } finally {
                        [IO.File]::WriteAllBytes($hook, $original)
                    }
                    $restored = @(& $node $hook verify-integrity 2>&1) -join ' '
                    if ($mutatedExit -eq 0) { throw 'A mutated hook passed integrity verification.' }
                    if ($LASTEXITCODE -ne 0) { throw ('Restored hook still fails verification: ' + $restored) }
                    return ('mutated hook rejected (exit ' + $mutatedExit + '); reviewed bytes restored and verified')
                } | Out-Null

                Invoke-Step -Id 'D.local-settings-not-pinned' -GateId 'D' -Body {
                    $settings = Join-Path $targets.Enabled '.claude\settings.local.json'
                    $node = (Get-Command node -CommandType Application | Select-Object -First 1).Path
                    $original = [IO.File]::ReadAllBytes($settings)
                    try {
                        $document = [Text.Encoding]::UTF8.GetString($original) | ConvertFrom-Json
                        $document.permissions.deny = @($document.permissions.deny) + 'Read(//**/acceptance-probe.txt)'
                        [IO.File]::WriteAllText($settings, ($document | ConvertTo-Json -Depth 10),
                            (New-Object Text.UTF8Encoding($false)))
                        $hook = Join-Path $targets.Enabled '.claude\hooks\hooks.mjs'
                        $output = @(& $node $hook verify-integrity 2>&1) -join ' '
                        $exit = $LASTEXITCODE
                    } finally {
                        [IO.File]::WriteAllBytes($settings, $original)
                    }
                    if ($exit -ne 0) {
                        throw ('Editing user-owned local settings raised drift: ' + $output)
                    }
                    return 'user-edited settings.local.json raised no drift; original bytes restored'
                } | Out-Null

                Confirm-Observation -Id 'D.claude-consent' -GateId 'D' -Instruction @(
                    ('Run: ' + (Join-Path $targets.Enabled 'Open-SecondBrain.ps1') + ' -Claude'),
                    'First answer the confirmation prompt with something other than CLAUDE.',
                    'Then run it again and type the exact word CLAUDE.'
                ) -Expected 'The wrong answer starts nothing; the exact word starts both applications in this vault.'

                Confirm-Observation -Id 'D.bounded-memory-injection' -GateId 'D' -Instruction @(
                    'Start a Claude Code session in the hook-enabled vault with synthetic content only.',
                    'Inspect what SessionStart injected, and review /hooks.'
                ) -Expected 'Only bounded, delimited sections marked as untrusted data appear; no raw session id is shown.'

                Confirm-Observation -Id 'D.disable-and-cleanup' -GateId 'D' -Instruction @(
                    'Follow SETUP.md to disable hooks and remove disposable state in this vault.'
                ) -Expected 'The permission-only settings example is restored and Markdown notes are untouched.'
            }
        }
    }

    # ---------------------------------------------------------------- Gate E
    if ($Gate -contains 'E') {
        Invoke-Step -Id 'E.invalid-confirmation' -GateId 'E' -Body {
            # Lower case: setup.ps1 compares case-sensitively, so this must be refused.
            $result = Invoke-Installer -TargetPath $targets.BadConfirm -WrongConfirmation 'create'
            if ($result.ExitCode -eq 0) { throw 'The installer accepted an invalid confirmation.' }
            # The reason matters: a prerequisite failure would also exit nonzero and leave the
            # target absent without ever testing the authorization check.
            if ($result.Output -notmatch 'was not authorized') {
                throw ('The run failed before the authorization check: ' + $result.Output)
            }
            if (Test-Path -LiteralPath $targets.BadConfirm) { throw 'The target was created despite refusal.' }
            return ('refused with exit ' + $result.ExitCode + '; ' + (Assert-NoResidue -TargetPath $targets.BadConfirm))
        } | Out-Null

        Invoke-Step -Id 'E.existing-target-refused' -GateId 'E' -Body {
            $sentinelText = 'acceptance sentinel'
            $null = [IO.Directory]::CreateDirectory($targets.Existing)
            $sentinel = Join-Path $targets.Existing 'sentinel.txt'
            [IO.File]::WriteAllText($sentinel, $sentinelText, (New-Object Text.UTF8Encoding($false)))
            try {
                $result = Invoke-Installer -TargetPath $targets.Existing -WrongConfirmation 'create'
                if ($result.ExitCode -eq 0) { throw 'The installer accepted an existing target.' }
                if ($result.Output -notmatch 'Target already exists') {
                    throw ('Unexpected refusal reason: ' + $result.Output)
                }
                $contents = @(Get-ChildItem -LiteralPath $targets.Existing -Force | ForEach-Object { $_.Name })
                if ($contents.Count -ne 1 -or $contents[0] -ne 'sentinel.txt') {
                    throw ('Existing target content changed: ' + ($contents -join ', '))
                }
                if ([IO.File]::ReadAllText($sentinel) -ne $sentinelText) { throw 'Sentinel file was modified.' }
                return ('refused with exit ' + $result.ExitCode + '; existing content untouched; ' +
                    (Assert-NoResidue -TargetPath $targets.Existing))
            } finally {
                Remove-SyntheticTarget -TargetPath $targets.Existing
            }
        } | Out-Null

        Invoke-Step -Id 'E.relative-path-refused' -GateId 'E' -Body {
            $relative = 'SecondBrainAcceptanceRelative'
            $result = Invoke-Installer -TargetPath $relative -WrongConfirmation 'create'
            $created = Join-Path $repoRoot $relative
            try {
                if ($result.ExitCode -eq 0) { throw 'The installer accepted a relative path.' }
                if ($result.Output -notmatch 'VaultPath must be absolute') {
                    throw ('Unexpected refusal reason: ' + $result.Output)
                }
                if (Test-Path -LiteralPath $created) { throw 'A relative target was created inside the checkout.' }
                return ('refused with exit ' + $result.ExitCode + '; nothing created inside the checkout')
            } finally {
                if (Test-Path -LiteralPath $created) { Remove-Item -LiteralPath $created -Recurse -Force }
            }
        } | Out-Null

        Invoke-Step -Id 'E.failed-precommit-no-residue' -GateId 'E' -Body {
            # The target is occupied while the installer is still working inside private
            # staging, so the failure happens after staging exists but before the commit
            # rename. That is the path whose cleanup this observation is about.
            $script:OccupiedTarget = $targets.Residue
            $trigger = [pscustomobject]@{
                Text = 'Copying the reviewed template into private staging'
                Fired = $false
                Action = {
                    param($StdIn)
                    $null = [IO.Directory]::CreateDirectory($script:OccupiedTarget)
                    [IO.File]::WriteAllText((Join-Path $script:OccupiedTarget 'occupied.txt'),
                        'occupied during staging', (New-Object Text.UTF8Encoding($false)))
                }
            }
            try {
                $result = Invoke-Installer -TargetPath $targets.Residue -ExtraTriggers @($trigger)
                if ($result.ExitCode -eq 0) {
                    # The staging window closed before the target could be occupied, so this
                    # run proves nothing either way. Reported honestly rather than as a pass.
                    Add-Step -Id 'E.failed-precommit-no-residue.note' -GateId 'E' -Status 'INCONCLUSIVE' `
                        -Detail 'The installer committed before the target could be occupied; rerun this step.'
                    throw 'The staging window closed too early to force a pre-commit failure.'
                }
                if ($result.Output -notmatch 'refusing to overwrite') {
                    throw ('Unexpected failure reason: ' + $result.Output)
                }
                $residue = Get-ResidueReport -TargetPath $targets.Residue
                if ($residue.StagingDirectories.Count -gt 0) {
                    throw ('Owned staging residue remains: ' + ($residue.StagingDirectories -join ', '))
                }
                if ($residue.LockPresent) { throw ('Owned lock residue remains: ' + $residue.LockPath) }
                if (-not (Test-Path -LiteralPath (Join-Path $targets.Residue 'occupied.txt') -PathType Leaf)) {
                    throw 'The occupying content was destroyed.'
                }
                return ('pre-commit failure with exit ' + $result.ExitCode +
                    '; no staging or lock residue; occupying content preserved')
            } finally {
                $script:OccupiedTarget = $null
                Remove-SyntheticTarget -TargetPath $targets.Residue
            }
        } | Out-Null

        Invoke-Step -Id 'E.foreign-lock-preserved' -GateId 'E' -Body {
            $parent = [IO.Path]::GetDirectoryName($targets.ForeignLock)
            $leaf = [IO.Path]::GetFileName($targets.ForeignLock)
            $lockPath = Join-Path $parent ('.' + $leaf + '.second-brainbro.lock')
            $lockText = 'foreign lock owned by another process'
            [IO.File]::WriteAllText($lockPath, $lockText, (New-Object Text.UTF8Encoding($false)))
            try {
                $result = Invoke-Installer -TargetPath $targets.ForeignLock
                if ($result.ExitCode -eq 0) { throw 'The installer ignored a foreign lock.' }
                if ($result.Output -notmatch 'lock') { throw ('Unexpected failure reason: ' + $result.Output) }
                if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
                    throw 'The foreign lock was deleted instead of preserved.'
                }
                if ([IO.File]::ReadAllText($lockPath) -ne $lockText) { throw 'The foreign lock was modified.' }
                if (Test-Path -LiteralPath $targets.ForeignLock) { throw 'The target was created despite the lock.' }
                $staging = @(Get-ChildItem -LiteralPath $parent -Force -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like '.second-brainbro-staging-*' })
                if ($staging.Count -gt 0) { throw ('Staging residue remains: ' + ($staging.Name -join ', ')) }
                return ('refused with exit ' + $result.ExitCode + '; foreign lock preserved byte-for-byte')
            } finally {
                if (Test-Path -LiteralPath $lockPath) { Remove-Item -LiteralPath $lockPath -Force }
            }
        } | Out-Null

        if ($null -eq $script:VaultDisabled) {
            Add-SkippedStep -Id 'E.launcher-dry-run-no-process' -GateId 'E' -Reason 'No installed vault is available.'
        } else {
            Invoke-Step -Id 'E.launcher-dry-run-no-process' -GateId 'E' -Body {
                $launcher = Join-Path $script:VaultDisabled 'Open-SecondBrain.ps1'
                $before = Get-WatchedProcessIds
                $result = Invoke-Child -Command ('& ' + (ConvertTo-PsLiteral $launcher) + ' -DryRun') -TimeoutSeconds 300
                Start-Sleep -Milliseconds 500
                $after = Get-WatchedProcessIds
                $started = @($after | Where-Object { $before -notcontains $_ })
                if ($result.ExitCode -ne 0) { throw ('Launcher dry-run exited ' + $result.ExitCode + ': ' + $result.Output) }
                if ($result.Output -notmatch 'Dry-run complete') { throw 'Launcher dry-run marker is absent.' }
                if ($started.Count -gt 0) { throw ('Launcher dry-run started processes: ' + ($started -join ', ')) }
                return 'validated with zero new Obsidian, Claude, or Node processes'
            } | Out-Null
        }
    }

    # ---------------------------------------------------------------- Report
    $reviewer = Read-Host 'Reviewer name or handle for the record'
    $script:Facts['Reviewer'] = $reviewer
    $script:Facts['ReviewDate'] = (Get-Date -Format 'yyyy-MM-dd')
    $script:Facts['ExpectedOrigin'] = $ExpectedOrigin
    $script:Facts['Storage'] = ('local fixed NTFS under ' + (Protect-Evidence $script:VaultRootFull))

    $failed = @($script:Steps | Where-Object { $_.Status -eq 'FAIL' })
    $unresolved = @($script:Steps | Where-Object { @('SKIPPED', 'INCONCLUSIVE') -contains $_.Status })
    $passed = @($script:Steps | Where-Object { $_.Status -eq 'PASS' })

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $baseName = 'phase7-' + $ExpectedCommit.Substring(0, 12) + '-' + $stamp
    $jsonPath = Join-Path $evidenceFull ($baseName + '.json')
    $markdownPath = Join-Path $evidenceFull ($baseName + '.md')

    $factObject = New-Object psobject
    foreach ($key in $script:Facts.Keys) {
        Add-Member -InputObject $factObject -MemberType NoteProperty -Name $key -Value (Protect-Evidence ([string]$script:Facts[$key]))
    }
    [pscustomobject]@{
        SchemaVersion = 1
        Generated = (Get-Date).ToString('o')
        ExpectedCommit = $ExpectedCommit
        ExpectedOrigin = $ExpectedOrigin
        Gates = $Gate
        Passed = $passed.Count
        Failed = $failed.Count
        Unresolved = $unresolved.Count
        Facts = $factObject
        Steps = $script:Steps.ToArray()
    } | ConvertTo-Json -Depth 6 | ForEach-Object {
        [IO.File]::WriteAllText($jsonPath, $_, (New-Object Text.UTF8Encoding($false)))
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Phase 7 acceptance evidence')
    $lines.Add('')
    $lines.Add('Usernames, the host name, and the profile path are replaced with placeholders. Review this')
    $lines.Add('file before publishing it and keep it outside the reviewed checkout.')
    $lines.Add('')
    $lines.Add('## Completion record')
    $lines.Add('')
    $lines.Add('| Required record | Value |')
    $lines.Add('|---|---|')
    foreach ($key in $script:Facts.Keys) {
        $lines.Add('| ' + $key + ' | ' + (Protect-Evidence ([string]$script:Facts[$key])) + ' |')
    }
    $lines.Add('')
    $lines.Add('## Steps')
    $lines.Add('')
    $lines.Add('| Step | Gate | Kind | Status | Detail |')
    $lines.Add('|---|---|---|---|---|')
    foreach ($step in $script:Steps) {
        $lines.Add('| ' + $step.Id + ' | ' + $step.Gate + ' | ' + $step.Kind + ' | ' + $step.Status +
            ' | ' + ($step.Detail -replace '\|', '\|') + ' |')
    }
    $lines.Add('')
    $lines.Add('Passed: ' + $passed.Count + '; Failed: ' + $failed.Count + '; Unresolved: ' + $unresolved.Count)
    if ($failed.Count -gt 0 -or $unresolved.Count -gt 0) {
        $lines.Add('')
        $lines.Add('Phase 7 is not complete. Every step must pass before the completion record is reviewed.')
    }
    # BOM-less UTF-8 with LF, matching every other text artefact this project produces.
    [IO.File]::WriteAllText($markdownPath, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))

    Write-Host ''
    Write-Host ('Evidence written to ' + $jsonPath)
    Write-Host ('Evidence written to ' + $markdownPath)
    Write-Host ''
    Write-Host ('Passed: ' + $passed.Count)
    Write-Host ('Failed: ' + $failed.Count)
    Write-Host ('Unresolved: ' + $unresolved.Count)
    Write-Host ''
    Write-Host 'Synthetic vaults left in place for review:'
    foreach ($vault in @($script:VaultDisabled, $script:VaultEnabled)) {
        if ($null -ne $vault) { Write-Host ('  ' + $vault) }
    }
    Write-Host 'Discard the whole VM snapshot, or delete these folders, once the evidence is reviewed.'
    Write-Host ''
    if ($failed.Count -gt 0) {
        Write-Host 'Phase 7 has failing steps and cannot be marked complete.' -ForegroundColor Red
        exit 1
    }
    if ($unresolved.Count -gt 0) {
        Write-Host 'Phase 7 is incomplete: some steps were skipped or inconclusive.' -ForegroundColor Yellow
        exit 2
    }
    Write-Host 'All driven steps passed. Submit the evidence for review before changing any status.' -ForegroundColor Green
} finally {
    [Console]::OutputEncoding = $originalOutputEncoding
}
