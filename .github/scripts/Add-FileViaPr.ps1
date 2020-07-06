#!/usr/bin/env pwsh

[CmdletBinding()]
param (
    # OAuth access token
    [Parameter(Mandatory)]
    [string]$Token
)

$repos = $github.event.client_payload.slash_command.repo -split ';'
$fileMaps = $github.event.client_payload.slash_command.unnamed_args -split ' ' | ForEach-Object {
    $text = $_
    $local, $url = $text -split ':', 2
    return @{
        local = $local
        url   = $url
    }
}
# get lines starting with second (skip command)
$lines = $github.event.client_payload.github.payload.comment.body -split '\r?\n' | Select-Object -Skip 1
# get first non-empty
$title = $lines | Where-Object { $_ } | Select-Object -First 1
$rest = $lines | Select-Object -Skip ($lines.IndexOf($title) + 1)
$prBody = "$($rest -join "`n")".Trim()
$sourceCommentUrl = $github.event.client_payload.github.payload.comment.html_url

# get files

$filesDir = New-Item ./files -ItemType Directory -Force
$files = @{}
foreach ($filePair in $fileMaps) {
    $filePath = Join-Path "$filesDir/"  $filePair.local
    $null = New-Item (Split-Path $filePath -Parent) -ItemType Directory -Force
    $reqArgs = @{
        Uri     = $filePair.url
        OutFile = $filePath
    }
    Write-ActionInfo "Downloading '$($reqArgs.Uri)' into '$filePath'"
    $null = Invoke-WebRequest @reqArgs
    $file = [string](Get-Item $filePath)
    $files[$file] = $filePair.local
}

# process repos

function Invoke-AddViaPr {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$Repository,
        
        [Parameter(Mandatory)]
        [string]$Token,

        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Body,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.IDictionary]$Files,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$SourceCommentUrl
    )
    
    begin {
        $authHeaders = @{
            'Authorization' = "token $Token"
        }
        $ApiBase = 'https://api.github.com'
        if ($Files.Count -eq 0) {
            throw "No files to add via PR were specified."
        }

        function Invoke-Native {
            param([scriptblock]$private:Command)
            Write-Host "$private:Command".Trim() -ForegroundColor Cyan
            . $private:Command | Write-Host
            if ($LASTEXITCODE -ne 0) {
                throw "Error calling $private:Command"
            }
        }
        $base64Auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("PAT:$Token"))
        $extraheader = "AUTHORIZATION: basic $base64Auth"
        $commitFileList = $Files.Values | ForEach-Object { "$_" }
        $commitMessage = @("🤖 $Title", "Files changed:") + @($commitFileList) -join "`n"
        $prBody = if ($SourceCommentUrl) {
            @($Body, "Requested via: $SourceCommentUrl" | Where-Object { $_ }) -join "`n"
        } else {
            $Body
        }
    }
    
    process {
        Push-Location
        try {
            $findForkArgs = @{
                Method             = 'POST'
                Uri                = "$ApiBase/repos/$Repository/forks"
                Headers            = $authHeaders
                SkipHttpErrorCheck = $true
                StatusCodeVariable = 'forkCode'
            }
            $fork = Invoke-RestMethod @findForkArgs
            if ($forkCode -ne 202) {
                throw "Failed to fork $Repository"
            }
            $branchName = "bsdata-bot-$(New-Guid)"
            # clone, configure and checkout new branch
            $forkDir = New-Item work -ItemType Directory
            Invoke-Native { git clone $fork.parent.clone_url $forkDir --depth=10 --no-tags }
            Set-Location $forkDir
            Invoke-Native { git config --local gc.auto 0 }
            Invoke-Native { git config --local user.email "40243916+BSData-bot@users.noreply.github.com" }
            Invoke-Native { git config --local user.name "BSData-bot" }
            Invoke-Native { git config --local http.https://github.com/.extraheader $extraheader }
            Invoke-Native { git remote add fork $fork.clone_url }
            Invoke-Native { git checkout -b $branchName }
            
            # copy the files
            foreach ($source in $Files.Keys) {
                $targetPath = $Files[$source]
                $targetDir = Split-Path $targetPath -Parent
                if ($targetDir) {
                    $null = New-Item $targetDir -ItemType Directory -Force
                }
                Copy-Item $source $targetPath -Force -Verbose
                Invoke-Native { git add --force -- $targetPath }
            }

            # commit and push changes
            Invoke-Native { git commit -m $commitMessage }
            Invoke-Native { git push --set-upstream fork $branchName }
            # open PR
            $prArgs = @{
                Method      = 'Post'
                Uri         = "$ApiBase/repos/$Repository/pulls"
                Headers     = $authHeaders
                ContentType = 'application/json'
                Body        = @{
                    title                 = "🤖 $Title"
                    head                  = "$($fork.owner.login):$branchName"
                    base                  = $fork.parent.default_branch
                    body                  = $prBody
                    maintainer_can_modify = $true
                } | ConvertTo-Json -EscapeHandling EscapeNonAscii
            }
            Write-ActionInfo "Sending $($prArgs.Method) $($prArgs.Uri) with body:`n$($prArgs.Body)"
            $pr = Invoke-RestMethod @prArgs
            return $pr

        }
        catch {
            $msg = "Processing $Repository changes failed: $($_.ToString())"
            Write-Error $msg
        }
        finally {
            Pop-Location
            if ($forkDir -and (Get-Item $forkDir -ErrorAction:Ignore)) {
                # cleanup directory:
                Remove-Item $forkDir -Recurse -Force -ErrorAction:Ignore
            }
        }
    }
}

$prs = $repos | Invoke-AddViaPr -Title $title -Body $prBody -SourceCommentUrl $sourceCommentUrl -Token $Token -Files $files -ErrorVariable prErrors

return @{
    pr_urls   = @($prs.html_url)
    pr_errors = @($prErrors | ForEach-Object { "$_" })
}