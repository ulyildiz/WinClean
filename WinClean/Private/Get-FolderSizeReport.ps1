function Initialize-FolderSizer {
    if ('WinClean.FolderSizer' -as [type]) { return }
    # C# 5 (what Windows PowerShell's Add-Type compiles): no interpolation, no tuples
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;

namespace WinClean {
    public sealed class FolderSize {
        public string Path;
        public int Depth;
        public long Bytes;
        public long Files;
    }

    public sealed class FolderScanResult {
        public string Root;
        public long TotalBytes;
        public long TotalFiles;
        public int Inaccessible;
        public int ReparsePointsSkipped;
        public List<FolderSize> Folders = new List<FolderSize>();
    }

    // Read-only. Iterative (no recursion limit), never follows junctions / symlinks, and
    // skips reparse-point files too (OneDrive online-only placeholders report a size they
    // do not occupy). Folders that cannot be read are counted, not fatal.
    public static class FolderSizer {
        public static FolderScanResult Scan(string root, int maxDepth) {
            FolderScanResult result = new FolderScanResult();
            result.Root = root;

            List<int> parent = new List<int>();
            List<int> depth = new List<int>();
            List<long> bytes = new List<long>();
            List<long> files = new List<long>();
            List<string> path = new List<string>();

            parent.Add(-1); depth.Add(0); bytes.Add(0); files.Add(0); path.Add(root);
            Stack<KeyValuePair<int, DirectoryInfo>> stack = new Stack<KeyValuePair<int, DirectoryInfo>>();
            stack.Push(new KeyValuePair<int, DirectoryInfo>(0, new DirectoryInfo(root)));

            while (stack.Count > 0) {
                KeyValuePair<int, DirectoryInfo> frame = stack.Pop();
                int index = frame.Key;
                try {
                    foreach (FileSystemInfo entry in frame.Value.EnumerateFileSystemInfos()) {
                        if ((entry.Attributes & FileAttributes.ReparsePoint) != 0) { result.ReparsePointsSkipped++; continue; }
                        DirectoryInfo dir = entry as DirectoryInfo;
                        if (dir != null) {
                            int childDepth = depth[index] + 1;
                            int child = parent.Count;
                            parent.Add(index); depth.Add(childDepth); bytes.Add(0); files.Add(0);
                            path.Add(childDepth <= maxDepth ? dir.FullName : null);
                            stack.Push(new KeyValuePair<int, DirectoryInfo>(child, dir));
                        } else {
                            bytes[index] += ((FileInfo)entry).Length;
                            files[index]++;
                        }
                    }
                }
                catch (UnauthorizedAccessException) { result.Inaccessible++; }
                catch (IOException) { result.Inaccessible++; }
                catch (System.Security.SecurityException) { result.Inaccessible++; }
            }

            // children always have a higher index than their parent: fold sizes upwards
            for (int i = parent.Count - 1; i > 0; i--) {
                bytes[parent[i]] += bytes[i];
                files[parent[i]] += files[i];
            }

            result.TotalBytes = bytes[0];
            result.TotalFiles = files[0];
            for (int i = 1; i < parent.Count; i++) {
                if (path[i] == null) continue;
                FolderSize f = new FolderSize();
                f.Path = path[i]; f.Depth = depth[i]; f.Bytes = bytes[i]; f.Files = files[i];
                result.Folders.Add(f);
            }
            return result;
        }
    }
}
'@
}

function Get-FolderSizeReport {
    <#
    .SYNOPSIS
        Measures folder sizes under one or more roots (read-only) and returns the largest.
    .DESCRIPTION
        Folders at every level down to -MaxDepth compete for the top -Top places, so a
        large nested folder (e.g. AppData\Local\npm-cache) shows up next to its parents.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Root,
        [ValidateRange(1, 64)][int]$MaxDepth = 3,
        [ValidateRange(1, 1000)][int]$Top = 10
    )

    Initialize-FolderSizer
    $all = New-Object 'System.Collections.Generic.List[object]'
    $scans = New-Object 'System.Collections.Generic.List[object]'

    foreach ($r in $Root) {
        $summary = [pscustomobject]@{
            PSTypeName           = 'WinClean.FolderScan'
            Root                 = $r
            TotalBytes           = 0L
            TotalFiles           = 0L
            Inaccessible         = 0
            ReparsePointsSkipped = 0
            Error                = $null
        }
        if (-not (Test-Path -LiteralPath $r -PathType Container)) {
            $summary.Error = 'folder not found'
            $scans.Add($summary)
            continue
        }
        $full = (Resolve-Path -LiteralPath $r).ProviderPath
        $summary.Root = $full
        $scan = [WinClean.FolderSizer]::Scan($full, $MaxDepth)
        $summary.TotalBytes = $scan.TotalBytes
        $summary.TotalFiles = $scan.TotalFiles
        $summary.Inaccessible = $scan.Inaccessible
        $summary.ReparsePointsSkipped = $scan.ReparsePointsSkipped
        $scans.Add($summary)

        foreach ($f in $scan.Folders) {
            $all.Add([pscustomobject]@{
                PSTypeName = 'WinClean.FolderSize'
                Name       = Split-Path -Path $f.Path -Leaf
                Path       = $f.Path
                Depth      = $f.Depth
                Bytes      = $f.Bytes
                Files      = $f.Files
                Root       = $full
            })
        }
    }

    [pscustomobject]@{
        Scans   = $scans.ToArray()
        Folders = @($all | Sort-Object -Property Bytes -Descending | Select-Object -First $Top)
    }
}
