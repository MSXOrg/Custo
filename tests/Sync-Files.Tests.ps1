#requires -Modules Pester

BeforeAll {
    # Load only the function definitions from the runtime script, without executing the
    # top-level pipeline (which requires GitHub authentication).
    $scriptPath = Resolve-Path (Join-Path $PSScriptRoot '..' 'scripts' 'Sync-Files.ps1')
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "Sync-Files.ps1 has parse errors: $($parseErrors -join '; ')"
    }
    $funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
    $definitions = ($funcs | ForEach-Object { $_.Extent.Text }) -join "`n`n"
    . ([scriptblock]::Create($definitions))

    # Minimal stub so functions that log through LogGroup still run in tests.
    function LogGroup {
        param($Title, [scriptblock]$ScriptBlock)
        & $ScriptBlock
    }
}

Describe 'ConvertTo-CanonicalObject' {
    It 'sorts dictionary keys deterministically' {
        $result = ConvertTo-CanonicalObject -InputObject @{ b = 1; a = 2; c = 3 }
        @($result.Keys) | Should -Be @('a', 'b', 'c')
    }

    It 'preserves array order' {
        $result = ConvertTo-CanonicalObject -InputObject @('z', 'a', 'm')
        $result | Should -Be @('z', 'a', 'm')
    }

    It 'normalizes PSCustomObject the same as an equivalent hashtable' {
        $fromJson = '{"b":1,"a":2}' | ConvertFrom-Json
        $fromHash = @{ a = 2; b = 1 }
        (ConvertTo-CanonicalObject $fromJson | ConvertTo-Json) |
            Should -Be (ConvertTo-CanonicalObject $fromHash | ConvertTo-Json)
    }
}

Describe 'Test-CanonicalSubset' {
    It 'treats server-added fields as satisfied' {
        $current = ConvertTo-CanonicalObject ('{"a":1,"b":2,"extra":"x"}' | ConvertFrom-Json)
        $desired = ConvertTo-CanonicalObject @{ a = 1; b = 2 }
        Test-CanonicalSubset -Superset $current -Subset $desired | Should -BeTrue
    }

    It 'detects real value drift' {
        $current = ConvertTo-CanonicalObject ('{"a":1,"b":9}' | ConvertFrom-Json)
        $desired = ConvertTo-CanonicalObject @{ a = 1; b = 2 }
        Test-CanonicalSubset -Superset $current -Subset $desired | Should -BeFalse
    }

    It 'treats array order as significant' {
        $current = ConvertTo-CanonicalObject @{ values = @('Module', 'Action') }
        $desired = ConvertTo-CanonicalObject @{ values = @('Action', 'Module') }
        Test-CanonicalSubset -Superset $current -Subset $desired | Should -BeFalse
    }

    It 'treats a null desired value as satisfied when the key is absent' {
        $current = ConvertTo-CanonicalObject @{ a = 1 }
        $desired = ConvertTo-CanonicalObject @{ a = 1; default_value = $null }
        Test-CanonicalSubset -Superset $current -Subset $desired | Should -BeTrue
    }
}

Describe 'Write-ConfigDiff' {
    It 'returns $false when the desired state is already satisfied' {
        $current = '{"value_type":"single_select","required":false,"extra":"x"}' | ConvertFrom-Json
        $desired = @{ value_type = 'single_select'; required = $false }
        Write-ConfigDiff -Title 'test' -Current $current -Desired $desired | Should -BeFalse
    }

    It 'returns $true when drift exists' {
        $current = '{"value_type":"multi_select"}' | ConvertFrom-Json
        $desired = @{ value_type = 'single_select' }
        Write-ConfigDiff -Title 'test' -Current $current -Desired $desired | Should -BeTrue
    }

    It 'returns $true when current state is missing' {
        Write-ConfigDiff -Title 'test' -Current $null -Desired @{ a = 1 } | Should -BeTrue
    }
}

Describe 'Resolve-PolicyLayerPaths' {
    It 'returns the enterprise folder for the enterprise layer' {
        $paths = Resolve-PolicyLayerPaths -PolicyRoot 'C:\root\PolicyEngine' -Enterprise 'MSXOrg' -Layer 'enterprise'
        $paths | Should -Contain (Join-Path 'C:\root\PolicyEngine' 'Policies' 'MSXOrg' 'enterprise')
    }

    It 'includes _default and org-specific folders for the repository layer' {
        $paths = Resolve-PolicyLayerPaths -PolicyRoot 'C:\root\PolicyEngine' -Enterprise 'MSXOrg' -Layer 'repository' -Organization 'PSModule' -Repository 'GitHub'
        $repoBase = Join-Path (Join-Path (Join-Path 'C:\root\PolicyEngine' 'Policies') 'MSXOrg') 'repository'
        $paths | Should -Contain (Join-Path $repoBase '_default')
        $paths | Should -Contain (Join-Path (Join-Path $repoBase 'PSModule') '_default')
        $paths | Should -Contain (Join-Path (Join-Path $repoBase 'PSModule') 'GitHub')
    }
}

Describe 'Invoke-PoliciesForScope authMode routing' {
    It 'routes the capability authMode to the enterprise ruleset handler' {
        $script:CapturedAuthMode = $null
        function Sync-EnterpriseRulesets {
            param($Enterprise, $Rulesets, $Context, $AuthMode, [switch]$WhatIf)
            $script:CapturedAuthMode = $AuthMode
        }

        $catalog = @{ 'enterprise.repo-rulesets' = @{ authMode = 'enterprise-pat' } }
        $policy = @{
            layer      = 'enterprise'
            capability = 'repo-rulesets'
            enabled    = $true
            name       = 'rs'
            sourceFile = 'x'
            config     = @{ enterprise = 'MSXOrg'; rulesets = @(@{ name = 'r' }) }
        }

        Invoke-PoliciesForScope -Policies @($policy) -FileSets @{} -CapabilityCatalog $catalog `
            -Context ([pscustomobject]@{}) -Enterprise 'MSXOrg' -TempPath $env:TEMP -WhatIf

        $script:CapturedAuthMode | Should -Be 'enterprise-pat'
    }

    It 'skips disabled policies' {
        $catalog = @{ 'enterprise.repo-rulesets' = @{ authMode = 'enterprise-pat' } }
        $policy = @{ layer = 'enterprise'; capability = 'repo-rulesets'; enabled = $false; name = 'rs'; sourceFile = 'x' }
        { Invoke-PoliciesForScope -Policies @($policy) -FileSets @{} -CapabilityCatalog $catalog `
                -Context ([pscustomobject]@{}) -Enterprise 'MSXOrg' -TempPath $env:TEMP -WhatIf } | Should -Not -Throw
    }
}
