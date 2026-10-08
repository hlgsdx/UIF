$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = $env:GITHUB_WORKSPACE
$nsUri = 'http://schemas.microsoft.com/developer/msbuild/2003'

function Set-ChildText([xml]$doc, [System.Xml.XmlNode]$parent, [string]$name, [string]$value) {
    $child = $parent.SelectSingleNode("m:$name", $script:ns)
    if ($null -eq $child) {
        $child = $doc.CreateElement($name, $nsUri)
        [void]$parent.AppendChild($child)
    }
    $child.InnerText = $value
}

foreach ($relative in @('src\UniversalInjectorFramework\UniversalInjectorFramework.vcxproj',
                       'src\Detours\Detours.vcxproj')) {
    $path = Join-Path $root $relative
    [xml]$doc = Get-Content -LiteralPath $path -Raw
    $script:ns = [System.Xml.XmlNamespaceManager]::new($doc.NameTable)
    $script:ns.AddNamespace('m', $nsUri)
    $globals = $doc.SelectSingleNode("//m:PropertyGroup[@Label='Globals']", $script:ns)
    if ($null -eq $globals) { throw "Globals not found in $relative" }
    Set-ChildText $doc $globals 'WindowsTargetPlatformVersion' '7.0'
    if ($relative -like '*UniversalInjectorFramework.vcxproj') {
        $configs = @($doc.SelectNodes("//m:PropertyGroup[@Label='Configuration']", $script:ns))
        $defs = $doc.SelectSingleNode('//m:ItemDefinitionGroup[not(@Condition) and m:ClCompile]', $script:ns)
    } else {
        $configs = @($doc.SelectNodes("//m:PropertyGroup[@Label='Configuration' and contains(@Condition, 'Release|Win32')]", $script:ns))
        $defs = $doc.SelectSingleNode("//m:ItemDefinitionGroup[contains(@Condition,'Release') and m:ClCompile]", $script:ns)
    }
    if ($configs.Count -eq 0 -or $null -eq $defs) { throw "Missing XP configuration in $relative" }
    foreach ($config in $configs) { Set-ChildText $doc $config 'PlatformToolset' 'v141_xp' }
    $cl = $defs.SelectSingleNode('m:ClCompile', $script:ns)
    if ($null -eq $cl) { throw "ClCompile missing in $relative" }
    Set-ChildText $doc $cl 'RuntimeLibrary' 'MultiThreaded'
    $oldDefs = $cl.SelectSingleNode('m:PreprocessorDefinitions', $script:ns)
    if ($null -eq $oldDefs) { throw "PreprocessorDefinitions missing in $relative" }
    $oldDefs.InnerText = '_WIN32_WINNT=0x0501;WINVER=0x0501;NTDDI_VERSION=0x05010300;' + $oldDefs.InnerText
    if ($relative -like '*UniversalInjectorFramework.vcxproj') {
        Set-ChildText $doc $cl 'LanguageStandard' 'stdcpp17'
        $link = $defs.SelectSingleNode('m:Link', $script:ns)
        if ($null -eq $link) { throw 'UIF linker settings missing' }
        Set-ChildText $doc $link 'MinimumRequiredVersion' '5.01'
    }
    $doc.Save($path)
}

function Replace-ExactlyOnce([string]$relative, [string]$old, [string]$new) {
    $path = Join-Path $root $relative
    $contents = [System.IO.File]::ReadAllText($path)
    $first = $contents.IndexOf($old, [System.StringComparison]::Ordinal)
    if ($first -lt 0 -or $contents.IndexOf($old, $first + $old.Length, [System.StringComparison]::Ordinal) -ge 0) {
        throw "Expected exactly one occurrence of '$old' in $relative; upstream source changed"
    }
    $contents = $contents.Replace($old, $new)
    [System.IO.File]::WriteAllText($path, $contents, [System.Text.UTF8Encoding]::new($false))
}

# Three known C++20-only constructs in UIF, replaced by C++11/17 equivalents.
Replace-ExactlyOnce 'src\UniversalInjectorFramework\utils.cpp' `
    "string.ends_with('h') || string.ends_with('H')" `
    "(!string.empty() && (string.back() == 'h' || string.back() == 'H'))"
Replace-ExactlyOnce 'src\UniversalInjectorFramework\features\text_processor.cpp' `
    "name.starts_with('@')" `
    "(!name.empty() && name.front() == '@')"
Replace-ExactlyOnce 'src\UniversalInjectorFramework\features\file_monitor.cpp' `
    'std::ranges::replace(path,' `
    'std::replace(path.begin(), path.end(),'
Replace-ExactlyOnce 'src\UniversalInjectorFramework\features\file_monitor.cpp' `
    '#include "file_monitor.h"' `
    "#include <algorithm>`n#include `"file_monitor.h`""
Write-Host 'XP source/SDK/C++17/MT patches applied to this job workspace only.'
