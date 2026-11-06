#requires -Version 7.0
# 管理器必须明确给、port_base 核对、游戏端口守卫的静态测试：不开模拟器、不连 adb、不调真的 modavd.exe。
# 跑法（Windows 和 Linux 都行）：pwsh -NoProfile -File tests/tooling-guards.ps1
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$scratch = Join-Path ([IO.Path]::GetTempPath()) "modavd-guards-$([guid]::NewGuid().ToString('N'))"
$failures = [Collections.Generic.List[string]]::new()
$checks = 0
function Check([bool]$ok, [string]$message) {
    $script:checks++
    if (-not $ok) { $script:failures.Add($message); Write-Host "FAIL $message" }
}
# 这个脚本里 dot-source 的东西只有 common.ps1 / port-guard.ps1（只有函数定义，不跑整段）
function Throws([scriptblock]$Body) {
    try { & $Body | Out-Null } catch { return "$($_.Exception.Message)" }
    return $null
}
$saved = @{}
foreach ($key in 'MODAVD_E2E_CONFIG', 'MODAVD_REGRESS_MANAGER', 'MODAVD_REGRESS_PACKAGE') { $saved[$key] = [Environment]::GetEnvironmentVariable($key) }
try {
    $null = New-Item -ItemType Directory -Force $scratch
    $mgrFixture = Join-Path $scratch 'manager'
    $null = New-Item -ItemType Directory -Force $mgrFixture
    $empty = Join-Path $scratch 'empty.psd1'
    Set-Content -LiteralPath $empty -Value '@{}'
    # 本机配置里有 Manager 键也不能被取用
    $withManager = Join-Path $scratch 'with-manager.psd1'
    Set-Content -LiteralPath $withManager -Value "@{ Manager = '$($mgrFixture.Replace("'", "''"))' }"

    # ---- 1. regress.ps1 不给 -Manager 就报错（环境变量和本机配置里有也不行）
    $env:MODAVD_E2E_CONFIG = $withManager
    $env:MODAVD_REGRESS_MANAGER = $mgrFixture
    $pwsh = (Get-Process -Id $PID).Path
    $out = & $pwsh -NoProfile -File (Join-Path $repo 'regress.ps1') -Suite (Join-Path $scratch 'no-suite.psd1') -Sdk $scratch 2>&1 | ForEach-Object { "$_" }
    Check ($LASTEXITCODE -ne 0) 'regress.ps1 without -Manager must fail'
    Check (($out -join "`n") -match '没给 -Manager') "regress.ps1 without -Manager must say so, got: $($out -join ' | ')"

    # ---- 2. common.ps1：没有 MODAVD_REGRESS_MANAGER 就报错；本机配置的 Manager 不算
    $env:MODAVD_E2E_CONFIG = $withManager
    $env:MODAVD_REGRESS_MANAGER = ''
    $env:MODAVD_REGRESS_PACKAGE = ''
    . (Join-Path $repo 'items\common.ps1')
    $m = Throws { Get-ManagerDir }
    Check ($m -and $m -match 'MODAVD_REGRESS_MANAGER') "Get-ManagerDir must fail without MODAVD_REGRESS_MANAGER, got: $m"
    $script:ManagerDir = $mgrFixture
    Check ((Get-ManagerDir) -eq $mgrFixture) 'Get-ManagerDir returns the manager that was given'

    # ---- 3. Assert-ManagerPortBase：取 JSON 的一步换成假的，不调真的 modavd
    $fx = @{ List = $null; Version = '0.3.0' }
    function Invoke-ModavdJson([string]$Root, [string]$Exe, [string[]]$Argv) {
        if ($Argv[0] -eq 'list') { return $fx.List }
        if ($Argv[0] -eq 'version') { return [pscustomobject]@{ version = $fx.Version } }
        throw "unexpected modavd call $($Argv -join ' ')"
    }
    function NewRoot([string]$name, $portBase) {
        $r = Join-Path $scratch $name
        $null = New-Item -ItemType Directory -Force $r
        $j = if ($null -ne $portBase) { @{ adbServerPort = 23083; portBase = $portBase } } else { @{ adbServerPort = 23083 } }
        $j | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $r 'mas-avd.json')
        $r
    }
    $fakeExe = Join-Path $mgrFixture 'tools/modavd.exe'

    # 没有 port_base（旧版）
    $fx.List = [pscustomobject]@{ root = 'x'; instances = @() }
    $m = Throws { Assert-ManagerPortBase (NewRoot 'r1' 23000) $fakeExe }
    Check ($m -and $m -match '不认 portBase' -and $m.Contains($fakeExe) -and $m.Contains('0.3.0')) "old manager without port_base must be refused with path and version, got: $m"
    # 和 mas-avd.json 的 portBase 不一致
    $fx.List = [pscustomobject]@{ port_base = 24000; instances = @() }
    $m = Throws { Assert-ManagerPortBase (NewRoot 'r2' 23000) $fakeExe }
    Check ($m -and $m -match '23000' -and $m -match '24000') "port_base different from portBase must be refused, got: $m"
    # 是 20000（根目录没写 portBase；写了 20000 也一样）
    $fx.List = [pscustomobject]@{ port_base = 20000; instances = @() }
    $m = Throws { Assert-ManagerPortBase (NewRoot 'r3' $null) $fakeExe }
    Check ($m -and $m -match '20000') "port_base 20000 must be refused, got: $m"
    $m = Throws { Assert-ManagerPortBase (NewRoot 'r3b' 20000) $fakeExe }
    Check ($m -and $m -match '20000') "port_base 20000 with portBase 20000 must be refused, got: $m"
    # 正常
    $fx.List = [pscustomobject]@{ port_base = 23000; instances = @() }
    $v = $null
    $m = Throws { $script:v = Assert-ManagerPortBase (NewRoot 'r4' 23000) $fakeExe }
    Check (-not $m -and $script:v -eq 23000) "matching port_base must pass and return 23000, got: $m / $($script:v)"
    $m = Throws { Assert-ManagerPortBase (NewRoot 'r5' $null) $fakeExe }
    Check (-not $m) "port_base 23000 with no portBase written must pass, got: $m"
    # Resolve-PortBase 走同一道核对（要求的 portBase 和实际不同也报错）
    $m = Throws { Resolve-PortBase (NewRoot 'r6' $null) $fakeExe 24000 }
    Check ($m -and $m -match '24000') "Resolve-PortBase must refuse a different wanted portBase, got: $m"
    $fx.List = [pscustomobject]@{ instances = @() }
    $m = Throws { Resolve-PortBase (NewRoot 'r7' 23000) $fakeExe 23000 }
    Check ($m -and $m -match 'port_base') "Resolve-PortBase must refuse a manager without port_base, got: $m"

    # ---- 4. 调用点：开测试根实例之前真的会核对（静态看函数体）
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'items\common.ps1'), [ref]$tokens, [ref]$errs)
    $fnBody = { param($name) ($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1).Body.Extent.Text }
    Check ((& $fnBody 'Set-RootSdk') -match 'Assert-ManagerPortBase') 'Set-RootSdk must check port_base before touching the test root'
    Check ((& $fnBody 'Resolve-PortBase') -match 'Assert-ManagerPortBase') 'Resolve-PortBase must use Assert-ManagerPortBase'
    Check ((& $fnBody 'Sync-RootTools') -match 'Get-ManagerDir') 'Sync-RootTools must require the manager'

    # ---- 5. 游戏端口守卫
    # 19998、5035 只有 +2（gRPC）会碰到
    foreach ($bad in 20000, 20040, 20047, 20049, 20050, 19999, 19998, 5037, 5036, 5035, 20048) {
        $m = Throws { Assert-GameConsolePort $bad 'sr' }
        Check ($null -ne $m) "game console port $bad must be refused"
    }
    foreach ($good in 20120, 20072, 20100, 20096, 20051) {
        $m = Throws { Assert-GameConsolePort $good 'sr' }
        Check ($null -eq $m) "game console port $good must pass, got: $m"
    }
    # game-real.ps1：默认端口不在生产段，真的调了守卫，认 GamePorts
    $game = Get-Content -LiteralPath (Join-Path $repo 'items\game-real.ps1') -Raw
    Check ($game -notmatch 'Port\s*=\s*200[0-4]\d\b') 'game-real.ps1 must not hard-code a port in 20000-20049'
    Check ($game -match "sr\s*=\s*@\{[^}]*Port\s*=\s*20120\b") 'game-real.ps1 sr port must be 20120'
    Check ($game -match '\(-not \$ReJudge\) \{\s+Assert-GameConsolePort \$cfg\.Port') 'game-real.ps1 must call Assert-GameConsolePort on the console port (unless -ReJudge)'
    Check ($game -match 'Use-Local GamePorts \$null' -and $game -match '\$gamePorts\.Contains\(\$Game\)') 'game-real.ps1 must read GamePorts'
    Check ($game -match 'Use-Local GameAvds \$null' -and $game -match '\$gameAvds\.Contains\(\$Game\)') 'game-real.ps1 must read GameAvds'

    # ---- 6. 已有测试根里新建实例前的端口检查：测试根自己的 adb server 开着不算（11-06 实跑：upgrade 之后 ime-pkg 被它拦住）
    $rootAdb = Join-Path $scratch 'root/sdk/platform-tools/adb.exe'
    $otherAdb = Join-Path $scratch 'other/sdk/platform-tools/adb.exe'
    function L([int]$port, $path) { [pscustomobject]@{ LocalPort = $port; Path = $path } }
    $inst = @(31090, 31091, 31092); $adbs = @(31099, 31098)
    $r = @(Get-PortConflicts @() $inst $adbs $rootAdb)
    Check ($r.Count -eq 0) "nothing listening must give no conflicts, got: $($r -join ',')"
    $r = @(Get-PortConflicts @((L 31099 $rootAdb), (L 31098 $rootAdb.ToUpper())) $inst $adbs $rootAdb)
    Check ($r.Count -eq 0) "the test root's own adb server on its adb ports must not count, got: $($r -join ',')"
    $r = @(Get-PortConflicts @((L 31099 (Join-Path $scratch 'root/sdk/../sdk/platform-tools/adb.exe'))) $inst $adbs $rootAdb)
    Check ($r.Count -eq 0) "own adb given as a non-normalized path must not count, got: $($r -join ',')"
    $r = @(Get-PortConflicts @((L 31099 $otherAdb)) $inst $adbs $rootAdb)
    Check ($r.Count -eq 1 -and $r[0] -eq 31099) "another root's adb on the adb port must count, got: $($r -join ',')"
    $r = @(Get-PortConflicts @((L 31098 $null)) $inst $adbs $rootAdb)
    Check ($r.Count -eq 1 -and $r[0] -eq 31098) "an adb port held by a process whose path is unknown must count, got: $($r -join ',')"
    $r = @(Get-PortConflicts @((L 31091 $rootAdb), (L 31090 $null), (L 31091 $null)) $inst $adbs $rootAdb)
    Check ($r.Count -eq 2 -and $r[0] -eq 31090 -and $r[1] -eq 31091) "instance ports must count whoever holds them (sorted, unique), got: $($r -join ',')"
    $r = @(Get-PortConflicts @((L 31093 $null), (L 31097 $otherAdb)) $inst $adbs $rootAdb)
    Check ($r.Count -eq 0) "ports outside the instance and adb ports must not count, got: $($r -join ',')"
    $ime = Get-Content -LiteralPath (Join-Path $repo 'items\ime-pkg.ps1') -Raw
    Check ($ime -match 'Get-PortConflicts \$listeners \$mine @\(\$AdbPort, \$ScriptAdbPort\) \$adbExe') 'ime-pkg.ps1 must check ports with Get-PortConflicts and the root''s own adb'
    Check ($ime -match "\`$adbExe = Join-Path \`$Root 'sdk\\platform-tools\\adb\.exe'") 'ime-pkg.ps1 adbExe must be the test root''s own adb'

    # ---- 7. regress.ps1 开跑前的核对（静态看：真跑要一个管理器目录，这里不造假 exe）
    $reg = Get-Content -LiteralPath (Join-Path $repo 'regress.ps1') -Raw
    $outCheck = $reg.IndexOf("Assert-NotProduction `$Out '回归输出'")
    $outMake = $reg.IndexOf('New-Item -ItemType Directory -Force $Out')
    Check ($outCheck -gt 0 -and $outMake -gt $outCheck) 'regress.ps1 must refuse -Out under a production root before creating it'
    Check ($reg -match "foreach \(\`$key in 'TestRoot', 'PackageRoot'\) \{\s+\`$configured = Use-Local \`$key \`$null '' -Optional\s+if \(\`$configured\) \{ Assert-NotProduction \`$configured `"本机配置的 \`$key`"; Assert-ListedTestRoot \`$configured") 'regress.ps1 must check the configured TestRoot / PackageRoot (production and TestRoots) before running'
    Check ($reg -match "foreach \(\`$key in 'GameAvdHome', 'SrAvdHome', 'ImeAvdHome'\) \{\s+\`$configured = Use-Local \`$key \`$null '' -Optional\s+if \(\`$configured\) \{ Assert-NotProduction \`$configured") 'regress.ps1 must check GameAvdHome / SrAvdHome / ImeAvdHome before running'
    $configCheck = $reg.IndexOf("foreach (`$key in 'GameAvdHome'")
    $firstItem = $reg.IndexOf('Start-Process pwsh')
    Check ($configCheck -gt 0 -and $firstItem -gt $configCheck) 'regress.ps1 must check the configuration before it starts any item'

    # ---- 8. 两条语句并成一行（11-06 审查：created-disk-usage 的 `Save-State    Run-Modavd @(...)` 让 create 根本没跑——
    # PowerShell 把后一条当成前一个函数的参数）。脚本里自己的函数后面跟着另一个函数名当裸参数、或 `}$x = …`，就算并行了
    $shared = foreach ($lib in 'items\common.ps1', 'items\port-guard.ps1', 'items\disk-usage-lib.ps1', 'items\fetch-lib.ps1', 'local.ps1') {
        $libAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $lib), [ref]$null, [ref]$null)
        $libAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name }
    }
    $merged = [Collections.Generic.List[string]]::new()
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $repo 'items') -Filter '*.ps1') + @(Get-Item -LiteralPath (Join-Path $repo 'regress.ps1'))) {
        $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
        # 调用按 PowerShell 的规矩不分大小写；裸参数要和函数名逐字相同才算（`A emu ime status` 里的 status 是控制台命令，不是 Status）
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $exact = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($n in @($shared) + @($fileAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })) { [void]$names.Add($n); [void]$exact.Add($n) }
        foreach ($c in $fileAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $cmd = $c.GetCommandName()
            if (-not $cmd -or -not $names.Contains($cmd)) { continue }
            foreach ($el in @($c.CommandElements | Select-Object -Skip 1)) {
                if ($el -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $el.StringConstantType -eq 'BareWord' -and $exact.Contains($el.Value)) {
                    $merged.Add("$($f.Name):$($c.Extent.StartLineNumber) $($c.Extent.Text)")
                }
            }
        }
        $lineNo = 0
        foreach ($line in [IO.File]::ReadAllLines($f.FullName)) { $lineNo++; if ($line -match '^\s*\}\s*\$\w+\s*=') { $merged.Add("$($f.Name):$lineNo $line") } }
    }
    Check ($merged.Count -eq 0) "two statements run together on one line: $($merged -join ' | ')"
}
finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}
if ($failures.Count) { Write-Host "$($failures.Count) of $checks checks failed"; exit 1 }
Write-Host "tooling guards: $checks checks passed"
# 上面调过故意失败的子进程；CI 的 pwsh 步骤会把最后的 $LASTEXITCODE 当成退出码
exit 0
