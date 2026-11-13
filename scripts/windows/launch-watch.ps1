param([Parameter(Mandatory=$true)][string]$Exe,
      [Parameter(Mandatory=$true)][string]$Data,
      [switch]$Show)
$ErrorActionPreference = 'Stop'

function Get-LanAddress {
    try {
        Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.IPv4Address } |
            ForEach-Object { $_.IPv4Address.IPAddress } |
            Where-Object { $_ -match '^(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)' } |
            Select-Object -First 1
    } catch { $null }
}

if ($Show) {
    $existing = Get-Process CopyBridge -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe }
    if ($existing) {
        Start-Process -FilePath $exe -ArgumentList "--data $data --notify-existing"
    } else {
        Start-ScheduledTask -TaskName 'CopyBridgeInteractive'
    }
    exit
}

$child = $null
$bound = $null
while ($true) {
    $address = Get-LanAddress
    if ($child -and $child.HasExited) { $child = $null; $bound = $null }
    if ($child -and $address -ne $bound) {
        Stop-Process -Id $child.Id -ErrorAction SilentlyContinue
        $child = $null; $bound = $null
    }
    if ($address -and -not $child) {
        $child = Start-Process -FilePath $exe -ArgumentList "--bind $address --port 43861 --data $data" -PassThru
        $bound = $address
    }
    Start-Sleep -Seconds 10
}
