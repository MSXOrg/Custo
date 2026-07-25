#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Syncs managed files from this repository to subscribing repositories across configured
    discovery scope.

.DESCRIPTION
    This script:
    1. Authenticates as a GitHub App for repo-level operations.
    2. Discovers available file sets from the Repos/ directory structure.
    3. Reads target discovery mode from config/targets.json.
    4. Discovers subscribing repositories from either:
       - all repositories visible to the current installation token, or
       - explicit organizations from config.
    5. For each subscribing repository:
       - Clones the repository
       - Copies managed files from the appropriate file sets
       - Detects changes using git
       - Creates or updates a pull request if changes are detected
    6. Outputs a summary of actions taken.

.NOTES
    Requires the GitHub PowerShell module and GitHub App authentication via GitHub-Script action.
    Target discovery scope is configuration, not code - see config/targets.json.
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
    <#
    .SYNOPSIS
        Reads repository discovery scope from config/targets.json.
    #>
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

    return $config
}

function Get-FileSets {
    <#
    .SYNOPSIS
        Discovers available file sets from the Repos/ directory structure.
    #>
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

function Get-SubscribingRepository {
    <#
    .SYNOPSIS
        Queries an organization's repositories for their Type and SubscribeTo custom properties.
    #>
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

        if (-not $customProps) {
            continue
        }

        $type = ($customProps | Where-Object Name -EQ 'Type').Value
        $subscribeTo = ($customProps | Where-Object Name -EQ 'SubscribeTo').Value

        if (-not $type -or -not $subscribeTo) {
            continue
        }

        if ($subscribeTo -is [string]) {
            $subscribeTo = @($subscribeTo)
        }

        if ($subscribeTo.Count -eq 0) {
            continue
        }

        $subscribingRepos += @{
            Name          = $repo.Name
            Owner         = $repo.Owner.Login
            FullName      = $repo.FullName
            Type          = $type
            SubscribeTo   = $subscribeTo
            DefaultBranch = $repo.DefaultBranch
        }
    }

    $subscribingRepos | ForEach-Object {
        [PSCustomObject]@{
            Owner       = $_.Owner
            Repo        = $_.Name
            Type        = $_.Type
            SubscribeTo = $_.SubscribeTo -join ', '
        }
    } | Format-Table -AutoSize | Out-String

    return $subscribingRepos
}

function Get-SubscribingRepositoryFromAllAccess {
    <#
    .SYNOPSIS
        Discovers subscribing repositories from all repositories visible to the
        current installation token.
    #>
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

    $subscribingRepos = @()

    foreach ($repo in $allRepos) {
        $owner = $repo.owner.login
        $repoName = $repo.name

        $customProps = (Invoke-GitHubAPI -Method GET -ApiEndpoint "/repos/$owner/$repoName/properties/values" -Context $Context).Response

        $typeProp = $customProps | Where-Object { $_.property_name -eq 'Type' }
        $subscribeToProp = $customProps | Where-Object { $_.property_name -eq 'SubscribeTo' }

        $type = $typeProp.value
        $subscribeTo = $subscribeToProp.value

        if (-not $type -or -not $subscribeTo) {
            continue
        }

        if ($subscribeTo -is [string]) {
            $subscribeTo = @($subscribeTo)
        }

        if ($subscribeTo.Count -eq 0) {
            continue
        }

        $subscribingRepos += @{
            Name          = $repoName
            Owner         = $owner
            FullName      = $repo.full_name
            Type          = $type
            SubscribeTo   = $subscribeTo
            DefaultBranch = $repo.default_branch
        }
    }

    $subscribingRepos | ForEach-Object {
        [PSCustomObject]@{
            Owner       = $_.Owner
            Repo        = $_.Name
            Type        = $_.Type
            SubscribeTo = $_.SubscribeTo -join ', '
        }
    } | Format-Table -AutoSize | Out-String

    return $subscribingRepos
}

function Sync-RepositoryFile {
    <#
    .SYNOPSIS
        Syncs files to a single repository.
    #>
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

    # Validate before opening a log group - skipped repos stay quiet
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

    # All real work inside a log group
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

                # Branch setup
                $remoteBranches = git branch -r 2>&1
                if ($remoteBranches -match "origin/$BranchName") {
                    git fetch origin $BranchName 2>&1 | Out-Null
                    git checkout $BranchName 2>&1 | Out-Null
                } else {
                    git checkout -b $BranchName 2>&1 | Out-Null
                }

                # Copy files
                foreach ($fileInfo in $filesToSync) {
                    $targetPath = Join-Path $clonePath $fileInfo.RelativePath
                    $targetDir = Split-Path $targetPath -Parent
                    if (-not (Test-Path $targetDir)) {
                        New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
                    }
                    Copy-Item -Path $fileInfo.SourcePath -Destination $targetPath -Force
                }

                # Detect changes
                $status = git status --porcelain 2>&1
                if ([string]::IsNullOrWhiteSpace($status)) {
                    Write-Host '✅ Already in sync'
                    $script:Summary.ReposAlreadyInSync++
                    return
                }

                $status -split "`n" | ForEach-Object { Write-Host "  $_" }

                # Commit and push
                git add --all 2>&1 | Out-Null
                git commit -m $CommitMessage 2>&1 | Out-Null
                $pushResult = git push --force --set-upstream origin $BranchName 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "Git push failed: $pushResult"
                }

                # Create or update PR
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

    LogGroup '🔍 Find subscribing repositories' {
        if ($targetScope.scope -eq 'all-access') {
            $subscribingRepos = Get-SubscribingRepositoryFromAllAccess -Context $context
            Write-Host "Found $($subscribingRepos.Count) subscribing repositories across all accessible repositories"
        } else {
            $subscribingRepos = @()
            foreach ($org in $targetScope.organizations) {
                $orgRepos = Get-SubscribingRepository -Owner $org -Context $context
                Write-Host "Found $($orgRepos.Count) subscribing repositories in $org"
                $subscribingRepos += $orgRepos
            }
        }
    }

    if ($subscribingRepos.Count -eq 0) {
        Write-Host '⚠️  No subscribing repositories found - nothing to do'
        exit 0
    }

    # Sync files to each repository
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

    # Summary
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
