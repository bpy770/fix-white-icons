<#
.SYNOPSIS
    Diagnose and repair the white (blank) desktop icon problem caused by a Low
    mandatory integrity label on the Desktop directory.

.DESCRIPTION
    Windows Mandatory Integrity Control can put a "mandatory label" ACE on a
    directory. When the Desktop directory carries a Low label (SID S-1-16-4096)
    with the No-Write-Up policy, every file inside it - including .lnk shortcuts -
    inherits that label. The shell then treats those shortcuts as untrusted and
    refuses to resolve the target executable's icon, so the desktop shows the
    generic blank page icon instead. Restoring the Medium label (S-1-16-8192) on
    the directory removes the inherited Low labels and icon resolution recovers.

    This script reads and writes that mandatory label ACE through the Windows
    security APIs (GetNamedSecurityInfo / SetNamedSecurityInfo, via P/Invoke),
    so it never depends on parsing localized icacls output. Both calls request
    LABEL_SECURITY_INFORMATION, which selects the integrity label alone: no
    audit ACE is ever read back or replaced, the DACL (ordinary file
    permissions) is preserved untouched, and no file is created, moved, or
    deleted. Using the label-specific access right is also what makes the tool
    work without administrator rights, since it - unlike a whole-SACL write -
    does not require SeSecurityPrivilege.

    If the integrity label cannot be modified through the API - for example when
    the target is owned by another account - the script stops and reports the
    failure. It does not silently fall back to a different mechanism; pass
    -AllowIcaclsFallback to explicitly permit an icacls read/set fallback.

.PARAMETER Path
    Directory whose mandatory integrity label is inspected and repaired.
    Defaults to the current user's Desktop folder, resolved through the shell
    (which also covers a Desktop redirected to a non-default location).

.PARAMETER CheckOnly
    Report the current label and exit without changing anything and without
    restarting Explorer. Exit code 2 means "a Low label was found".

.PARAMETER NoRestart
    Repair the label but do not restart Explorer.

.PARAMETER Log
    Path of the log file to append to. Defaults to fix-log.txt next to the script.

.PARAMETER AllowIcaclsFallback
    Permit falling back to icacls when the API path fails. Off by default.

.PARAMETER Quiet
    Suppress the human-readable report and emit only the structured result
    object, so the script can be used in a pipeline or with ConvertTo-Json.
    Warnings are still shown, and the exit codes are unchanged.

.PARAMETER StatusOnly
    Print one plain-language Chinese status line instead of the full report.
    Used by fix-white-icons.bat, whose own text must stay ASCII. The Chinese
    text is defined in this UTF-8 script, so it always renders correctly.

.OUTPUTS
    One structured object (PSCustomObject) with the current label, whether a
    change was made, and the label after the change.

.EXIT CODES
    0  Label is already Medium (or higher): nothing to repair.
    0  A Low label was found and successfully repaired (or repaired, with
       -NoRestart leaving Explorer alone).
    1  Failure: path missing, not a directory, or the label could not be read
       or written.
    2  -CheckOnly only: a Low label was found and would need repair.

.EXAMPLE
    .\Fix-WhiteIcons.ps1 -CheckOnly
    Inspect the desktop label only - changes nothing, never restarts Explorer.

.EXAMPLE
    .\Fix-WhiteIcons.ps1
    Repair the desktop label if needed, then restart Explorer.

.EXAMPLE
    .\Fix-WhiteIcons.ps1 -Path 'D:\MyFolder' -NoRestart -Log 'C:\Temp\fix.log'
    Repair another directory without restarting Explorer.

.NOTES
    Windows 10 / 11, PowerShell 5.1 or later.
    No administrator rights are required for a Desktop you own: the integrity
    label can be read and written by its owner. Elevation is only needed when
    the target directory belongs to another account or to a protected system
    location.
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Path,

    [switch]$CheckOnly,

    [switch]$NoRestart,

    [string]$Log,

    [switch]$AllowIcaclsFallback,

    [switch]$Quiet,

    [switch]$StatusOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 renders Write-Host text using the console output code
# page, which is the local ANSI code page (936 on a Chinese system) unless it is
# pinned. The Chinese status line below is stored as UTF-8 in this file, so the
# output encoding is set to UTF-8 here; without this the status text is mangled
# whenever the console code page and this file's encoding disagree.
try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
}
catch {
    # No console attached (for example a non-interactive host): nothing to set.
}

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# All user-facing Chinese text lives in this UTF-8 script, so the batch wrapper
# can stay pure ASCII. See the encoding note in fix-white-icons.bat: cmd.exe
# mis-parses a UTF-8 batch file that both switches to code page 65001 and
# carries multi-byte text.
$script:Messages = @{
    StatusOk                = '[状态] 桌面完整性标签正常（Medium 或更高），无需修复。'
    StatusLow               = '[状态] 检测到 Low 完整性标签，但当前是仅检测模式，未做任何修改。去掉 -CheckOnly 再运行一次即可修复。'
    StatusRepaired          = '[状态] 已修复：完整性标签已从 Low 改回 Medium，并已重启资源管理器重画图标。'
    StatusRepairedNoRestart = '[状态] 已修复：完整性标签已从 Low 改回 Medium。已指定 -NoRestart，资源管理器未重启。'
    StatusFailed            = '[状态][失败] {0}'
    StatusUnknown           = '[状态][失败] 未预期的结果，请查看日志文件。'
}

# Integrity level RIDs carried by SIDs in the S-1-16-<RID> authority.
$script:IntegrityLevels = @{
    0     = 'Untrusted'
    4096  = 'Low'
    8192  = 'Medium'
    12288 = 'High'
    16384 = 'System'
}

# What this tool repairs to. Medium is the level a normal user directory has.
$script:TargetIntegrityRid  = 8192
$script:TargetIntegrityName = 'Medium'

# No-Write-Up: the mandatory policy a Low desktop label carries.
$script:SYSTEM_MANDATORY_LABEL_NO_WRITE_UP = 0x1

# ACE flags applied to the label so it is also inherited by child objects,
# matching what `icacls <dir> /setintegritylevel Medium` produces.
$script:AceFlagsObjectAndContainerInherit = 0x1 -bor 0x2   # (OI)(CI)

# Exit codes.
$script:ExitOk            = 0
$script:ExitFailure       = 1
$script:ExitRepairNeeded  = 2

$script:LogPath = $null

# ---------------------------------------------------------------------------
# Console output
# ---------------------------------------------------------------------------

# Console ink chosen to stay legible on both a dark and a light console theme.
$script:HostColor = 'Cyan'

function Write-Report {
    <#
        Human-readable progress and result text. These lines are suppressed by
        -Quiet, which leaves the structured object as the only thing written to
        the success stream, and by -StatusOnly, which prints a single localized
        status line instead. In both cases the details still reach the log file,
        so nothing is lost.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Message = '',
        [System.ConsoleColor]$ForegroundColor = $script:HostColor
    )

    if ($Quiet -or $StatusOnly) { return }
    Write-Host $Message -ForegroundColor $ForegroundColor
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $script:LogPath) { return }

    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line  = "$stamp  $Message"

    try {
        # [System.IO.Path] is used instead of Split-Path because Windows
        # PowerShell 5.1's Split-Path has no -LiteralPath parameter, and a log
        # path containing wildcard characters would otherwise be misinterpreted.
        $dir = [System.IO.Path]::GetDirectoryName($script:LogPath)
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        # The mandatory label is documented in the log as an SDDL fragment, so
        # the log itself stays pure ASCII regardless of the system language.
        # System.IO is used instead of Add-Content because the -Encoding
        # parameter set differs between Windows PowerShell 5.1 and PowerShell 7,
        # while a UTF8Encoding without a byte order mark is accepted by both and
        # also avoids appending a BOM on every line of an existing log.
        [System.IO.File]::AppendAllText($script:LogPath, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch {
        Write-Warning "Could not write the log file '$script:LogPath': $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# P/Invoke layer: read and write the mandatory label ACE in the SACL
# ---------------------------------------------------------------------------

if (-not ('DshWhiteIcon.NativeSecurity' -as [type])) {
    $nativeSource = @'
using System;
using System.Runtime.InteropServices;

namespace DshWhiteIcon
{
    [StructLayout(LayoutKind.Sequential)]
    public struct ACL_SIZE_INFORMATION
    {
        public uint AceCount;
        public uint AclBytesInUse;
        public uint AclBytesFree;
    }

    public static class NativeSecurity
    {
        public const int SE_PRIVILEGE_ENABLED = 0x00000002;
        public const uint SE_SECURITY_NAME = 1;      // SE_SECURITY_NAME
        public const uint DACL_SECURITY_INFORMATION = 0x00000004;

        // LABEL_SECURITY_INFORMATION selects only the mandatory integrity label
        // ACE, not the whole SACL. This matters: reading or writing a SACL needs
        // SeSecurityPrivilege, which a standard user token does not hold, while
        // the integrity label is explicitly exempt from that requirement. Using
        // 0x10 is therefore what lets this tool work without administrator
        // rights, and it also guarantees that only label ACEs are ever touched.
        public const uint LABEL_SECURITY_INFORMATION = 0x00000010;

        // SACL_SECURITY_INFORMATION is used only by the optional fallback probe.
        public const uint SACL_SECURITY_INFORMATION = 0x00000008;

        // ACE types
        public const byte ACCESS_ALLOWED_ACE_TYPE = 0x00;
        public const byte ACCESS_DENIED_ACE_TYPE = 0x01;
        public const byte SYSTEM_MANDATORY_LABEL_ACE_TYPE = 0x11;

        // Every pointer-to-pointer parameter must be declared "out IntPtr": the
        // CLR then passes the address of the local instead of marshalling the
        // (zero) value, which is what made the first version fail with a bogus
        // Win32 error. CharSet.Unicode is explicit because GetNamedSecurityInfoW
        // is the Unicode entry point.
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern uint GetNamedSecurityInfo(
            string pObjectName,
            int ObjectType,
            uint SecurityInfo,
            out IntPtr ppsidOwner,
            out IntPtr ppsidGroup,
            out IntPtr ppDacl,
            out IntPtr ppSacl,
            out IntPtr ppSecurityDescriptor);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern uint SetNamedSecurityInfo(
            string pObjectName,
            int ObjectType,
            uint SecurityInfo,
            IntPtr psidOwner,
            IntPtr psidGroup,
            IntPtr pDacl,
            IntPtr pSacl);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool GetAce(IntPtr pAcl, uint dwAceIndex, out IntPtr pAce);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool InitializeAcl(byte[] pAcl, uint nAclLength, uint dwAclRevision);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool AddMandatoryAce(
            byte[] pAcl, uint dwAceRevision, uint AceFlags, uint MandatoryPolicy, byte[] pLabelSid);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool GetAclInformation(
            IntPtr pAcl, ref ACL_SIZE_INFORMATION pAclInformation, uint nAclInformationLength, int dwAclInformationClass);

        // LocalFree lives in kernel32, not advapi32.
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr LocalFree(IntPtr hMem);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr GetCurrentProcess();
    }
}
'@

    Add-Type -TypeDefinition $nativeSource -Language CSharp | Out-Null
}

# ---------------------------------------------------------------------------
# Reading the mandatory label
# ---------------------------------------------------------------------------

function Get-SidIntegrityInfo {
    <#
        Converts a S-1-16-<RID> SID to its integrity level. Returns $null when the
        SID is not an integrity SID: only SIDs whose authority is SECURITY_
        MANDATORY_LABEL_AUTHORITY (S-1-16) describe an integrity level.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][IntPtr]$SidPointer
    )

    try {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($SidPointer)
    }
    catch {
        return $null
    }

    $value = $sid.Value
    if ($value -notmatch '^S-1-16-(\d+)$') { return $null }

    $rid = [int]$Matches[1]

    $name = "RID $rid"
    if ($script:IntegrityLevels.ContainsKey($rid)) {
        $name = $script:IntegrityLevels[$rid]
    }

    return [pscustomobject]@{
        Rid   = $rid
        Level = $name
        Sid   = $value
    }
}

function Get-MandatoryLabel {
    <#
        Reads the mandatory label ACE of the object through GetNamedSecurityInfo,
        asking for LABEL_SECURITY_INFORMATION so that only integrity label ACEs
        are returned. Because the result set contains nothing but labels, no
        audit ACE can be reported or later replaced by accident, and the call
        succeeds without SeSecurityPrivilege.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath
    )

    $sacl        = [IntPtr]::Zero
    $sd          = [IntPtr]::Zero
    $ownerPtr    = [IntPtr]::Zero
    $groupPtr    = [IntPtr]::Zero
    $daclPtr     = [IntPtr]::Zero
    $labels      = New-Object System.Collections.ArrayList

    try {
        $rc = [DshWhiteIcon.NativeSecurity]::GetNamedSecurityInfo(
            $LiteralPath, 1,   # SE_FILE_OBJECT
            [DshWhiteIcon.NativeSecurity]::LABEL_SECURITY_INFORMATION,
            [ref]$ownerPtr, [ref]$groupPtr, [ref]$daclPtr, [ref]$sacl, [ref]$sd)

        if ($rc -ne 0) {
            throw "GetNamedSecurityInfo failed with Win32 error $rc."
        }

        if ($sacl -eq [IntPtr]::Zero) {
            return [pscustomobject]@{
                Labels       = @()
                CurrentRid   = $null
                CurrentLevel = 'None'
                HasLowLabel  = $false
                SddlFragment = ''
                Error        = ''
            }
        }

        $sizeInfo = New-Object DshWhiteIcon.ACL_SIZE_INFORMATION
        if (-not [DshWhiteIcon.NativeSecurity]::GetAclInformation(
                $sacl, [ref]$sizeInfo, [uint32][Runtime.InteropServices.Marshal]::SizeOf($sizeInfo), 2)) {   # AclSizeInformation
            throw "GetAclInformation failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
        }

        for ($i = 0; $i -lt $sizeInfo.AceCount; $i++) {
            $acePtr = [IntPtr]::Zero
            if (-not [DshWhiteIcon.NativeSecurity]::GetAce($sacl, [uint32]$i, [ref]$acePtr)) { continue }
            if ($acePtr -eq [IntPtr]::Zero) { continue }

            # ACE_HEADER: AceType (1 byte), AceFlags (1 byte), AceSize (2 bytes)
            $aceType  = [Runtime.InteropServices.Marshal]::ReadByte($acePtr, 0)
            $aceFlags = [Runtime.InteropServices.Marshal]::ReadByte($acePtr, 1)

            if ($aceType -ne [DshWhiteIcon.NativeSecurity]::SYSTEM_MANDATORY_LABEL_ACE_TYPE) { continue }

            # SYSTEM_MANDATORY_LABEL_ACE: header(4) + Mask(4) + Sid starts at 8
            $mask    = [Runtime.InteropServices.Marshal]::ReadInt32($acePtr, 4)
            $sidPtr  = [IntPtr]::Add($acePtr, 8)
            $info    = Get-SidIntegrityInfo -SidPointer $sidPtr

            if ($null -eq $info) { continue }

            [void]$labels.Add([pscustomobject]@{
                Rid          = $info.Rid
                Level        = $info.Level
                Sid          = $info.Sid
                NoWriteUp    = (($mask -band $script:SYSTEM_MANDATORY_LABEL_NO_WRITE_UP) -ne 0)
                Inherited    = (($aceFlags -band 0x10) -ne 0)   # INHERITED_ACE
            })
        }

        # The effective label is the most restrictive one present.
        $effective      = $null
        $sddlFragments  = New-Object System.Collections.ArrayList
        foreach ($label in $labels) {
            if ($null -eq $effective -or $label.Rid -lt $effective.Rid) { $effective = $label }
            $policy = if ($label.NoWriteUp) { 'NW' } else { 'NONE' }
            [void]$sddlFragments.Add("S:(ML;;$policy;;;$($label.Sid))")
        }

        return [pscustomobject]@{
            Labels       = @($labels)
            CurrentRid   = if ($effective) { $effective.Rid } else { $null }
            CurrentLevel = if ($effective) { $effective.Level } else { 'None' }
            HasLowLabel  = ($null -ne $effective -and $effective.Rid -lt $script:TargetIntegrityRid)
            SddlFragment = ($sddlFragments -join ' ')
            Error        = ''
        }
    }
    finally {
        if ($sd -ne [IntPtr]::Zero) { [void][DshWhiteIcon.NativeSecurity]::LocalFree($sd) }
    }
}

# ---------------------------------------------------------------------------
# Writing the mandatory label
# ---------------------------------------------------------------------------

function Set-MandatoryLabel {
    <#
        Replaces the object's mandatory label ACEs with a single label at the
        requested integrity level, using SetNamedSecurityInfo with
        LABEL_SECURITY_INFORMATION. That flag restricts the write to the
        integrity label, so the DACL, the owner, the group and any audit ACEs
        are left exactly as they were - and, unlike a full SACL write, it does
        not require SeSecurityPrivilege. The label SID is built directly as
        S-1-16-<rid>, so no localized group name is involved.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,

        [Parameter(Mandatory = $true)][int]$IntegrityRid
    )

    # SID layout: Revision(1) SubAuthorityCount(1) IdentifierAuthority(6) SubAuthorities(4 each)
    $sidBytes = New-Object byte[] 16
    $sidBytes[0] = 1        # SID_REVISION
    $sidBytes[1] = 1        # one sub-authority
    $sidBytes[2] = 0; $sidBytes[3] = 0; $sidBytes[4] = 0
    $sidBytes[5] = 0; $sidBytes[6] = 0; $sidBytes[7] = 16   # SECURITY_MANDATORY_LABEL_AUTHORITY
    $ridBytes  = [BitConverter]::GetBytes([uint32]$IntegrityRid)
    [Array]::Copy($ridBytes, 0, $sidBytes, 8, 4)

    # ACL: header (8 bytes) + one mandatory label ACE (4 header + 4 mask + 16 SID)
    $aclBytes = New-Object byte[] 32

    if (-not [DshWhiteIcon.NativeSecurity]::InitializeAcl($aclBytes, [uint32]$aclBytes.Length, 2)) {   # ACL_REVISION
        throw "InitializeAcl failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
    }

    $policy = [uint32]$script:SYSTEM_MANDATORY_LABEL_NO_WRITE_UP
    if (-not [DshWhiteIcon.NativeSecurity]::AddMandatoryAce(
            $aclBytes, 2, [uint32]$script:AceFlagsObjectAndContainerInherit, $policy, $sidBytes)) {
        throw "AddMandatoryAce failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())."
    }

    $handle = [Runtime.InteropServices.GCHandle]::Alloc($aclBytes, [Runtime.InteropServices.GCHandleType]::Pinned)
    try {
        $rc = [DshWhiteIcon.NativeSecurity]::SetNamedSecurityInfo(
            $LiteralPath, 1,   # SE_FILE_OBJECT
            [DshWhiteIcon.NativeSecurity]::LABEL_SECURITY_INFORMATION,
            [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, $handle.AddrOfPinnedObject())

        if ($rc -ne 0) {
            throw "SetNamedSecurityInfo failed with Win32 error $rc."
        }
    }
    finally {
        $handle.Free()
    }
}

# ---------------------------------------------------------------------------
# icacls fallback (opt-in only)
# ---------------------------------------------------------------------------

function Get-MandatoryLabelViaIcacls {
    <#
        Opt-in fallback. Parses icacls output, so it depends on how the local
        system renders the integrity level name; the English forms and the
        language-neutral SID form are both accepted. Only reached when
        -AllowIcaclsFallback is given and the API path failed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath
    )

    $output = & icacls.exe "$LiteralPath" 2>&1 | Out-String

    $hasLow = $false
    if ($output -match 'S-1-16-4096' -or
        $output -match 'Low Mandatory Level' -or
        $output -match ([string][char]0x4F4E + [string][char]0x5F3A + [string][char]0x5236 + [string][char]0x7EA7 + [string][char]0x522B)) {
        $hasLow = $true
    }

    return [pscustomobject]@{
        CurrentRid   = if ($hasLow) { 4096 } else { $null }
        CurrentLevel = if ($hasLow) { 'Low' } else { 'Unknown' }
        HasLowLabel  = $hasLow
        Raw          = $output.Trim()
        Method       = 'icacls'
    }
}

# ---------------------------------------------------------------------------
# Explorer restart
# ---------------------------------------------------------------------------

function Restart-ExplorerShell {
    <#
        Restarts explorer.exe so the shell redraws the desktop icons. The icon
        bitmaps are painted by Explorer from the system image list, so an ACL
        change alone does not repaint them. Takes no other action.
    #>
    [CmdletBinding()]
    param()

    Write-Host 'Restarting Explorer to redraw the desktop icons...' -ForegroundColor Cyan

    $stopped = $false
    try {
        Get-Process -Name 'explorer' -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
        $stopped = $true
    }
    catch {
        Write-Warning "Could not stop explorer.exe: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds 3

    $explorerPath = Join-Path $env:WINDIR 'explorer.exe'
    Start-Process -FilePath $explorerPath -ErrorAction SilentlyContinue | Out-Null
    Start-Sleep -Seconds 6

    $running = Get-Process -Name 'explorer' -ErrorAction SilentlyContinue
    if (-not $running) {
        Write-Warning 'Explorer did not start; trying once more...'
        Start-Process -FilePath $explorerPath -ErrorAction SilentlyContinue | Out-Null
        Start-Sleep -Seconds 5
        $running = Get-Process -Name 'explorer' -ErrorAction SilentlyContinue
    }

    if ($running) {
        Write-Host 'Explorer is running again.' -ForegroundColor Green
        return $true
    }

    Write-Warning 'Explorer is still not running.'
    Write-Host 'If the taskbar is missing: press Ctrl+Shift+Esc, then File > Run new task > explorer.exe > Enter.' -ForegroundColor Yellow
    return $false
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

function New-Result {
    <#
        Builds the single structured result object this script writes to the
        pipeline. Every return path produces one, so a caller can always inspect
        what happened without parsing the human-readable report.
    #>
    [CmdletBinding()]
    param(
        [string]$ResultPath,
        [string]$CurrentLevel,
        [Nullable[int]]$CurrentRid,
        [string]$Sddl,
        [bool]$IsLow,
        [bool]$RepairAttempted,
        [bool]$RepairSucceeded,
        [string]$LevelAfter,
        [Nullable[int]]$RidAfter,
        [string]$Method,
        [string]$Message,
        [int]$ExitCode,
        [bool]$ExplorerRestarted
    )

    return [pscustomobject]@{
        Path             = $ResultPath
        CurrentLevel     = $CurrentLevel
        CurrentRid       = $CurrentRid
        CurrentSddl      = $Sddl
        IsLowLabel       = $IsLow
        RepairAttempted  = $RepairAttempted
        RepairSucceeded  = $RepairSucceeded
        LevelAfter       = $LevelAfter
        RidAfter         = $RidAfter
        Method           = $Method
        Message          = $Message
        ExplorerRestarted = $ExplorerRestarted
        LogPath          = $script:LogPath
        ExitCode         = $ExitCode
    }
}

function Invoke-WhiteIconFix {
    [CmdletBinding()]
    param()

    # Default target: the current user's Desktop as the shell resolves it, which
    # also covers a Desktop redirected away from %USERPROFILE%\Desktop.
    $target = $Path
    if ([string]::IsNullOrWhiteSpace($target)) {
        $target = [Environment]::GetFolderPath('Desktop')
    }
    if ([string]::IsNullOrWhiteSpace($target)) {
        $target = Join-Path $env:USERPROFILE 'Desktop'
    }

    try {
        $resolved = (Resolve-Path -LiteralPath $target -ErrorAction Stop).ProviderPath
    }
    catch {
        Write-Report "The path does not exist: $target" -ForegroundColor Red
        Write-Log "FAILURE  target not found: $target"
        return New-Result -ResultPath $target -CurrentLevel 'Unknown' -Message 'The path does not exist.' `
            -ExitCode $script:ExitFailure
    }

    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        Write-Report "The path is not a directory: $resolved" -ForegroundColor Red
        Write-Log "FAILURE  not a directory: $resolved"
        return New-Result -ResultPath $resolved -CurrentLevel 'Unknown' -Message 'The path is not a directory.' `
            -ExitCode $script:ExitFailure
    }

    if ($resolved.StartsWith('\\')) {
        Write-Report 'A UNC path was given. Integrity labels are not supported on network shares.' -ForegroundColor Red
        Write-Log "FAILURE  UNC path is not supported: $resolved"
        return New-Result -ResultPath $resolved -CurrentLevel 'Unknown' -Message 'UNC paths are not supported.' `
            -ExitCode $script:ExitFailure
    }

    Write-Report ''
    Write-Report 'Desktop white-icon repair' -ForegroundColor White
    Write-Report '=========================' -ForegroundColor White
    Write-Report "Directory : $resolved"
    Write-Report "Mode      : $(if ($CheckOnly) { 'check only (nothing is changed)' } else { 'repair if needed' })"
    Write-Report ''

    # ---- read the current label -------------------------------------------
    $readMethod = 'integrity label API (GetNamedSecurityInfo)'
    $label      = $null

    try {
        $label = Get-MandatoryLabel -LiteralPath $resolved
    }
    catch {
        Write-Warning "Reading the mandatory label through the API failed: $($_.Exception.Message)"

        if (-not $AllowIcaclsFallback) {
            Write-Report ''
            Write-Report 'Could not read the mandatory label. This is unexpected for a directory you own.' -ForegroundColor Red
            Write-Report 'Pass -AllowIcaclsFallback to read the label by parsing icacls output instead.' -ForegroundColor Red
            Write-Log "FAILURE  label read failed: $($_.Exception.Message)"
            return New-Result -ResultPath $resolved -CurrentLevel 'Unknown' -Message $_.Exception.Message `
                -ExitCode $script:ExitFailure
        }

        Write-Report 'Falling back to icacls output parsing (-AllowIcaclsFallback was given).' -ForegroundColor Yellow
        $label      = Get-MandatoryLabelViaIcacls -LiteralPath $resolved
        $readMethod = 'icacls output parsing (fallback)'
    }

    $sddl = ''
    if ($label.PSObject.Properties['SddlFragment'] -and $label.SddlFragment) { $sddl = $label.SddlFragment }

    Write-Report "Read via  : $readMethod"
    Write-Report "Label now : $($label.CurrentLevel)$(if ($null -ne $label.CurrentRid) { " (S-1-16-$($label.CurrentRid))" })"
    if ($sddl) { Write-Report "SDDL      : $sddl" }
    Write-Report ''

    # ---- already healthy ---------------------------------------------------
    if (-not $label.HasLowLabel) {
        Write-Report 'No Low integrity label found on this directory.' -ForegroundColor Green
        Write-Report 'If desktop icons are still blank, the cause is something else; see the README self-check table.'
        Write-Log "OK       $resolved already at $($label.CurrentLevel); no change made."
        return New-Result -ResultPath $resolved -CurrentLevel $label.CurrentLevel -CurrentRid $label.CurrentRid `
            -Sddl $sddl -IsLow $false -LevelAfter $label.CurrentLevel -RidAfter $label.CurrentRid `
            -Method 'read only' -Message 'No Low integrity label present; nothing to repair.' `
            -ExitCode $script:ExitOk
    }

    Write-Report "Found a Low integrity label on this directory (S-1-16-$($label.CurrentRid))." -ForegroundColor Yellow
    Write-Report 'Children inherit it, so the shell treats the shortcuts inside as untrusted,'

    if ($CheckOnly) {
        Write-Report ''
        Write-Report 'Check-only mode: nothing was changed.' -ForegroundColor Yellow
        Write-Log "CHECK    $resolved has a Low integrity label; -CheckOnly so no change was made."
        return New-Result -ResultPath $resolved -CurrentLevel $label.CurrentLevel -CurrentRid $label.CurrentRid `
            -Sddl $sddl -IsLow $true -LevelAfter $label.CurrentLevel -RidAfter $label.CurrentRid `
            -Method 'read only' -Message 'A Low integrity label was found; -CheckOnly so nothing was changed.' `
            -ExitCode $script:ExitRepairNeeded
    }

    # ---- write the label ---------------------------------------------------
    $writeMethod = 'integrity label API (SetNamedSecurityInfo)'
    $writeError  = ''

    try {
        Set-MandatoryLabel -LiteralPath $resolved -IntegrityRid $script:TargetIntegrityRid
        Write-Log "REPAIRED $resolved  S-1-16-$($label.CurrentRid) -> S-1-16-$($script:TargetIntegrityRid)"
    }
    catch {
        $writeError = $_.Exception.Message

        if (-not $AllowIcaclsFallback) {
            Write-Report ''
            Write-Report "Could not set the label: $writeError" -ForegroundColor Red
            Write-Report 'Setting a mandatory label on an object you do not own - or on a protected system' -ForegroundColor Red
            Write-Report 'location - needs an elevated PowerShell. No administrator rights are needed for your' -ForegroundColor Red
            Write-Report 'own Desktop. Pass -AllowIcaclsFallback to retry through icacls.' -ForegroundColor Red
            Write-Log "FAILURE  $resolved label write failed: $writeError"
            return New-Result -ResultPath $resolved -CurrentLevel $label.CurrentLevel -CurrentRid $label.CurrentRid `
                -Sddl $sddl -IsLow $true -RepairAttempted $true -RepairSucceeded $false `
                -LevelAfter $label.CurrentLevel -Method 'write failed' -Message $writeError `
                -ExitCode $script:ExitFailure
        }

        Write-Report "API write failed ($writeError); retrying with icacls (-AllowIcaclsFallback)." -ForegroundColor Yellow
        $writeMethod = 'icacls /setintegritylevel (fallback)'
        & icacls.exe "$resolved" /setintegritylevel Medium | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Report "icacls also failed with exit code $LASTEXITCODE." -ForegroundColor Red
            Write-Log "FAILURE  $resolved icacls fallback failed with exit code $LASTEXITCODE"
            return New-Result -ResultPath $resolved -CurrentLevel $label.CurrentLevel -CurrentRid $label.CurrentRid `
                -Sddl $sddl -IsLow $true -RepairAttempted $true -RepairSucceeded $false `
                -LevelAfter $label.CurrentLevel -Method 'icacls fallback' `
                -Message "icacls failed with exit code $LASTEXITCODE." -ExitCode $script:ExitFailure
        }
        Write-Log "REPAIRED $resolved via icacls fallback"
    }

    # ---- verify ------------------------------------------------------------
    $after = $null
    try {
        $after = Get-MandatoryLabel -LiteralPath $resolved
    }
    catch {
        Write-Warning "Could not re-read the label to verify: $($_.Exception.Message)"
    }

    Write-Report ''
    Write-Report "Label set to : $script:TargetIntegrityName (via $writeMethod)"

    $verified = ($null -ne $after -and -not $after.HasLowLabel)
    if ($null -ne $after) {
        Write-Report "Label after  : $($after.CurrentLevel) (S-1-16-$($after.CurrentRid))"
    }

    if (-not $verified) {
        Write-Report 'The label could not be verified as Medium. Re-check with: icacls "<directory>"' -ForegroundColor Red
        Write-Log "FAILURE  $resolved could not be verified after the change."
        return New-Result -ResultPath $resolved -CurrentLevel $label.CurrentLevel -CurrentRid $label.CurrentRid `
            -Sddl $sddl -IsLow $true -RepairAttempted $true -RepairSucceeded $false `
            -LevelAfter 'Unknown' -Method $writeMethod -Message 'The change could not be verified.' `
            -ExitCode $script:ExitFailure
    }

    Write-Report 'Verified: the directory no longer carries a Low integrity label.' -ForegroundColor Green

    # ---- restart explorer --------------------------------------------------
    $restarted = $false
    if ($NoRestart) {
        Write-Report ''
        Write-Report 'NoRestart was given, so Explorer was left alone.' -ForegroundColor Yellow
        Write-Report 'The desktop keeps drawing the old icons until Explorer restarts.'
        Write-Log 'NOTE     -NoRestart: Explorer was not restarted.'
    }
    else {
        Write-Report ''
        $restarted = [bool](Restart-ExplorerShell)
    }

    Write-Report ''
    Write-Report 'Done.' -ForegroundColor Green
    Write-Report 'If a few icons are still blank, press F5 on the desktop to refresh.'
    if ($script:LogPath) { Write-Report "Log file  : $script:LogPath" }

    return New-Result -ResultPath $resolved -CurrentLevel $label.CurrentLevel -CurrentRid $label.CurrentRid `
        -Sddl $sddl -IsLow $true -RepairAttempted $true -RepairSucceeded $true `
        -LevelAfter $after.CurrentLevel -RidAfter $after.CurrentRid -Method $writeMethod `
        -Message 'The Low integrity label was replaced with the Medium label.' `
        -ExitCode $script:ExitOk -ExplorerRestarted $restarted
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($Log)) {
    # Log beside the script, matching the .bat behaviour (%~dp0).
    $scriptDir = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptDir)) {
        $scriptDir = (Get-Location).ProviderPath
    }
    $script:LogPath = Join-Path $scriptDir 'fix-log.txt'
}
else {
    $script:LogPath = $Log
}

$result   = Invoke-WhiteIconFix
$exitCode = [int]$result.ExitCode

# The result object is written to the success stream so callers can capture it,
# with -NoEnumerate so it survives as a single object. -Quiet and -StatusOnly
# both suppress the human-readable report; -StatusOnly additionally replaces the
# object on the console with one localized status line, because its caller
# (fix-white-icons.bat) needs console output it can print unambiguously and must
# not have to render a PowerShell object.
if ($StatusOnly) {
    # The Chinese strings above are source literals in this UTF-8 file, so they
    # are readable in the repository and are unaffected by the console code page
    # the wrapper sets.
    $status = switch -Exact ($exitCode) {
        0 {
            if ($null -ne $result -and $result.RepairSucceeded) {
                if ($result.ExplorerRestarted) { $script:Messages.StatusRepaired }
                else { $script:Messages.StatusRepairedNoRestart }
            }
            else { $script:Messages.StatusOk }
        }
        2 { $script:Messages.StatusLow }
        default {
            if ($result.Message) { $script:Messages.StatusFailed -f $result.Message }
            else { $script:Messages.StatusUnknown }
        }
    }
    Write-Host ''
    Write-Host $status
}
else {
    Write-Output $result -NoEnumerate
}

exit $exitCode
