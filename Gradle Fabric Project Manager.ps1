param(
    [string]$ProjectPath = ""
)

$ErrorActionPreference = "Stop"

$env:JAVA_HOME = "C:\Program Files\Java\jdk-25"
$env:PATH = "$env:JAVA_HOME\bin;$env:PATH"

$script:projectPath = $null
$script:taskCache = $null
$script:projectCache = $null
$script:stateFile = Join-Path $env:TEMP "gfpm-managed-processes.json"
$script:projectRoots = @(
    "G:\My mods",
    "G:\My mods\CombinedResourceLoader",
    "G:\My mods\CombinedResourceLoader\versions",
    "$HOME\Desktop\RUN"
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique

function Normalize-ProjectPath {
    param([string]$PathText)

    if ([string]::IsNullOrWhiteSpace($PathText)) {
        return $null
    }

    $trimmed = $PathText.Trim().Trim('"').Trim("'")
    if (-not (Test-Path -LiteralPath $trimmed)) {
        return $null
    }

    try {
        return (Resolve-Path -LiteralPath $trimmed).Path
    } catch {
        return $trimmed
    }
}

function Test-GradleProject {
    param([string]$PathText)

    if ([string]::IsNullOrWhiteSpace($PathText)) {
        return $false
    }

    return (
        (Test-Path -LiteralPath (Join-Path $PathText "gradlew.bat")) -or
        (Test-Path -LiteralPath (Join-Path $PathText "settings.gradle")) -or
        (Test-Path -LiteralPath (Join-Path $PathText "settings.gradle.kts")) -or
        (Test-Path -LiteralPath (Join-Path $PathText "build.gradle")) -or
        (Test-Path -LiteralPath (Join-Path $PathText "build.gradle.kts"))
    )
}

function Write-Header {
    Clear-Host
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  Gradle Fabric Project Manager" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    if ($script:projectPath) {
        Write-Host "Project: $(Split-Path $script:projectPath -Leaf)" -ForegroundColor Yellow
        Write-Host "Path   : $script:projectPath" -ForegroundColor DarkGray
        Write-Host "============================================" -ForegroundColor Cyan
    }
    Write-Host ""
}

function Get-DiscoveredProjects {
    if ($script:projectCache) {
        return $script:projectCache
    }

    $projects = New-Object System.Collections.Generic.List[pscustomobject]
    $seen = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($root in $script:projectRoots) {
        try {
            Get-ChildItem -LiteralPath $root -Filter "gradlew.bat" -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                $directory = $_.DirectoryName
                if ($seen.Add($directory)) {
                    $projects.Add([pscustomobject]@{
                        Name = Split-Path $directory -Leaf
                        Path = $directory
                        Root = $root
                    })
                }
            }
        } catch {
        }
    }

    $script:projectCache = $projects | Sort-Object Name, Path
    return $script:projectCache
}

function Reset-ProjectDiscovery {
    $script:projectCache = $null
}

function Show-DiscoveredProjects {
    param([System.Collections.IEnumerable]$Projects)

    $projectList = @($Projects)
    if ($projectList.Count -eq 0) {
        Write-Host "No Gradle projects were discovered in the default search roots yet." -ForegroundColor DarkGray
        return
    }

    Write-Host "Known Gradle projects:" -ForegroundColor Yellow
    Write-Host ""
    for ($index = 0; $index -lt $projectList.Count; $index++) {
        $project = $projectList[$index]
        Write-Host ("  {0,2}. {1}" -f ($index + 1), $project.Name) -ForegroundColor White
        Write-Host ("      {0}" -f $project.Path) -ForegroundColor DarkGray
    }
    Write-Host ""
}

function Request-ProjectPath {
    while ($true) {
        $projects = @(Get-DiscoveredProjects)
        Write-Header
        Write-Host "Pick a project by number, or paste a full path." -ForegroundColor Yellow
        Write-Host "Type 'refresh' to rescan or 'exit' to close." -ForegroundColor DarkGray
        Write-Host ""
        Show-DiscoveredProjects $projects

        $inputText = (Read-Host "Project").Trim()
        switch -Regex ($inputText) {
            '^(exit|x)$' { exit 0 }
            '^(refresh|rescan|r)$' {
                Reset-ProjectDiscovery
                continue
            }
        }

        $candidate = $null
        if ($inputText -match '^\d+$') {
            $projectIndex = [int]$inputText - 1
            if ($projectIndex -ge 0 -and $projectIndex -lt $projects.Count) {
                $candidate = $projects[$projectIndex].Path
            }
        } else {
            $candidate = Normalize-ProjectPath $inputText
        }

        if (-not $candidate) {
            Write-Host ""
            Write-Host "That was not a valid project selection." -ForegroundColor Red
            Read-Host "Press Enter to try again"
            continue
        }

        if (-not (Test-GradleProject $candidate)) {
            Write-Host ""
            Write-Host "No Gradle wrapper or Gradle build files were found in that folder." -ForegroundColor Red
            Read-Host "Press Enter to try again"
            continue
        }

        return $candidate
    }
}

function Get-GradleExecutable {
    if (Test-Path -LiteralPath (Join-Path $script:projectPath "gradlew.bat")) {
        return "gradlew.bat"
    }

    return "gradle"
}

function Add-GradleStacktrace {
    param([string]$CommandText)

    if ($CommandText -match '(^|\s)--stacktrace(\s|$)') {
        return $CommandText
    }

    return "$CommandText --stacktrace"
}

function ConvertTo-CmdQuoted {
    param([string]$Text)

    return '"' + ($Text -replace '"', '\"') + '"'
}

function Invoke-GradleForOutput {
    param([string]$Arguments)

    Push-Location $script:projectPath
    try {
        $gradleExecutable = Get-GradleExecutable
        $gradleArguments = Add-GradleStacktrace $Arguments
        $output = & cmd.exe /c "call $gradleExecutable $gradleArguments" 2>&1
        return @($output | ForEach-Object { $_.ToString() })
    } finally {
        Pop-Location
    }
}

function Get-TaskGroups {
    if ($script:taskCache) {
        return $script:taskCache
    }

    Write-Host ""
    Write-Host "Reading Gradle task groups..." -ForegroundColor DarkGray
    $raw = Invoke-GradleForOutput "tasks --all --console=plain"

    $groups = [ordered]@{}
    $currentGroup = $null

    foreach ($line in $raw) {
        $trimmed = $line.TrimEnd()
        if ($trimmed -match '^\s*([A-Za-z0-9][A-Za-z0-9 /&:_()\-]+?) tasks\s*$') {
            $currentGroup = $Matches[1].Trim()
            if (-not $groups.Contains($currentGroup)) {
                $groups[$currentGroup] = New-Object System.Collections.Generic.List[pscustomobject]
            }
            continue
        }

        if ($currentGroup -and $trimmed -match '^\s*([A-Za-z][A-Za-z0-9:_\-]+)\s+-\s+(.+)$') {
            $groups[$currentGroup].Add([pscustomobject]@{
                Name = $Matches[1].Trim()
                Description = $Matches[2].Trim()
            })
        }
    }

    $script:taskCache = $groups
    return $script:taskCache
}

function Reset-TaskCache {
    $script:taskCache = $null
}

function Get-AllTaskNames {
    $names = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($group in (Get-TaskGroups).Values) {
        foreach ($task in $group) {
            $null = $names.Add($task.Name)
        }
    }
    return @($names)
}

function Get-ManagedState {
    if (-not (Test-Path -LiteralPath $script:stateFile)) {
        return @()
    }

    try {
        $loaded = Get-Content -LiteralPath $script:stateFile -Raw | ConvertFrom-Json
    } catch {
        return @()
    }

    if ($null -eq $loaded) {
        return @()
    }

    if ($loaded -is [System.Array]) {
        return @($loaded)
    }

    return @($loaded)
}

function Save-ManagedState {
    param([object[]]$Entries)

    $entryList = @($Entries)
    $json = if ($entryList.Count -eq 0) {
        "[]"
    } else {
        $entryList | ConvertTo-Json -Depth 4
    }

    Set-Content -LiteralPath $script:stateFile -Value $json -Encoding ASCII
}

function Test-ProcessAlive {
    param([int]$ProcessId)

    return $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Get-CleanManagedState {
    $cleaned = @(Get-ManagedState | Where-Object { Test-ProcessAlive ([int]$_.RootPid) })
    Save-ManagedState $cleaned
    return $cleaned
}

function Get-LaunchKind {
    param([string]$CommandText)

    $resolvedCommand = Resolve-GradleCommandText $CommandText

    if ($resolvedCommand -match '(^|\s)runClient(\s|$)') {
        return "client"
    }
    if ($resolvedCommand -match '(^|\s)runServer(\s|$)') {
        return "server"
    }
    return "task"
}

function Resolve-GradleCommandText {
    param([string]$CommandText)

    if ([string]::IsNullOrWhiteSpace($CommandText)) {
        return ""
    }

    $resolved = $CommandText.Trim()
    $resolved = [regex]::Replace($resolved, '^(?i)runclient(?=\s|$)', 'runClient')
    $resolved = [regex]::Replace($resolved, '^(?i)runserver(?=\s|$)', 'runServer')
    return $resolved
}

function Register-ManagedProcess {
    param(
        [int]$RootPid,
        [string]$CommandText
    )

    $entries = Get-CleanManagedState
    $entries += [pscustomobject]@{
        ProjectPath = $script:projectPath
        ProjectName = Split-Path $script:projectPath -Leaf
        RootPid = $RootPid
        Kind = Get-LaunchKind $CommandText
        Command = $CommandText
        Started = (Get-Date).ToString("s")
    }
    Save-ManagedState $entries
}

function Get-ProcessTreeIds {
    param([int]$RootPid)

    $allProcesses = @(Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId)
    $pending = New-Object System.Collections.Generic.Queue[int]
    $results = New-Object System.Collections.Generic.HashSet[int]
    $pending.Enqueue($RootPid)

    while ($pending.Count -gt 0) {
        $current = $pending.Dequeue()
        if (-not $results.Add($current)) {
            continue
        }
        foreach ($child in $allProcesses | Where-Object { $_.ParentProcessId -eq $current }) {
            $pending.Enqueue([int]$child.ProcessId)
        }
    }

    return @($results)
}

function Stop-ManagedEntries {
    param([System.Collections.IEnumerable]$Entries)

    $entries = @($Entries)
    if ($entries.Count -eq 0) {
        return 0
    }

    foreach ($entry in $entries) {
        $pids = @(Get-ProcessTreeIds ([int]$entry.RootPid) | Sort-Object -Descending)
        foreach ($processId in $pids) {
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
        }
    }

    $remaining = @(Get-CleanManagedState | Where-Object {
        $keep = $true
        foreach ($entry in $entries) {
            if ([int]$_.RootPid -eq [int]$entry.RootPid) {
                $keep = $false
                break
            }
        }
        $keep
    })
    Save-ManagedState $remaining
    return $entries.Count
}

function Invoke-GradleBlocking {
    param([string]$CommandText)

    Invoke-GradleNewWindow $CommandText
}

function Invoke-GradleNewWindow {
    param([string]$CommandText)

    $resolvedCommand = Add-GradleStacktrace (Resolve-GradleCommandText $CommandText)
    $gradleExecutable = Get-GradleExecutable
    $gradleCommand = "$gradleExecutable $resolvedCommand"
    $firstTask = ($resolvedCommand -split '\s+')[0]
    $windowTitle = "Gradle $firstTask"
    $startEquivalent = "start $(ConvertTo-CmdQuoted $windowTitle) /D $(ConvertTo-CmdQuoted $script:projectPath) cmd /k $(ConvertTo-CmdQuoted $gradleCommand)"

    Write-Host ""
    Write-Host "Launching: cmd.exe /k $(ConvertTo-CmdQuoted $gradleCommand)" -ForegroundColor Cyan
    Write-Host "Working directory: $script:projectPath" -ForegroundColor Cyan
    Write-Host "Equivalent start command: $startEquivalent" -ForegroundColor DarkGray

    $process = Start-Process -FilePath "cmd.exe" -ArgumentList "/k `"$gradleCommand`"" -WorkingDirectory $script:projectPath -PassThru
    Register-ManagedProcess -RootPid $process.Id -CommandText $resolvedCommand

    Write-Host ""
    Write-Host "Launched '$resolvedCommand' in a new window." -ForegroundColor Green
    Write-Host "Use 'stop', 'stopclient', or 'stopserver' here when you want to stop it." -ForegroundColor DarkGray
    Read-Host "Press Enter to continue"
}

function Invoke-RunTask {
    $taskNames = @(Get-AllTaskNames)
    $task = if ($taskNames -contains "runClient") {
        "runClient"
    } elseif ($taskNames -contains "runServer") {
        "runServer"
    } elseif ($taskNames -contains "run") {
        "run"
    } else {
        $null
    }

    if (-not $task) {
        Write-Host ""
        Write-Host "No run task was found in this project." -ForegroundColor Red
        Read-Host "Press Enter to continue"
        return
    }

    Invoke-GradleNewWindow $task
}

function Stop-ProjectProcesses {
    param(
        [string]$Kind = "all",
        [string]$Label = "project"
    )

    $entries = @(Get-CleanManagedState | Where-Object { $_.ProjectPath -ieq $script:projectPath })
    if ($Kind -ne "all") {
        $entries = @($entries | Where-Object { $_.Kind -ieq $Kind })
    }

    Write-Host ""
    if ($entries.Count -eq 0) {
        Write-Host "No tracked $Label processes are running for this project." -ForegroundColor Yellow
        Read-Host "Press Enter to continue"
        return
    }

    $stopped = Stop-ManagedEntries $entries
    Write-Host "Stopped $stopped $Label process(es)." -ForegroundColor Green
    Read-Host "Press Enter to continue"
}

function Show-TaskGroup {
    param(
        [string]$GroupName,
        [System.Collections.IEnumerable]$Tasks
    )

    $taskList = @($Tasks)
    while ($true) {
        Write-Header
        Write-Host "$GroupName tasks:" -ForegroundColor Yellow
        Write-Host ""
        for ($index = 0; $index -lt $taskList.Count; $index++) {
            $task = $taskList[$index]
            Write-Host ("  {0,2}. {1,-24} {2}" -f ($index + 1), $task.Name, $task.Description) -ForegroundColor White
        }
        Write-Host ""
        Write-Host "Type a number or task name to run it. Type 'back' to return." -ForegroundColor DarkGray
        Write-Host ""

        $inputText = (Read-Host "Task").Trim()
        if ($inputText -in @("", "back", "b")) {
            return
        }

        $selectedTask = $null
        if ($inputText -match '^\d+$') {
            $taskIndex = [int]$inputText - 1
            if ($taskIndex -ge 0 -and $taskIndex -lt $taskList.Count) {
                $selectedTask = $taskList[$taskIndex].Name
            }
        } else {
            $selectedTask = ($taskList | Where-Object { $_.Name -ieq $inputText } | Select-Object -First 1).Name
        }

        if (-not $selectedTask) {
            Write-Host ""
            Write-Host "That task was not found in this group." -ForegroundColor Red
            Start-Sleep -Seconds 1
            continue
        }

        if ($selectedTask -match '^run') {
            Invoke-GradleNewWindow $selectedTask
        } else {
            Invoke-GradleBlocking $selectedTask
        }
    }
}

function Show-HelpMenu {
    $groups = Get-TaskGroups
    if ($groups.Count -eq 0) {
        Write-Host ""
        Write-Host "No Gradle task groups were detected for this project." -ForegroundColor Red
        Read-Host "Press Enter to continue"
        return
    }

    $groupNames = @($groups.Keys)
    while ($true) {
        Write-Header
        Write-Host "Gradle task groups:" -ForegroundColor Yellow
        Write-Host ""
        for ($index = 0; $index -lt $groupNames.Count; $index++) {
            $groupName = $groupNames[$index]
            Write-Host ("  {0,2}. {1} ({2})" -f ($index + 1), $groupName, $groups[$groupName].Count) -ForegroundColor White
        }
        Write-Host ""
        Write-Host "Type a number or group name to browse it. Type 'back' to return." -ForegroundColor DarkGray
        Write-Host ""

        $inputText = (Read-Host "Group").Trim()
        if ($inputText -in @("", "back", "b")) {
            return
        }

        $selectedGroup = $null
        if ($inputText -match '^\d+$') {
            $groupIndex = [int]$inputText - 1
            if ($groupIndex -ge 0 -and $groupIndex -lt $groupNames.Count) {
                $selectedGroup = $groupNames[$groupIndex]
            }
        } else {
            $selectedGroup = $groupNames | Where-Object { $_ -ieq $inputText } | Select-Object -First 1
            if (-not $selectedGroup) {
                $selectedGroup = $groupNames | Where-Object { $_ -ilike "*$inputText*" } | Select-Object -First 1
            }
        }

        if (-not $selectedGroup) {
            Write-Host ""
            Write-Host "That group was not found." -ForegroundColor Red
            Start-Sleep -Seconds 1
            continue
        }

        Show-TaskGroup -GroupName $selectedGroup -Tasks $groups[$selectedGroup]
    }
}

function Show-MainMenu {
    Write-Header
    Write-Host "Commands:" -ForegroundColor Yellow
    Write-Host "  run          Auto-detect and launch runClient / runServer / run" -ForegroundColor White
    Write-Host "  build        Run gradlew.bat build" -ForegroundColor White
    Write-Host "  assemble     Run gradlew.bat assemble" -ForegroundColor White
    Write-Host "  help         Browse Gradle task groups and run any task" -ForegroundColor White
    Write-Host "  stop         Stop tracked client/server windows for this project" -ForegroundColor White
    Write-Host "  stopclient   Stop tracked client windows for this project" -ForegroundColor White
    Write-Host "  stopserver   Stop tracked server windows for this project" -ForegroundColor White
    Write-Host "  quit         Return to project selection" -ForegroundColor White
    Write-Host "  exit         Close the manager" -ForegroundColor White
    Write-Host ""
    Write-Host "You can also type any Gradle task or command directly." -ForegroundColor DarkGray
    Write-Host ""
}

function Resolve-StartupProjectPath {
    param(
        [string]$BoundProjectPath,
        [object[]]$ExtraArgs
    )

    $parts = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($BoundProjectPath)) {
        $parts.Add($BoundProjectPath)
    }

    for ($index = 0; $index -lt $ExtraArgs.Count; $index++) {
        $argText = [string]$ExtraArgs[$index]
        if ([string]::IsNullOrWhiteSpace($argText)) {
            continue
        }

        if ($argText -ieq "-ProjectPath") {
            continue
        }

        $parts.Add($argText)
    }

    $candidateParts = New-Object System.Collections.Generic.List[string]
    foreach ($part in $parts) {
        $candidateParts.Add($part)
        $candidate = ($candidateParts -join " ").Trim().Trim('"').Trim("'")
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $rawCommandLine = [Environment]::CommandLine
    if ($rawCommandLine -match '(?i)(?:^|\s)-ProjectPath\s+"([^"]+)"') {
        return $Matches[1]
    }
    if ($rawCommandLine -match '(?i)(?:^|\s)-ProjectPath\s+([^\s]+)') {
        return $Matches[1]
    }

    return $BoundProjectPath
}

$ProjectPath = Resolve-StartupProjectPath -BoundProjectPath $ProjectPath -ExtraArgs $args
$normalizedStartupPath = Normalize-ProjectPath $ProjectPath
if ($normalizedStartupPath -and (Test-GradleProject $normalizedStartupPath)) {
    $script:projectPath = $normalizedStartupPath
}

while ($true) {
    if (-not $script:projectPath) {
        $script:projectPath = Request-ProjectPath
        Reset-TaskCache
    }

    Show-MainMenu
    $inputText = (Read-Host ">")
    try {
        $inputText = $inputText.Trim()
        switch -Regex ($inputText) {
            '^(exit|x)$' {
                exit 0
            }
            '^(quit|q|path|change)$' {
                $script:projectPath = $null
                Reset-TaskCache
                continue
            }
            '^(help|\?)$' {
                Show-HelpMenu
                continue
            }
            '^run$' {
                Invoke-RunTask
                continue
            }
            '^build$' {
                Invoke-GradleBlocking "build"
                continue
            }
            '^assemble$' {
                Invoke-GradleBlocking "assemble"
                continue
            }
            '^stop$' {
                Stop-ProjectProcesses -Kind "all" -Label "tracked"
                continue
            }
            '^stopclient$' {
                Stop-ProjectProcesses -Kind "client" -Label "client"
                continue
            }
            '^stopserver$' {
                Stop-ProjectProcesses -Kind "server" -Label "server"
                continue
            }
            default {
                if ([string]::IsNullOrWhiteSpace($inputText)) {
                    continue
                }
                if ($inputText -match '(^|\s)run(Client|Server)?(\s|$)') {
                    Invoke-GradleNewWindow $inputText
                } else {
                    Invoke-GradleBlocking $inputText
                }
            }
        }
    } catch {
        Write-Host ""
        Write-Host ("Manager error: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Read-Host "Press Enter to continue"
    }
}
