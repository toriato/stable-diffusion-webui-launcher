param(
    [Parameter(HelpMessage = "사용할 디렉토리 경로")]
    [string] $HomeDir = (Get-Location).Path,

    [Parameter(HelpMessage = "사용할 레포지토리 디렉터리 경로")]
    [string] $RepoDir = "${HomeDir}\repo",

    [Parameter(HelpMessage = "사용할 캐시 디렉터리 경로")]
    [string] $CacheDir = "${HomeDir}\cache",

    [Parameter(HelpMessage = "사용할 임시 디렉터리 경로")]
    [string] $TempDir = "$(New-TemporaryFile | ForEach-Object { Remove-Item $_; New-Item -ItemType Directory -Path "${CacheDir}\$($_.Name)" })",

    [Parameter(HelpMessage = "사용할 인자")]
    [string[]] $LaunchArguments = $null,

    [Parameter(HelpMessage = "첫 설치시 가져올 확장 기능의 레포지토리 주소")]
    [string[]] $DefaultExtensions = @(
        "https://github.com/36DB/stable-diffusion-webui-localization-ko_KR.git",
        "https://github.com/DominikDoom/a1111-sd-webui-tagcomplete.git",
        "https://github.com/yfszzx/stable-diffusion-webui-images-browser.git"
    ),

    [Parameter(HelpMessage = "첫 설치시 가져올 모델 파일")]
    [hashtable[]] $DefaultModelFiles = @(
        @{
            Url     = "https://huggingface.co/Linaqruf/anything-v3.0/resolve/main/Anything-V3.0-pruned-fp16.safetensors"
            OutFile = "${RepoDir}\models\Stable-diffusion\Anything-V3.0-pruned-fp16.safetensors"
        },
        @{
            Url     = "https://huggingface.co/Linaqruf/anything-v3.0/resolve/main/Anything-V3.0.vae.pt"
            OutFile = "${RepoDir}\models\VAE\Anything-V3.0.vae.pt"
        }
    )
)

# 프로세스 종료 후 실행할 작업들
$defers = @(
    # 임시 디렉터리 제거하기
    { Remove-Item -Recurse -Force $TempDir }
)

$env:LC_ALL = "C.UTF-8" # 한글 출력 깨짐 방지
$env:HF_HOME = "${CacheDir}\huggingface" # HuggingFace 캐시 디렉터리 설정
$ProgressPreference = "SilentlyContinue" # Invoke-WebRequest 진행 상황이 보여질시 속도가 매우 느려지므로 숨김
Add-Type -AssemblyName PresentationCore, PresentationFramework # System.Windows.MessageBox

function Invoke-Aria2() {
    param(
        [Parameter(Mandatory = $True)]
        [string] $Url,

        [Parameter(Mandatory = $True)]
        [string] $OutFile
    )

    # Aria2 존재하는지 확인하기 없다면 설치하기
    if (!(Get-Command "aria2c.exe" -ErrorAction SilentlyContinue)) {
        if (!(Test-Path "${CacheDir}/aria2")) {
            Write-Output "Aria2 를 가져옵니다"

            $p = if ([Environment]::Is64BitOperatingSystem)
            { "https://github.com/aria2/aria2/releases/download/release-1.36.0/aria2-1.36.0-win-64bit-build1.zip" } else 
            { "https://github.com/aria2/aria2/releases/download/release-1.36.0/aria2-1.36.0-win-32bit-build1.zip" }
    
            Invoke-WebRequest -Uri $p -OutFile "${TempDir}\aria2.zip"
            Expand-Archive "${TempDir}\aria2.zip" "${TempDir}\aria2"
            Move-Item "$(@(Get-ChildItem "${TempDir}\aria2")[0].FullName)" "${CacheDir}\aria2"
        }

        $env:Path = "${CacheDir}\aria2;${env:Path}"
    }

    aria2c `
        --continue `
        --always-resume `
        --console-log-level warn `
        --disk-cache 64M `
        --min-split-size 8M `
        --max-concurrent-downloads 8 `
        --max-connection-per-server 8 `
        --max-overall-download-limit 0 `
        --max-download-limit 0 `
        --split 8 `
        --dir "$(Split-Path $OutFile -Parent)" `
        --out "$(Split-Path $OutFile -Leaf)" `
        "$Url"
    
    if (!$?) {
        throw "파일 다운로드 중 오류가 발생했습니다"
    }
}

function Test-XFormersOperator() {
    param(
        [string[]] $OperatorNames = @(
            # TODO: 웹UI 실행할 때 필요한 오퍼레이터들이 맞는지 검증 필요함
            'flshattF',
            'flshattB'
        )
    )

    python -c "
from logging import getLogger, CRITICAL
getLogger().setLevel(CRITICAL)

import sys
from xformers.ops.common import OPERATORS_REGISTRY
ops = [op.NAME for op in OPERATORS_REGISTRY if op.info() == 'available']
sys.exit(0 if all(x in ops for x in sys.argv[1:]) else 1)
" @OperatorNames

    return $?
}

$cuda = (nvidia-smi --query-gpu="index,name,compute_cap,memory.total" --format="csv,nounits" | ConvertFrom-Csv -ErrorAction SilentlyContinue)

if ($cuda) {
    $cuda | Add-Member -NotePropertyName "half" -NotePropertyValue $false
    $cuda | Add-Member -NotePropertyName "memory" -NotePropertyValue $cuda."memory.total [MiB]"

    try {
        # FP16 은 5.3 부터 지원함
        # https://en.wikipedia.org/wiki/CUDA#Data_types
        $cuda.half = [int]($cuda.compute_cap.Replace(".", "")) -ge 53
    }
    catch {
        Write-Error "CUDA 버전을 가져올 수 없습니다"
    }

    Write-Output "$($cuda.name) ($($cuda.compute_cap); VRAM $($cuda.memory) MiB)"
}

try {
    # 캐시 디렉터리 만들기
    if (!(Test-Path $CacheDir)) {
        New-Item $CacheDir -ItemType Directory | Out-Null
    }

    # Python 존재하는지 확인하고 없다면 새로 설치하기
    if (!(Get-Command "python" -ErrorAction SilentlyContinue) -or "$(python -V)" -notlike "Python 3.10*") {
        Write-Output "Python 을 설치합니다"

        if ([System.Windows.MessageBox]::Show(
                "Python 3.10 를 설치합니다, 진행하시겠습니까?`n환경 변수를 덮어쓰므로 다른 Python 버전이 설치된 환경이라면 취소한 뒤 수동으로 설치하고 작업을 다시 실행하는 것이 좋습니다.", 
                "Python 설치", 
                "YesNo", 
                "Question"
            ) -ne "Yes") {
            throw "사용자에 의해 작업이 중단되었습니다"
        }

        $p = if ([Environment]::Is64BitOperatingSystem)
        { "https://www.python.org/ftp/python/3.10.9/python-3.10.9-amd64.exe" } else 
        { "https://www.python.org/ftp/python/3.10.9/python-3.10.9.exe" }

        Invoke-Aria2 -Url $p -OutFile "${TempDir}\python.exe"

        # https://docs.python.org/3.10/using/windows.html#installing-without-ui
        Start-Process "${TempDir}\python.exe" `
            -Wait `
            -ArgumentList "/quiet AssociateFiles=0 PrependPath=1 Shortcuts=0 Include_doc=0 Include_launcher=0 InstallLauncherAllUsers=0 Include_tcltk=0 Include_test=0 Include_tools=0"

        # 새로운 환경 변수로부터 python.exe 실행 경로 가져오기
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "User")
    }

    # Git 존재하는지 확인하고 없다면 MinGit 설치하기
    if (!(Get-Command "git.exe" -ErrorAction SilentlyContinue)) {
        if (!(Test-Path "${CacheDir}/mingit")) {
            Write-Output "Git 을 가져옵니다"

            $p = if ([Environment]::Is64BitOperatingSystem)
            { "https://github.com/git-for-windows/git/releases/download/v2.39.0.windows.2/MinGit-2.39.0.2-busybox-64-bit.zip" } else 
            { "https://github.com/git-for-windows/git/releases/download/v2.39.0.windows.2/MinGit-2.39.0.2-busybox-32-bit.zip" }

            Invoke-Aria2 -Url $p -OutFile "${TempDir}/mingit.zip"
            Expand-Archive "${TempDir}/mingit.zip" "${CacheDir}/mingit"
        }

        $env:Path = "${CacheDir}/mingit/cmd;${env:Path}"
    }

    # virtualenv 로 가상 환경 구성하기
    # TODO: 잘못된 python 실행 경로를 가르킬 수 있으므로 확인해야함
    "${CacheDir}\virtualenv" | ForEach-Object {
        if (!(Test-Path $_)) {
            Write-Output "Python 가상 환경이 존재하지 않습니다, 생성을 시도합니다"
            python -m pip install virtualenv
            python -m venv "$_"
        }

        # 프로세스 종료 후 가상 환경 종료하기
        Invoke-Expression "${_}\Scripts\Activate.ps1"
        $defers += { deactivate }
    }

    # 프로세스 종료 후 작업 디렉터리 원래대로 복구하기
    $defers += { Pop-Location }

    if (Test-Path "${RepoDir}\.git") {
        # 레포지토리 속 .git 파일이 온전히 존재한다면 정상적으로 설치된 것으로 간주하기
        Push-Location $RepoDir
    }
    else {
        Write-Output "레포지토리를 가져옵니다"
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $RepoDir
        git clone --quiet --depth=1 "https://github.com/AUTOMATIC1111/stable-diffusion-webui.git" "$RepoDir"
        Push-Location $RepoDir
  
        # 확장 기능 가져오기
        Write-Output "확장 기능을 가져옵니다"
        Push-Location ".\extensions"
        try {
            $DefaultExtensions | ForEach-Object { 
                Write-Output $_
                git clone --quiet --depth=1 $_ 
            }
        }
        finally {
            Pop-Location
        }

        # 종속 패키지 설치하기
        # 윈도우 환경일 때 PIP 에서 torch==1.13.1 환경에서 미리 컴파일된 xformers 패키지를 가져올 수 있음
        # TODO: --extra-index-url 에 CUDA 버전을 명시해도 괜찮은지...?
        pip install `
            --pre `
            --prefer-binary `
            --extra-index-url https://download.pytorch.org/whl/cu116 `
            torch==1.13.1 xformers `
            --requirement .\requirements.txt `
    
    }

    # 모델 파일 존재하지 않으면 기본 모델 받아오기
    if ($DefaultModelFiles.Length -gt 0) {
        $checkpoints = @(
            Get-ChildItem -Path ".\models\Stable-diffusion" -Filter "*" -Recurse | Where-Object { 
                ($_.Extension -eq ".ckpt") -or ($_.Extension -eq ".safetensors") 
            }
        )
    
        if ($checkpoints.Length -eq 0) {
            Write-Output "모델 파일이 존재하지 않습니다, 기본 모델을 가져옵니다"
            $DefaultModelFiles | ForEach-Object {
                Invoke-Aria2 @_
            }
        }
    }

    $xformers = (Test-XFormersOperator)

    # 실행 인자 만들기
    if (!$LaunchArguments) {
        $LaunchArguments = @(
            "--skip-torch-cuda-test",
            "--gradio-img2img-tool", "color-sketch",
            "--autolaunch"
        )

        # xformers 사용 가능하다면 인자 추가하기
        if ($xformers) {
            $LaunchArguments += "--xformers"
        }


        # FP16 을 지원하지 않는 구형 GPU 에선 --no-half 인자가 필요함
        if (!$cuda.half) {
            $LaunchArguments += "--no-half"
        }

        # TODO: --lowram 인자가 필요한지 확인하기

        if ($cuda -and ((python -c 'import torch; print(torch.cuda.is_available())') -eq "True")) {
            # VRAM 에 맞는 최적화 인자 적용하기
            switch ([math]::round($cuda.memory / 1024)) {
                { $_ -lt 4 } {
                    # VRAM 이 4GB 미만일 때
                    Write-Output "VRAM 이 매우 낮습니다, 최적화 인자를 사용합니다"
                    $LaunchArguments += @(
                        "--lowvram",
                        "--always-batch-cond-uncond",
                        "--opt-sub-quad-attention"
                    )
                    break
                }
                { $_ -le 6 } {
                    # VRAM 이 6GB 이하일 때
                    Write-Output "VRAM 이 낮습니다, 최적화 인자를 사용합니다"
                    $LaunchArguments += @(
                        "--medvram",
                        "--opt-sub-quad-attention"
                    ) 
                    break
                }
                default {
                    $env:PYTORCH_CUDA_ALLOC_CONF = "garbage_collection_threshold:0.9,max_split_size_mb:512"
                }
            }
        }
        else {
            Write-Output "CPU 를 사용합니다"
            $LaunchArguments += "--no-half"
        }
    }

    # 웹UI 실행하기
    python -m launch @LaunchArguments
}
finally {
    $defers | ForEach-Object { $_.Invoke() }
    Read-Host "엔터를 눌러 작업을 종료합니다"
}
