$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$arch = $env:BUILD_ARCH
$platform = $env:BUILD_PLATFORM
$toolset = $env:BUILD_TOOLSET
$root = $env:GITHUB_WORKSPACE
$solutionDir = (Resolve-Path (Join-Path $root 'src')).Path + '\'
$project = Join-Path $root 'src\UniversalInjectorFramework\UniversalInjectorFramework.vcxproj'
$detours = Join-Path $root 'src\Detours\Detours.vcxproj'
$packageDir = Join-Path $root "package\$arch"
New-Item -ItemType Directory -Force -Path $packageDir | Out-Null

# Different configuration names: UIF uses proxy names, Detours uses Release.
[xml]$xml = Get-Content -LiteralPath $project -Raw
$nsUri = 'http://schemas.microsoft.com/developer/msbuild/2003'
$ns = [System.Xml.XmlNamespaceManager]::new($xml.NameTable)
$ns.AddNamespace('m', $nsUri)
$reference = $xml.SelectSingleNode("//m:ProjectReference[contains(@Include, 'Detours\Detours.vcxproj')]", $ns)
if ($null -eq $reference) { throw 'Detours ProjectReference not found' }
foreach ($setting in @(@('SetConfiguration','Configuration=Release'), @('SetPlatform','Platform=$(Platform)'))) {
    $node = $reference.SelectSingleNode("m:$($setting[0])", $ns)
    if ($null -eq $node) {
        $node = $xml.CreateElement($setting[0], $nsUri)
        [void]$reference.AppendChild($node)
    }
    $node.InnerText = $setting[1]
}
$xml.Save($project)

function Invoke-ProjectBuild([string]$path, [string]$configuration) {
    & msbuild $path /m /t:Build "/p:Configuration=$configuration" "/p:Platform=$platform" "/p:PlatformToolset=$toolset" "/p:SolutionDir=$solutionDir" /verbosity:minimal
    if ($LASTEXITCODE -ne 0) { throw "Build failed: $configuration / $platform / $toolset" }
}

Invoke-ProjectBuild $detours 'Release'
$detoursLib = Join-Path $solutionDir "Build\Detours\$platform\Release\Detours.lib"
if (-not (Test-Path $detoursLib)) { throw "Detours.lib not found: $detoursLib" }

$proxies = @('d3d8', 'd3d9', 'd3d11', 'd3dcompiler_43', 'd3dcompiler_47',
    'd3dx9_43', 'dxgi', 'iphlpapi', 'opengl32', 'version', 'winmm')
if ($arch -eq 'x86-xp') {
    # Windows XP lacks Direct3D 11 and DXGI; do not ship their proxies as XP-compatible.
    $proxies = @('d3d8', 'd3d9', 'd3dcompiler_43', 'd3dx9_43',
        'iphlpapi', 'opengl32', 'version', 'winmm')
}
foreach ($proxy in $proxies) {
    Write-Host "Building $proxy ($arch, $toolset)"
    Invoke-ProjectBuild $project $proxy
    $dll = Join-Path $solutionDir "Build\UniversalInjectorFramework\$platform\$proxy\$proxy.dll"
    if (-not (Test-Path $dll)) { throw "Missing built DLL: $dll" }
    Copy-Item -LiteralPath $dll -Destination $packageDir -Force
}
if (@(Get-ChildItem $packageDir -Filter *.dll -File).Count -ne $proxies.Count) {
    throw "Incomplete $arch package: expected $($proxies.Count) DLLs"
}
