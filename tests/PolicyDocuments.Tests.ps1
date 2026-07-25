#requires -Modules Pester

BeforeAll {
    $engineRoot = Resolve-Path (Join-Path $PSScriptRoot '..' 'PolicyEngine')
    $script:CapabilityFiles = @(Get-ChildItem -Path (Join-Path $engineRoot 'Capabilities') -Recurse -Filter '*.capability.json')
    $script:PolicyFiles = @(Get-ChildItem -Path (Join-Path $engineRoot 'Policies') -Recurse -Filter '*.policy.json')

    # Build a catalog keyed by "layer.capability" for cross-checking policies.
    $script:Catalog = @{}
    foreach ($file in $script:CapabilityFiles) {
        $doc = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
        $script:Catalog["$($doc.layer).$($doc.capability)"] = $doc
    }
}

Describe 'Capability documents' {
    It 'ships at least one capability' {
        $script:CapabilityFiles.Count | Should -BeGreaterThan 0
    }

    It '<Name> is valid JSON with required fields and enums' -ForEach (
        Get-ChildItem -Path (Join-Path $PSScriptRoot '..' 'PolicyEngine' 'Capabilities') -Recurse -Filter '*.capability.json' |
            ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
    ) {
        $doc = Get-Content -Path $Path -Raw | ConvertFrom-Json
        $doc.version | Should -Not -BeNullOrEmpty
        $doc.name | Should -Not -BeNullOrEmpty
        $doc.layer | Should -BeIn @('enterprise', 'organization', 'repository')
        $doc.capability | Should -Match '^[a-z0-9]+(-[a-z0-9]+)*$'
        $doc.authMode | Should -BeIn @('github-app', 'enterprise-pat')
    }
}

Describe 'Policy documents' {
    It 'ships at least one policy' {
        $script:PolicyFiles.Count | Should -BeGreaterThan 0
    }

    It '<Name> is valid JSON with required fields' -ForEach (
        Get-ChildItem -Path (Join-Path $PSScriptRoot '..' 'PolicyEngine' 'Policies') -Recurse -Filter '*.policy.json' |
            ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
    ) {
        $doc = Get-Content -Path $Path -Raw | ConvertFrom-Json
        $doc.version | Should -Not -BeNullOrEmpty
        $doc.name | Should -Not -BeNullOrEmpty
        $doc.layer | Should -BeIn @('enterprise', 'organization', 'repository')
        $doc.capability | Should -Match '^[a-z0-9]+(-[a-z0-9]+)*$'
        ($doc.PSObject.Properties.Name -contains 'enabled') | Should -BeTrue
    }

    It '<Name> references a known capability for its layer' -ForEach (
        Get-ChildItem -Path (Join-Path $PSScriptRoot '..' 'PolicyEngine' 'Policies') -Recurse -Filter '*.policy.json' |
            ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
    ) {
        $doc = Get-Content -Path $Path -Raw | ConvertFrom-Json
        $key = "$($doc.layer).$($doc.capability)"
        $script:Catalog.ContainsKey($key) | Should -BeTrue -Because "capability '$key' must exist in PolicyEngine/Capabilities"
    }

    It '<Name> lives under a folder matching its declared layer' -ForEach (
        Get-ChildItem -Path (Join-Path $PSScriptRoot '..' 'PolicyEngine' 'Policies') -Recurse -Filter '*.policy.json' |
            ForEach-Object { @{ Name = $_.Name; Path = $_.FullName; Layer = ($_ | Get-Content -Raw | ConvertFrom-Json).layer } }
    ) {
        $separator = [System.IO.Path]::DirectorySeparatorChar
        $Path | Should -Match ([regex]::Escape("$separator$Layer$separator"))
    }
}
