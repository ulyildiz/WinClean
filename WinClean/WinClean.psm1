Set-StrictMode -Version Latest

# Used by Clear-FolderContents so a module that lives inside a cleanup target never deletes itself.
$script:ModuleRoot = $PSScriptRoot

$private = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
$public  = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public')  -Filter '*.ps1' -File -ErrorAction SilentlyContinue)

foreach ($file in @($private + $public)) {
    try { . $file.FullName }
    catch { throw "WinClean: failed to load '$($file.FullName)': $_" }
}

Export-ModuleMember -Function @($public | ForEach-Object { $_.BaseName })
