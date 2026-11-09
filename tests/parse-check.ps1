$errors = $null
$tokens = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path (Split-Path -Parent $PSScriptRoot) 'main.ps1'),
    [ref]$tokens,
    [ref]$errors
)
if ($errors.Count -eq 0) {
    'PARSE OK'
    exit 0
}
$errors | Select-Object Message, Extent | Format-List
exit 1
