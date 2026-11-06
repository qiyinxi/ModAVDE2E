# fetch 项（items\fetch.ps1）的主体，只有函数定义：tests\fetch-item.ps1 也 dot-source 它，把命令行和批处理换成假的来测，
# 不跑真程序。用到 common.ps1 的 Say、Result（调用方先 dot-source common.ps1）。

# 补全组件要的两个 zip（-Cache 里放的、命令行 --keep-downloads 留下的）
$script:FetchZips = @('platform-tools_r37.0.1-win.zip', 'x86_64-34_r14.zip')

# 这个组包目录要跑哪几遍：命令行（cli）总跑；包根还有「补全组件.bat」的（0.38.1 及更早）再跑批处理（bat）。
# 0.39 起包里没有批处理，补全组件在管理器和命令行里（ModAVD/ModAVD#119）。没有 tools\modavd.exe 的不是组包目录，报错。
function Get-FetchPasses([string]$Package) {
    if (-not (Test-Path -LiteralPath (Join-Path $Package 'tools\modavd.exe') -PathType Leaf)) {
        throw "不是组包目录（要有 tools\modavd.exe）：$Package"
    }
    if (Test-Path -LiteralPath (Join-Path $Package '补全组件.bat') -PathType Leaf) { @('cli', 'bat') } else { @('cli') }
}

# 真的命令行：根目录自己的 tools\modavd.exe --root $Root --json <参数>。只要 stdout（--json 时进度日志写在 stderr）。
function Invoke-FetchCli([string]$Root, [string[]]$Argv) {
    $out = & (Join-Path $Root 'tools\modavd.exe') --root $Root --json @Argv 2>$null
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = @($out) }
}

# 真的批处理：cmd /d /c 跑 $Root 下的「补全组件.bat」，输入、输出、错误都重定向到文件，窗口藏起来。返回退出码；
# 30 分钟没结束就结束它（只结束自己起的这个 cmd 和它的子进程），返回 $null。
function Invoke-FetchBat([string]$Root, [string]$InFile, [string]$OutFile, [string]$ErrFile) {
    $p = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\cmd.exe') -ArgumentList ('/d /c ""' + (Join-Path $Root '补全组件.bat') + '""') `
        -WorkingDirectory $Root -RedirectStandardInput $InFile -RedirectStandardOutput $OutFile `
        -RedirectStandardError $ErrFile -WindowStyle Hidden -PassThru
    if (-not $p.WaitForExit(30 * 60 * 1000)) {
        & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null
        return $null
    }
    $p.ExitCode
}

# 搭一个只够补全组件用的根目录：包根的批处理（有的话）、tools\、sdk\emulator 里的 emulator.exe 和 source.properties
function New-FetchRoot([string]$Package, [string]$Dir) {
    New-Item -ItemType Directory -Force (Join-Path $Dir 'sdk\emulator') | Out-Null
    Get-ChildItem -LiteralPath $Package -File | Where-Object { $_.Extension -eq '.bat' } | Copy-Item -Destination $Dir
    Copy-Item -LiteralPath (Join-Path $Package 'tools') -Destination $Dir -Recurse
    foreach ($n in 'emulator.exe', 'source.properties') {
        Copy-Item -LiteralPath (Join-Path $Package "sdk\emulator\$n") -Destination (Join-Path $Dir 'sdk\emulator')
    }
}

# 命令行的输出读成 JSON；读不出返回 $null
function Read-FetchJson($Run) {
    try { (@($Run.Out) -join "`n") | ConvertFrom-Json } catch { $null }
}

# 根目录 $Dir 两样都装齐了：再跑一次 fetch，两样都是「跳过」，什么也不下。有问题返回一句话，没有就什么也不返回
function Test-FetchComplete([scriptblock]$Cli, [string]$Dir, [string]$Label) {
    $run = & $Cli $Dir @('components', 'fetch', '--accept-license')
    $r = Read-FetchJson $run
    if ($run.Code -ne 0 -or -not $r -or -not $r.ok) { return "${Label}：再跑一次 fetch 失败（退出码 $($run.Code)）" }
    $bad = @($r.data.components | Where-Object { -not ($_.installed -and $_.skipped) })
    if ($bad) { "${Label}：再跑一次 fetch 时没算齐全：$(($bad | ForEach-Object { $_.id }) -join '、')" }
}

# fetch 项本身：在 $Work（要是不存在的新目录）下按 Get-FetchPasses 搭根目录、补全组件、核对，最后输出结果行（Result）。
# 管理器 0.5.0 起按 Windows 用户记住下载源（%LOCALAPPDATA%\ModAVD\components-settings.json）：跑的时候 LOCALAPPDATA
# 指到 $Work\localappdata（空目录），命令行和批处理（它的子进程继承环境）都不读也不写本机真的设置，下载源照默认（自动）；
# 跑完（出错也一样）换回原值。跑完删掉 $Work（-Keep 留着）。
# $Cli、$Bat 默认是上面真的命令行、批处理，测试换成假的（参数和返回值同上）。
function Invoke-FetchItem {
    param(
        [Parameter(Mandatory)][string]$Package,
        [string]$Cache,
        [Parameter(Mandatory)][string]$Work,
        [switch]$Keep,
        [scriptblock]$Cli = ${function:Invoke-FetchCli},
        [scriptblock]$Bat = ${function:Invoke-FetchBat}
    )
    $passes = @(Get-FetchPasses $Package)
    if (Test-Path -LiteralPath $Work) { throw "-Work 要是不存在的新目录：$Work" }
    $zips = $script:FetchZips
    $problems = @()
    $notes = @()
    $made = $false
    $savedLocalAppData = $env:LOCALAPPDATA
    try {
        New-Item -ItemType Directory -Path $Work | Out-Null
        $made = $true
        $env:LOCALAPPDATA = Join-Path $Work 'localappdata'
        New-Item -ItemType Directory -Force $env:LOCALAPPDATA | Out-Null

        # 1. 命令行
        $cliRoot = Join-Path $Work 'cli'
        New-FetchRoot $Package $cliRoot
        if ($Cache) {
            New-Item -ItemType Directory -Force (Join-Path $cliRoot 'downloads') | Out-Null
            foreach ($z in $zips) { Copy-Item -LiteralPath (Join-Path $Cache $z) -Destination (Join-Path $cliRoot 'downloads') }
        }
        Say "命令行：components fetch（$(if ($Cache) { '用缓存的 zip' } else { '从网上下载' })）"
        $t0 = Get-Date
        $run = & $Cli $cliRoot @('components', 'fetch', '--accept-license', '--keep-downloads')
        $r = Read-FetchJson $run
        if ($run.Code -ne 0 -or -not $r -or -not $r.ok) {
            $problems += "命令行补全组件失败（退出码 $($run.Code)）：$(if ($r.error) { $r.error.message } else { 'JSON 读不出' })"
        } else {
            $notes += "命令行 $([int]((Get-Date) - $t0).TotalSeconds) 秒装好 $(@($r.data.components | Where-Object installed).Count) 样"
            foreach ($c in $r.data.components) {
                if (-not ($c.installed -and $c.downloaded)) { $problems += "命令行：$($c.id) 不是这次装好的" }
            }
            $problems += @(Test-FetchComplete $Cli $cliRoot '命令行')
            Say "  $($notes[-1])"
        }

        # 2. 批处理（只有 0.38.1 及更早的包有）：zip 用上一步留下的（或缓存的）
        if ($passes -notcontains 'bat') {
            $notes += '包里没有「补全组件.bat」（0.39 起），只跑了命令行这一遍'
        } else {
            $batRoot = Join-Path $Work 'bat'
            New-FetchRoot $Package $batRoot
            $from = if ($Cache) { $Cache } else { Join-Path $cliRoot 'downloads' }
            $have = @($zips | Where-Object { Test-Path -LiteralPath (Join-Path $from $_) })
            if ($have.Count -eq $zips.Count) {
                New-Item -ItemType Directory -Force (Join-Path $batRoot 'downloads') | Out-Null
                foreach ($z in $zips) { Copy-Item -LiteralPath (Join-Path $from $z) -Destination (Join-Path $batRoot 'downloads') }
            } else {
                $notes += '批处理那遍要从网上下载（命令行那遍没留下 zip）'
            }
            # 调 fetch-components.ps1 的批处理：许可协议、pause
            $inFile = Join-Path $Work 'bat-input.txt'
            [IO.File]::WriteAllText($inFile, "y`r`n`r`n", [Text.Encoding]::ASCII)
            $batLog = Join-Path $Work 'bat-output.txt'
            Say '批处理：「补全组件.bat」'
            $t0 = Get-Date
            $code = & $Bat $batRoot $inFile $batLog (Join-Path $Work 'bat-stderr.txt')
            if ($null -eq $code) {
                $problems += '批处理 30 分钟没结束，结束了它'
            } elseif ($code -ne 0) {
                $tail = @(Get-Content -LiteralPath $batLog -Encoding utf8 -ErrorAction SilentlyContinue | Where-Object { $_ -match '失败|原因|错误' } | Select-Object -Last 2) -join ' / '
                $problems += "批处理补全组件失败（退出码 $code）：$tail"
            } else {
                $notes += "批处理 $([int]((Get-Date) - $t0).TotalSeconds) 秒装好"
                $problems += @(Test-FetchComplete $Cli $batRoot '批处理')
            }
        }
        if ($notes) { Say "  $($notes[-1])" }
    } catch {
        $problems += "出错：$($_.Exception.Message)"
    } finally {
        $env:LOCALAPPDATA = $savedLocalAppData
        if ($made -and -not $Keep) {
            for ($k = 0; $k -lt 10 -and (Test-Path -LiteralPath $Work); $k++) {
                try { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction Stop } catch { Start-Sleep 2 }
            }
            if (Test-Path -LiteralPath $Work) { $problems += "收尾没删干净 $Work" } else { Say "删掉了 $Work" }
        }
    }
    $summary = $notes -join '；'
    if ($problems) { $summary += "；问题：$($problems -join '；')" }
    Result ($problems.Count -eq 0) $summary
}
