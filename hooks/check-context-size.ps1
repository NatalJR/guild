# Maintenance check, not a hook: every file the SessionStart hooks inject must stay under the
# harness cap (a hook's stdout near 10KB is replaced by a 2KB preview). Run after editing
# anything under context/. Exit 1 on a violation.
$limit = 9000
$root = Split-Path -Parent $PSScriptRoot
$failed = $false
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'context') -Filter '*.md') {
    $size = $file.Length
    $state = if ($size -gt $limit) { 'TOO LARGE' } else { 'ok' }
    if ($size -gt $limit) { $failed = $true }
    Write-Output ("{0,-22} {1,6} bytes  {2}" -f $file.Name, $size, $state)
}
if ($failed) { exit 1 }
exit 0
