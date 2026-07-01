# Copies only the Swift runtime DLLs actually reachable from the app, by walking
# the dependency graph (dumpbin /dependents) from the shipped binaries — the
# Windows analog of packaging/linux/collect-swift-libs.sh. Replaces a blind glob
# of the whole runtime dir, dropping DLLs nothing imports (XCTest, Testing,
# plugin server, demangle...). dumpbin comes from MSVC (msvc-dev-cmd puts it on
# PATH). The smoke test that follows is the safety net if the walk misses one.

param(
    [string]$DestDir = "dist\desgrana",
    [string[]]$Roots = @("dist\desgrana\desgrana-gui.exe",
                          "dist\desgrana\DesgranaBridge.dll")
)
$ErrorActionPreference = "Stop"

# The Swift runtime bin dir doubles as the filter ("is this a Swift DLL?") and
# the source to copy from. Same location the previous glob used.
$swiftDir = (Resolve-Path "$env:LOCALAPPDATA\Programs\Swift\Runtimes\*\usr\bin" `
             -ErrorAction SilentlyContinue | Select-Object -First 1).Path
if (-not $swiftDir) {
    throw "Swift runtime dir not found under $env:LOCALAPPDATA\Programs\Swift\Runtimes\*\usr\bin"
}

function Get-Dependents([string]$file) {
    # Lines like "    swiftCore.dll" in dumpbin's dependencies section.
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
