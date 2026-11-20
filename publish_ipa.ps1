<#
.SYNOPSIS
  把 iOS 工程推到 GitHub，触发 Actions 编译，并把编译出来的未签名 IPA 拉回本地。

.EXAMPLE
  pwsh -File publish_ipa.ps1 -Token ghp_xxxxxxxx

.NOTES
  需要的 token 权限：repo（含 workflow）。经典 token 勾 repo + workflow 即可。
#>
param(
    [Parameter(Mandatory = $true)][string]$Token,
    [string]$Owner = "",
    [string]$RepoName = "lanmei-ios",
    [string]$SourceDir = "",
    [string]$OutDir = ""
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not $SourceDir) { $SourceDir = $PSScriptRoot }
if (-not $OutDir) { $OutDir = Join-Path $SourceDir "out" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$api = "https://api.github.com"
$hdr = @{
    "Authorization"        = "Bearer $Token"
    "Accept"               = "application/vnd.github+json"
    "User-Agent"           = "dsh-ipa-publisher"
    "X-GitHub-Api-Version" = "2022-11-28"
}

function Invoke-GH {
    param([string]$Method, [string]$Path, $Body = $null)
    $p = @{
        Method      = $Method
        Uri         = "$api$Path"
        Headers     = $hdr
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $p['Body']        = ($Body | ConvertTo-Json -Depth 8)
        $p['ContentType'] = 'application/json'
    }
    return Invoke-RestMethod @p
}

# ---------- 1. 校验 token ----------
Write-Host "[1/6] 校验 token ..." -ForegroundColor Cyan
try {
    $me = Invoke-GH -Method GET -Path "/user"
} catch {
    Write-Host "  token 无效或无网络：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
$login = $me.login
if (-not $Owner) { $Owner = $login }
Write-Host "  登录为 $login"

# ---------- 2. 建仓库 ----------
Write-Host "[2/6] 创建/复用仓库 $Owner/$RepoName ..." -ForegroundColor Cyan
$exists = $true
try { Invoke-GH -Method GET -Path "/repos/$Owner/$RepoName" | Out-Null }
catch { $exists = $false }

if (-not $exists) {
    Invoke-GH -Method POST -Path "/user/repos" -Body @{
        name        = $RepoName
        private     = $false
        auto_init   = $false
        description = "LanmeiVideo iOS shell (unsigned IPA build)"
    } | Out-Null
    Write-Host "  已创建"
    Start-Sleep -Seconds 3
} else {
    Write-Host "  已存在，直接复用"
}

# ---------- 3. 推送源码 ----------
Write-Host "[3/6] 推送源码 ..." -ForegroundColor Cyan
Push-Location $SourceDir
try {
    if (-not (Test-Path ".git")) {
        git init -q -b main 2>$null
        if ($LASTEXITCODE -ne 0) { git init -q; git checkout -q -b main }
    }
    git add -A
    git -c user.name="dsh" -c user.email="dsh@local" commit -q -m "feat: LanmeiVideo iOS shell + CI" 2>$null
    $push = "https://x-access-token:$Token@github.com/$Owner/$RepoName.git"
    git remote remove origin 2>$null
    git remote add origin $push
    git push -q -u origin main --force
    if ($LASTEXITCODE -ne 0) { throw "git push 失败" }
    Write-Host "  推送完成"
} finally {
    Pop-Location
}

# ---------- 4. 触发 workflow ----------
Write-Host "[4/6] 触发构建 ..." -ForegroundColor Cyan
Start-Sleep -Seconds 4
$wf = "$api/repos/$Owner/$RepoName/actions/workflows/build-ipa.yml"
try {
    Invoke-WebRequest -Method POST -Uri "$wf/dispatches" -Headers $hdr -Body '{"ref":"main"}' -ContentType 'application/json' | Out-Null
} catch {
    Write-Host "  dispatch 失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ---------- 5. 轮询 ----------
Write-Host "[5/6] 等待云端编译（约 5-8 分钟）..." -ForegroundColor Cyan
$runId = $null
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Seconds 15
    $runs = Invoke-GH -Method GET -Path "/repos/$Owner/$RepoName/actions/runs?per_page=5"
    $run = $runs.workflow_runs | Where-Object { $_.name -eq 'build-ipa' } | Select-Object -First 1
    if ($run) {
        if (-not $runId) { $runId = $run.id; Write-Host "  run #$($run.run_number) 已启动" }
        if ($run.status -eq 'completed') {
            Write-Host "  完成：$($run.conclusion)"
            if ($run.conclusion -ne 'success') {
                Write-Host "  构建失败，打开 $($run.html_url) 看日志" -ForegroundColor Red
                exit 1
            }
            break
        }
        Write-Host "  状态：$($run.status) ..."
    }
}

# ---------- 6. 拉 artifact ----------
Write-Host "[6/6] 下载 artifact ..." -ForegroundColor Cyan
$arts = Invoke-GH -Method GET -Path "/repos/$Owner/$RepoName/actions/runs/$runId/artifacts"
$art = $arts.artifacts | Where-Object { $_.name -like 'LanmeiVideo-unsigned-ipa*' } | Select-Object -First 1
if (-not $art) { Write-Host "  没找到 artifact" -ForegroundColor Red; exit 1 }

$zipPath = Join-Path $OutDir "artifact.zip"
Invoke-WebRequest -Uri $art.archive_download_url -Headers $hdr -OutFile $zipPath
Expand-Archive -Path $zipPath -DestinationPath $OutDir -Force

$ipa = Get-ChildItem $OutDir -Recurse -Filter *.ipa | Select-Object -First 1
if (-not $ipa) { Write-Host "  解压后没有 ipa" -ForegroundColor Red; exit 1 }

$final = Join-Path $OutDir "蓝莓视频_unsigned.ipa"
Copy-Item $ipa.FullName $final -Force
Write-Host ""
Write-Host "IPA 已就绪：" -ForegroundColor Green
Write-Host "  $final" -ForegroundColor Green
Write-Host "  大小：$([math]::Round((Get-Item $final).Length/1MB,2)) MB"
Write-Host ""
Write-Host "下一步：用 Sideloadly 拖入该 ipa，填免费 Apple ID 签名安装（7 天有效，可重签）。"
