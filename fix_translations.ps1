# Fix corrupted language files: restore Status entry and clean Offline entry
$langDir = "C:\Users\cri\Desktop\rustdesk-1.4.6\src\lang"
$fixed = 0
$skipped = 0

foreach ($file in Get-ChildItem -Path $langDir -Filter "*.rs") {
    $content = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)

    # Detect corruption: Status line has no value on same line
    if ($content -notmatch '^\s*\("Status",\s*$' -and $content -notmatch '\("Status",\r?\n') {
        $skipped++
        continue
    }

    # Find the broken Offline line: ("Offline", "VALUE1"), "STATUS_VALUE"),
    # Capture group 1 = offline translation, group 2 = status translation (misplaced)
    if ($content -match '\("Offline", "([^"]+)"\), "([^"]+)"\),') {
        $offlineVal = $Matches[1]
        $statusVal  = $Matches[2]

        # Fix the Offline line: remove the trailing , "STATUS_VALUE")
        $brokenOffline = "(`"Offline`", `"$offlineVal`"), `"$statusVal`"),"
        $goodOffline   = "(`"Offline`", `"$offlineVal`"),"
        $content = $content.Replace($brokenOffline, $goodOffline)

        # Fix the Status line: ("Status",\n  ->  ("Status", "STATUS_VALUE"),\n
        # Use regex to handle both \r\n and \n
        $content = $content -replace '\("Status",(\r?\n)', "(`"Status`", `"$statusVal`")`$1"

        [System.IO.File]::WriteAllText($file.FullName, $content, [System.Text.Encoding]::UTF8)
        Write-Host "Fixed: $($file.Name)  (Status=`"$statusVal`")"
        $fixed++
    } else {
        Write-Host "WARN: could not find broken Offline pattern in $($file.Name)"
    }
}

Write-Host "`nFixed $fixed files, skipped $skipped."
