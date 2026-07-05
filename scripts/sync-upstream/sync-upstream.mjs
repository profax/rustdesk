// Upstream sync for the Armilen Remote fork.
//
// Watches rustdesk/rustdesk for new *stable* release tags (plain semver, e.g.
// 1.4.8 — nightly/pre-release tags are ignored) and, when one appears, merges
// it onto our branding commits on a throwaway branch, opens a PR against our
// base branch and triggers the flutter-build workflow on that branch.
//
// Deliberately NOT auto-merging to the base branch or deploying: a remote-access
// client is security-sensitive, so a human reviews the PR + a green build before
// anything ships. The submodule branding (config.rs APP_NAME) is reapplied by
// the apply-branding CI action, so nothing branding-related is lost in the merge.
//
// Runs from a systemd timer (see scripts/sync-upstream/systemd/). All progress
// goes to stdout/journald; failures exit non-zero so `OnFailure=` can alert.
// Telegram alerts are best-effort if TG_BOT_TOKEN/TG_CHAT_ID are set.
//
// Config (env):
//   REPO_DIR        fork clone to operate on            (default: cwd)
//   UPSTREAM_REMOTE name of the upstream remote         (default: upstream)
//   FORK_REMOTE     name of our fork remote             (default: origin)
//   BASE_BRANCH     branch our branding lives on        (default: master)
//   GH_WORKFLOW     workflow file to dispatch           (default: flutter-build.yml)
//   TRIGGER_BUILD   dispatch the build workflow         (default: true)
//   TG_BOT_TOKEN, TG_CHAT_ID, HTTPS_PROXY   optional Telegram alert
// CLI: --force  process the latest stable tag even if already recorded.
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import path from "node:path";

const UPSTREAM_URL = "https://github.com/rustdesk/rustdesk.git";
const REPO_DIR = path.resolve(process.env.REPO_DIR || process.cwd());
const UPSTREAM_REMOTE = process.env.UPSTREAM_REMOTE || "upstream";
const FORK_REMOTE = process.env.FORK_REMOTE || "origin";
const BASE_BRANCH = process.env.BASE_BRANCH || "master";
const GH_WORKFLOW = process.env.GH_WORKFLOW || "flutter-build.yml";
const TRIGGER_BUILD = (process.env.TRIGGER_BUILD || "true") !== "false";
// DRY_RUN performs the merge locally to check it applies cleanly, then rolls the
// branch back without pushing, opening a PR, dispatching a build or touching state.
const DRY_RUN = (process.env.DRY_RUN || "false") === "true";
const STATE_FILE = path.join(REPO_DIR, ".git", "upstream-sync-state.json");
const FORCE = process.argv.includes("--force");

const log = (m) => console.log(`[sync-upstream] ${m}`);

// execFileSync wrapper: git/gh in REPO_DIR. `run` throws on non-zero (fatal
// steps); `tryRun` never throws (probing / cleanup).
function run(file, args, opts = {}) {
	return execFileSync(file, args, {
		cwd: REPO_DIR,
		encoding: "utf8",
		stdio: ["ignore", "pipe", "pipe"],
		...opts,
	}).trim();
}
function tryRun(file, args, opts = {}) {
	try {
		return { ok: true, out: run(file, args, opts) };
	} catch (err) {
		return { ok: false, out: (err.stdout || "").toString().trim(), err: (err.stderr || err.message || "").toString().trim() };
	}
}

const git = (...args) => run("git", args);
const tryGit = (...args) => tryRun("git", args);
const hasGh = () => tryRun("gh", ["--version"]).ok;

const semver = (t) => t.split(".").map(Number);
function newerStable(a, b) {
	const [a1, a2, a3] = semver(a);
	const [b1, b2, b3] = semver(b);
	return a1 - b1 || a2 - b2 || a3 - b3;
}

function readState() {
	if (!existsSync(STATE_FILE)) return {};
	try {
		return JSON.parse(readFileSync(STATE_FILE, "utf8"));
	} catch {
		return {};
	}
}
function writeState(state) {
	writeFileSync(STATE_FILE, JSON.stringify(state, null, "\t") + "\n");
}

// Best-effort Telegram alert. Uses undici ProxyAgent only if HTTPS_PROXY is set
// and undici resolves (the VPS reaches Telegram through a local Xray proxy);
// otherwise a direct fetch. Never throws.
async function notify(text) {
	const token = (process.env.TG_BOT_TOKEN || "").trim();
	const chatId = (process.env.TG_CHAT_ID || "").trim();
	if (!token || !chatId) return;
	try {
		const proxy = (process.env.HTTPS_PROXY || "").trim();
		let dispatcher;
		if (proxy) {
			try {
				const { ProxyAgent } = await import("undici");
				dispatcher = new ProxyAgent(proxy);
			} catch {
				// undici not installed: fall back to a direct connection
			}
		}
		await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ chat_id: chatId, text, disable_web_page_preview: true }),
			signal: AbortSignal.timeout(15_000),
			...(dispatcher ? { dispatcher } : {}),
		});
	} catch (err) {
		log(`telegram notify failed (non-fatal): ${err.message}`);
	}
}

function ensureUpstreamRemote() {
	const remotes = git("remote").split("\n");
	if (!remotes.includes(UPSTREAM_REMOTE)) {
		git("remote", "add", UPSTREAM_REMOTE, UPSTREAM_URL);
		log(`added remote ${UPSTREAM_REMOTE} -> ${UPSTREAM_URL}`);
	}
}

// Highest plain-semver tag on upstream (ignores nightly / -rc / suffixed tags).
function latestUpstreamStable() {
	const raw = git("ls-remote", "--tags", "--refs", UPSTREAM_REMOTE);
	const tags = raw
		.split("\n")
		.map((l) => l.split("/").pop())
		.filter((t) => /^\d+\.\d+\.\d+$/.test(t));
	if (!tags.length) throw new Error("no stable semver tags found upstream");
	return tags.sort(newerStable).pop();
}

async function main() {
	if (!existsSync(path.join(REPO_DIR, ".git"))) {
		throw new Error(`${REPO_DIR} is not a git repository (set REPO_DIR)`);
	}
	ensureUpstreamRemote();
	log(`fetching ${UPSTREAM_REMOTE} tags…`);
	// --no-recurse-submodules: we only need the top-level tags/refs; recursing
	// makes git try (and fail) to fetch libs/hbb_common from a ref the fork's
	// submodule remote doesn't serve, and its non-zero exit would abort us.
	git("fetch", UPSTREAM_REMOTE, "--tags", "--prune", "--force", "--no-recurse-submodules");
	tryGit("fetch", FORK_REMOTE, "--prune", "--no-recurse-submodules");

	const latest = latestUpstreamStable();
	const state = readState();
	log(`latest upstream stable: ${latest} | last recorded: ${state.lastTag ?? "(none)"}`);

	// First ever run: record a baseline, don't surprise-merge history.
	if (!state.lastTag && !FORCE) {
		writeState({ lastTag: latest, baselineAt: new Date().toISOString() });
		log(`baseline recorded at ${latest}; future newer tags will trigger a sync`);
		return;
	}
	if (state.lastTag === latest && !FORCE) {
		log("already up to date, nothing to do");
		return;
	}

	// A dirty top-level tree would make the merge ambiguous: bail early and
	// loudly. --ignore-submodules=dirty: an uncommitted edit *inside* a
	// submodule (e.g. a local APP_NAME tweak) is irrelevant here — CI reapplies
	// branding — but a changed submodule *pointer* still shows and still blocks.
	if (git("status", "--porcelain", "--ignore-submodules=dirty")) {
		throw new Error("working tree is dirty; refusing to sync");
	}

	const branch = `sync/upstream-${latest}`;
	log(`preparing ${branch} from ${BASE_BRANCH}`);
	git("checkout", BASE_BRANCH);
	// Keep base in step with our fork if it can fast-forward; ignore divergence.
	tryGit("merge", "--ff-only", `${FORK_REMOTE}/${BASE_BRANCH}`);
	if (tryGit("rev-parse", "--verify", branch).ok) git("branch", "-D", branch);
	git("checkout", "-b", branch);

	const merge = tryGit("merge", "--no-edit", latest);
	if (!merge.ok) {
		const conflicts = tryGit("diff", "--name-only", "--diff-filter=U").out;
		tryGit("merge", "--abort");
		git("checkout", BASE_BRANCH);
		tryGit("branch", "-D", branch);
		// Record the conflicting tag so we don't re-alert every timer tick, but
		// leave lastTag untouched so a resolved sync is still recognised as new.
		writeState({ ...state, conflictTag: latest, conflictAt: new Date().toISOString() });
		const msg = `⚠️ Armilen Remote: конфликт при слиянии upstream ${latest}. Требуется ручное разрешение.\nФайлы:\n${conflicts || "(unknown)"}`;
		log(msg);
		await notify(msg);
		process.exitCode = 1;
		return;
	}

	if (DRY_RUN) {
		log(`DRY_RUN: ${latest} merges cleanly onto ${BASE_BRANCH}; rolling back ${branch}`);
		git("checkout", BASE_BRANCH);
		tryGit("branch", "-D", branch);
		return;
	}

	log("clean merge; pushing sync branch");
	// --force-with-lease is safe: the branch is disposable and namespaced per tag.
	git("push", "--force-with-lease", FORK_REMOTE, branch);

	if (hasGh()) {
		const pr = tryRun("gh", [
			"pr", "create",
			"--base", BASE_BRANCH,
			"--head", branch,
			"--title", `Sync upstream RustDesk ${latest}`,
			"--body",
			`Automated merge of upstream tag \`${latest}\` onto the Armilen branding.\n\n` +
				`- Branding of submodule code (config.rs APP_NAME) is reapplied by the apply-branding CI action.\n` +
				`- Review the diff and the triggered build before merging to \`${BASE_BRANCH}\`.`,
		]);
		log(pr.ok ? `PR opened: ${pr.out}` : `gh pr create: ${pr.err || pr.out} (may already exist)`);
	} else {
		log("gh CLI not found: open a PR manually for the sync branch");
	}

	if (TRIGGER_BUILD && hasGh()) {
		const wf = tryRun("gh", [
			"workflow", "run", GH_WORKFLOW,
			"--ref", branch,
			"-f", "upload-artifact=true",
			"-f", "upload-tag=nightly",
		]);
		log(wf.ok ? `build dispatched on ${branch}` : `workflow dispatch failed: ${wf.err || wf.out}`);
	} else if (TRIGGER_BUILD) {
		log(`gh CLI not found: dispatch ${GH_WORKFLOW} on ${branch} manually`);
	}

	git("checkout", BASE_BRANCH);
	writeState({ lastTag: latest, syncedAt: new Date().toISOString(), branch });
	const done = `✅ Armilen Remote: upstream ${latest} слит в ветку ${branch}, PR открыт, сборка запущена. Проверьте PR перед мержем в ${BASE_BRANCH}.`;
	log(done);
	await notify(done);
}

main().catch(async (err) => {
	log(`FATAL: ${err.message}`);
	await notify(`❌ Armilen Remote upstream-sync упал: ${err.message}`);
	process.exit(1);
});
