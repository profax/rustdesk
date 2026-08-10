#!/usr/bin/env bash
#
# Локальная сборка ArmDesk: проверить правку до пуша, не дожидаясь часа
# GitHub Actions и ничего никуда не выкладывая.
#
# Выигрыш не в том, что машина быстрее раннера (она медленнее), а в том, что
# она не начинает с нуля. Раннер каждый раз заново ставит Rust, собирает ffmpeg
# через vcpkg и качает Flutter: это и есть тот час. Здесь всё лежит в кеше и
# переживает запуск, поэтому вторая и следующие сборки укладываются в минуты.
#
#   ./scripts/build-local.sh --target windows --deps   # разово, ставит инструменты
#   ./scripts/build-local.sh --target windows          # сборка
#   ./scripts/build-local.sh --target android
#   ./scripts/build-local.sh --target linux [--full]
#
# Про Windows. Собрать Windows-клиент из WSL нельзя: Flutter собирает
# Windows-десктоп через MSBuild и MSVC, кросс-компиляции у этой связки нет.
# Поэтому цель windows работает иначе остальных: исходники с уже наложенным
# брендингом синхронизируются на диск C:, а сборку на хосте запускает
# scripts/build-windows-local.ps1 через интероп WSL. Результат остаётся на
# стороне Windows, где его и надо запускать.
#
# Версии Rust, Flutter, NDK и коммит vcpkg читаются из
# .github/workflows/flutter-build.yml. Захардкодить их здесь значило бы
# получить локальную сборку на других версиях, чем CI: такая проверка хуже,
# чем никакой.
#
# Брендинг правит рабочее дерево, включая сабмодули, ровно как на CI. Это
# ожидаемо, коммитить эти правки не нужно, откат обычным
# `git checkout -- libs/hbb_common src/lang`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORKFLOW=".github/workflows/flutter-build.yml"
CACHE_DIR="${ARMILEN_BUILD_CACHE:-$HOME/.cache/armilen-remote-build}"
WIN_SRC_DIR="${ARMILEN_WIN_SRC:-/mnt/c/dev/armilen-remote}"
WIN_SRC_DIR_NATIVE='C:\dev\armilen-remote'

TARGET=""
DEPS=0
FULL=0
SYNC_ONLY=0

while [ $# -gt 0 ]; do
	case "$1" in
	--target)
		TARGET="${2:-}"
		shift 2
		;;
	--deps)
		DEPS=1
		shift
		;;
	--full)
		FULL=1
		shift
		;;
	--sync-only)
		SYNC_ONLY=1
		shift
		;;
	-h | --help)
		awk 'NR>2 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"
		exit 0
		;;
	*)
		echo "Неизвестный аргумент: $1. Смотрите --help" >&2
		exit 1
		;;
	esac
done

case "$TARGET" in
windows | android | linux) ;;
"")
	echo "Укажите цель: --target windows|android|linux. Смотрите --help" >&2
	exit 1
	;;
*)
	echo "Неизвестная цель: $TARGET. Доступны windows, android, linux" >&2
	exit 1
	;;
esac

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
die() {
	printf '\n\033[1;31mОшибка:\033[0m %s\n' "$*" >&2
	exit 1
}

# Значение env-блока workflow: одна точка правды на CI и локальную сборку.
workflow_env() {
	local key="$1" file="${2:-$WORKFLOW}" value
	value="$(grep -m1 -E "^  ${key}: " "$file" | sed -E 's/^[^:]+: *"?([^"#]*[^"# ])"? *(#.*)?$/\1/')"
	[ -n "$value" ] || die "в $file не найден ключ $key"
	printf '%s' "$value"
}

RUST_VERSION="$(workflow_env RUST_VERSION)"
FLUTTER_VERSION="$(workflow_env FLUTTER_VERSION)"
ANDROID_FLUTTER_VERSION="$(workflow_env ANDROID_FLUTTER_VERSION)"
VCPKG_COMMIT_ID="$(workflow_env VCPKG_COMMIT_ID)"
NDK_VERSION="$(workflow_env NDK_VERSION)"
# CI пинит LLVM 15.0.6, но под Windows у неё нет портативной сборки: только
# установщик NSIS, требующий администратора. Берём ближайшую версию с архивом,
# на которой bindgen разбирает заголовки aom верно (проверено), см. Install-Llvm
WIN_LLVM_VERSION="18.1.8"
CARGO_NDK_VERSION="$(workflow_env CARGO_NDK_VERSION)"

export VCPKG_ROOT="$CACHE_DIR/vcpkg"
export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
export ANDROID_SDK_ROOT="$CACHE_DIR/android-sdk"

# У Android своя версия Flutter. Один клон на обе цели заставлял бы
# переключать ветку между сборками и каждый раз перекачивать движок.
if [ "$TARGET" = "android" ]; then
	FLUTTER_ROOT="$CACHE_DIR/flutter-$ANDROID_FLUTTER_VERSION"
else
	FLUTTER_ROOT="$CACHE_DIR/flutter-$FLUTTER_VERSION"
fi
export FLUTTER_ROOT
export PATH="$FLUTTER_ROOT/bin:$CARGO_HOME/bin:$PATH"

log "ArmDesk, локальная сборка (цель: $TARGET)"
echo "    Rust    $RUST_VERSION"
echo "    Кеш     $CACHE_DIR"

# ── Общие помощники ──────────────────────────────────────────────────────────

require_sudo() {
	sudo -n true 2>/dev/null && return 0
	cat >&2 <<-EOF

		Для системных пакетов нужен sudo, а он просит пароль, и в этом сеансе
		ввести его некуда. Выполните сначала

		    sudo -v

		и сразу следом ту же команду: пароль закешируется на несколько минут.
	EOF
	exit 1
}

install_rust() {
	log "Rust $RUST_VERSION"
	if ! command -v rustup >/dev/null 2>&1; then
		curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs |
			sh -s -- -y --default-toolchain "$RUST_VERSION" --no-modify-path
	fi
	rustup toolchain install "$RUST_VERSION" --component rustfmt
}

install_flutter() {
	local version="$1" root="$2"
	log "Flutter $version"
	if [ ! -d "$root" ]; then
		mkdir -p "$CACHE_DIR"
		git clone https://github.com/flutter/flutter.git --depth 1 -b "$version" "$root"
	fi
	git config --global --add safe.directory "$root" || true
}

install_vcpkg() {
	log "vcpkg ${VCPKG_COMMIT_ID:0:12}"
	mkdir -p "$CACHE_DIR"
	if [ ! -d "$VCPKG_ROOT/.git" ]; then
		git clone https://github.com/microsoft/vcpkg "$VCPKG_ROOT"
	fi
	git -C "$VCPKG_ROOT" fetch --depth 1 origin "$VCPKG_COMMIT_ID"
	git -C "$VCPKG_ROOT" checkout -q "$VCPKG_COMMIT_ID"
	[ -x "$VCPKG_ROOT/vcpkg" ] || "$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
}

# Хостовый C-тулчейн нужен даже кросс-сборкам: build.rs у hwcodec гоняет bindgen
# хостовым libclang. Без заголовков libc он падает на /usr/include/stdint.h с
# «'bits/libc-header-start.h' file not found», и сообщение никак не намекает,
# что дело в отсутствующем пакете.
require_host_cc() {
	command -v clang >/dev/null 2>&1 || die "нет clang: sudo apt-get install -y clang"
	[ -f /usr/include/stdint.h ] || die "нет заголовков libc: sudo apt-get install -y libc6-dev"
}

# Мост Rust↔Dart не лежит в репозитории: `src/bridge_generated.rs` стоит в
# .gitignore, при этом `lib.rs` объявляет `mod bridge_generated`. Без него не
# собирается ни одна цель, даже `cargo build --lib`.
#
# Мост не генерируется здесь, а скачивается готовым, и это ровно то, что делают
# сами сборочные джобы CI шагом «Restore bridge files»: генерирует его один
# отдельный job, остальные берут артефакт. Локальная генерация повторяла бы
# цепочку из cargo-expand, pub get, ffigen, cbindgen и freezed, где падение
# любого звена оставляет наполовину записанный bridge_generated.rs с
# незакрытым блоком DUMMY CODE FOR BINDGEN. Такой файл выглядит свежее входа,
# проходит любую проверку по времени правки и ломает сборку ссылкой на
# необъявленный Dart_Handle. Скачанный артефакт вдобавок побайтово совпадает с
# тем, на чём собирается релиз, включая generated_bridge.freezed.dart, который
# локальная генерация не создаёт вовсе.
BRIDGE_WORKFLOW="flutter-ci.yml"
BRIDGE_ARTIFACT="bridge-artifact"

restore_bridge() {
	if [ -f "src/bridge_generated.rs" ] && [ -f "flutter/lib/generated_bridge.freezed.dart" ]; then
		log "Мост на месте, пропускаем"
		return
	fi
	command -v gh >/dev/null 2>&1 || die "нужен gh для загрузки моста: https://cli.github.com"

	log "Мост Rust↔Dart: артефакт последней зелёной сборки CI"
	local run_id
	run_id="$(gh run list --workflow="$BRIDGE_WORKFLOW" --status success --limit 1 --json databaseId -q '.[0].databaseId')"
	[ -n "$run_id" ] || die "у $BRIDGE_WORKFLOW нет ни одного успешного прогона, мост брать неоткуда"

	local dest="$CACHE_DIR/bridge/$run_id"
	if [ ! -d "$dest" ]; then
		mkdir -p "$dest"
		gh run download "$run_id" -n "$BRIDGE_ARTIFACT" -D "$dest" ||
			die "не скачался артефакт $BRIDGE_ARTIFACT прогона $run_id (артефакты живут ограниченное время)"
	fi
	cp -a "$dest/." "$REPO_ROOT/"
	echo "    из прогона $run_id"
}

# Gradle андроидного проекта работает на Java 17: CI-джоб явно прописывает
# JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64. На системной Java 21 сборка
# падает на несовместимости Gradle с версией JVM. Ставим свой JDK в кеш, а не
# в систему, чтобы цель android оставалась без sudo.
JDK_DIR="$CACHE_DIR/jdk-17"

install_jdk17() {
	if [ -x "$JDK_DIR/bin/java" ]; then
		log "JDK 17 на месте"
		return
	fi
	log "JDK 17 (Temurin)"
	mkdir -p "$JDK_DIR"
	curl -fsSL "https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse" |
		tar -xz -C "$JDK_DIR" --strip-components=1
	"$JDK_DIR/bin/java" -version
}

android_ndk_dir() {
	local dir
	dir="$(find "$ANDROID_SDK_ROOT/ndk" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -V | tail -1)"
	[ -n "$dir" ] || die "NDK не найден, сначала --deps"
	printf '%s' "$dir"
}

# Брендинг живёт в composite action, потому что часть правок меняет файлы
# сабмодулей. Здесь прогоняются те же шаги, а не переписанные рядом: сборка с
# другим брендингом, чем на CI, ничего бы не проверяла.
apply_branding() {
	log "Брендинг Armilen"
	python3 -c 'import yaml' 2>/dev/null || die "нужен PyYAML: sudo apt-get install -y python3-yaml"

	# Шаги отдаются как «имя\0тело\0»: тела многострочные, по переводу строки
	# их не разделить
	while IFS= read -r -d '' name && IFS= read -r -d '' script; do
		echo "  · $name"
		bash -c "$script"
	done < <(python3 -c '
import sys, yaml

with open(".github/actions/apply-branding/action.yml") as f:
    action = yaml.safe_load(f)

for step in action["runs"]["steps"]:
    if not step.get("run"):
        continue
    sys.stdout.write(step.get("name", "шаг без имени") + "\0" + step["run"] + "\0")
')
}

# ── Windows ──────────────────────────────────────────────────────────────────

# Windows PowerShell 5.1 читает .ps1 без BOM как ANSI: кириллица в скрипте
# превращается в мусор, парсер спотыкается о случайную кавычку, и ошибка
# приходит про синтаксис, а не про кодировку. Проверяем явно, потому что
# редактор может снять BOM молча.
assert_ps_bom() {
	local ps="scripts/build-windows-local.ps1"
	[ "$(head -c 3 "$ps" | xxd -p)" = "efbbbf" ] ||
		die "$ps потерял UTF-8 BOM, PowerShell 5.1 прочитает кириллицу как ANSI. Вернуть: printf '\\\\xef\\\\xbb\\\\xbf' | cat - $ps > tmp && mv tmp $ps"
}

sync_to_windows() {
	assert_ps_bom
	log "Синхронизация исходников на диск C:"
	command -v rsync >/dev/null 2>&1 || die "нужен rsync: sudo apt-get install -y rsync"
	mkdir -p "$WIN_SRC_DIR"
	# target/ и flutter/build/ остаются на стороне Windows: это её артефакты, и
	# таскать их через 9p значило бы каждый раз убивать инкрементальность.
	#
	# Всё остальное в списке это состояние конкретной машины, и через границу
	# WSL и Windows оно ехать не должно. Flutter записывает туда абсолютные
	# пути: в package_config.json путями к пакетам, в ephemeral/.plugin_symlinks
	# симлинками на них. После `pub get` в WSL это /home/profax/.pub-cache/...,
	# и на диске C: сборка либо ищет исходники по linux-путям, либо натыкается
	# на битые симлинки в CMake. Пересоздаётся всё это `pub get` уже на хосте,
	# поэтому здесь ровно один принцип: едут только исходники.
	rsync -a --delete \
		--exclude 'target/' \
		--exclude 'flutter/build/' \
		--exclude '.dart_tool/' \
		--exclude 'ephemeral/' \
		--exclude '.flutter-plugins' \
		--exclude '.flutter-plugins-dependencies' \
		--exclude '.git/' \
		"$REPO_ROOT/" "$WIN_SRC_DIR/"
	echo "    $WIN_SRC_DIR"
}

windows_deps() {
	# Мост кладётся на сторону WSL до синхронизации: файлы платформенно
	# независимы, и на хост они уезжают вместе с исходниками
	apply_branding
	restore_bridge
	sync_to_windows
	cat <<-EOF

		Дальше нужна ваша рука: инструменты ставятся на стороне Windows и требуют
		прав администратора, то есть UAC должен спросить вас, а не меня.

		Откройте PowerShell от имени администратора и выполните одну строку:

		    powershell -ExecutionPolicy Bypass -File "${WIN_SRC_DIR_NATIVE}\\scripts\\build-windows-local.ps1" -Deps

		Ставится Git, Python 3.12, Rustup, LLVM, CMake, NASM, Visual Studio 2022
		Build Tools с рабочей нагрузкой C++, Flutter ${FLUTTER_VERSION}, vcpkg и
		LLVM ${WIN_LLVM_VERSION} (bindgen привязан к версии libclang).
		Порядка 15 ГБ и около часа, один раз на машину.

		После этого сборка запускается отсюда и уже без вас:

		    ./scripts/build-local.sh --target windows
	EOF
}

build_windows() {
	apply_branding
	restore_bridge
	sync_to_windows
	[ "$SYNC_ONLY" -eq 0 ] || {
		log "Только синхронизация, сборку не запускаю"
		return
	}

	log "Сборка на стороне Windows"
	powershell.exe -NoProfile -ExecutionPolicy Bypass \
		-File "${WIN_SRC_DIR_NATIVE}\\scripts\\build-windows-local.ps1" \
		-FlutterVersion "$FLUTTER_VERSION" \
		-RustVersion "$RUST_VERSION" \
		-VcpkgCommitId "$VCPKG_COMMIT_ID" \
		-LlvmVersion "$WIN_LLVM_VERSION" ||
		die "сборка на Windows не прошла"

	local out="$WIN_SRC_DIR/flutter/build/windows/x64/runner/Release"
	[ -d "$out" ] || die "сборка отработала, но каталога $out нет"
	log "Готово"
	echo "    Из WSL:     $out"
	echo "    Из Windows: ${WIN_SRC_DIR_NATIVE}\\flutter\\build\\windows\\x64\\runner\\Release\\rustdesk.exe"
}

# ── Android ──────────────────────────────────────────────────────────────────
# Единственная цель, которой не нужен ни sudo, ни Windows: SDK, NDK, Rust и
# Flutter ставятся в домашний каталог.

android_deps() {
	require_host_cc
	install_jdk17
	install_rust
	rustup target add aarch64-linux-android
	install_flutter "$ANDROID_FLUTTER_VERSION" "$FLUTTER_ROOT"

	log "Android SDK и NDK $NDK_VERSION"
	local tools_dir="$ANDROID_SDK_ROOT/cmdline-tools"
	if [ ! -d "$tools_dir/latest" ]; then
		mkdir -p "$tools_dir"
		local zip="$CACHE_DIR/cmdline-tools.zip"
		curl -fsSL -o "$zip" https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
		unzip -q -o "$zip" -d "$tools_dir"
		mv "$tools_dir/cmdline-tools" "$tools_dir/latest"
		rm -f "$zip"
	fi

	local sdkmanager="$tools_dir/latest/bin/sdkmanager"
	# В workflow версия вида r28c, а sdkmanager знает только числовые. Берём
	# старшую в том же мажоре, чтобы не хардкодить соответствие r28c → 28.x.y:
	# оно поедет при следующем обновлении CI
	local ndk_major="${NDK_VERSION#r}"
	ndk_major="${ndk_major%%[a-z]*}"
	local ndk_pkg
	ndk_pkg="$("$sdkmanager" --list 2>/dev/null | grep -oE "ndk;${ndk_major}\.[0-9.]+" | sort -V | tail -1)" || true
	[ -n "$ndk_pkg" ] || die "в sdkmanager нет ветки NDK ${ndk_major}.x, ожидалась по $NDK_VERSION из workflow"

	yes | "$sdkmanager" --licenses >/dev/null 2>&1 || true
	"$sdkmanager" --install "platform-tools" "platforms;android-35" "build-tools;35.0.0" "$ndk_pkg"

	log "cargo-ndk $CARGO_NDK_VERSION"
	cargo install cargo-ndk --version "$CARGO_NDK_VERSION" --locked

	# hwcodec линкуется с ffmpeg из vcpkg и под Android тоже: без этого его
	# build.rs падает на `VCPKG_ROOT` со скупым `NotPresent`. Триплет собирает
	# тот же скрипт, что и на CI, а не своя копия команды vcpkg
	install_vcpkg
	log "Зависимости vcpkg под Android (arm64-android, первый раз это долго)"
	ANDROID_NDK_HOME="$(android_ndk_dir)" ANDROID_NDK_ROOT="$(android_ndk_dir)" \
		./flutter/build_android_deps.sh arm64-v8a

	log "Зависимости Android установлены"
}

build_android() {
	apply_branding
	restore_bridge
	require_host_cc
	command -v cargo-ndk >/dev/null 2>&1 || die "нет cargo-ndk, сначала --deps"
	[ -d "$VCPKG_ROOT/installed/arm64-android" ] || die "нет зависимостей vcpkg под arm64-android, сначала --deps"

	local ndk
	ndk="$(android_ndk_dir)"
	export ANDROID_NDK_HOME="$ndk"
	export ANDROID_NDK_ROOT="$ndk"

	# bindgen внутри hwcodec зовёт libclang с андроидным таргетом, но набор
	# инклюдов берёт хостовый. На ubuntu-22.04 с clang 14 это сходило с рук, на
	# clang 18 он читает /usr/include/stdint.h и не находит multiarch-заголовок
	# bits/libc-header-start.h. Явный sysroot из NDK убирает неоднозначность и
	# не мешает более старым clang
	export BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$ndk/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

	log "Ядро Rust под aarch64 (ndk_arm64.sh, как на CI)"
	./flutter/ndk_arm64.sh

	local jni="flutter/android/app/src/main/jniLibs/arm64-v8a"
	mkdir -p "$jni"
	cp "./target/aarch64-linux-android/release/liblibrustdesk.so" "$jni/librustdesk.so"
	cp "$ndk/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$jni/"

	# Релизного ключа здесь нет и быть не должно, поэтому apk подписывается
	# отладочным. Тот же приём, что на CI
	sed -i "s/signingConfigs.release/signingConfigs.debug/g" ./flutter/android/app/build.gradle
	# Тот же подъём памяти Gradle, что на CI: 1 ГБ по умолчанию не хватает
	sed -i "s/org.gradle.jvmargs=-Xmx1024M/org.gradle.jvmargs=-Xmx2g/g" ./flutter/android/gradle.properties

	log "APK (Java 17)"
	[ -x "$JDK_DIR/bin/java" ] || die "нет JDK 17, сначала --deps"
	(cd flutter && JAVA_HOME="$JDK_DIR" PATH="$JDK_DIR/bin:$PATH" \
		flutter build apk --release --target-platform android-arm64 --split-per-abi)
	git checkout -- ./flutter/android/app/build.gradle ./flutter/android/gradle.properties

	local apk="flutter/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
	[ -f "$apk" ] || die "Flutter не отдал apk в $apk"

	# Из WSL файл на телефон не перекинуть, поэтому копия кладётся в Загрузки
	# Windows, откуда его видно проводником
	local user drop
	user="$(powershell.exe -NoProfile -Command 'Write-Output $env:USERNAME' 2>/dev/null | tr -d '\r\n')"
	drop="/mnt/c/Users/$user/Downloads"
	if [ -n "$user" ] && [ -d "$drop" ]; then
		cp "$apk" "$drop/armilen-remote-arm64.apk"
		log "Готово: $drop/armilen-remote-arm64.apk"
		echo "    В проводнике это Загрузки, оттуда закидывайте на телефон"
	else
		log "Готово: $REPO_ROOT/$apk"
	fi
}

# ── Linux ────────────────────────────────────────────────────────────────────

linux_deps() {
	require_sudo
	log "Системные пакеты"
	sudo apt-get update -y
	sudo apt-get install -y \
		build-essential clang cmake curl gcc git g++ \
		libayatana-appindicator3-dev libasound2-dev libclang-dev \
		libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libgtk-3-dev \
		libpam0g-dev libpulse-dev libva-dev \
		libxcb-randr0-dev libxcb-shape0-dev libxcb-xfixes0-dev \
		libxdo-dev libxfixes-dev nasm ninja-build pkg-config \
		python3 python3-yaml rpm rsync unzip wget xz-utils libssl-dev zip
	# libopus берётся из vcpkg, системный конфликтует при линковке
	sudo apt-get remove -y libopus-dev || true

	install_rust
	rustup target add x86_64-unknown-linux-gnu --toolchain "$RUST_VERSION"
	install_flutter "$FLUTTER_VERSION" "$FLUTTER_ROOT"
	flutter config --enable-linux-desktop
	flutter precache --linux

	install_vcpkg

	log "Зависимости Linux установлены"
}

build_linux() {
	apply_branding
	restore_bridge

	[ -x "$VCPKG_ROOT/vcpkg" ] || die "vcpkg не собран, сначала --deps"
	log "Зависимости vcpkg (x64-linux)"
	"$VCPKG_ROOT/vcpkg" install --triplet x64-linux --x-install-root="$VCPKG_ROOT/installed"

	log "Ядро Rust"
	cargo +"$RUST_VERSION" build --lib --features hwcodec,flutter,unix-file-copy-paste --release

	if [ "$FULL" -eq 0 ]; then
		log "Ядро собралось, правка компилируется"
		echo "    Полное приложение: ./scripts/build-local.sh --target linux --full"
		return
	fi

	log "Приложение Flutter"
	(cd flutter && flutter build linux --release)
	log "Готово: $REPO_ROOT/flutter/build/linux/x64/release/bundle"
}

# ── Диспетчер ────────────────────────────────────────────────────────────────

if [ "$DEPS" -eq 1 ]; then
	case "$TARGET" in
	windows) windows_deps ;;
	android) android_deps ;;
	linux) linux_deps ;;
	esac
	exit 0
fi

case "$TARGET" in
windows) build_windows ;;
android) build_android ;;
linux) build_linux ;;
esac
