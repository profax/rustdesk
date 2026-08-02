<#
.SYNOPSIS
    Сборка Armilen Remote под Windows на самой Windows.

.DESCRIPTION
    Запускается не руками, а из WSL через scripts/build-local.sh --target windows.
    Отдельным файлом он лежит потому, что собрать Windows-клиент из Linux нельзя
    в принципе: Flutter собирает Windows-десктоп через MSBuild и MSVC, и
    кросс-компиляции у этой связки нет. Работать в WSL и собирать на хосте это
    единственный рабочий вариант, а не компромисс.

    Исходники сюда приезжают уже с наложенным брендингом (его накладывает
    WSL-сторона тем же composite action, что и CI), поэтому здесь только сборка.
    Дублировать логику брендинга на PowerShell значило бы завести второй
    источник правды и разъехаться с CI на первой же правке.

.PARAMETER Deps
    Разовая установка инструментов через winget. Требует прав администратора.

.PARAMETER SourceDir
    Каталог с исходниками на диске Windows. По умолчанию C:\dev\armilen-remote.
#>
[CmdletBinding()]
param(
	[switch]$Deps,
	[string]$SourceDir = "C:\dev\armilen-remote",
	[string]$FlutterVersion = "3.24.5",
	[string]$RustVersion = "1.75",
	[string]$VcpkgCommitId = "120deac3062162151622ca4860575a33844ba10b",
	[string]$LlvmVersion = "15.0.6"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$CacheDir = Join-Path $env:LOCALAPPDATA "armilen-remote-build"
$VcpkgRoot = Join-Path $CacheDir "vcpkg"
$FlutterRoot = Join-Path $CacheDir "flutter"
$LlvmRoot = Join-Path $CacheDir "llvm-$LlvmVersion"
$VcpkgTriplet = "x64-windows-static"

function Write-Step { param([string]$Text) Write-Host "`n==> $Text" -ForegroundColor Green }
function Die { param([string]$Text) Write-Host "`nОшибка: $Text" -ForegroundColor Red; exit 1 }

# Инструменты ставятся в текущую сессию PATH: winget правит переменную
# машины, но уже запущенный процесс её не перечитывает.
function Add-ToPath {
	param([string]$Dir)
	if ((Test-Path $Dir) -and ($env:PATH -notlike "*$Dir*")) { $env:PATH = "$Dir;$env:PATH" }
}

function Initialize-Paths {
	Add-ToPath (Join-Path $FlutterRoot "bin")
	Add-ToPath (Join-Path $env:USERPROFILE ".cargo\bin")
	Add-ToPath $VcpkgRoot
	foreach ($p in @(
			"$env:LOCALAPPDATA\Programs\Python\Python312",
			"$env:LOCALAPPDATA\Programs\Python\Python312\Scripts",
			"$env:ProgramFiles\Git\cmd",
			"$env:ProgramFiles\NASM"
		)) { Add-ToPath $p }

	# Пиновая LLVM идёт впереди системной, а LIBCLANG_PATH снимает догадки:
	# bindgen ищет libclang сам и без подсказки берёт первую попавшуюся
	if (Test-Path (Join-Path $LlvmRoot "bin")) {
		Add-ToPath (Join-Path $LlvmRoot "bin")
		$env:LIBCLANG_PATH = Join-Path $LlvmRoot "bin"
	}
}

# bindgen читает заголовки не компилятором MSVC, а libclang, и результат
# зависит от её версии. На libclang 22 разбор заголовков aom и vpx рассыпается
# молча: bindgen не падает, а отдаёт непрозрачные заглушки вида
# `struct aom_codec_dec_cfg { _address: u8 }`, и сборка ломается уже в Rust на
# «no field named threads». CI пинит LLVM ровно этой переменной, повторяем.
function Install-Llvm {
	if (Test-Path (Join-Path $LlvmRoot "bin\libclang.dll")) {
		Write-Step "LLVM $LlvmVersion на месте"
		return
	}
	Write-Step "LLVM $LlvmVersion (пиновая, как на CI)"
	$exe = Join-Path $env:TEMP "LLVM-$LlvmVersion-win64.exe"
	$url = "https://github.com/llvm/llvm-project/releases/download/llvmorg-$LlvmVersion/LLVM-$LlvmVersion-win64.exe"
	Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing
	# Установщик NSIS: /S тихий режим, /D обязан идти последним и без кавычек.
	# -NoNewWindow с NSIS несовместим (InvalidOperationException), а установка
	# в LOCALAPPDATA прав администратора не требует
	Start-Process -FilePath $exe -ArgumentList "/S", "/D=$LlvmRoot" -Wait
	Remove-Item $exe -ErrorAction SilentlyContinue
	if (-not (Test-Path (Join-Path $LlvmRoot "bin\libclang.dll"))) {
		Die "LLVM $LlvmVersion не установился в $LlvmRoot"
	}
}

function Install-Deps {
	Write-Step "Инструменты через winget"

	$id = @{ Silent = "--silent"; Accept = "--accept-package-agreements", "--accept-source-agreements" }
	# LLVM здесь намеренно нет: bindgen привязан к версии libclang, и свежая
	# из winget ломает разбор заголовков. Ставится пиновая, см. Install-Llvm
	foreach ($pkg in @(
			"Git.Git",
			"Python.Python.3.12",
			"Rustlang.Rustup",
			"Kitware.CMake",
			"NASM.NASM"
		)) {
		Write-Host "  · $pkg"
		winget install --id $pkg --exact --disable-interactivity $id.Silent @($id.Accept) 2>&1 | Out-Null
		if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
			# -1978335189 = уже установлен, это не ошибка
			Write-Host "    winget вернул $LASTEXITCODE, проверьте пакет вручную" -ForegroundColor Yellow
		}
	}

	Install-Llvm

	# Build Tools ставятся отдельно: без рабочей нагрузки VCTools у Flutter нет
	# ни MSBuild, ни компилятора, и `flutter build windows` падает на конфигурации
	Write-Step "Visual Studio 2022 Build Tools, рабочая нагрузка C++ (несколько ГБ, долго)"
	winget install --id Microsoft.VisualStudio.2022.BuildTools --exact `
		--disable-interactivity --silent `
		--accept-package-agreements --accept-source-agreements `
		--override "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --includeRecommended" 2>&1 | Out-Null

	Initialize-Paths

	Write-Step "Rust $RustVersion (MSVC)"
	rustup toolchain install "$RustVersion-x86_64-pc-windows-msvc" --component rustfmt
	rustup default "$RustVersion-x86_64-pc-windows-msvc"

	Write-Step "Flutter $FlutterVersion"
	if (-not (Test-Path $FlutterRoot)) {
		New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
		git clone https://github.com/flutter/flutter.git --depth 1 -b $FlutterVersion $FlutterRoot
	}
	Initialize-Paths
	flutter config --enable-windows-desktop
	flutter precache --windows

	Write-Step "vcpkg $($VcpkgCommitId.Substring(0,12))"
	if (-not (Test-Path (Join-Path $VcpkgRoot ".git"))) {
		git clone https://github.com/microsoft/vcpkg $VcpkgRoot
	}
	git -C $VcpkgRoot fetch --depth 1 origin $VcpkgCommitId
	git -C $VcpkgRoot checkout -q $VcpkgCommitId
	if (-not (Test-Path (Join-Path $VcpkgRoot "vcpkg.exe"))) {
		& (Join-Path $VcpkgRoot "bootstrap-vcpkg.bat") -disableMetrics
	}

	Write-Step "Готово. Дальше сборка запускается из WSL"
}

function Invoke-Build {
	if (-not (Test-Path $SourceDir)) { Die "нет каталога с исходниками: $SourceDir. Сначала синхронизация из WSL" }
	Initialize-Paths

	if (-not (Test-Path (Join-Path $LlvmRoot "bin\libclang.dll"))) {
		Die "нет пиновой LLVM $LlvmVersion в $LlvmRoot. Запустите с -Deps от администратора"
	}

	foreach ($tool in @("git", "python", "cargo", "flutter")) {
		if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
			Die "$tool не найден в PATH. Запустите с -Deps от администратора"
		}
	}

	$env:VCPKG_ROOT = $VcpkgRoot
	Set-Location $SourceDir

	Write-Step "Зависимости vcpkg ($VcpkgTriplet)"
	# ffmpeg объявлен в vcpkg.json как host: true, то есть ставится в хостовый
	# триплет. По умолчанию на Windows это x64-windows, а hwcodec ищет заголовки
	# в x64-windows-static и падает на libavutil/pixfmt.h. CI приравнивает
	# хостовый триплет к целевому этой же переменной, повторяем.
	$env:VCPKG_DEFAULT_HOST_TRIPLET = $VcpkgTriplet
	# Аргумент кавычится целиком: `--flag="$var\path"` с кавычкой в середине
	# токена парсер PowerShell не принимает
	$installRoot = Join-Path $VcpkgRoot "installed"
	& (Join-Path $VcpkgRoot "vcpkg.exe") install --triplet $VcpkgTriplet "--x-install-root=$installRoot"
	if ($LASTEXITCODE -ne 0) { Die "vcpkg не собрал зависимости" }

	# Та же строка, что в job build-for-windows-flutter. --skip-portable-pack
	# оставляет распакованный каталог вместо самораспаковывающегося экзешника:
	# для проверки правки он и нужен, а упаковка это лишние минуты
	Write-Step "Сборка (build.py --portable --flutter --hwcodec --vram)"
	python .\build.py --portable --flutter --skip-portable-pack --hwcodec --vram
	if ($LASTEXITCODE -ne 0) { Die "build.py завершился с ошибкой" }

	$out = Join-Path $SourceDir "flutter\build\windows\x64\runner\Release"
	if (-not (Test-Path $out)) { Die "сборка прошла, но каталога $out нет" }

	Write-Step "Готово"
	Write-Host "  Каталог:  $out"
	Write-Host "  Запустить: $out\rustdesk.exe"
}

if ($Deps) { Install-Deps } else { Invoke-Build }
