function Test-IsAdministrator {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
