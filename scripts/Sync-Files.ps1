#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Syncs managed files from this repository to subscribing repositories.

.DESCRIPTION
    This script runs a layered policy engine and then performs repository file sync:
    1. Authenticate as GitHub App for repository-level operations.
    2. Discover managed file sets from Repos/.
    3. Read discovery scope from config/targets.json.
    4. Load capability and policy documents from PolicyEngine/.
    5. Apply policies in order:
       - Enterprise layer
       - Organization layer
       - Repository layer
    6. If repository file-subscription policy is enabled, sync files to subscribing repositories.

.NOTES
    Enterprise policy API calls prefer GitHub App context first, then fall back to
    CUSTO_ENTERPRISE_PAT only when App access fails and PAT is configured.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Track summary information
$script:Summary = @{
    TotalReposProcessed = 0
    PRsCreated          = 0
    PRsUpdated          = 0
    ReposAlreadyInSync  = 0
    ReposSkipped        = 0
    Errors              = @()
}

#region Helper Functions

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

    if ($config.policy) {
        if (-not $config.policy.enterprise) {
            throw "Config policy section requires 'enterprise'."
        }
    }

    return $config
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
    foreach ($capabilityFile in $capabilityFiles) {
        $doc = Get-Content -Path $capabilityFile.FullName -Raw | ConvertFrom-Json -AsHashtable

        if (-not $doc.layer -or -not $doc.capability) {
            throw "Capability '$($capabilityFile.Name)' must define both layer and capability."
        }

        $layer = $doc.layer.ToLowerInvariant()
        $capability = $doc.capability.ToLowerInvariant()
        $key = "$layer.$capability"

        if ($catalog.ContainsKey($key)) {
            throw "Duplicate capability definition for '$key': $($capabilityFile.FullName)"
        }

        $doc.layer = $layer
        $doc.capability = $capability
        $doc.sourceFile = $capabilityFile.FullName
        $catalog[$key] = $doc
    }

    return $catalog
}

function Get-PolicyDocuments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PolicyPath,

        [Parameter(Mandatory)]
        [hashtable]$CapabilityCatalog
    )

    if (-not (Test-Path $PolicyPath)) {
        throw "Policy path not found at: $PolicyPath"
    }

    $policyFiles = Get-ChildItem -Path $PolicyPath -File -Recurse -Filter '*.policy.json' | Sort-Object FullName
    if ($policyFiles.Count -eq 0) {
        throw "No policy documents found in: $PolicyPath"
    }

    $layerOrder = @{
        enterprise   = 1
        organization = 2
        repository   = 3
    }

    $documents = @()
    foreach ($policyFile in $policyFiles) {
        $doc = Get-Content -Path $policyFile.FullName -Raw | ConvertFrom-Json -AsHashtable

        if (-not $doc.layer) {
            throw "Policy '$($policyFile.Name)' is missing required field 'layer'."
        }
        if (-not $doc.capability) {
            throw "Policy '$($policyFile.Name)' is missing required field 'capability'."
        }
        if (-not $doc.ContainsKey('enabled')) {
            throw "Policy '$($policyFile.Name)' is missing required field 'enabled'."
        }

        $doc.layer = $doc.layer.ToLowerInvariant()
        $doc.capability = $doc.capability.ToLowerInvariant()
        $doc.sourceFile = $policyFile.FullName

        if (-not $layerOrder.ContainsKey($doc.layer)) {
            throw "Policy '$($policyFile.Name)' has unsupported layer '$($doc.layer)'."
        }

        $capabilityKey = "$($doc.layer).$($doc.capability)"
        if (-not $CapabilityCatalog.ContainsKey($capabilityKey)) {
            throw "Policy '$($policyFile.Name)' references unsupported capability '$capabilityKey'."
        }

        $documents += $doc
    }

    $documents |
        Sort-Object @{ Expression = { $layerOrder[$_.layer] } }, @{ Expression = { $_.capability } }, @{ Expression = { $_.sourceFile } }
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
    $fileSetTable = @()

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
            $fileSetTable += [PSCustomObject]@{
                Type    = $typeName
                FileSet = $selectionName
                Files   = $fileList.Count
            }
        }
    }

    $fileSetTable | Format-Table -AutoSize | Out-String
    return $fileSets
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
        [object]$Context
    )

    try {
        return (Invoke-GitHubAPI -Method $Method -ApiEndpoint $ApiEndpoint -Body $Body -Context $Context).Response
    } catch {
        $enterprisePat = $env:CUSTO_ENTERPRISE_PAT
        if ([string]::IsNullOrWhiteSpace($enterprisePat)) {
            throw
        }

        Write-Host "ℹ️  App auth failed for $ApiEndpoint; retrying with CUSTO_ENTERPRISE_PAT"

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
            $invokeArgs.Body = $Body | ConvertTo-Json -Depth 30
        }

        return Invoke-RestMethod @invokeArgs
    }
}

function Get-AllAccessibleRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Context
    )

    $allRepos = @()
    $page = 1
    $perPage = 100

    while ($true) {
        $response = (Invoke-GitHubAPI -Method GET -ApiEndpoint '/installation/repositories' -Body @{
                per_page = $perPage
                page     = $page
            } -Context $Context).Response

        if (-not $response.repositories -or $response.repositories.Count -eq 0) {
            break
        }

        $allRepos += $response.repositories

        if ($response.repositories.Count -lt $perPage) {
            break
        }

        $page++
    }

    return $allRepos
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
        [string]$SubscriptionPropertyName = 'SubscribeTo'
    )

    $typeValues = @($FileSets.Keys | Sort-Object -Unique)
    if ($typeValues.Count -eq 0) {
        throw 'Cannot sync custom-property schema: no repository types discovered in Repos/.'
    }

    $subscriptionValues = @(
        $FileSets.Values |
            ForEach-Object { $_.Keys } |
            Sort-Object -Unique
    )

    if ($subscriptionValues.Count -eq 0) {
        throw 'Cannot sync custom-property schema: no file-set selections discovered in Repos/.'
    }

    Invoke-EnterprisePolicyApi -Method PUT -ApiEndpoint "/enterprises/$Enterprise/properties/schema/$TypePropertyName" -Body @{
        value_type     = 'single_select'
        required       = $false
        default_value  = $null
        description    = 'Repository type used by Custo managed-file distribution.'
        allowed_values = $typeValues
    } -Context $Context | Out-Null

    Invoke-EnterprisePolicyApi -Method PUT -ApiEndpoint "/enterprises/$Enterprise/properties/schema/$SubscriptionPropertyName" -Body @{
        value_type     = 'multi_select'
        required       = $false
        default_value  = $null
        description    = 'Managed file sets the repository subscribes to from Custo.'
        allowed_values = $subscriptionValues
    } -Context $Context | Out-Null

    Write-Host "✅ Synced enterprise custom-property schema on '$Enterprise'"
    Write-Host "   - ${TypePropertyName}: $($typeValues -join ', ')"
    Write-Host "   - ${SubscriptionPropertyName}: $($subscriptionValues -join ', ')"
}

function Sync-EnterpriseRulesets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Enterprise,

        [Parameter(Mandatory)]
        [object[]]$Rulesets,

        [Parameter(Mandatory)]
        [object]$Context
    )

    if (-not $Rulesets -or $Rulesets.Count -eq 0) {
        Write-Host "ℹ️  No enterprise rulesets declared for '$Enterprise'"
        return
    }

    $existingRulesets = @(
        Invoke-EnterprisePolicyApi -Method GET -ApiEndpoint "/enterprises/$Enterprise/rulesets" -Context $Context
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

        $payload = @{}
        foreach ($key in $ruleset.Keys) {
            if ($key -ne 'id' -and $key -ne 'source' -and $key -ne 'source_type' -and $key -ne 'created_at' -and $key -ne 'updated_at') {
                $payload[$key] = $ruleset[$key]
            }
        }

        if ($existingByName.ContainsKey($ruleset.name)) {
            $rulesetId = $existingByName[$ruleset.name].id
            Invoke-EnterprisePolicyApi -Method PUT -ApiEndpoint "/enterprises/$Enterprise/rulesets/$rulesetId" -Body $payload -Context $Context | Out-Null
            Write-Host "✅ Updated enterprise ruleset '$($ruleset.name)'"
        } else {
            Invoke-EnterprisePolicyApi -Method POST -ApiEndpoint "/enterprises/$Enterprise/rulesets" -Body $payload -Context $Context | Out-Null
            Write-Host "✅ Created enterprise ruleset '$($ruleset.name)'"
        }
    }
}

function Get-SubscribingRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Owner,

        [Parameter(Mandatory)]
        [object]$Context
    )

    $repos = Get-GitHubRepository -Owner $Owner -Context $Context
    $subscribingRepos = @()

    foreach ($repo in $repos) {
        $customProps = $repo.CustomProperties
        if (-not $customProps) { continue }

        $type = ($customProps | Where-Object Name -EQ 'Type').Value
        $subscribeTo = ($customProps | Where-Object Name -EQ 'SubscribeTo').Value

        if (-not $type -or -not $subscribeTo) { continue }
        if ($subscribeTo -is [string]) { $subscribeTo = @($subscribeTo) }
        if ($subscribeTo.Count -eq 0) { continue }

        $subscribingRepos += @{
            Name          = $repo.Name
            Owner         = $repo.Owner.Login
            FullName      = $repo.FullName
            Type          = $type
            SubscribeTo   = $subscribeTo
            DefaultBranch = $repo.DefaultBranch
        }
    }

    return $subscribingRepos
}

function Get-SubscribingRepositoryByOrganizationFromAllAccess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Context
    )

    $allRepos = Get-AllAccessibleRepository -Context $Context
    $reposByOrg = @{}

    foreach ($repo in $allRepos) {
        if ($repo.owner.type -ne 'Organization') { continue }

        $owner = $repo.owner.login
        $repoName = $repo.name

        $customProps = (Invoke-GitHubAPI -Method GET -ApiEndpoint "/repos/$owner/$repoName/properties/values" -Context $Context).Response
        $typeProp = $customProps | Where-Object { $_.property_name -eq 'Type' }
        $subscribeToProp = $customProps | Where-Object { $_.property_name -eq 'SubscribeTo' }

        $type = $typeProp.value
        $subscribeTo = $subscribeToProp.value

        if (-not $type -or -not $subscribeTo) { continue }
        if ($subscribeTo -is [string]) { $subscribeTo = @($subscribeTo) }
        if ($subscribeTo.Count -eq 0) { continue }

        $repoEntry = @{
            Name          = $repoName
            Owner         = $owner
            FullName      = $repo.full_name
            Type          = $type
            SubscribeTo   = $subscribeTo
            DefaultBranch = $repo.default_branch
        }

        if (-not $reposByOrg.ContainsKey($owner)) {
            $reposByOrg[$owner] = @()
        }
        $reposByOrg[$owner] += $repoEntry
    }

    return $reposByOrg
}

function Get-AllSubscribingRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$TargetScope,

        [Parameter(Mandatory)]
        [object]$Context
    )

    $subscribingRepos = @()

    if ($TargetScope.scope -eq 'all-access') {
        $reposByOrg = Get-SubscribingRepositoryByOrganizationFromAllAccess -Context $Context
        foreach ($org in @($reposByOrg.Keys | Sort-Object)) {
            Write-Host "Found $($reposByOrg[$org].Count) subscribing repositories in $org"
            $subscribingRepos += $reposByOrg[$org]
        }
    } else {
        foreach ($org in $TargetScope.organizations) {
            $orgRepos = Get-SubscribingRepository -Owner $org -Context $Context
            Write-Host "Found $($orgRepos.Count) subscribing repositories in $org"
            $subscribingRepos += $orgRepos
        }
    }

    return $subscribingRepos
}

function Invoke-PolicyEngine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Policies,

        [Parameter(Mandatory)]
        [hashtable]$FileSets,

        [Parameter(Mandatory)]
        [pscustomobject]$TargetScope,

        [Parameter(Mandatory)]
        [object]$Context
    )

    $state = @{
        RepoFileSubscriptionEnabled = $false
    }

    foreach ($policy in $Policies) {
        $name = if ($policy.name) { $policy.name } else { [System.IO.Path]::GetFileName($policy.sourceFile) }
        $capabilityId = "$($policy.layer).$($policy.capability)"

        if ($policy.enabled -ne $true) {
            Write-Host "⏭️  Policy disabled: $name ($capabilityId)"
            continue
        }

        Write-Host "▶️  Applying policy: $name ($capabilityId)"

        switch ($capabilityId) {
            'enterprise.repo-custom-property' {
                $enterprise = $policy.config.enterprise
                if (-not $enterprise) { throw "Policy '$name' requires config.enterprise." }

                $typeName = if ($policy.config.typePropertyName) { $policy.config.typePropertyName } else { 'Type' }
                $subscriptionName = if ($policy.config.subscriptionPropertyName) { $policy.config.subscriptionPropertyName } else { 'SubscribeTo' }

                Sync-EnterpriseCustomPropertySchema `
                    -Enterprise $enterprise `
                    -FileSets $FileSets `
                    -Context $Context `
                    -TypePropertyName $typeName `
                    -SubscriptionPropertyName $subscriptionName
            }
            'enterprise.repo-rulesets' {
                $enterprise = $policy.config.enterprise
                if (-not $enterprise) { throw "Policy '$name' requires config.enterprise." }
                $rulesets = if ($policy.config.rulesets) { @($policy.config.rulesets) } else { @() }
                Sync-EnterpriseRulesets -Enterprise $enterprise -Rulesets $rulesets -Context $Context
            }
            'organization.none' {
                Write-Host "ℹ️  Organization policy layer intentionally empty"
            }
            'repository.file-subscription-service' {
                $state.RepoFileSubscriptionEnabled = $true
            }
            default {
                throw "Unsupported policy capability '$capabilityId' in '$name'."
            }
        }
    }

    return $state
}

function Sync-RepositoryFile {
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
        [object]$Context
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
        foreach ($selection in $subscribeTo) {
            if ($FileSets[$type].ContainsKey($selection)) {
                Write-Host "  + $type/$selection ($($FileSets[$type][$selection].Count) files)"
            }
        }

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

                $status -split "`n" | ForEach-Object { Write-Host "  $_" }

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

#endregion

#region Main Script

try {
    LogGroup '🔑 Authenticate' {
        $context = Connect-GitHubApp -PassThru
        $context | Format-List | Out-String
    }

    LogGroup '📂 Discover file sets' {
        $reposPath = Join-Path $PSScriptRoot '../Repos'
        $reposPath = Resolve-Path $reposPath
        $fileSets = Get-FileSets -ReposPath $reposPath
    }

    if ($fileSets.Count -eq 0) {
        Write-Host '⚠️  No file sets found - nothing to do'
        exit 0
    }

    LogGroup '🎯 Read target discovery scope' {
        $targetsPath = Join-Path $PSScriptRoot '../config/targets.json'
        $targetsPath = Resolve-Path $targetsPath
        $targetScope = Get-TargetScope -ConfigPath $targetsPath
        Write-Host "Target scope: $($targetScope.scope)"
        if ($targetScope.scope -eq 'organizations') {
            Write-Host "Target organizations: $($targetScope.organizations -join ', ')"
        }
    }

    LogGroup '📜 Load policy documents' {
        $policyRoot = if ($targetScope.policy.rootPath) { $targetScope.policy.rootPath } else { '../PolicyEngine' }
        if (-not [System.IO.Path]::IsPathRooted($policyRoot)) {
            $policyRoot = Join-Path $PSScriptRoot $policyRoot
        }
        $policyRoot = Resolve-Path $policyRoot

        $policyEnterprise = if ($targetScope.policy.enterprise) { $targetScope.policy.enterprise } else { 'default' }
        $capabilityPath = Join-Path $policyRoot 'Capabilities'
        $policyPath = Join-Path (Join-Path $policyRoot 'Policies') $policyEnterprise

        $capabilityCatalog = Get-CapabilityCatalog -CapabilityPath (Resolve-Path $capabilityPath)
        $policies = Get-PolicyDocuments -PolicyPath (Resolve-Path $policyPath) -CapabilityCatalog $capabilityCatalog
        Write-Host "Loaded $($policies.Count) policy documents for enterprise '$policyEnterprise'"
    }

    LogGroup '🧭 Execute policy engine' {
        $policyState = Invoke-PolicyEngine -Policies $policies -FileSets $fileSets -TargetScope $targetScope -Context $context
    }

    if ($policyState.RepoFileSubscriptionEnabled -ne $true) {
        Write-Host 'ℹ️  Repository file-subscription policy is disabled; file sync skipped.'
        exit 0
    }

    LogGroup '🔍 Find subscribing repositories' {
        $subscribingRepos = Get-AllSubscribingRepository -TargetScope $targetScope -Context $context
        Write-Host "Found $($subscribingRepos.Count) subscribing repositories in total"
    }

    if ($subscribingRepos.Count -eq 0) {
        Write-Host '⚠️  No subscribing repositories found - nothing to do'
        exit 0
    }

    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) "custo-sync-$(Get-Random)"
    New-Item -Path $tempPath -ItemType Directory -Force | Out-Null

    $branchName = 'managed-files/update'
    $commitMessage = 'chore: sync managed files'
    $prTitle = '⚙️ [Maintenance]: Sync managed files'
    $prLabel = 'NoRelease'
    $prBody = @'
This pull request was automatically created by the [Custo](https://github.com/MSXOrg/Custo) workflow that keeps shared files in sync across the organization's repositories.

The files in this PR are centrally managed. Any local changes to these files will be overwritten on the next sync. To propose changes, update the source files in the Custo repo instead.
'@

    try {
        foreach ($repo in $subscribingRepos) {
            Sync-RepositoryFile -Repository $repo `
                -FileSets $fileSets `
                -TempPath $tempPath `
                -BranchName $branchName `
                -CommitMessage $commitMessage `
                -PRTitle $prTitle `
                -PRBody $prBody `
                -PRLabel $prLabel `
                -Context $context
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
    }

} catch {
    Write-Host "❌ Fatal: $_"
    Write-Host $_.ScriptStackTrace
    exit 1
}

#endregion
