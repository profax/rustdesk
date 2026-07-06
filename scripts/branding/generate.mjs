// Armilen Remote brand-asset generator.
//
// Rasterizes the brand SVGs in scripts/branding/src/ into every icon target the
// desktop/mobile builds consume: Windows .ico, macOS .icns, Android mipmaps
// (legacy + round + adaptive foreground + status-bar), Flutter in-app logos and
// the Linux res/*.png set. Idempotent: rerun after editing any src SVG.
//
// Needs `sharp`. The fork has no node_modules, so run it resolving sharp from
// the main site checkout, e.g.:
//   NODE_PATH=/home/profax/armilen-site/node_modules \
//     node scripts/branding/generate.mjs
import { readFile, writeFile, mkdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

// The fork has no node_modules of its own; sharp is resolved from a checkout
// passed via SHARP_FROM (defaults to the sibling armilen-site). ESM ignores
// NODE_PATH, so we bridge through createRequire.
const require = createRequire(import.meta.url);
const sharpFrom =
	process.env.SHARP_FROM ||
	path.resolve(fileURLToPath(import.meta.url), "..", "..", "..", "..", "armilen-site", "node_modules");
const sharp = require(path.join(sharpFrom, "sharp"));

const ROOT = path.resolve(fileURLToPath(import.meta.url), "..", "..", "..");
const SRC = path.join(ROOT, "scripts", "branding", "src");

const svg = (name) => readFile(path.join(SRC, `${name}.svg`));
const out = (...p) => path.join(ROOT, ...p);

// Rasterize an SVG source to a square PNG buffer at the given pixel size.
async function png(name, size) {
	return sharp(await svg(name)).resize(size, size).png().toBuffer();
}

async function writePng(name, size, dest) {
	await mkdir(path.dirname(dest), { recursive: true });
	await writeFile(dest, await png(name, size));
	console.log(`${name}.svg -> ${path.relative(ROOT, dest)} (${size}px)`);
}

// --- Windows .ico: header + directory + concatenated PNG frames ---
function buildIco(frames) {
	const header = Buffer.alloc(6);
	header.writeUInt16LE(0, 0); // reserved
	header.writeUInt16LE(1, 2); // type: icon
	header.writeUInt16LE(frames.length, 4);
	let offset = 6 + 16 * frames.length;
	const entries = [];
	for (const { size, buf } of frames) {
		const e = Buffer.alloc(16);
		e.writeUInt8(size >= 256 ? 0 : size, 0); // 0 means 256
		e.writeUInt8(size >= 256 ? 0 : size, 1);
		e.writeUInt16LE(1, 4); // color planes
		e.writeUInt16LE(32, 6); // bits per pixel
		e.writeUInt32LE(buf.length, 8);
		e.writeUInt32LE(offset, 12);
		entries.push(e);
		offset += buf.length;
	}
	return Buffer.concat([header, ...entries, ...frames.map((f) => f.buf)]);
}

async function writeIco(name, sizes, dest) {
	const frames = [];
	for (const size of sizes) frames.push({ size, buf: await png(name, size) });
	await mkdir(path.dirname(dest), { recursive: true });
	await writeFile(dest, buildIco(frames));
	console.log(`${name}.svg -> ${path.relative(ROOT, dest)} (ico ${sizes.join("/")})`);
}

// --- macOS .icns: 'icns' magic + total length, then typed PNG chunks.
// Each OSType maps to a pixel size; modern macOS accepts PNG payloads. ---
const ICNS_TYPES = [
	["ic10", 1024],
	["ic09", 512],
	["ic08", 256],
	["ic07", 128],
	["ic12", 64],
	["ic11", 32],
];

async function writeIcns(name, dest) {
	const chunks = [];
	for (const [type, size] of ICNS_TYPES) {
		const data = await png(name, size);
		const head = Buffer.alloc(8);
		head.write(type, 0, "ascii");
		head.writeUInt32BE(data.length + 8, 4); // length includes the 8-byte header
		chunks.push(head, data);
	}
	const body = Buffer.concat(chunks);
	const file = Buffer.alloc(8);
	file.write("icns", 0, "ascii");
	file.writeUInt32BE(body.length + 8, 4);
	await mkdir(path.dirname(dest), { recursive: true });
	await writeFile(dest, Buffer.concat([file, body]));
	console.log(`${name}.svg -> ${path.relative(ROOT, dest)} (icns 32..1024)`);
}

// Android density buckets: [dir suffix, scale]. Baseline px is multiplied.
const DENSITIES = [
	["mdpi", 1],
	["hdpi", 1.5],
	["xhdpi", 2],
	["xxhdpi", 3],
	["xxxhdpi", 4],
];
const androidRes = (dir, file) =>
	out("flutter", "android", "app", "src", "main", "res", dir, file);

async function androidSet(name, baseline, file) {
	for (const [suffix, scale] of DENSITIES) {
		await writePng(name, Math.round(baseline * scale), androidRes(`mipmap-${suffix}`, file));
	}
}

async function main() {
	// --- Windows ---
	await writeIco("tile-dark", [16, 32, 48, 64, 128, 256],
		out("flutter", "windows", "runner", "resources", "app_icon.ico"));
	// res/icon.ico: embedded by build.rs (winres) as the Windows resource icon
	// of the core Rust exe itself (Explorer/taskbar/installer icon before the
	// app ever runs) - separate from app_icon.ico above, which only brands the
	// Flutter Windows *runner* shown once the app is actually running. Missing
	// this one is why the installer/downloaded .exe kept showing the upstream
	// RustDesk icon even though the running app was already correctly branded.
	await writeIco("tile-dark", [16, 32, 48, 64, 128, 256], out("res", "icon.ico"));

	// --- macOS (project references AppIcon.icns, not an .appiconset) ---
	await writeIcns("tile-macos", out("flutter", "macos", "Runner", "AppIcon.icns"));

	// --- Android mipmaps ---
	await androidSet("tile-dark", 48, "ic_launcher.png"); // legacy square
	await androidSet("tile-round", 48, "ic_launcher_round.png"); // round mask
	await androidSet("foreground", 108, "ic_launcher_foreground.png"); // adaptive fg + monochrome
	await androidSet("glyph-mono", 24, "ic_stat_logo.png"); // status-bar notification

	// --- Flutter in-app assets (bundled via `- assets/` in pubspec) ---
	await writePng("logo-light", 240, out("flutter", "assets", "logo_light.png"));
	await writePng("logo-dark", 240, out("flutter", "assets", "logo_dark.png"));
	await writePng("logo-dark", 240, out("flutter", "assets", "logo.png")); // default fallback
	await writePng("tile-dark", 512, out("flutter", "assets", "icon.png"));
	await writeFile(out("flutter", "assets", "icon.svg"), await svg("tile-dark"));
	console.log("tile-dark.svg -> flutter/assets/icon.svg");

	// --- Linux packaging icons (res/*) ---
	await writePng("tile-dark", 32, out("res", "32x32.png"));
	await writePng("tile-dark", 64, out("res", "64x64.png"));
	await writePng("tile-dark", 128, out("res", "128x128.png"));
	await writePng("tile-dark", 256, out("res", "128x128@2x.png"));
	await writePng("tile-dark", 1024, out("res", "icon.png"));
	await writePng("tile-macos", 1024, out("res", "mac-icon.png"));
	await writePng("glyph-mono", 48, out("res", "mac-tray-light-x2.png"));
	await writePng("glyph-mono", 60, out("res", "mac-tray-dark-x2.png"));
	await writeIco("tile-dark", [16, 32, 48, 64, 128, 256], out("res", "tray-icon.ico"));
	await writeFile(out("res", "logo.svg"), await svg("tile-dark"));
	await writeFile(out("res", "logo-header.svg"), await svg("logo-dark"));
	console.log("tile-dark.svg -> res/logo.svg ; logo-dark.svg -> res/logo-header.svg");
}

main().catch((err) => {
	console.error(err);
	process.exit(1);
});
