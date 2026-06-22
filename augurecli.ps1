<#
.SYNOPSIS
 PowerShell 7 CLI for Augure.
#>

# --- Configuration ---
$BaseUrl = "https://api.augureai.ca/v1"
$ChatEndpoint = "$BaseUrl/chat/completions"
$ModelEndpoint = "$BaseUrl/models"
$ApiKey = $env:AUGURE_API_KEY
$StorageDir = Join-Path $HOME ".augure"
$SessionsDir = Join-Path $StorageDir "sessions"
$ExportDir = Join-Path $StorageDir "exports"

# ANSI Color Codes
$C_Reset = "$([char]27)[0m"
$C_User = "$([char]27)[36m" # Cyan
$C_Augure = "$([char]27)[32m" # Green
$C_Error = "$([char]27)[31m" # Red
$C_System = "$([char]27)[90m" # Grey
$C_Cmd = "$([char]27)[35m" # Magenta
$C_Match = "$([char]27)[33m" # Yellow

# Ensure directories exist
if (-not (Test-Path $SessionsDir)) { New-Item -ItemType Directory -Path $SessionsDir -Force | Out-Null }
if (-not (Test-Path $ExportDir)) { New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null }

if (-not $ApiKey) {
    Write-Error "Missing API Key. Please set the AUGURE_API_KEY environment variable."
    return
}

# --- Global State ---
$Global:CurrentSessionName = "none"
$Global:History = @()
$Global:Model = ""
$Global:AvailableModels = @()
$Global:SystemPrompt = @{ role = "system"; content = "You are Augure, a smart, direct, and helpful Canadian AI assistant." }

# --- Helper Functions ---

function Fetch-Models {
    Write-Host "${C_System}[Fetching available models...]${C_Reset}"
    $Headers = @{ "Authorization" = "Bearer $ApiKey" }
    try {
        $Response = Invoke-RestMethod -Uri $ModelEndpoint -Method Get -Headers $Headers -ErrorAction Stop
        $Global:AvailableModels = $Response.data.id
        if (-not $Global:Model -and $Global:AvailableModels.Count -gt 0) {
            $Global:Model = $Global:AvailableModels[0]
        }
        Write-Host "${C_System}[Models synchronized.${C_Reset}"
    }
    catch {
        Write-Host "${C_Error}[Failed to fetch models. Using fallback: ossington-4]${C_Reset}"
        $Global:AvailableModels = @("ossington-4")
        $Global:Model = "ossington-4"
    }
}

function Show-Help {
    Write-Host "`n${C_Cmd}Available Commands:${C_Reset}"
    Write-Host " ${C_Cmd}:new [name]${C_Reset} Create a new session"
    Write-Host " ${C_Cmd}:list${C_Reset} Show all saved sessions"
    Write-Host " ${C_Cmd}:load [name]${C_Reset} Load an existing session"
    Write-Host " ${C_Cmd}:delete [name]${C_Reset} Delete a session"
    Write-Host " ${C_Cmd}:search [term]${C_Reset} Search all sessions"
    Write-Host " ${C_Cmd}:export [name]${C_Reset} Export to Markdown"
    Write-Host " ${C_Cmd}:list-models${C_Reset} List available AI models"
    Write-Host " ${C_Cmd}:use [model]${C_Reset} Switch current model"
    Write-Host " ${C_Cmd}:clear${C_Reset} Clear current conversation"
    Write-Host " ${C_Cmd}:help${C_Reset} Show this menu"
    Write-Host " ${C_Cmd}:exit${C_Reset} Close the CLI`n"
}

function Save-CurrentSession {
    if ($Global:CurrentSessionName -eq "none") { return }
    $FilePath = Join-Path $SessionsDir "$($Global:CurrentSessionName).json"
    # We save an object containing BOTH history and the model used
    $SessionData = @{
        model   = $Global:Model
        history = $Global:History
    }
    $SessionData | ConvertTo-Json -Depth 10 | Out-File -FilePath $FilePath -Encoding utf8
}

function Load-Session {
    param([string]$Name)
    $FilePath = Join-Path $SessionsDir "$Name.json"
    if (-not (Test-Path $FilePath)) { Write-Host "${C_Error}[Error: Session '$Name' not found]${C_Reset}"; return }
 
    $SessionData = Get-Content $FilePath -Raw | ConvertFrom-Json
    # Restore Model and History
    $Global:Model = $SessionData.model
    $Global:History = $SessionData.history | ForEach-Object { @{ role = $_.role; content = $_.content } }
    $Global:CurrentSessionName = $Name
    Write-Host "${C_System}[Loaded session: $Name (Model: $Global:Model)]${C_Reset}"
}

function List-Sessions {
    $Files = Get-ChildItem $SessionsDir -Filter "*.json"
    if ($Files.Count -eq 0) { Write-Host "${C_System}[No saved sessions found]${C_Reset}"; return }
    Write-Host "`n${C_Cmd}Saved Sessions:${C_Reset}"
    foreach ($File in $Files) {
        $Date = $File.CreationTime.ToString("yyyy-MM-dd HH:mm")
        Write-Host " - $($File.BaseName) ($Date)"
    }
}

function Search-Sessions {
    param([string]$Term)
    if (-not $Term) { Write-Host "${C_Error}[Usage: :search <keyword>]${C_Reset}"; return }
    Write-Host "${C_System}[Searching for '$Term' in all sessions...]${C_Reset}"
    $Files = Get-ChildItem $SessionsDir -Filter "*.json"
    $MatchesFound = 0
    foreach ($File in $Files) {
        $SessionData = Get-Content $File.FullName -Raw | ConvertFrom-Json
        $MatchInFile = $false
        foreach ($Msg in $SessionData.history) {
            if ($Msg.content -notlike "*$Term*") { continue }
            if (-not $MatchInFile) {
                Write-Host "`n${C_Match}Match in session: $($File.BaseName)${C_Reset}"
                $MatchInFile = $true
                $MatchesFound++
            }
            $Snippet = $Msg.content -replace "`r|`n", " "
            if ($Snippet.Length -gt 100) { $Snippet = $Snippet.Substring(0, 100) + "..." }
            Write-Host " (${($Msg.role)}) $Snippet"
        }
    }
    if ($MatchesFound -eq 0) { Write-Host "${C_System}[No matches found]${C_Reset}" }
    else { Write-Host "`n${C_System}[Search complete. Found $MatchesFound session(s).]${C_Reset}" }
}

function Export-ToMarkdown {
    param([string]$Name)
    if ($Global:CurrentSessionName -eq "none") { Write-Host "${C_Error}[No active session]${C_Reset}"; return }
    $ExportName = if ($Name) { $Name } else { $Global:CurrentSessionName }
    $FilePath = Join-Path $ExportDir "$($ExportName).md"
    $MdLines = @("# Session: $ExportName", "Model Used: $Global:Model", "Exported on: $(Get-Date)", "")
    foreach ($Msg in $Global:History) {
        if ($Msg.role -eq "system") { continue }
        $Role = if ($Msg.role -eq "user") { "User" } else { "Augure" }
        $MdLines += "

### $Role`n$($Msg.content)`n"
    }
    $MdLines | Out-File -FilePath $FilePath -Encoding utf8
    Write-Host "${C_System}[Exported to: $FilePath]${C_Reset}"
}

function List-Models {
    if ($Global:AvailableModels.Count -eq 0) { Write-Host "${C_Error}[No models available]${C_Reset}"; return }
    Write-Host "`n${C_Cmd}Available Augure Models:${C_Reset}"
    foreach ($M in $Global:AvailableModels) {
        $Marker = if ($M -eq $Global:Model) { "-> (Active)" } else { " " }
        Write-Host " $Marker $M"
    }
    Write-Host ""
}

function Switch-Model {
    param([string]$TargetModel)
    if (-not $TargetModel) { Write-Host "${C_Error}[Usage: :use <model-name>]${C_Reset}"; return }
    if ($TargetModel -notin $Global:AvailableModels) { Write-Host "${C_Error}[Error: '$TargetModel' is not valid]${C_Reset}"; return }
    $Global:Model = $TargetModel
    Write-Host "${C_System}[Model switched to: $TargetModel]${C_Reset}"
}

# --- Command Engine ---

function Invoke-CommandLogic {
    param([string]$InputString)
    $Parts = $InputString.Split(" ", 2)
    $Cmd = $Parts[0].ToLower()
    $Arg = if ($Parts.Count -gt 1) { $Parts[1] } else { $null }

    switch ($Cmd) {
        ":exit" { Save-CurrentSession; return "EXIT" }
        ":help" { Show-Help }
        ":list" { List-Sessions }
        ":list-models" { List-Models }
        ":use" { Switch-Model -TargetModel $Arg }
        ":search" { Search-Sessions -Term $Arg }
        ":export" { Export-ToMarkdown -Name $Arg }
        ":new" {
            Save-CurrentSession
            $NewName = if ($Arg) { $Arg } else { "session_$(Get-Date -Format 'yyyyMMdd_HHmmss')" }
            $Global:CurrentSessionName = $NewName
            $Global:History = @($Global:SystemPrompt)
            # Default to first available model discovered from API
            if ($Global:AvailableModels.Count -gt 0) { $Global:Model = $Global:AvailableModels[0] }
            New-Item -Path (Join-Path $SessionsDir "$NewName.json") -ItemType File -Force | Out-Null
            Write-Host "${C_System}[Created: $NewName (Model: $Global:Model)]${C_Reset}"
        }
        ":load" { if ($Arg) { Load-Session -Name $Arg } else { Write-Host "Usage: :load <name>" } }
        ":delete" {
            if (-not $Arg) { Write-Host "Usage: :delete <name>"; return }
            $Target = Join-Path $SessionsDir "$Arg.json"
            if (-not (Test-Path $Target)) { Write-Host "Not found"; return }
            Remove-Item $Target
            if ($Global:CurrentSessionName -eq $Arg) { $Global:CurrentSessionName = "none"; $Global:History = @() }
            Write-Host "[Deleted]"
        }
        ":clear" { $Global:History = @($Global:SystemPrompt); Save-CurrentSession; Write-Host "[Cleared]" }
        Default { Write-Host "${C_Error}[Unknown: $Cmd]${C_Reset}" }
    }
    return "CONTINUE"
}

# --- Main Execution Loop ---

# 1. Initial setup: Fetch models from API
Fetch-Models

Write-Host "${C_System}[Augure CLI Ready]${C_Reset}"
Show-Help

while ($true) {
    $Status = if ($Global:CurrentSessionName -eq "none") { "No Session" } else { "Session: $($Global:CurrentSessionName)" }
    Write-Host -NoNewline "${C_User}$Status [Model: $($Global:Model)] ${C_Reset}❯ "
    try {
        $UserInput = [Console]::ReadLine()
    }
    catch {
        break
    }

    if ([string]::IsNullOrWhiteSpace($UserInput)) { continue }

    if ($UserInput.StartsWith(":")) {
        if ((Invoke-CommandLogic -InputString $UserInput) -eq "EXIT") { break }
        continue
    }

    if ($Global:CurrentSessionName -eq "none") {
        Write-Host "${C_Error}[Use :new first]${C_Reset}"; continue
    }

    $Global:History += @{ role = "user"; content = $UserInput }
    $Body = @{ model = $Global:Model; messages = $Global:History } | ConvertTo-Json -Depth 10
    $Headers = @{ "Authorization" = "Bearer $ApiKey"; "Content-Type" = "application/json" }

    Write-Host "${C_Augure}[Thinking with $($Global:Model)...]${C_Reset}"

    try {
        $Response = Invoke-RestMethod -Uri $ChatEndpoint -Method Post -Headers $Headers -Body $Body -ErrorAction Stop
        $Msg = $Response.choices[0].message.content
        Write-Host "`n${C_Augure}Augure:${C_Reset} $Msg`n"
        $Global:History += @{ role = "assistant"; content = $Msg }
        Save-CurrentSession
    }
    catch {
        Write-Host "${C_Error}[Error: $($_.Exception.Message)]${C_Reset}"
        $Global:History = $Global:History[0..($Global:History.Count - 2)]
    }
}
