#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Policy-driven managed file and governance sync runtime.

.DESCRIPTION
    Execution model:
    0) GitHub App bootstrap auth (ClientID + PrivateKey)
    1) Enterprise layer: execute enterprise policies in order
    2) Organization layer: for each org installation, execute org policies in order
    3) Repository layer: for each repo in each org, execute repo policies in order

    Policies are loaded dynamically from PolicyEngine/Policies/{enterprise}/...
    Capabilities are loaded dynamically from PolicyEngine/Capabilities/...

    Enterprise policy capabilities declare auth mode explicitly:
    - github-app: use GitHub App installation context
    - enterprise-pat: use CUSTO_ENTERPRISE_PAT for enterprise-admin endpoints
#>

[CmdletBinding()]
param(
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

$script:Summary = @{
    TotalReposProcessed = 0
    PRsCreated          = 0
    PRsUpdated          = 0
    ReposAlreadyInSync  = 0
    ReposSkipped        = 0
    Errors              = @()
}

function Get-TargetScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    if (-not (Test-Path $ConfigPath)) {
        throw "Targets config not found at: $ConfigPath"
    }

    $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    if (-not $config.scope) {
        throw "Missing required 'scope' in: $ConfigPath"
    }

    if ($config.scope -eq 'organizations') {
        if (-not $config.organizations -or $config.organizations.Count -eq 0) {
            throw "Scope 'organizations' requires a non-empty organizations list in: $ConfigPath"
        }
    } elseif ($config.scope -ne 'all-access') {
        throw "Unsupported scope '$($config.scope)' in: $ConfigPath"
    }

    if (-not $config.policy) {
        throw "Missing required 'policy' section in: $ConfigPath"
    }

    if (-not $config.policy.enterprise) {
        throw "Config policy section requires 'enterprise'."
    }

    return $config
}

function Get-FileSets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ReposPath
    )

    $fileSets = @{}
    if (-not (Test-Path $ReposPath)) {
        throw "Repos directory not found at: $ReposPath"
    }

    $typeDirs = Get-ChildItem -Path $ReposPath -Directory
    foreach ($typeDir in $typeDirs) {
        $typeName = $typeDir.Name
        $fileSets[$typeName] = @{}
        $selectionDirs = Get-ChildItem -Path $typeDir.FullName -Directory

        foreach ($selectionDir in $selectionDirs) {
            $selectionName = $selectionDir.Name
            $files = Get-ChildItem -Path $selectionDir.FullName -File -Recurse

            $fileList = @()
            foreach ($file in $files) {
                $relativePath = $file.FullName.Substring($selectionDir.FullName.Length + 1)
                $fileList += @{
                    SourcePath   = $file.FullName
                    RelativePath = $relativePath
                }
            }
            $fileSets[$typeName][$selectionName] = $fileList
        }
    }

    return $fileSets
}

function Get-CapabilityCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CapabilityPath
    )

    if (-not (Test-Path $CapabilityPath)) {
        throw "Capability path not found at: $CapabilityPath"
    }

    $capabilityFiles = Get-ChildItem -Path $CapabilityPath -File -Recurse -Filter '*.capability.json' | Sort-Object FullName
    if ($capabilityFiles.Count -eq 0) {
        throw "No capability documents found in: $CapabilityPath"
    }

    $catalog = @{}
    foreach ($file in $capabilityFiles) {
        $doc = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json -AsHashtable
        if (-not $doc.layer -or -not $doc.capability) {
            throw "Capability '$($file.Name)' must define both layer and capability."
        }

        $layer = $doc.layer.ToLowerInvariant()
        $capability = $doc.capability.ToLowerInvariant()
        $key = "$layer.$capability"

        if ($catalog.ContainsKey($key)) {
            throw "Duplicate capability definition for '$key': $($file.FullName)"
        }

        $doc.layer = $layer
        $doc.capability = $capability
        $doc.sourceFile = $file.FullName
        $catalog[$key] = $doc
    }

    return $catalog
}

function Get-PolicyDocumentsFromPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Paths,

        [Parameter(Mandatory)]
        [hashtable]$CapabilityCatalog,

        [Parameter(Mandatory)]
        [string]$Layer
    )

    $layerOrder = @{
        enterprise   = 1
        organization = 2
        repository   = 3
    }

    $documents = @()
    foreach ($path in $Paths) {
        if (-not (Test-Path $path)) {
            continue
        }

        $files = Get-ChildItem -Path $path -File -Filter '*.policy.json' | Sort-Object FullName
        foreach ($file in $files) {
            $doc = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json -AsHashtable
            if (-not $doc.layer -or -not $doc.capability -or -not $doc.ContainsKey('enabled')) {
                throw "Policy '$($file.Name)' must include layer, capability, and enabled."
            }

            $doc.layer = $doc.layer.ToLowerInvariant()
            $doc.capability = $doc.capability.ToLowerInvariant()
            $doc.sourceFile = $file.FullName
            if ($doc.layer -ne $Layer) {
                continue
            }

            $capabilityKey = "$($doc.layer).$($doc.capability)"
            if (-not $CapabilityCatalog.ContainsKey($capabilityKey)) {
                throw "Policy '$($file.Name)' references unsupported capability '$capabilityKey'."
            }

            $documents += $doc
        }
    }

    $documents | Sort-Object @{ Expression = { if ($_.ContainsKey('order')) { [int]$_.order } else { 1000 } } }, @{ Expression = { $layerOrder[$_.layer] } }, @{ Expression = { $_.capability } }, @{ Expression = { $_.sourceFile } }
}

function Resolve-PolicyLayerPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PolicyRoot,

        [Parameter(Mandatory)]
        [string]$Enterprise,

        [Parameter(Mandatory)]
        [ValidateSet('enterprise', 'organization', 'repository')]
        [string]$Layer,

        [string]$Organization,
        [string]$Repository
    )

    $base = Join-Path (Join-Path $PolicyRoot 'Policies') $Enterprise
    $paths = @()

    switch ($Layer) {
        'enterprise' {
            $paths += (Join-Path $base 'enterprise')
        }
        'organization' {
            $paths += (Join-Path $base 'organization')
            $paths += (Join-Path (Join-Path $base 'organization') '_default')
            if ($Organization) {
                $paths += (Join-Path (Join-Path $base 'organization') $Organization)
            }
        }
        'repository' {
            $paths += (Join-Path $base 'repository')
            $paths += (Join-Path (Join-Path $base 'repository') '_default')
            if ($Organization) {
                $orgBase = Join-Path (Join-Path $base 'repository') $Organization
                $paths += (Join-Path $orgBase '_default')
                if ($Repository) {
                    $paths += (Join-Path $orgBase $Repository)
                }
            }
        }
    }

    return $paths
}

function ConvertTo-CanonicalObject {
    [CmdletBinding()]
    param(
        $InputObject
    )

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [string] -or $InputObject -is [ValueType]) {
        return $InputObject
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in ($InputObject.Keys | Sort-Object)) {
            $ordered[[string]$key] = ConvertTo-CanonicalObject -InputObject $InputObject[$key]
        }
        return $ordered
    }

    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $ordered = [ordered]@{}
        foreach ($prop in ($InputObject.PSObject.Properties.Name | Sort-Object)) {
            $ordered[$prop] = ConvertTo-CanonicalObject -InputObject $InputObject.$prop
        }
        return $ordered
    }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        $list = @()
        foreach ($item in $InputObject) {
            $list += , (ConvertTo-CanonicalObject -InputObject $item)
        }
        return , $list
    }

    return $InputObject
}

function Test-CanonicalSubset {
    <#
        Returns $true when every value declared in $Subset is present and equal in
        $Superset. Both inputs must already be canonicalized. A $null desired value is
        satisfied when the key is absent or already null, so server-added fields never
        register as drift.
    #>
    [CmdletBinding()]
    param(
        $Superset,
        $Subset
    )

    if ($Subset -is [System.Collections.IDictionary]) {
        if (-not ($Superset -is [System.Collections.IDictionary])) { return $false }
        foreach ($key in $Subset.Keys) {
            $desiredValue = $Subset[$key]
            $hasKey = $Superset.Contains($key)
            $currentValue = if ($hasKey) { $Superset[$key] } else { $null }

            if ($null -eq $desiredValue) {
                if ($hasKey -and $null -ne $currentValue) { return $false }
                continue
            }

            if (-not $hasKey) { return $false }
            if (-not (Test-CanonicalSubset -Superset $currentValue -Subset $desiredValue)) { return $false }
        }
        return $true
    }

    if ($Subset -is [array]) {
        if (-not ($Superset -is [array])) { return $false }
        if ($Superset.Count -ne $Subset.Count) { return $false }
        for ($i = 0; $i -lt $Subset.Count; $i++) {
            if (-not (Test-CanonicalSubset -Superset $Superset[$i] -Subset $Subset[$i])) { return $false }
        }
        return $true
    }

    return ($Superset -eq $Subset)
}

function ConvertTo-NormalizedJson {
    [CmdletBinding()]
    param(
        $InputObject
    )

    return (ConvertTo-CanonicalObject -InputObject $InputObject | ConvertTo-Json -Depth 50)
}

function Write-ConfigDiff {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        $Current,
        $Desired
    )

    $canonicalCurrent = ConvertTo-CanonicalObject -InputObject $Current
    $canonicalDesired = ConvertTo-CanonicalObject -InputObject $Desired

    if (Test-CanonicalSubset -Superset $canonicalCurrent -Subset $canonicalDesired) {
        Write-Host "✅ $Title already matches desired state"
        return $false
    }

    Write-Host "🔎 Diff for $Title (< current / > desired)"
    $currentLines = ($canonicalCurrent | ConvertTo-Json -Depth 50) -split "`r?`n"
    $desiredLines = ($canonicalDesired | ConvertTo-Json -Depth 50) -split "`r?`n"
    $diff = Compare-Object -ReferenceObject $currentLines -DifferenceObject $desiredLines
    foreach ($line in $diff) {
        Write-Host "   $($line.SideIndicator) $($line.InputObject)"
    }
    return $true
}

function Invoke-EnterprisePolicyApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$ApiEndpoint,

        [object]$Body,

        [Parameter(Mandatory)]
        [ValidateSet('github-app', 'enterprise-pat')]
        [string]$AuthMode,

        [Parameter(Mandatory)]
        [object]$Context
    )

    switch ($AuthMode) {
        'github-app' {
            return (Invoke-GitHubAPI -Method $Method -ApiEndpoint $ApiEndpoint -Body $Body -Context $Context).Response
        }
        'enterprise-pat' {
            $enterprisePat = $env:CUSTO_ENTERPRISE_PAT
            if ([string]::IsNullOrWhiteSpace($enterprisePat)) {
                throw "CUSTO_ENTERPRISE_PAT is required for auth mode 'enterprise-pat' ($ApiEndpoint)."
            }

            $headers = @{
                Authorization          = "Bearer $enterprisePat"
                Accept                 = 'application/vnd.github+json'
                'X-GitHub-Api-Version' = '2022-11-28'
            }

            $uri = "https://api.github.com$ApiEndpoint"
            $invokeArgs = @{
                Method  = $Method
                Uri     = $uri
                Headers = $headers
            }

            if ($null -ne $Body) {
                $invokeArgs.ContentType = 'application/json'
                $invokeArgs.Body = $Body | ConvertTo-Json -Depth 50
            }

            return Invoke-RestMethod @invokeArgs
        }
    }
}

function Get-OrganizationContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Organization
    )

    return (Connect-GitHubApp -Owner $Organization -PassThru)
}

function Get-TargetOrganizations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$TargetScope,

        [Parameter(Mandatory)]
        [object]$RootContext
    )

    if ($TargetScope.scope -eq 'organizations') {
        return @($TargetScope.organizations | Sort-Object -Unique)
    }

    $installations = @((Invoke-GitHubAPI -Method GET -ApiEndpoint '/app/installations' -Context $RootContext).Response)
    $orgs = $installations |
        Where-Object { $_.account.type -eq 'Organization' } |
        ForEach-Object { $_.account.login } |
        Sort-Object -Unique

    return @($orgs)
}

function Get-RepositoryCustomProperties {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Owner,

        [Parameter(Mandatory)]
        [string]$Repo,

        [Parameter(Mandatory)]
        [object]$Context
    )

    return @((Invoke-GitHubAPI -Method GET -ApiEndpoint "/repos/$Owner/$Repo/properties/values" -Context $Context).Response)
}

function Sync-EnterpriseCustomPropertySchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Enterprise,

        [Parameter(Mandatory)]
        [hashtable]$FileSets,

        [Parameter(Mandatory)]
        [object]$Context,

        [string]$TypePropertyName = 'Type',
        [string]$SubscriptionPropertyName = 'SubscribeTo',
        [bool]$Required = $false,
        [object]$ValuesEditableBy = 'org_actors',
        [bool]$RequireExplicitValues = $false,
        [Parameter(Mandatory)]
        [ValidateSet('github-app', 'enterprise-pat')]
        [string]$AuthMode,
        [switch]$WhatIf
    )

    $typeValues = @($FileSets.Keys | Sort-Object -Unique)
    if ($typeValues.Count -eq 0) {
        throw 'Cannot sync custom-property schema: no repository types discovered in Repos/.'
    }

    $subscriptionValues = @($FileSets.Values | ForEach-Object { $_.Keys } | Sort-Object -Unique)
    if ($subscriptionValues.Count -eq 0) {
        throw 'Cannot sync custom-property schema: no file-set selections discovered in Repos/.'
    }

    $desiredType = @{
        value_type              = 'single_select'
        required                = $Required
        default_value           = $null
        description             = 'Repository type used by Custo managed-file distribution.'
        allowed_values          = $typeValues
        values_editable_by      = $ValuesEditableBy
        require_explicit_values = $RequireExplicitValues
    }

    $desiredSubscription = @{
        value_type              = 'multi_select'
        required                = $Required
        default_value           = $null
        description             = 'Managed file sets the repository subscribes to from Custo.'
        allowed_values          = $subscriptionValues
        values_editable_by      = $ValuesEditableBy
        require_explicit_values = $RequireExplicitValues
    }

    $currentType = $null
    $currentSubscription = $null
    try { $currentType = Invoke-EnterprisePolicyApi -Method GET -ApiEndpoint "/enterprises/$Enterprise/properties/schema/$TypePropertyName" -AuthMode $AuthMode -Context $Context } catch {}
    try { $currentSubscription = Invoke-EnterprisePolicyApi -Method GET -ApiEndpoint "/enterprises/$Enterprise/properties/schema/$SubscriptionPropertyName" -AuthMode $AuthMode -Context $Context } catch {}

    $typeChanged = Write-ConfigDiff -Title "enterprise property '$TypePropertyName'" -Current $currentType -Desired $desiredType
    $subscriptionChanged = Write-ConfigDiff -Title "enterprise property '$SubscriptionPropertyName'" -Current $currentSubscription -Desired $desiredSubscription

    if ($WhatIf) {
        Write-Host "WhatIf: skipping enterprise property updates"
        return
    }

    if ($typeChanged) {
        Invoke-EnterprisePolicyApi -Method PUT -ApiEndpoint "/enterprises/$Enterprise/properties/schema/$TypePropertyName" -Body $desiredType -AuthMode $AuthMode -Context $Context | Out-Null
        Write-Host "✅ Updated enterprise property '$TypePropertyName'"
    }

    if ($subscriptionChanged) {
        Invoke-EnterprisePolicyApi -Method PUT -ApiEndpoint "/enterprises/$Enterprise/properties/schema/$SubscriptionPropertyName" -Body $desiredSubscription -AuthMode $AuthMode -Context $Context | Out-Null
        Write-Host "✅ Updated enterprise property '$SubscriptionPropertyName'"
    }
}

function Sync-EnterpriseRulesets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Enterprise,

        [Parameter(Mandatory)]
        [object[]]$Rulesets,

        [Parameter(Mandatory)]
        [object]$Context,

        [Parameter(Mandatory)]
        [ValidateSet('github-app', 'enterprise-pat')]
        [string]$AuthMode,

        [switch]$WhatIf
    )

    if (-not $Rulesets -or $Rulesets.Count -eq 0) {
        Write-Host "ℹ️  No enterprise rulesets declared for '$Enterprise'"
        return
    }

    $existingRulesets = @(
        Invoke-EnterprisePolicyApi -Method GET -ApiEndpoint "/enterprises/$Enterprise/rulesets" -AuthMode $AuthMode -Context $Context
    )

    $existingByName = @{}
    foreach ($existing in $existingRulesets) {
        if ($existing.name) {
            $existingByName[$existing.name] = $existing
        }
    }

    foreach ($ruleset in $Rulesets) {
        if (-not $ruleset.name) {
            throw "Enterprise ruleset entry is missing required field 'name'."
        }

        $desired = @{}
        foreach ($key in $ruleset.Keys) {
            if ($key -notin @('id', 'source', 'source_type', 'created_at', 'updated_at', 'node_id', '_links', 'current_user_can_bypass')) {
                $desired[$key] = $ruleset[$key]
            }
        }

        $currentComparable = $null
        $endpoint = "/enterprises/$Enterprise/rulesets"
        $method = 'POST'
        if ($existingByName.ContainsKey($ruleset.name)) {
            $existing = $existingByName[$ruleset.name]
            $currentComparable = @{}
            foreach ($key in $desired.Keys) {
                if ($existing.PSObject.Properties.Name -contains $key) {
                    $currentComparable[$key] = $existing.$key
                }
            }
            $endpoint = "/enterprises/$Enterprise/rulesets/$($existing.id)"
            $method = 'PUT'
        }

        $changed = Write-ConfigDiff -Title "enterprise ruleset '$($ruleset.name)'" -Current $currentComparable -Desired $desired
        if (-not $changed) {
            continue
        }

        if ($WhatIf) {
            Write-Host "WhatIf: skipping ruleset write for '$($ruleset.name)'"
            continue
        }

        Invoke-EnterprisePolicyApi -Method $method -ApiEndpoint $endpoint -Body $desired -AuthMode $AuthMode -Context $Context | Out-Null
        Write-Host "✅ Upserted enterprise ruleset '$($ruleset.name)'"
    }
}

function Get-RepositoriesForOrganization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Organization,

        [Parameter(Mandatory)]
        [object]$Context
    )

    return @((Get-GitHubRepository -Owner $Organization -Context $Context))
}

function Sync-RepositoryFileSubscription {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingWriteHost', '', Scope = 'Function',
        Justification = 'Intended for logging in GitHub Actions runners.'
    )]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Repository,

        [Parameter(Mandatory)]
        [hashtable]$FileSets,

        [Parameter(Mandatory)]
        [string]$TempPath,

        [Parameter(Mandatory)]
        [string]$BranchName,

        [Parameter(Mandatory)]
        [string]$CommitMessage,

        [Parameter(Mandatory)]
        [string]$PRTitle,

        [Parameter(Mandatory)]
        [string]$PRBody,

        [Parameter(Mandatory)]
        [string]$PRLabel,

        [Parameter(Mandatory)]
        [object]$Context,

        [switch]$WhatIf
    )

    $repoFullName = $Repository.FullName
    $owner = $Repository.Owner
    $repoName = $Repository.Name
    $type = $Repository.Type
    $subscribeTo = $Repository.SubscribeTo

    $script:Summary.TotalReposProcessed++

    if (-not $FileSets.ContainsKey($type)) {
        Write-Host "⚠️  $repoFullName - Type folder '$type' not found, skipping"
        $script:Summary.ReposSkipped++
        return
    }

    $filesToSync = @()
    foreach ($selection in $subscribeTo) {
        if (-not $FileSets[$type].ContainsKey($selection)) {
            Write-Host "⚠️  $repoFullName - Selection '$selection' not found under '$type'"
            continue
        }
        $filesToSync += $FileSets[$type][$selection]
    }

    if ($filesToSync.Count -eq 0) {
        Write-Host "⚠️  $repoFullName - No matching files, skipping"
        $script:Summary.ReposSkipped++
        return
    }

    LogGroup "📦 $repoFullName" {
        $clonePath = Join-Path $TempPath "clone-$repoName-$(Get-Random)"
        New-Item -Path $clonePath -ItemType Directory -Force | Out-Null

        try {
            $cloneUrl = "https://github.com/$repoFullName.git"
            $gitCloneResult = git clone --depth 1 $cloneUrl $clonePath 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Git clone failed: $gitCloneResult"
            }

            Push-Location $clonePath
            try {
                Set-GitHubGitConfig -Context $Context

                $remoteBranches = git branch -r 2>&1
                if ($remoteBranches -match "origin/$BranchName") {
                    git fetch origin $BranchName 2>&1 | Out-Null
                    git checkout $BranchName 2>&1 | Out-Null
                } else {
                    git checkout -b $BranchName 2>&1 | Out-Null
                }

                foreach ($fileInfo in $filesToSync) {
                    $targetPath = Join-Path $clonePath $fileInfo.RelativePath
                    $targetDir = Split-Path $targetPath -Parent
                    if (-not (Test-Path $targetDir)) {
                        New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
                    }
                    Copy-Item -Path $fileInfo.SourcePath -Destination $targetPath -Force
                }

                $status = git status --porcelain 2>&1
                if ([string]::IsNullOrWhiteSpace($status)) {
                    Write-Host '✅ Already in sync'
                    $script:Summary.ReposAlreadyInSync++
                    return
                }

                Write-Host '🔎 Repository file diff'
                $status -split "`n" | ForEach-Object { Write-Host "  $_" }

                if ($WhatIf) {
                    Write-Host "WhatIf: skipping commit/push/PR for $repoFullName"
                    return
                }

                git add --all 2>&1 | Out-Null
                git commit -m $CommitMessage 2>&1 | Out-Null
                $pushResult = git push --force --set-upstream origin $BranchName 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "Git push failed: $pushResult"
                }

                $existingPRs = (Invoke-GitHubAPI -Method GET -ApiEndpoint "/repos/$owner/$repoName/pulls" -Body @{
                        head  = "${owner}:${BranchName}"
                        state = 'open'
                    } -Context $Context).Response

                if ($existingPRs.Count -gt 0) {
                    Write-Host "✅ Updated PR #$($existingPRs[0].number) - $($existingPRs[0].html_url)"
                    $script:Summary.PRsUpdated++
                } else {
                    $pr = (Invoke-GitHubAPI -Method POST -ApiEndpoint "/repos/$owner/$repoName/pulls" -Body @{
                            title = $PRTitle
                            head  = $BranchName
                            base  = $Repository.DefaultBranch
                            body  = $PRBody
                        } -Context $Context).Response

                    try {
                        Invoke-GitHubAPI -Method POST -ApiEndpoint "/repos/$owner/$repoName/issues/$($pr.number)/labels" -Body @{
                            labels = @($PRLabel)
                        } -Context $Context | Out-Null
                    } catch {
                        Write-Host "⚠️  Failed to add label: $_"
                    }

                    Write-Host "✅ Created PR #$($pr.number) - $($pr.html_url)"
                    $script:Summary.PRsCreated++
                }
            } finally {
                Pop-Location
            }
        } catch {
            Write-Host "❌ $_"
            $script:Summary.Errors += "$repoFullName : $_"
        } finally {
            if (Test-Path $clonePath) {
                Remove-Item -Path $clonePath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Invoke-PoliciesForScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Policies,

        [Parameter(Mandatory)]
        [hashtable]$FileSets,

        [Parameter(Mandatory)]
        [hashtable]$CapabilityCatalog,

        [Parameter(Mandatory)]
        [object]$Context,

        [string]$Enterprise,
        [string]$Organization,
        [object]$Repository,
        [Parameter(Mandatory)]
        [string]$TempPath,
        [switch]$WhatIf
    )

    foreach ($policy in $Policies) {
        $name = if ($policy.name) { $policy.name } else { [System.IO.Path]::GetFileName($policy.sourceFile) }
        $capabilityId = "$($policy.layer).$($policy.capability)"
        $capabilityDefinition = $CapabilityCatalog[$capabilityId]
        $authMode = if ($capabilityDefinition.authMode) { [string]$capabilityDefinition.authMode } else { 'github-app' }

        if ($policy.enabled -ne $true) {
            Write-Host "⏭️  Policy disabled: $name ($capabilityId)"
            continue
        }

        Write-Host "▶️  Applying policy: $name ($capabilityId)"

        switch ($capabilityId) {
            'enterprise.repo-custom-property' {
                $typeName = if ($policy.config.typePropertyName) { [string]$policy.config.typePropertyName } else { 'Type' }
                $subscriptionName = if ($policy.config.subscriptionPropertyName) { [string]$policy.config.subscriptionPropertyName } else { 'SubscribeTo' }
                $required = if ($policy.config.ContainsKey('required')) { [bool]$policy.config.required } else { $false }
                $valuesEditableBy = if ($policy.config.ContainsKey('valuesEditableBy')) { $policy.config.valuesEditableBy } else { 'org_actors' }
                $requireExplicitValues = if ($policy.config.ContainsKey('requireExplicitValues')) { [bool]$policy.config.requireExplicitValues } else { $false }

                Sync-EnterpriseCustomPropertySchema `
                    -Enterprise $policy.config.enterprise `
                    -FileSets $FileSets `
                    -Context $Context `
                    -TypePropertyName $typeName `
                    -SubscriptionPropertyName $subscriptionName `
                    -Required $required `
                    -ValuesEditableBy $valuesEditableBy `
                    -RequireExplicitValues $requireExplicitValues `
                    -AuthMode $authMode `
                    -WhatIf:$WhatIf
            }
            'enterprise.repo-rulesets' {
                $rulesets = if ($policy.config.rulesets) { @($policy.config.rulesets) } else { @() }
                Sync-EnterpriseRulesets -Enterprise $policy.config.enterprise -Rulesets $rulesets -Context $Context -AuthMode $authMode -WhatIf:$WhatIf
            }
            'organization.none' {
                Write-Host "ℹ️  Organization policy layer placeholder for $Organization"
            }
            'repository.file-subscription-service' {
                if (-not $Repository) {
                    throw "repository.file-subscription-service requires a repository scope."
                }

                $owner = $Repository.Owner.Login
                $repoName = $Repository.Name
                $customProps = Get-RepositoryCustomProperties -Owner $owner -Repo $repoName -Context $Context
                $typeProp = $customProps | Where-Object { $_.property_name -eq 'Type' }
                $subscribeToProp = $customProps | Where-Object { $_.property_name -eq 'SubscribeTo' }

                $type = $typeProp.value
                $subscribeTo = $subscribeToProp.value

                if (-not $type -or -not $subscribeTo) {
                    Write-Host "ℹ️  $owner/$repoName has no Type/SubscribeTo subscription, skipping."
                    $script:Summary.ReposSkipped++
                    continue
                }
                if ($subscribeTo -is [string]) { $subscribeTo = @($subscribeTo) }

                $repoSpec = @{
                    Name          = $Repository.Name
                    Owner         = $owner
                    FullName      = $Repository.FullName
                    Type          = $type
                    SubscribeTo   = $subscribeTo
                    DefaultBranch = $Repository.DefaultBranch
                }

                $branchName = if ($policy.config.branchName) { [string]$policy.config.branchName } else { 'managed-files/update' }
                $commitMessage = if ($policy.config.commitMessage) { [string]$policy.config.commitMessage } else { 'chore: sync managed files' }
                $prTitle = if ($policy.config.prTitle) { [string]$policy.config.prTitle } else { '⚙️ [Maintenance]: Sync managed files' }
                $prLabel = if ($policy.config.prLabel) { [string]$policy.config.prLabel } else { 'NoRelease' }
                $prBody = if ($policy.config.prBody) {
                    [string]$policy.config.prBody
                } else {
@'
This pull request was automatically created by the [Custo](https://github.com/MSXOrg/Custo) workflow that keeps shared files in sync across the organization's repositories.

The files in this PR are centrally managed. Any local changes to these files will be overwritten on the next sync. To propose changes, update the source files in the Custo repo instead.
'@
                }

                Sync-RepositoryFileSubscription `
                    -Repository $repoSpec `
                    -FileSets $FileSets `
                    -TempPath $TempPath `
                    -BranchName $branchName `
                    -CommitMessage $commitMessage `
                    -PRTitle $prTitle `
                    -PRBody $prBody `
                    -PRLabel $prLabel `
                    -Context $Context `
                    -WhatIf:$WhatIf
            }
            default {
                throw "Unsupported policy capability '$capabilityId' in '$name'."
            }
        }
    }
}

try {
    LogGroup '🔑 Authenticate bootstrap context' {
        $rootContext = Connect-GitHubApp -PassThru
        $rootContext | Format-List | Out-String
    }

    LogGroup '🎯 Read target and policy scope' {
        $targetsPath = Resolve-Path (Join-Path $PSScriptRoot '../config/targets.json')
        $targetScope = Get-TargetScope -ConfigPath $targetsPath
        Write-Host "Target scope: $($targetScope.scope)"
    }

    LogGroup '📂 Discover managed file sets' {
        $reposPath = Resolve-Path (Join-Path $PSScriptRoot '../Repos')
        $fileSets = Get-FileSets -ReposPath $reposPath
        if ($fileSets.Count -eq 0) {
            throw 'No managed file sets discovered under Repos/.'
        }
    }

    LogGroup '🧩 Load capabilities and policy documents' {
        $policyRoot = if ($targetScope.policy.rootPath) { $targetScope.policy.rootPath } else { '../PolicyEngine' }
        if (-not [System.IO.Path]::IsPathRooted($policyRoot)) {
            $policyRoot = Join-Path $PSScriptRoot $policyRoot
        }
        $policyRoot = Resolve-Path $policyRoot

        $policyEnterprise = [string]$targetScope.policy.enterprise
        $capabilityCatalog = Get-CapabilityCatalog -CapabilityPath (Resolve-Path (Join-Path $policyRoot 'Capabilities'))
        Write-Host "Loaded $($capabilityCatalog.Count) capability definitions"
    }

    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) "custo-sync-$(Get-Random)"
    New-Item -Path $tempPath -ItemType Directory -Force | Out-Null

    try {
        LogGroup '🏢 Enterprise layer' {
            $enterprisePolicyPaths = Resolve-PolicyLayerPaths -PolicyRoot $policyRoot -Enterprise $policyEnterprise -Layer 'enterprise'
            $enterprisePolicies = Get-PolicyDocumentsFromPaths -Paths $enterprisePolicyPaths -CapabilityCatalog $capabilityCatalog -Layer 'enterprise'
            Write-Host "Enterprise policies loaded: $($enterprisePolicies.Count)"

            Invoke-PoliciesForScope -Policies $enterprisePolicies -FileSets $fileSets -CapabilityCatalog $capabilityCatalog -Context $rootContext -Enterprise $policyEnterprise -TempPath $tempPath -WhatIf:$WhatIf
        }

        LogGroup '🏢➡️🏬 Organization and repository layers' {
            $organizations = Get-TargetOrganizations -TargetScope $targetScope -RootContext $rootContext
            Write-Host "Organizations discovered: $($organizations -join ', ')"

            foreach ($org in $organizations) {
                LogGroup "🔐 Connect org installation: $org" {
                    $orgContext = Get-OrganizationContext -Organization $org
                }

                LogGroup "🏬 Organization policies: $org" {
                    $orgPolicyPaths = Resolve-PolicyLayerPaths -PolicyRoot $policyRoot -Enterprise $policyEnterprise -Layer 'organization' -Organization $org
                    $orgPolicies = Get-PolicyDocumentsFromPaths -Paths $orgPolicyPaths -CapabilityCatalog $capabilityCatalog -Layer 'organization'
                    Write-Host "Organization policies loaded: $($orgPolicies.Count)"
                    Invoke-PoliciesForScope -Policies $orgPolicies -FileSets $fileSets -CapabilityCatalog $capabilityCatalog -Context $orgContext -Enterprise $policyEnterprise -Organization $org -TempPath $tempPath -WhatIf:$WhatIf
                }

                LogGroup "📦 Repositories in $org" {
                    $repos = Get-RepositoriesForOrganization -Organization $org -Context $orgContext
                    Write-Host "Repositories discovered in ${org}: $($repos.Count)"
                }

                foreach ($repo in $repos) {
                    LogGroup "🏷️ Repository policies: $($repo.FullName)" {
                        $repoPolicyPaths = Resolve-PolicyLayerPaths -PolicyRoot $policyRoot -Enterprise $policyEnterprise -Layer 'repository' -Organization $org -Repository $repo.Name
                        $repoPolicies = Get-PolicyDocumentsFromPaths -Paths $repoPolicyPaths -CapabilityCatalog $capabilityCatalog -Layer 'repository'
                        Write-Host "Repository policies loaded: $($repoPolicies.Count)"
                        Invoke-PoliciesForScope -Policies $repoPolicies -FileSets $fileSets -CapabilityCatalog $capabilityCatalog -Context $orgContext -Enterprise $policyEnterprise -Organization $org -Repository $repo -TempPath $tempPath -WhatIf:$WhatIf
                    }
                }
            }
        }
    } finally {
        if (Test-Path $tempPath) {
            Remove-Item -Path $tempPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ''
    Write-Host '📊 Summary'
    Write-Host "   Processed: $($script:Summary.TotalReposProcessed)"
    Write-Host "   Created:   $($script:Summary.PRsCreated)"
    Write-Host "   Updated:   $($script:Summary.PRsUpdated)"
    Write-Host "   In sync:   $($script:Summary.ReposAlreadyInSync)"
    Write-Host "   Skipped:   $($script:Summary.ReposSkipped)"
    if ($script:Summary.Errors.Count -gt 0) {
        Write-Host "   Errors:    $($script:Summary.Errors.Count)"
        foreach ($err in $script:Summary.Errors) {
            Write-Host "     ❌ $err"
        }
        exit 1
    }

} catch {
    Write-Host "❌ Fatal: $_"
    Write-Host $_.ScriptStackTrace
    exit 1
}
