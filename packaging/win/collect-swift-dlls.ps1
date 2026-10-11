
param(
    [string]$DestDir = "dist\desgrana",
    [string[]]$Roots = @("dist\desgrana\desgrana-gui.exe",
                          "dist\desgrana\DesgranaBridge.dll")
)
$ErrorActionPreference = "Stop"

$swiftDir = (Resolve-Path "$env:LOCALAPPDATA\Programs\Swift\Runtimes\*\usr\bin" `
             -ErrorAction SilentlyContinue | Select-Object -First 1).Path
if (-not $swiftDir) {
    throw "Swift runtime dir not found under $env:LOCALAPPDATA\Programs\Swift\Runtimes\*\usr\bin"
}

function Get-Dependents([string]$file) {
    dumpbin /dependents $file 2>$null |
        Select-String -Pattern '^\s+(\S+\.dll)\s*$' |
        ForEach-Object { $_.Matches[0].Groups[1].Value }
}

$seen  = @{}
$queue = New-Object System.Collections.Queue
$Roots | ForEach-Object { $queue.Enqueue($_) }

while ($queue.Count -gt 0) {
    $file = $queue.Dequeue()
    foreach ($dep in Get-Dependents $file) {
        $key = $dep.ToLower()
        if ($seen.ContainsKey($key)) { continue }
        $src = Join-Path $swiftDir $dep
        if (Test-Path $src) {                       # a Swift runtime DLL → bundle it
            $seen[$key] = $true
            Copy-Item $src -Destination $DestDir -Force
            $queue.Enqueue((Join-Path $DestDir $dep))
            Write-Host "  + $dep"
        }
    }
}

Write-Host "Bundled $($seen.Count) Swift runtime DLL(s) from $swiftDir"
