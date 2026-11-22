$ErrorActionPreference = "Stop"

Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, OSArchitecture

$service = Get-Service -Name "Apple Mobile Device Service" -ErrorAction SilentlyContinue
if ($service) {
    $service | Select-Object DisplayName, Status
} else {
    Write-Host "Apple Mobile Device Service was not found. Install or repair Apple's Windows device driver."
}

$appleDevices = @(
    Get-PnpDevice -PresentOnly | Where-Object {
        $_.InstanceId -like "USB\VID_05AC*" -or $_.FriendlyName -eq "Apple iPhone"
    }
)
if ($appleDevices.Count -eq 0) {
    Write-Host "Windows did not list a connected Apple USB device. Unlock the phone and check the cable and USB port."
} else {
    $appleDevices | Select-Object Status, Class, FriendlyName
    Write-Host "Use the Apple device app or iLoader to confirm trust and pairing."
}
