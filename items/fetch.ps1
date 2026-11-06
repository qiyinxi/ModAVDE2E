# 打完包补跑：用组包目录搭新的根目录，从空补全组件（adb 和系统镜像）。
# 0.37.0–0.38.0 的「补全组件.bat」装系统镜像必然失败，回归一直没测出来：别的项都把组件链到官方 SDK，不走补全组件。
#  - 命令行：tools\modavd.exe components fetch --accept-license --keep-downloads --json，两样都装好、都是这次下的。
#  - 批处理：只有包根还有「补全组件.bat」时才跑（0.38.1 及更早；0.39 起包里没有批处理，补全组件在管理器和命令行里，
#    ModAVD/ModAVD#119）。另搭一个根目录，把上一步下好的两个 zip 放进 downloads\（不重下 1.5 GB），用重定向的输入跑它：
#    它调 fetch-components.ps1，只问许可协议，结尾 pause 也喂一个回车，退出码 0。
#  - 各个根目录最后都再跑一次 components fetch：两样都算齐全、跳过（「齐全」按 fetch 的严格规则，不是 status 的宽松规则）。
# 管理器 0.5.0 起按 Windows 用户记住下载源（%LOCALAPPDATA%\ModAVD\components-settings.json）：跑的时候 LOCALAPPDATA
# 指到工作目录里的空目录，不读也不写本机真的设置，下载源照默认（自动）。
# 只有取许可协议清单要联网；-Cache 给了放着这两个 zip 的目录时，命令行那一步也不下载。
# 根目录只放补全组件用得到的：包根的批处理（有的话）、tools\、sdk\emulator 里的 emulator.exe 和 source.properties。
# 跑完删掉（-Keep 留着）。不开模拟器，不起 adb server。
# 主体在 fetch-lib.ps1（Invoke-FetchItem），tests\fetch-item.ps1 换上假的命令行和批处理测它。
param(
    # 组包目录（release\ModAVD-<版本>-win-x64，只读）
    [Parameter(Mandatory)][string]$Package,
    # 放着 platform-tools_r37.0.1-win.zip、x86_64-34_r14.zip 的目录（本机配置 ComponentCache，可以没有）
    [string]$Cache,
    # 默认 <TempRoot>\regress-fetch
    [string]$Work,
    [switch]$Keep
)
$ErrorActionPreference = 'Stop'
[cultureinfo]::CurrentCulture = [cultureinfo]::InvariantCulture
. "$PSScriptRoot\common.ps1"
. "$PSScriptRoot\fetch-lib.ps1"
$Cache = Use-Local ComponentCache $Cache '-Cache' -Optional
if (-not $Work) { $Work = Join-Path (Use-Local TempRoot $null '-Work') 'regress-fetch' }
$Work = [IO.Path]::GetFullPath($Work)
Assert-NotProduction $Work '工作目录'
$Package = (Resolve-Path -LiteralPath $Package).Path
Invoke-FetchItem -Package $Package -Cache $Cache -Work $Work -Keep:$Keep
exit 0
