#!/usr/bin/env bash
# Склеивает два собранных .app (x86_64 и arm64) в один универсальный.
#
# Зачем: Mac с 2020 года все на Apple Silicon, а x86_64-сборка идёт на них
# через Rosetta 2, которую система предлагает доустановить при первом запуске.
# Для инструмента поддержки лишний диалог возникает ровно в тот момент, когда у
# человека уже что-то сломалось. Универсальный бинарник снимает и его, и вопрос
# «а какую версию качать» на странице загрузки.
#
# Как: у универсального бандла общие ресурсы и Info.plist, разной бывает только
# машинная часть. Поэтому берём arm64-бандл за основу (у него новее
# MACOSX_DEPLOYMENT_TARGET и включён ScreenCaptureKit), обходим его целиком и
# каждый Mach-O файл заменяем результатом lipo с одноимённым файлом из
# x86_64-бандла.
#
# Использование:
#   scripts/macos-universal.sh <x86_64.app> <arm64.app> <выходной .app>

set -euo pipefail

if [ $# -ne 3 ]; then
	echo "usage: $0 <x86_64.app> <arm64.app> <output.app>" >&2
	exit 2
fi

x64_app=$1
arm_app=$2
out_app=$3

for app in "$x64_app" "$arm_app"; do
	[ -d "$app" ] || { echo "not a bundle: $app" >&2; exit 1; }
done

rm -rf "$out_app"
# -R сохраняет симлинки внутри фреймворков (Versions/Current -> A), без них
# бандл перестаёт грузиться.
cp -R "$arm_app" "$out_app"

merged=0
arm_only=0

# -type f пропускает симлинки, их и не надо трогать: они уже скопированы как
# симлинки и указывают на файлы, которые мы заменяем на месте.
while IFS= read -r rel; do
	out_file="$out_app/$rel"
	x64_file="$x64_app/$rel"

	file -b "$out_file" | grep -q 'Mach-O' || continue

	if [ ! -f "$x64_file" ]; then
		# Бинарник есть только в arm64-сборке. Оставляем как есть: бандл
		# запустится на Apple Silicon и не запустится на Intel, что лучше
		# молчаливой поломки обоих.
		echo "  only in arm64, left as is: $rel"
		arm_only=$((arm_only + 1))
		continue
	fi

	lipo -create "$x64_file" "$out_file" -output "$out_file.universal"
	mv -f "$out_file.universal" "$out_file"
	merged=$((merged + 1))
done < <(cd "$arm_app" && find . -type f | sed 's|^\./||')

echo "склеено бинарников: $merged, только arm64: $arm_only"
[ "$merged" -gt 0 ] || { echo "ни одного Mach-O не склеено, что-то не так со структурой бандла" >&2; exit 1; }

# lipo стирает подпись, а arm64-macOS отказывается запускать неподписанный код
# вообще: без ad-hoc подписи универсальный бандл упадёт именно на тех машинах,
# ради которых он собран. Подписываем изнутри наружу, --deep для ad-hoc
# устарел и на вложенных фреймворках срабатывает не всегда.
while IFS= read -r rel; do
	f="$out_app/$rel"
	file -b "$f" | grep -q 'Mach-O' && codesign --force --sign - "$f" >/dev/null 2>&1 || true
done < <(cd "$out_app" && find . -type f | sed 's|^\./||')
codesign --force --sign - "$out_app"

# Проверка того, ради чего всё делалось.
main_bin="$out_app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$out_app/Contents/Info.plist")"
archs=$(lipo -archs "$main_bin")
echo "архитектуры $main_bin: $archs"
for want in x86_64 arm64; do
	case " $archs " in
		*" $want "*) ;;
		*) echo "в основном бинарнике нет среза $want" >&2; exit 1 ;;
	esac
done
codesign --verify --deep --strict "$out_app"
echo "готов универсальный бандл: $out_app"
