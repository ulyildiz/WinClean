function ConvertTo-ArgumentString {
    <#
    .SYNOPSIS
        Joins arguments into one command line, quoted the way CommandLineToArgvW parses them.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyCollection()][string[]]$ArgumentList = @())

    $quoted = foreach ($a in $ArgumentList) {
        if ($a.Length -gt 0 -and $a -notmatch '[\s"]') { $a; continue }
        # double the backslashes that precede a quote (or the closing quote), escape the quote
        $escaped = [regex]::Replace($a, '(\\*)"', { param($m) ($m.Groups[1].Value * 2) + '\"' })
        $escaped = [regex]::Replace($escaped, '(\\+)$', { param($m) $m.Groups[1].Value * 2 })
        '"' + $escaped + '"'
    }
    return ($quoted -join ' ')
}

function Invoke-ExternalCommand {
    <#
    .SYNOPSIS
        Runs a console program with a timeout and captures its output.
    .DESCRIPTION
        Never throws for a missing program, a non-zero exit code or a hang: the result
        object says what happened, so callers can skip safely. A process that exceeds
        -TimeoutSeconds is killed.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [AllowEmptyCollection()][string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [ValidateRange(1, 86400)][int]$TimeoutSeconds = 60
    )

    $result = [pscustomobject]@{
        PSTypeName = 'WinClean.ExternalCommandResult'
        FilePath   = $FilePath
        Arguments  = $ArgumentList
        ExitCode   = $null
        StdOut     = ''
        StdErr     = ''
        TimedOut   = $false
        Started    = $false
        Error      = $null
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ConvertTo-ArgumentString -ArgumentList $ArgumentList
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    try {
        [void]$process.Start()
        $result.Started = $true
        # read both streams asynchronously so a full pipe can never deadlock the child
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $result.TimedOut = $true
            try { $process.Kill() } catch { }
            [void]$process.WaitForExit(5000)
        }
        else {
            $process.WaitForExit()   # flush async readers
            $result.ExitCode = $process.ExitCode
        }
        if ($stdout.Wait(5000)) { $result.StdOut = $stdout.Result }
        if ($stderr.Wait(5000)) { $result.StdErr = $stderr.Result }
    }
    catch {
        $result.Error = $_.Exception.Message
    }
    finally {
        $process.Dispose()
    }
    return $result
}

function Get-ExternalToolPath {
    <#
    .SYNOPSIS
        Resolves a tool to an executable Process.Start can run (prefers .exe / .cmd over .ps1 shims).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)

    foreach ($candidate in "$Name.exe", "$Name.cmd", "$Name.bat") {
        $cmd = Get-Command -Name $candidate -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    return $null
}
