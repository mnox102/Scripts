$out = "C:\Windows\Temp\winget-diag-$env:COMPUTERNAME.txt"
Start-Transcript -Path $out -Force

'=== App Installer (alle Benutzer / provisioniert) ==='
Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller | Select-Object Name, Version, InstallLocation | Format-List
Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like '*DesktopAppInstaller*' | Select-Object DisplayName, Version

'=== Alle winget.exe im SYSTEM-Pfad ==='
$all = Get-ChildItem 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe' -ErrorAction SilentlyContinue
foreach ($w in $all) { $w.FullName; & $w.FullName --version }

$wg = ($all | Sort-Object { [version](($_.Directory.Name -split '_')[1]) } -Descending | Select-Object -First 1).FullName
"Verwendet: $wg"
& $wg --info
& $wg source list

'=== Test winget-Quelle ==='
& $wg search --id Mozilla.Firefox --source winget --accept-source-agreements --disable-interactivity
'=== Test msstore-Quelle ==='
& $wg search notepad --source msstore --accept-source-agreements --disable-interactivity
"Exitcode msstore: $LASTEXITCODE"

'=== Proxy SYSTEM (WinHTTP) ==='
netsh winhttp show proxy

'=== Zertifikat msstore-Endpunkt ==='
try {
  $req = [Net.HttpWebRequest]::Create('https://storeedgefd.dsx.mp.microsoft.com')
  try { $req.GetResponse() | Out-Null } catch {}
  $req.ServicePoint.Certificate | Format-List Subject, Issuer
} catch { $_.Exception.Message }

Stop-Transcript
