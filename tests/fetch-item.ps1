#requires -Version 7.0
# fetch 项（items\fetch-lib.ps1 的 Invoke-FetchItem）的测试：命令行和批处理都换成假的，不跑任何真程序、不联网、不开模拟器。
#  - 包里没有「补全组件.bat」（0.39 起，ModAVD/ModAVD#119）只跑命令行那一遍；有的（0.38.1 及更早）两遍都跑；
#    没有 tools\modavd.exe 的不是组包目录。
#  - 两遍跑的时候 LOCALAPPDATA 都指到工作目录里的空目录，跑完（出错也一样）换回原值；「本机的」LOCALAPPDATA 一个文件都不变。
# 这个测试碰不到真的 %LOCALAPPDATA%\ModAVD，被测代码就算坏了（变异检查会故意弄坏）也一样：「本机的」LOCALAPPDATA 是
# 临时目录里造的；组包目录里的 tools\modavd.exe 只是占位的文本文件，从不运行（也不造能跑的假 exe，会在桌面弹窗），
# 真的命令行、批处理在这里换成一调就报错的。
#   pwsh -NoProfile -File tests/fetch-item.ps1
$ErrorActionPreference = 'Stop'
$script:count = 0
function Check([bool]$ok, [string]$message) { $script:count++; if (-not $ok) { throw $message } }
function Throws([scriptblock]$Block) { try { & $Block | Out-Null } catch { return "$($_.Exception.Message)" }; return $null }
# 目录里的每一项（路径、文件的长度和内容哈希）
function Snapshot([string]$Dir) {
    (Get-ChildItem -LiteralPath $Dir -Recurse -Force | ForEach-Object {
        if ($_.PSIsContainer) { "$($_.FullName)|dir" } else { "$($_.FullName)|$($_.Length)|$((Get-FileHash -LiteralPath $_.FullName).Hash)" }
    } | Sort-Object) -join "`n"
}

$temp = [IO.Path]::GetTempPath()
$work = Join-Path $temp "fetch-item-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force $work | Out-Null
$config = Join-Path $work 'local.psd1'
Set-Content -LiteralPath $config -Value '@{}' -Encoding utf8
$saved = @{}
foreach ($k in 'MODAVD_E2E_CONFIG', 'MODAVD_REGRESS_MANAGER', 'MODAVD_REGRESS_PACKAGE', 'LOCALAPPDATA') { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
$env:MODAVD_E2E_CONFIG = $config
$env:MODAVD_REGRESS_MANAGER = Join-Path $work 'no-manager'
$env:MODAVD_REGRESS_PACKAGE = Join-Path $work 'no-package'
# 「本机的」LOCALAPPDATA：临时目录里的，像管理器 0.5.0 起那样记着用户选的下载源
$userLad = Join-Path $work 'user-localappdata'
if (-not $userLad.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) { throw "「本机的」LOCALAPPDATA 要在临时目录里：$userLad" }
New-Item -ItemType Directory -Force (Join-Path $userLad 'ModAVD') | Out-Null
Set-Content -LiteralPath (Join-Path $userLad 'ModAVD' 'components-settings.json') -Value '{"source":"github"}' -Encoding utf8
$env:LOCALAPPDATA = $userLad
try {
    . (Join-Path $PSScriptRoot '..\items\common.ps1')
    . (Join-Path $PSScriptRoot '..\items\fetch-lib.ps1')
    # 真的命令行、批处理：一调就报错（Invoke-FetchItem 的默认值万一没换掉，也跑不了任何程序）
    function Invoke-FetchCli { throw '测试里不许调真的命令行' }
    function Invoke-FetchBat { throw '测试里不许调真的批处理' }
    $userBefore = Snapshot $userLad
    $script:zips = @('platform-tools_r37.0.1-win.zip', 'x86_64-34_r14.zip')

    # 组包目录：tools\modavd.exe、sdk\emulator 的两个文件都是占位的；-Bat 时包根再放「补全组件.bat」（也从不运行）
    function New-FakePackage([string]$Name, [switch]$Bat, [switch]$NoExe) {
        $p = Join-Path $work $Name
        New-Item -ItemType Directory -Force (Join-Path $p 'tools'), (Join-Path $p 'sdk' 'emulator') | Out-Null
        if (-not $NoExe) { Set-Content -LiteralPath (Join-Path $p 'tools' 'modavd.exe') -Value 'placeholder, never run' -Encoding utf8 }
        Set-Content -LiteralPath (Join-Path $p 'sdk' 'emulator' 'emulator.exe') -Value 'placeholder, never run' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $p 'sdk' 'emulator' 'source.properties') -Value 'Pkg.Revision=36.4.0' -Encoding utf8
        if ($Bat) { Set-Content -LiteralPath (Join-Path $p '补全组件.bat') -Value '@echo placeholder, never run' -Encoding utf8 }
        $p
    }
    function Get-Downloads([string]$Root) {
        @(Get-ChildItem -LiteralPath (Join-Path $Root 'downloads') -File -ErrorAction SilentlyContinue | ForEach-Object Name | Sort-Object)
    }
    # 像管理器 0.5.0 起那样，按 Windows 用户把下载源记在 %LOCALAPPDATA%\ModAVD 下
    function Save-FakeSource {
        $d = Join-Path $env:LOCALAPPDATA 'ModAVD'
        New-Item -ItemType Directory -Force $d | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'components-settings.json') -Value '{"source":"auto"}' -Encoding utf8
    }

    $script:calls = [Collections.Generic.List[object]]::new()
    $script:cliThrows = $false
    $script:batCode = 0
    # 假的命令行：记下看到的 LOCALAPPDATA；第一次装好（--keep-downloads 时留下两个 zip），再跑就都是「跳过」
    $fakeCli = {
        param([string]$Root, [string[]]$Argv)
        $script:calls.Add([pscustomobject]@{ Kind = 'cli'; Root = $Root; Argv = @($Argv); LocalAppData = $env:LOCALAPPDATA; Downloads = (Get-Downloads $Root) })
        if ($script:cliThrows) { throw '假的命令行出错了' }
        Save-FakeSource
        $marker = Join-Path $Root 'fake-installed'
        $again = Test-Path -LiteralPath $marker
        if (-not $again) {
            Set-Content -LiteralPath $marker -Value 'cli' -Encoding utf8
            if ($Argv -contains '--keep-downloads') {
                New-Item -ItemType Directory -Force (Join-Path $Root 'downloads') | Out-Null
                foreach ($z in $script:zips) { Set-Content -LiteralPath (Join-Path $Root 'downloads' $z) -Value 'zip' -Encoding utf8 }
            }
        }
        $components = @(foreach ($id in 'platform-tools', 'system-image') { [ordered]@{ id = $id; installed = $true; downloaded = -not $again; skipped = $again } })
        [pscustomobject]@{ Code = 0; Out = @(([ordered]@{ ok = $true; data = [ordered]@{ components = $components } } | ConvertTo-Json -Depth 5 -Compress)) }
    }
    # 假的批处理：记下看到的 LOCALAPPDATA、根目录里有没有批处理、downloads 里有哪些 zip、喂的输入
    $fakeBat = {
        param([string]$Root, [string]$InFile, [string]$OutFile, [string]$ErrFile)
        $script:calls.Add([pscustomobject]@{ Kind = 'bat'; Root = $Root; LocalAppData = $env:LOCALAPPDATA; Downloads = (Get-Downloads $Root)
                HasBat = (Test-Path -LiteralPath (Join-Path $Root '补全组件.bat')); Input = [IO.File]::ReadAllText($InFile) })
        Save-FakeSource
        if ($script:batCode -ne 0) {
            Set-Content -LiteralPath $OutFile -Value @('正在下载', '补全组件失败：假的原因') -Encoding utf8
            return $script:batCode
        }
        Set-Content -LiteralPath (Join-Path $Root 'fake-installed') -Value 'bat' -Encoding utf8
        Set-Content -LiteralPath $OutFile -Value '完成' -Encoding utf8
        0
    }
    # 跑一遍 fetch 项，返回结果行和假程序被调的记录
    function Invoke-FakeFetch([string]$Package, [string]$Cache, [switch]$Keep) {
        $script:calls.Clear()
        $w = Join-Path $work "w-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        $lines = @(Invoke-FetchItem -Package $Package -Cache $Cache -Work $w -Keep:$Keep -Cli $fakeCli -Bat $fakeBat | ForEach-Object { "$_" })
        $last = @($lines | Where-Object { $_.StartsWith('REGRESS-RESULT ') })
        Check ($last.Count -eq 1) "要有一行结果，得到：$($lines -join ' | ')"
        $r = $last[0].Substring('REGRESS-RESULT '.Length) | ConvertFrom-Json
        [pscustomobject]@{ Work = $w; Pass = [bool]$r.pass; Summary = [string]$r.summary; Calls = @($script:calls); Lines = $lines }
    }
    # 每一次调假程序时，LOCALAPPDATA 都是这次工作目录里的空目录；跑完换回原值，「本机的」一个文件都没变
    function Check-LocalAppData($Run, [string]$Case) {
        $want = Join-Path $Run.Work 'localappdata'
        Check ($Run.Calls.Count -gt 0) "${Case}：假程序一次都没被调"
        foreach ($c in $Run.Calls) {
            Check ($c.LocalAppData -eq $want) "${Case}：$($c.Kind) 跑的时候 LOCALAPPDATA 应该是 $want，实际是 $($c.LocalAppData)"
        }
        Check ($env:LOCALAPPDATA -eq $userLad) "${Case}：跑完 LOCALAPPDATA 要换回 $userLad，实际是 $env:LOCALAPPDATA"
        Check ((Snapshot $userLad) -eq $userBefore) "${Case}：「本机的」LOCALAPPDATA 被动过了"
    }

    $noBat = New-FakePackage 'pkg-0.39'
    $withBat = New-FakePackage 'pkg-0.38.1' -Bat
    Check ((@(Get-FetchPasses $noBat) -join ',') -eq 'cli') '没有批处理的包只跑命令行'
    Check ((@(Get-FetchPasses $withBat) -join ',') -eq 'cli,bat') '有批处理的包两遍都跑'

    # ---- 1. 0.39 起的包（没有批处理）：只跑命令行那一遍，结果 pass，结果里写一句
    $r = Invoke-FakeFetch $noBat
    Check $r.Pass "没有批处理的包应该 pass：$($r.Summary)"
    Check ($r.Summary -match '只跑了命令行这一遍') "结果里要写只跑了命令行：$($r.Summary)"
    Check ((@($r.Calls | ForEach-Object Kind) -join ',') -eq 'cli,cli') "只调命令行（装一次、核对一次），实际：$(@($r.Calls | ForEach-Object Kind) -join ',')"
    Check (($r.Calls[0].Argv -join ' ') -eq 'components fetch --accept-license --keep-downloads') "第一次是 components fetch --accept-license --keep-downloads：$($r.Calls[0].Argv -join ' ')"
    Check (($r.Calls[1].Argv -join ' ') -eq 'components fetch --accept-license') "核对那次不留 zip：$($r.Calls[1].Argv -join ' ')"
    Check ($r.Calls[0].Root -eq (Join-Path $r.Work 'cli')) "命令行在工作目录的 cli 下跑：$($r.Calls[0].Root)"
    Check-LocalAppData $r '没有批处理的包'
    Check (-not (Test-Path -LiteralPath $r.Work)) '跑完删掉工作目录'

    # ---- 2. 0.38.1 及更早的包（有批处理）：两遍都跑，批处理那遍用命令行留下的 zip，喂「y、回车」
    $r = Invoke-FakeFetch $withBat
    Check $r.Pass "有批处理的包应该 pass：$($r.Summary)"
    Check ((@($r.Calls | ForEach-Object Kind) -join ',') -eq 'cli,cli,bat,cli') "命令行装、核对，批处理装、核对，实际：$(@($r.Calls | ForEach-Object Kind) -join ',')"
    $bat = $r.Calls[2]
    Check ($bat.Root -eq (Join-Path $r.Work 'bat')) "批处理在另搭的 bat 根目录下跑：$($bat.Root)"
    Check $bat.HasBat '批处理那个根目录里要有「补全组件.bat」'
    Check (($bat.Downloads -join ',') -eq ($zips -join ',')) "批处理那遍要先放好命令行留下的两个 zip：$($bat.Downloads -join ',')"
    Check ($bat.Input -eq "y`r`n`r`n") '批处理喂的输入是同意许可协议加一个回车'
    Check ($r.Calls[3].Root -eq $bat.Root) '批处理之后在它的根目录核对齐全'
    Check ($r.Summary -match '命令行 \d+ 秒装好 2 样' -and $r.Summary -match '批处理 \d+ 秒装好') "结果里两遍都写：$($r.Summary)"
    Check-LocalAppData $r '有批处理的包'
    Check (-not (Test-Path -LiteralPath $r.Work)) '跑完删掉工作目录（有批处理的包）'

    # ---- 3. 给了 -Cache：命令行那遍开跑前 downloads 里就有两个 zip，批处理那遍也从缓存拿
    $cache = Join-Path $work 'cache'
    New-Item -ItemType Directory -Force $cache | Out-Null
    foreach ($z in $zips) { Set-Content -LiteralPath (Join-Path $cache $z) -Value 'cached' -Encoding utf8 }
    $r = Invoke-FakeFetch $withBat $cache
    Check $r.Pass "给了缓存应该 pass：$($r.Summary)"
    Check (($r.Calls[0].Downloads -join ',') -eq ($zips -join ',')) "命令行开跑前缓存的 zip 要放进 downloads：$($r.Calls[0].Downloads -join ',')"
    Check (($r.Calls[2].Downloads -join ',') -eq ($zips -join ',')) '批处理那遍也放好缓存的 zip'
    Check-LocalAppData $r '给了缓存'

    # ---- 4. 批处理失败：结果不 pass，写退出码和日志里的原因
    $script:batCode = 3
    $r = Invoke-FakeFetch $withBat
    $script:batCode = 0
    Check (-not $r.Pass) '批处理失败要不 pass'
    Check ($r.Summary -match '批处理补全组件失败（退出码 3）' -and $r.Summary -match '假的原因') "批处理失败要写退出码和原因：$($r.Summary)"
    Check-LocalAppData $r '批处理失败'

    # ---- 5. 命令行出错（抛异常）：结果不 pass，LOCALAPPDATA 照样换回，工作目录照样删
    $script:cliThrows = $true
    $r = Invoke-FakeFetch $noBat
    $script:cliThrows = $false
    Check (-not $r.Pass -and $r.Summary -match '假的命令行出错了') "命令行出错要不 pass 并写原因：$($r.Summary)"
    Check-LocalAppData $r '命令行出错'
    Check (-not (Test-Path -LiteralPath $r.Work)) '出错时也删掉工作目录'

    # ---- 6. -Keep：工作目录留着；假程序记的下载源落在工作目录里的 localappdata 下
    $r = Invoke-FakeFetch $noBat -Keep
    Check $r.Pass "-Keep 应该 pass：$($r.Summary)"
    Check (Test-Path -LiteralPath (Join-Path $r.Work 'localappdata' 'ModAVD' 'components-settings.json'))'-Keep 时工作目录留着，记的下载源在它的 localappdata 下'
    Check-LocalAppData $r '-Keep'
    Remove-Item -LiteralPath $r.Work -Recurse -Force

    # ---- 7. 跑之前没有 LOCALAPPDATA：跑的时候照样指到空目录，跑完还是没有
    $env:LOCALAPPDATA = $null
    try {
        $r = Invoke-FakeFetch $noBat
        $seen = @($r.Calls | ForEach-Object LocalAppData | Select-Object -Unique)
        Check ($r.Pass -and $seen.Count -eq 1 -and $seen[0] -eq (Join-Path $r.Work 'localappdata')) "没有 LOCALAPPDATA 时也要指到工作目录里：$($seen -join ',')"
        Check ($null -eq $env:LOCALAPPDATA) "原来没有 LOCALAPPDATA，跑完也要没有：$env:LOCALAPPDATA"
    } finally { $env:LOCALAPPDATA = $userLad }
    Check ((Snapshot $userLad) -eq $userBefore) '没有 LOCALAPPDATA 那遍也没碰「本机的」'

    # ---- 8. 不是组包目录、工作目录已经有了：一开始就停，什么都不跑、不建
    $script:calls.Clear()
    $notPkg = New-FakePackage 'not-a-package' -Bat -NoExe
    $w = Join-Path $work 'w-not-a-package'
    $m = Throws { Invoke-FetchItem -Package $notPkg -Work $w -Cli $fakeCli -Bat $fakeBat }
    Check ($m -match '不是组包目录') "没有 tools\modavd.exe 要报不是组包目录：$m"
    Check (-not (Test-Path -LiteralPath $w)) '不是组包目录时没建工作目录'
    $w = Join-Path $work 'w-exists'
    New-Item -ItemType Directory -Force $w | Out-Null
    Set-Content -LiteralPath (Join-Path $w 'keep.txt') -Value 'keep' -Encoding utf8
    $m = Throws { Invoke-FetchItem -Package $noBat -Work $w -Cli $fakeCli -Bat $fakeBat }
    Check ($m -match '-Work 要是不存在的新目录') "工作目录已经有了要停：$m"
    Check ((Get-Content -LiteralPath (Join-Path $w 'keep.txt') -Raw).Trim() -eq 'keep') '已有的工作目录不动'
    Check ($script:calls.Count -eq 0) '一开始就停时假程序一次都没被调'
    Check ($env:LOCALAPPDATA -eq $userLad) '一开始就停时 LOCALAPPDATA 不变'

    # ---- 9. 静态看：fetch.ps1 只经 Invoke-FetchItem 跑；Invoke-FetchItem 里不直接调程序，真程序只在 Invoke-FetchCli / Invoke-FetchBat 里
    $fetch = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\items\fetch.ps1') -Raw
    Check ($fetch -match '(?m)^Invoke-FetchItem -Package \$Package -Cache \$Cache -Work \$Work -Keep:\$Keep\s*$') 'fetch.ps1 要调 Invoke-FetchItem'
    Check ($fetch -notmatch 'modavd\.exe''\)? --root|Start-Process') 'fetch.ps1 自己不调 modavd.exe、不起进程'
    $libAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\items\fetch-lib.ps1'), [ref]$null, [ref]$null)
    $runners = @('Invoke-FetchCli', 'Invoke-FetchBat')
    foreach ($fn in $libAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if ($runners -contains $fn.Name) { continue }
        foreach ($c in $fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $name = $c.GetCommandName()
            $direct = (-not $name -and $c.CommandElements[0] -isnot [System.Management.Automation.Language.VariableExpressionAst]) -or ($name -and ($name -match '\.(exe|bat|cmd)$' -or $name -in 'Start-Process', 'cmd', 'taskkill', 'Invoke-FetchCli', 'Invoke-FetchBat'))
            Check (-not $direct) "$($fn.Name) 不该直接调程序（要经 `$Cli / `$Bat）：$($c.Extent.Text)"
        }
    }
    Write-Host "fetch item: $script:count checks passed"
} finally {
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
