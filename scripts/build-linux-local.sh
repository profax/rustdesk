#!/usr/bin/env bash
#
# Локальная сборка Armilen Remote под Linux: проверить правку до пуша, не
# дожидаясь часа GitHub Actions.
#
# Выигрыш не в том, что машина быстрее раннера (она медленнее), а в том, что
# она не начинает с нуля. Раннер каждый раз заново ставит Rust, собирает
# ffmpeg через vcpkg и качает Flutter: это и есть тот час. Здесь всё это
# лежит в $CACHE_DIR и переживает запуск, поэтому вторая и все следующие
# сборки укладываются в минуты.
#
#   ./scripts/build-linux-local.sh --deps     # один раз на машину: зависимости
#   ./scripts/build-linux-local.sh            # smoke: компилируется ли Rust
#   ./scripts/build-linux-local.sh --full     # + Flutter, готовое приложение
#
# Версии Rust, Flutter и коммит vcpkg читаются из .github/workflows/flutter-build.yml.
# Захардкодить их здесь значило бы получить локальную сборку, которая зелёная
# на других версиях, чем CI: такая проверка хуже, чем никакой.
#
# Брендинг правит рабочее дерево, включая сабмодули, ровно как на CI. Это
# ожидаемо и коммитить эти правки не нужно: откат обычным
# `git checkout -- libs/hbb_common src/lang`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

WORKFLOW=".github/workflows/flutter-build.yml"
CACHE_DIR="${ARMILEN_BUILD_CACHE:-$HOME/.cache/armilen-remote-build}"
TARGET="x86_64-unknown-linux-gnu"
VCPKG_TRIPLET="x64-linux"
CARGO_FEATURES="hwcodec,flutter,unix-file-copy-paste"

MODE="smoke"
case "${1:-}" in
	--deps) MODE="deps" ;;
	--full) MODE="full" ;;
	--smoke | "") MODE="smoke" ;;
	-h | --help)
		# Шапка файла и есть справка: печатаем комментарий до первой строки кода
		awk 'NR>2 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"
		exit 0
		;;
	*)
		echo "Неизвестный аргумент: $1. Смотрите --help" >&2
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
	local key="$1" value
	value="$(grep -m1 -E "^  ${key}: " "$WORKFLOW" | sed -E 's/^[^:]+: *"?([^"#]*[^"# ])"? *(#.*)?$/\1/')"
	[ -n "$value" ] || die "в $WORKFLOW не найден ключ $key"
	printf '%s' "$value"
}

RUST_VERSION="$(workflow_env RUST_VERSION)"
FLUTTER_VERSION="$(workflow_env FLUTTER_VERSION)"
VCPKG_COMMIT_ID="$(workflow_env VCPKG_COMMIT_ID)"
FLUTTER_RUST_BRIDGE_VERSION="$(grep -m1 -E "^  FLUTTER_RUST_BRIDGE_VERSION: " .github/workflows/bridge.yml | sed -E 's/^[^:]+: *"?([^"#]*[^"# ])"? *(#.*)?$/\1/')"

export VCPKG_ROOT="$CACHE_DIR/vcpkg"
export FLUTTER_ROOT="$CACHE_DIR/flutter"
export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
export PATH="$FLUTTER_ROOT/bin:$CARGO_HOME/bin:$PATH"

log "Armilen Remote, локальная сборка Linux (режим: $MODE)"
echo "    Rust      $RUST_VERSION"
echo "    Flutter   $FLUTTER_VERSION"
echo "    vcpkg     ${VCPKG_COMMIT_ID:0:12}"
echo "    Кеш       $CACHE_DIR"

# ── Зависимости ──────────────────────────────────────────────────────────────
# Тот же список, что ставит job build-rustdesk-linux. Шаг отдельный и ручной:
# он требует sudo и на готовой машине не нужен.
install_deps() {
	log "Системные пакеты (нужен sudo)"
	sudo apt-get update -y
	sudo apt-get install -y \
		build-essential clang cmake curl gcc git g++ \
		libayatana-appindicator3-dev libasound2-dev libclang-dev \
		libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libgtk-3-dev \
		libpam0g-dev libpulse-dev libva-dev \
		libxcb-randr0-dev libxcb-shape0-dev libxcb-xfixes0-dev \
		libxdo-dev libxfixes-dev nasm ninja-build pkg-config \
		python3 python3-yaml rpm unzip wget xz-utils libssl-dev zip
	# libopus берётся из vcpkg, системный конфликтует при линковке
	sudo apt-get remove -y libopus-dev || true

	log "Rust $RUST_VERSION"
	if ! command -v rustup >/dev/null 2>&1; then
		curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain "$RUST_VERSION"
	fi
	rustup toolchain install "$RUST_VERSION" --component rustfmt
	rustup target add "$TARGET" --toolchain "$RUST_VERSION"

	mkdir -p "$CACHE_DIR"

	log "vcpkg ${VCPKG_COMMIT_ID:0:12}"
	if [ ! -d "$VCPKG_ROOT/.git" ]; then
		git clone https://github.com/microsoft/vcpkg "$VCPKG_ROOT"
	fi
	git -C "$VCPKG_ROOT" fetch --depth 1 origin "$VCPKG_COMMIT_ID"
	git -C "$VCPKG_ROOT" checkout -q "$VCPKG_COMMIT_ID"
	[ -x "$VCPKG_ROOT/vcpkg" ] || "$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics

	log "Flutter $FLUTTER_VERSION"
	if [ ! -d "$FLUTTER_ROOT" ]; then
		git clone https://github.com/flutter/flutter.git --depth 1 -b "$FLUTTER_VERSION" "$FLUTTER_ROOT"
	fi
	git config --global --add safe.directory "$FLUTTER_ROOT" || true
	flutter config --enable-linux-desktop --no-analytics
	flutter precache --linux

	log "Кодогенератор моста flutter_rust_bridge $FLUTTER_RUST_BRIDGE_VERSION"
	cargo install flutter_rust_bridge_codegen --version "$FLUTTER_RUST_BRIDGE_VERSION" --features uuid --locked

	log "Зависимости установлены. Дальше: ./scripts/build-linux-local.sh"
}

# ── Брендинг ─────────────────────────────────────────────────────────────────
# Правки лежат в composite action, потому что часть из них меняет файлы
# сабмодулей. Здесь они прогоняются тем же способом, что и на CI: шаги action
# читаются из yml и исполняются как есть, а не переписываются второй раз рядом.
# Расхождение локального брендинга с CI означало бы, что проверять на VPS
# бессмысленно, а именно ради этой проверки скрипт и написан.
apply_branding() {
	log "Брендинг Armilen"
	python3 -c 'import yaml' 2>/dev/null || die "нужен PyYAML: sudo apt-get install -y python3-yaml"

	# Шаги отдаются как «имя\0тело\0»: тела многострочные, и по переводу
	# строки их не разделить
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

# ── Мост Rust ↔ Dart ─────────────────────────────────────────────────────────
# На CI это отдельный job generate-bridge, отдающий артефакт. Локально
# генерируем сами и только когда исходник моста новее сгенерированного.
generate_bridge() {
	local generated="flutter/lib/generated_bridge.dart"
	if [ -f "$generated" ] && [ "$generated" -nt "src/flutter_ffi.rs" ]; then
		log "Мост актуален, пропускаем"
		return
	fi
	log "Генерация моста"
	flutter_rust_bridge_codegen \
		--rust-input ./src/flutter_ffi.rs \
		--dart-output ./flutter/lib/generated_bridge.dart \
		--c-output ./flutter/macos/Runner/bridge_generated.h
}

build_vcpkg_deps() {
	log "Зависимости vcpkg ($VCPKG_TRIPLET)"
	[ -x "$VCPKG_ROOT/vcpkg" ] || die "vcpkg не собран, сначала запустите --deps"
	"$VCPKG_ROOT/vcpkg" install --triplet "$VCPKG_TRIPLET" --x-install-root="$VCPKG_ROOT/installed"
}

build_rust() {
	log "Сборка ядра Rust (features: $CARGO_FEATURES)"
	cargo +"$RUST_VERSION" build --lib --features "$CARGO_FEATURES" --release
}

build_flutter() {
	log "Сборка приложения Flutter"
	(cd flutter && flutter build linux --release)

	local app="flutter/build/linux/x64/release/bundle"
	[ -d "$app" ] || die "Flutter не отдал бандл в $app"
	log "Готово: $app"
	echo
	echo "  Запустить:  $REPO_ROOT/$app/rustdesk"
	echo "  Без экрана: xvfb-run -a $REPO_ROOT/$app/rustdesk --version"
}

case "$MODE" in
deps)
	install_deps
	;;
smoke)
	apply_branding
	build_vcpkg_deps
	build_rust
	log "Ядро собралось. Правка компилируется, можно пушить"
	echo "    Полное приложение: ./scripts/build-linux-local.sh --full"
	;;
full)
	apply_branding
	generate_bridge
	build_vcpkg_deps
	build_rust
	build_flutter
	;;
esac
