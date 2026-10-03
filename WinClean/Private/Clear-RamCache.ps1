function Get-MemStats {
    [CmdletBinding()]
    param()

    $m = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Memory
    [pscustomobject]@{
        Free    = [double]$m.FreeAndZeroPageListBytes
        Standby = [double]($m.StandbyCacheNormalPriorityBytes + $m.StandbyCacheReserveBytes + $m.StandbyCacheCoreBytes)
    }
}

function Clear-RamCache {
    <#
    .SYNOPSIS
        Empties working sets, flushes the modified page list and purges the standby list.
    .DESCRIPTION
        The modified list is written to disk before anything is dropped, so no data is lost.
        Requires administrator rights. With -DryRun only the current figures are measured.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([switch]$DryRun)

    $result = [pscustomobject]@{
        PSTypeName = 'WinClean.RamResult'
        Before     = Get-MemStats
        After      = $null
        Flushed    = $false
        Failures   = @()
    }
    if ($DryRun) { return $result }

    if (-not ('MemTool' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class MemTool {
    [DllImport("ntdll.dll")] static extern int RtlAdjustPrivilege(int privilege, bool enable, bool currentThread, out bool previous);
    [DllImport("ntdll.dll")] static extern int NtSetSystemInformation(int infoClass, IntPtr info, int length);
    const int SystemMemoryListInformation = 80;
    // 2 = empty working sets, 3 = flush modified list, 4 = purge standby list
    public static int Command(int cmd) {
        bool prev;
        RtlAdjustPrivilege(5,  true, false, out prev);   // SeIncreaseQuotaPrivilege
        RtlAdjustPrivilege(13, true, false, out prev);   // SeProfileSingleProcessPrivilege
        IntPtr p = Marshal.AllocHGlobal(4);
        try { Marshal.WriteInt32(p, cmd); return NtSetSystemInformation(SystemMemoryListInformation, p, 4); }
        finally { Marshal.FreeHGlobal(p); }
    }
}
'@
    }

    $steps = @(
        @{ Name = 'Empty working sets';        Cmd = 2 },
        @{ Name = 'Flush modified page list';  Cmd = 3 },   # writes dirty pages to disk first (no data loss)
        @{ Name = 'Purge standby list';        Cmd = 4 }
    )
    $failures = @()
    foreach ($s in $steps) {
        $rc = [MemTool]::Command($s.Cmd)
        if ($rc -ne 0) { $failures += ('{0} failed (NTSTATUS 0x{1:X8})' -f $s.Name, $rc) }
    }

    Start-Sleep -Seconds 1
    $result.After    = Get-MemStats
    $result.Failures = $failures
    $result.Flushed  = ($failures.Count -lt $steps.Count)
    return $result
}
