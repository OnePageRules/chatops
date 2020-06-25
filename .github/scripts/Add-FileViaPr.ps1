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
# get second non-empty line
$title = $github.event.client_payload.github.payload.comment.body -split '\r?\n'
| Where-Object { $_ } | Select-Object -Skip 1 -First 1

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

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Files
    )
    
    begin {
        $authHeaders = @{
            'Authorization' = "token $Token"
        }
        $ApiBase = 'https://api.github.com'

        function Invoke-Native {
            param([scriptblock]$Command)
            $LASTEXITCODE = 0
            Write-Host "$Command".Trim() -ForegroundColor Cyan
            Write-Host (& $Command)
            if ($LASTEXITCODE) {
                throw "Error calling $Command"
            }
            $LASTEXITCODE = 0
        }
        $base64Auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("PAT:$Token"))
        $extraheader = "AUTHORIZATION: basic $base64Auth"
        $prErrors = @()
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
            Invoke-Native { git clone $fork.parent.clone_url $forkDir --depth=1 --no-tags }
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
                Copy-Item $source $targetPath -Force
            }

            # commit and push changes
            Invoke-Native { git add --all }
            $commitFileList = $Files.Values | ForEach-Object { "$_" }
            $commitMessage = @("[Bot update] $Title", "Files changed:") + @($commitFileList) -join "`n"
            Invoke-Native { git commit -m $commitMessage }
            Invoke-Native { git push --set-upstream fork $branchName }
            # open PR
            $prArgs = @{
                Method      = 'Post'
                Uri         = "$ApiBase/repos/$Repository/pulls"
                Headers     = $authHeaders
                ContentType = 'application/json'
                Body        = @{
                    title                 = "[Bot update] $Title"
                    head                  = "$($fork.owner.login):$branchName"
                    base                  = $fork.parent.default_branch
                    maintainer_can_modify = $true
                } | ConvertTo-Json -EscapeHandling EscapeNonAscii
            }
            Write-ActionInfo "Sending $($prArgs.Method) $($prArgs.Uri) with body:`n$($prArgs.Body)"
            $pr = Invoke-RestMethod @prArgs
            return $pr

        }
        catch {
            $msg = "Processing $Repository changes failed: $($_.ToString())"
            Write-ActionError $msg
            $prErrors += $msg
        }
        finally {
            Pop-Location
            if ($forkDir -and (Get-Item $forkDir -ErrorAction:Ignore)) {
                # cleanup directory:
                Remove-Item $forkDir -Recurse -Force -ErrorAction:Ignore
            }
        }
    }

    end {
        Set-ActionOutput pr_errors $prErrors
    }
}

$repos | Invoke-AddViaPr -Title $title -Token $Token -Files $files
| ForEach-Object {
    $_.html_url
}