#!/usr/bin/env bash
# shellcheck disable=SC2034 # variables read only inside check strings look unused
# End-to-end tests for the asdf-tsc-rs plugin and its optional tsc redirect.
# Runs in an isolated ASDF_DATA_DIR, HOME and XDG_DATA_HOME under a scratch
# work directory, so it never touches your profiles or settings. Needs node,
# npm and pnpm (bun, zsh and fish are used when present) and network access to
# GitHub releases and the npm registry.
#   test/run.sh [work-dir]
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${1:-$(mktemp -d)}"
WORK="$(mkdir -p "$WORK" && cd "$WORK" && pwd -P)"
PIN=0.8.0
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   - $*"; }
no() { FAIL=$((FAIL + 1)); echo "FAIL - $*"; }
check() { if eval "$2"; then ok "$1"; else no "$1"; fi; }
patch_file() { perl -0pi -e "$1" "$2"; } # portable in-place edit (no BSD/GNU sed split)

# Resolve the real runtimes before isolating asdf, so the fixtures keep working
# node/pnpm/bun while tsc-rs installs into a throwaway data dir.
bin_dir() { local p; p="$(asdf which "$1" 2>/dev/null || command -v "$1" 2>/dev/null)" && dirname "$p"; }
NODE_DIR="$(bin_dir node)" || { echo "node is required"; exit 2; }
PNPM_DIR="$(bin_dir pnpm)" || { echo "pnpm is required"; exit 2; }
BUN_DIR="$(bin_dir bun || echo /nonexistent)"
export PATH="$NODE_DIR:$PNPM_DIR:$BUN_DIR:$PATH"
export ASDF_DATA_DIR="$WORK/asdf" HOME="$WORK/home" XDG_DATA_HOME="$WORK/x data" SHELL=/bin/zsh
export npm_config_cache="$WORK/npm-cache" npm_config_update_notifier=false
rm -rf "${ASDF_DATA_DIR:?}" "${HOME:?}" "${XDG_DATA_HOME:?}"
mkdir -p "$HOME"
unset NODE_OPTIONS ASDF_TSC_RS_VERSION TSC_RS TSC_RS_LOG TSC_RS_PROXY_ACTIVE ZDOTDIR CLAUDE_CONFIG_DIR XDG_CONFIG_HOME
PROXY="$XDG_DATA_HOME/asdf-tsc-rs/tsc-proxy.cjs"
STATE="$XDG_DATA_HOME/asdf-tsc-rs"
TAB=$'\t'

echo "# plugin"
# Copy the working tree: asdf plugin add would clone only the committed HEAD,
# and asdf skips a symlinked plugin directory when creating shims.
PLUGIN="$ASDF_DATA_DIR/plugins/tsc-rs"
mkdir -p "$ASDF_DATA_DIR/plugins" && cp -R "$REPO" "$PLUGIN"
check "list-all includes $PIN" "asdf list all tsc-rs | grep -qx $PIN"
check "latest-stable excludes previews" "[ -n \"\$(asdf latest tsc-rs)\" ] && ! asdf latest tsc-rs | grep -q preview"
install_out="$(asdf install tsc-rs $PIN 2>&1)"
check "install $PIN verifies SHA256SUMS" "echo \"\$install_out\" | grep -q 'against SHA256SUMS'"
check "install $PIN verifies the checksum pinned in the plugin" "echo \"\$install_out\" | grep -q 'pinned in this plugin'"
INST="$ASDF_DATA_DIR/installs/tsc-rs/$PIN"
check "only tsc-rs is exposed in bin/" "[ \"\$(ls $INST/bin)\" = tsc-rs ]"
check "lib .d.ts files sit next to the executable" "[ \$(ls $INST/libexec | grep -c '^lib.*d.ts$') -gt 100 ]"
check "shim resolves through ASDF_TSC_RS_VERSION" "ASDF_TSC_RS_VERSION=$PIN $ASDF_DATA_DIR/shims/tsc-rs --version | grep -q Version"
check "every pinned checksum line is well formed" "! grep -v '^#' \"$REPO/checksums\" | grep -vE '^[0-9a-f]{64}  tsc-rs-[0-9][^ ]*-(darwin|linux)-(arm64|x64)\.tar\.gz$'"

# Checksum mismatches, through patched copies of the plugin. Each must have
# downloaded the archive, printed the mismatch, exited nonzero and deleted it.
mismatch() { # name, perl-substitution, file
	local p="$WORK/bad-$1" dl="$WORK/baddl-$1"
	rm -rf "${p:?}" "${dl:?}" && cp -R "$REPO" "$p" && patch_file "$2" "$p/$3"
	out="$(ASDF_INSTALL_TYPE=version ASDF_INSTALL_VERSION=$PIN ASDF_DOWNLOAD_PATH="$dl" "$p/bin/download" 2>&1)"; code=$?
	check "$1: download ran before the check" "[ -e \"$dl/SHA256SUMS\" ]"
	check "$1: refuses with exit 1 and the mismatch message" "[ $code -eq 1 ] && echo \"\$out\" | grep -q 'checksum mismatch'"
	check "$1: mismatched archive is deleted" "! ls \"$dl\"/*.tar.gz >/dev/null 2>&1"
}
mismatch sha256sums 's/expected="\$\(awk/expected="0000\$(awk/' lib/utils.bash
os="$(uname -s | tr '[:upper:]' '[:lower:]')"; arch="$(uname -m | sed 's/aarch64/arm64/; s/x86_64/x64/')"
mismatch pinned "s/^\\w+(  tsc-rs-$PIN-$os-$arch\\.tar\\.gz)\$/0000000000000000000000000000000000000000000000000000000000000000\$1/m" checksums

# A failed install must not leave a partial install behind.
FAKE="$WORK/fakedl" FAKEINST="$WORK/fakeinst/9.9.9"
rm -rf "${FAKE:?}" "$WORK/fakeinst" && mkdir -p "$FAKE/tsc-rs-9.9.9-$os-$arch"
printf '#!/bin/sh\nexit 3\n' >"$FAKE/tsc-rs-9.9.9-$os-$arch/tsc" && chmod +x "$FAKE/tsc-rs-9.9.9-$os-$arch/tsc"
touch "$FAKE/tsc-rs-9.9.9-$os-$arch/lib.d.ts"
ASDF_INSTALL_TYPE=version ASDF_INSTALL_VERSION=9.9.9 ASDF_DOWNLOAD_PATH="$FAKE" ASDF_INSTALL_PATH="$FAKEINST" "$REPO/bin/install" >/dev/null 2>&1; code=$?
check "broken binary fails the install" "[ $code -ne 0 ]"
check "failed install leaves no partial install" "[ ! -e \"$FAKEINST\" ]"

echo "# enable, disable, status"
out="$(asdf cmd tsc-rs status 2>&1)"
check "status before enable says not installed" "echo \"\$out\" | grep -q 'redirect:   not installed'"
out="$(asdf cmd tsc-rs enable print 2>/dev/null)"
check "enable print installs the redirect and prints NODE_OPTIONS" "[ -f \"$PROXY\" ] && [ \"\$out\" = 'NODE_OPTIONS=--require \"$PROXY\"' ]"
check "the installed redirect matches the plugin copy" "cmp -s \"$PROXY\" \"$REPO/proxy/tsc-proxy.cjs\""
check "the redirect path contains a space (quoting is exercised)" "case \"$PROXY\" in *' '*) true ;; *) false ;; esac"

printf 'export KEEP=1\n' >"$HOME/.zshenv"
check "enable (no target) writes the profile chosen from SHELL" "asdf cmd tsc-rs enable >/dev/null 2>&1 && grep -qxF '# >>> asdf-tsc-rs >>>' \"$HOME/.zshenv\""
check "enable keeps the existing profile content" "head -n 1 \"$HOME/.zshenv\" | grep -qx 'export KEEP=1'"
asdf cmd tsc-rs enable shell >/dev/null 2>&1
check "enable is idempotent (one block after two runs)" "[ \$(grep -cxF '# >>> asdf-tsc-rs >>>' \"$HOME/.zshenv\") -eq 1 ]"
check "a backup of the profile was kept" "ls -a \"$XDG_DATA_HOME/asdf-tsc-rs/backups/\" | grep -q '^.zshenv\.'"
sourced() { bash -c '. "$1"; . "$1"; printf %s "$NODE_OPTIONS"' _ "$1"; }
check "sourcing the block twice loads the redirect once" "[ \"\$(env -u NODE_OPTIONS bash -c '. \"\$1\"; . \"\$1\"; printf %s \"\$NODE_OPTIONS\"' _ \"$HOME/.zshenv\")\" = '--require \"$PROXY\"' ]"
check "the block appends to an existing NODE_OPTIONS" "[ \"\$(NODE_OPTIONS=--max-old-space-size=99 sourced \"$HOME/.zshenv\")\" = '--max-old-space-size=99 --require \"$PROXY\"' ]"
mkdir -p "$WORK/dotfiles" && printf '# managed\n' >"$WORK/dotfiles/bashrc" && ln -sf "$WORK/dotfiles/bashrc" "$HOME/.bashrc"
SHELL=/bin/bash asdf cmd tsc-rs enable >/dev/null 2>&1
check "a symlinked profile stays a symlink and its target is edited" "[ -L \"$HOME/.bashrc\" ] && grep -qF \"$PROXY\" \"$WORK/dotfiles/bashrc\""
SHELL=/usr/bin/fish asdf cmd tsc-rs enable >/dev/null 2>&1
FISHF="$HOME/.config/fish/conf.d/asdf-tsc-rs.fish"
check "fish gets a conf.d file with set -gx" "grep -q 'set -gx NODE_OPTIONS' \"$FISHF\""
if command -v fish >/dev/null 2>&1; then
	check "fish: sourcing the file twice loads the redirect once" "[ \"\$(env -u NODE_OPTIONS fish -c 'source \"$FISHF\"; source \"$FISHF\"; printf %s \$NODE_OPTIONS')\" = '--require \"$PROXY\"' ]"
fi
check "enable rejects an unknown target" "! asdf cmd tsc-rs enable bogus >/dev/null 2>&1"

CS="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
printf '{\n    "env": {\n        "NODE_OPTIONS": "--max-old-space-size=4096 --require \\"/old place/toolchain/tsc-proxy.cjs\\"",\n        "OTHER": "1"\n    },\n    "model": "m"\n}\n' >"$CS"
out="$(asdf cmd tsc-rs enable claude 2>&1)"
js() { node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=process.argv[2].split(".").reduce((o,k)=>o==null?o:o[k],s);process.stdout.write(v===undefined?"<unset>":typeof v==="object"?JSON.stringify(v):String(v))' "$CS" "$1"; }
check "enable claude replaces an older tsc-proxy.cjs and keeps other options" "[ \"\$(js env.NODE_OPTIONS)\" = '--max-old-space-size=4096 --require \"$PROXY\"' ]"
check "enable claude reports the replaced redirect" "echo \"\$out\" | grep -q 'replaced --require \"/old place/toolchain/tsc-proxy.cjs\"'"
check "enable claude keeps the other settings and the 4-space indent" "[ \"\$(js env.OTHER)\" = 1 ] && [ \"\$(js model)\" = m ] && grep -q '^    \"env\"' \"$CS\""
cp "$CS" "$WORK/settings.before"
asdf cmd tsc-rs enable claude >/dev/null 2>&1
check "enable claude is idempotent" "cmp -s \"$CS\" \"$WORK/settings.before\""
printf '{ not json' >"$WORK/broken.json"
check "enable claude refuses invalid JSON and leaves it unchanged" "! asdf cmd tsc-rs enable claude \"$WORK/broken.json\" >/dev/null 2>&1 && [ \"\$(cat \"$WORK/broken.json\")\" = '{ not json' ]"
check "status lists the enabled targets" "[ \$(asdf cmd tsc-rs status | grep -c '(enabled)') -eq 4 ]"

asdf cmd tsc-rs disable claude >/dev/null 2>&1
check "disable claude removes only the redirect" "[ \"\$(js env.NODE_OPTIONS)\" = '--max-old-space-size=4096' ] && [ \"\$(js env.OTHER)\" = 1 ]"
printf '{"env":{"NODE_OPTIONS":"--require \\"%s\\""}}\n' "$PROXY" >"$CS"
asdf cmd tsc-rs enable claude >/dev/null 2>&1 && asdf cmd tsc-rs disable claude >/dev/null 2>&1
check "disable claude drops an emptied NODE_OPTIONS and env" "[ \"\$(js env)\" = '<unset>' ]"

echo "// stale" >"$PROXY"
(cd "$PLUGIN" && ./bin/post-plugin-update >/dev/null 2>&1)
check "post-plugin-update refreshes the installed redirect" "cmp -s \"$PROXY\" \"$REPO/proxy/tsc-proxy.cjs\""
asdf cmd tsc-rs enable claude >/dev/null 2>&1
(cd "$PLUGIN" && ./bin/pre-plugin-remove >/dev/null 2>&1)
check "pre-plugin-remove disables every target" "! grep -qF \"$PROXY\" \"$HOME/.zshenv\" \"$WORK/dotfiles/bashrc\" \"$FISHF\" \"$CS\""
check "pre-plugin-remove keeps the profile's own content" "grep -qx 'export KEEP=1' \"$HOME/.zshenv\" && grep -qx '# managed' \"$WORK/dotfiles/bashrc\""
check "disable keeps the redirect file for running processes" "[ -f \"$PROXY\" ]"
check "disable with nothing enabled is harmless" "asdf cmd tsc-rs disable >/dev/null 2>&1"

echo "# robustness"
mkdir -p "$WORK/rel/a" "$WORK/rel/b"
(cd "$WORK/rel/a" && asdf cmd tsc-rs enable shell ./prof >/dev/null 2>&1)
check "a relative profile path is recorded as an absolute one" "grep -qxF \"shell${TAB}$WORK/rel/a/prof\" \"$STATE/targets\""
(cd "$WORK/rel/b" && asdf cmd tsc-rs disable >/dev/null 2>&1)
check "disable from another directory removes it" "! grep -qF \"$PROXY\" \"$WORK/rel/a/prof\""

printf 'export A=1\n# >>> asdf-tsc-rs >>>\nexport AFTER=1\nalias x=y\n' >"$WORK/half.sh" && cp "$WORK/half.sh" "$WORK/half.before"
check "enable refuses a profile with an unterminated block and leaves it unchanged" "! asdf cmd tsc-rs enable shell \"$WORK/half.sh\" >/dev/null 2>&1 && cmp -s \"$WORK/half.sh\" \"$WORK/half.before\""
check "disable refuses it too" "! asdf cmd tsc-rs disable shell \"$WORK/half.sh\" >/dev/null 2>&1 && cmp -s \"$WORK/half.sh\" \"$WORK/half.before\""
printf '# >>> asdf-tsc-rs >>>\n# <<< asdf-tsc-rs <<<\nexport MID=1\n# >>> asdf-tsc-rs >>>\n# <<< asdf-tsc-rs <<<\n' >"$WORK/twice.sh" && cp "$WORK/twice.sh" "$WORK/twice.before"
check "enable refuses a profile with two blocks" "! asdf cmd tsc-rs enable shell \"$WORK/twice.sh\" >/dev/null 2>&1 && cmp -s \"$WORK/twice.sh\" \"$WORK/twice.before\""
check "enable refuses a profile for an unsupported shell" "! asdf cmd tsc-rs enable shell \"$WORK/x.cshrc\" >/dev/null 2>&1 && [ ! -e \"$WORK/x.cshrc\" ]"

asdf cmd tsc-rs enable shell "$WORK/p1.sh" >/dev/null 2>&1
asdf cmd tsc-rs enable claude "$WORK/c1.json" >/dev/null 2>&1
printf '{ broken "%s"' "$PROXY" >"$WORK/c1.json"
out="$(asdf cmd tsc-rs disable 2>&1)"; code=$?
check "disable carries on past a target it cannot undo, and names it" "[ $code -ne 0 ] && ! grep -qF \"$PROXY\" \"$WORK/p1.sh\" && echo \"\$out\" | grep -q 'could not disable' && echo \"\$out\" | grep -qF \"$WORK/c1.json\""
rm -f "$WORK/c1.json"
check "a missing target is forgotten" "asdf cmd tsc-rs disable >/dev/null 2>&1 && [ ! -s \"$STATE/targets\" ]"

mkdir -p "$WORK/badnode" && printf '#!/bin/sh\necho "No version is set for command node" >&2\nexit 126\n' >"$WORK/badnode/node" && chmod +x "$WORK/badnode/node"
asdf cmd tsc-rs enable claude "$WORK/c2.json" >/dev/null 2>&1
check "disable finds a working node behind a node shim that cannot run" "PATH=\"$WORK/badnode:\$PATH\" asdf cmd tsc-rs disable >/dev/null 2>&1 && ! grep -qF \"$PROXY\" \"$WORK/c2.json\""

asdf cmd tsc-rs enable shell "$WORK/p2.sh" >/dev/null 2>&1
check "disable without XDG_DATA_HOME still finds targets enabled with it" "env -u XDG_DATA_HOME asdf cmd tsc-rs disable >/dev/null 2>&1 && ! grep -qF \"$PROXY\" \"$WORK/p2.sh\""
XDG_DATA_HOME="$HOME/.local/share" asdf cmd tsc-rs enable shell "$WORK/p2.sh" >/dev/null 2>&1
check "disable with XDG_DATA_HOME still finds targets enabled without it" "asdf cmd tsc-rs disable >/dev/null 2>&1 && ! grep -qF tsc-proxy.cjs \"$WORK/p2.sh\""

check "with ZDOTDIR set and ~/.zshenv present, enable writes ~/.zshenv" "ZDOTDIR=\"$WORK/zd\" asdf cmd tsc-rs enable >/dev/null 2>&1 && grep -qF \"$PROXY\" \"$HOME/.zshenv\" && [ ! -e \"$WORK/zd/.zshenv\" ]"
asdf cmd tsc-rs disable >/dev/null 2>&1

mkdir -p "$WORK/cdot" && printf '{"env":{"NODE_OPTIONS":"-r /a/tsc-proxy.cjs --require=/b/tsc-proxy.cjs --x"}}\n' >"$WORK/cdot/settings.json"
chmod 600 "$WORK/cdot/settings.json" && ln -sf "$WORK/cdot/settings.json" "$WORK/clink.json"
asdf cmd tsc-rs enable claude "$WORK/clink.json" >/dev/null 2>&1
mode() { node -e 'console.log((require("fs").statSync(process.argv[1]).mode & 0o777).toString(8))' "$1"; }
check "enable claude replaces -r and --require= forms" "[ \"\$(CS=\"$WORK/clink.json\" js env.NODE_OPTIONS)\" = '--x --require \"$PROXY\"' ]"
check "enable claude keeps a symlinked settings file and its mode" "[ -L \"$WORK/clink.json\" ] && [ \"\$(mode \"$WORK/cdot/settings.json\")\" = 600 ]"
nb() { find "$STATE/backups" -name "$1.*" | wc -l | tr -d ' '; }
before=$(nb clink.json); asdf cmd tsc-rs enable claude "$WORK/clink.json" >/dev/null 2>&1
check "an enable that changes nothing keeps no backup" "[ \$(nb clink.json) -eq $before ]"
for _ in 1 2 3 4 5 6 7; do asdf cmd tsc-rs enable shell "$WORK/p4.sh" >/dev/null 2>&1; asdf cmd tsc-rs disable shell "$WORK/p4.sh" >/dev/null 2>&1; done
check "at most 10 backups are kept per file" "[ \$(nb p4.sh) -le 10 ] && [ \$(nb p4.sh) -ge 5 ]"
printf '{"env":[]}\n' >"$WORK/envarr.json"
check "enable claude refuses an env that is not an object" "! asdf cmd tsc-rs enable claude \"$WORK/envarr.json\" >/dev/null 2>&1 && [ \"\$(cat \"$WORK/envarr.json\")\" = '{\"env\":[]}' ]"
asdf cmd tsc-rs disable >/dev/null 2>&1

check "asdf cmd tsc-rs lists the commands" "asdf cmd tsc-rs 2>&1 | grep -q 'enable \\[shell'"
check "disable help and status help print usage" "asdf cmd tsc-rs disable help | grep -q usage && asdf cmd tsc-rs status help | grep -q usage"

BADP="$WORK/bad-proxy-plugin"
rm -rf "${BADP:?}" && cp -R "$REPO" "$BADP" && echo 'syntax error (' >>"$BADP/proxy/tsc-proxy.cjs"
cp "$PROXY" "$WORK/proxy.before"
check "an update whose redirect fails to load keeps the installed one" "! \"$BADP/bin/post-plugin-update\" >/dev/null 2>&1 && cmp -s \"$PROXY\" \"$WORK/proxy.before\""

echo "# real asdf plugin update and remove"
UP="$WORK/upstream"
rm -rf "${UP:?}" && cp -R "$REPO" "$UP" && rm -rf "$UP/.git"
(cd "$UP" && git init -q -b main && git add -A && git -c user.name=t -c user.email=t@example.com commit -qm one)
asdf plugin add tsc-rs-hooks "$UP" >/dev/null 2>&1
echo "// stale" >"$PROXY"
(cd "$UP" && echo >>README.md && git -c user.name=t -c user.email=t@example.com commit -qam two)
asdf plugin update tsc-rs-hooks >/dev/null 2>&1
check "asdf plugin update runs post-plugin-update" "cmp -s \"$PROXY\" \"$UP/proxy/tsc-proxy.cjs\""
asdf cmd tsc-rs enable shell "$WORK/p3.sh" >/dev/null 2>&1
asdf plugin remove tsc-rs-hooks >/dev/null 2>&1
check "asdf plugin remove runs pre-plugin-remove" "! grep -qF \"$PROXY\" \"$WORK/p3.sh\" && [ ! -d \"$ASDF_DATA_DIR/plugins/tsc-rs-hooks\" ]"

echo "# redirect"
FX="$WORK/fx"
rm -rf "${FX:?}" && mkdir -p "$FX/npm" "$FX/pnpm"
for d in npm pnpm; do
	printf '{"name":"fx-%s","version":"1.0.0","private":true,"scripts":{"check":"tsc --noEmit","v":"tsc -v","w":"tsc --watch --noEmit"}}\n' "$d" >"$FX/$d/package.json"
	printf '{"compilerOptions":{"target":"es2022","strict":true,"noEmit":true}}\n' >"$FX/$d/tsconfig.json"
done
(cd "$FX/npm" && npm i -s -D typescript@5.9.3 >/dev/null 2>&1)
(cd "$FX/pnpm" && pnpm add -s -D typescript@5.9.3 >/dev/null 2>&1)

(cd "$HOME" && asdf set -u tsc-rs $PIN)
export NODE_OPTIONS="--require \"$PROXY\"" TSC_RS_LOG="$WORK/proxy.jsonl"
rm -f "$TSC_RS_LOG"
GOOD='const m: Map<string, number> = new Map([["a", 1]]); export const p: Promise<readonly number[]> = Promise.resolve([...m.values()]);'
BADTS='export const n: number = "not a number";'

for d in npm pnpm; do
	cd "$FX/$d" || exit 1
	check "$d: npm run selects tsc-rs" "npm run -s v | grep -q '7\.'"
	check "$d: pnpm run selects tsc-rs" "pnpm -s run v | grep -q '7\.'"
	check "$d: pnpm exec selects tsc-rs" "pnpm exec tsc -v | grep -q '7\.'"
	check "$d: npx selects tsc-rs" "npx tsc -v | grep -q '7\.'"
	check "$d: node <typescript/bin/tsc> selects tsc-rs" "node node_modules/typescript/bin/tsc -v | grep -q '7\.'"
	check "$d: node <typescript/lib/tsc.js> selects tsc-rs" "node node_modules/typescript/lib/tsc.js -v | grep -q '7\.'"
	check "$d: node <typescript/lib/_tsc.js> selects tsc-rs" "node node_modules/typescript/lib/_tsc.js -v | grep -q '7\.'"
	if command -v bun >/dev/null 2>&1; then
		check "$d: bun run (node runtime) selects tsc-rs" "bun run v 2>&1 | grep -q '7\.'"
	fi
	check "$d: TSC_RS=typescript selects 5.9.3" "TSC_RS=typescript npm run -s v | grep -q 'Version 5.9.3'"
	echo "$GOOD" >a.ts
	check "$d: valid stdlib fixture exits 0" "npm run -s check"
	echo "$BADTS" >a.ts
	out="$(npm run -s check 2>&1)"; code=$?
	check "$d: type error exits nonzero" "[ $code -ne 0 ]"
	check "$d: type error prints TS2322" "echo \"\$out\" | grep -q 'TS2322'"
	check "$d: require(typescript) is not redirected" "[ \"\$(node -e 'console.log(require(\"typescript\").version)')\" = 5.9.3 ]"
	echo "$GOOD" >a.ts
done

cd "$FX/npm" || exit 1
echo "# version selection (asdf order)"
mkdir -p "$FX/npm/sub/deeper"
vlog() { tail -n 1 "$TSC_RS_LOG"; }
check "the global .tool-versions is used outside any project" "(cd \"$WORK\" && node \"$FX/npm/node_modules/typescript/bin/tsc\" -v | grep -q '7\.') && vlog | grep -qF '\"version_source\":\"$HOME/.tool-versions\"'"
printf 'nodejs 22.0.0\ntsc-rs 9.9.9 %s # comment\n' "$PIN" >"$FX/npm/.tool-versions"
check "the nearest .tool-versions wins, from a subdirectory" "(cd sub/deeper && node ../../node_modules/typescript/bin/tsc -v | grep -q '7\.') && vlog | grep -qF '\"version_source\":\"$FX/npm/.tool-versions\"'"
check "the first installed of several listed versions is used" "vlog | grep -q '\"version\":\"$PIN\"'"
mkdir -p "$WORK/logical" "$WORK/physical/proj" && printf 'tsc-rs 7.7.7\n' >"$WORK/logical/.tool-versions" && ln -sfn "$WORK/physical/proj" "$WORK/logical/proj"
out="$(cd "$WORK/logical/proj" && node "$FX/npm/node_modules/typescript/bin/tsc" -v 2>&1)"; code=$?
check "a directory reached through a symlink uses the .tool-versions above the link, as asdf does" "[ $code -eq 127 ] && echo \"\$out\" | grep -qF \"$WORK/logical/.tool-versions\""
printf 'tsc-rs 9.9.9\n' >"$FX/npm/.tool-versions"
out="$(npm run -s v 2>&1)"; code=$?
check "an uninstalled version exits 127 with the install command" "[ $code -eq 127 ] && echo \"\$out\" | grep -q 'asdf install tsc-rs 9.9.9' && ! echo \"\$out\" | grep -q 'Version 5'"
check "ASDF_TSC_RS_VERSION beats .tool-versions" "ASDF_TSC_RS_VERSION=$PIN npm run -s v | grep -q '7\.'"
printf 'tsc-rs system\n' >"$FX/npm/.tool-versions"
check "\"system\" runs the project's TypeScript" "npm run -s v | grep -q 'Version 5.9.3' && vlog | grep -q '\"selected_by\":\"system\"'"
printf 'tsc-rs ref:main\n' >"$FX/npm/.tool-versions"
check "ref: versions are refused with exit 127" "npm run -s v >/dev/null 2>&1; [ \$? -eq 127 ]"
printf 'tsc-rs %s\n' "$PIN" >"$FX/npm/.tv-alt" && printf 'tsc-rs 9.9.9\n' >"$FX/npm/.tool-versions"
check "ASDF_TOOL_VERSIONS_FILENAME is honoured" "ASDF_TOOL_VERSIONS_FILENAME=.tv-alt npm run -s v | grep -q '7\.'"
rm -f "$FX/npm/.tool-versions" "$FX/npm/.tv-alt" "$HOME/.tool-versions"
out="$(npm run -s v 2>&1)"; code=$?
check "no version anywhere exits 127 and says how to set one" "[ $code -eq 127 ] && echo \"\$out\" | grep -q 'asdf set -u tsc-rs' && echo \"\$out\" | grep -q 'TSC_RS=typescript'"
export ASDF_TSC_RS_VERSION=$PIN

echo "# selection and failure"
fake() { mkdir -p "$WORK/fake-$1/bin" && printf '#!/bin/sh\n%s\n' "$2" >"$WORK/fake-$1/bin/tsc-rs" && chmod +x "$WORK/fake-$1/bin/tsc-rs" && echo "path:$WORK/fake-$1"; }
check "path:<dir> runs <dir>/bin/tsc-rs" "[ \"\$(ASDF_TSC_RS_VERSION=\$(fake echo 'echo fake \"\$@\"') node node_modules/typescript/bin/tsc -p x)\" = 'fake -p x' ]"
check "TSC_RS=tsc-rs selects tsc-rs" "TSC_RS=tsc-rs npm run -s v | grep -q '7\.'"
out="$(ASDF_TSC_RS_VERSION=path:./x node node_modules/typescript/bin/tsc -v 2>&1)"; code=$?
check "a relative path: version is refused with exit 127" "[ $code -eq 127 ] && echo \"\$out\" | grep -q 'must be absolute'"
out="$(ASDF_TSC_RS_VERSION=../../x node node_modules/typescript/bin/tsc -v 2>&1)"; code=$?
check "a version naming another directory is refused with exit 127" "[ $code -eq 127 ] && echo \"\$out\" | grep -q 'not a valid'"
out="$(ASDF_DATA_DIR="$WORK/no-asdf" node node_modules/typescript/bin/tsc -v 2>&1)"; code=$?
check "a removed plugin says to remove the redirect" "[ $code -eq 127 ] && echo \"\$out\" | grep -q 'plugin is not installed'"
check "a bad TSC_RS value exits 64" "TSC_RS=tsgo npm run -s v >/dev/null 2>&1; [ \$? -eq 64 ]"
out="$(ASDF_TSC_RS_VERSION="$(fake recurse "exec node \"$FX/npm/node_modules/typescript/bin/tsc\" \"\$@\"")" node node_modules/typescript/bin/tsc -v 2>&1)"; code=$?
check "recursion through the binary is refused with exit 70" "[ $code -eq 70 ] && echo \"\$out\" | grep -q 'refusing to redirect'"
ASDF_TSC_RS_VERSION="$(fake sigpipe 'kill -PIPE $$')" node node_modules/typescript/bin/tsc >/dev/null 2>&1; code=$?
check "a child killed by SIGPIPE yields exit 141" "[ $code -eq 141 ]"
before=$(wc -l <"$TSC_RS_LOG")
NODE_OPTIONS="$NODE_OPTIONS --require \"$REPO/proxy/tsc-proxy.cjs\"" node node_modules/typescript/bin/tsc -v >/dev/null
check "two copies of the redirect run the compiler once" "[ \$((\$(wc -l <\"$TSC_RS_LOG\") - before)) -eq 1 ]"
check "node -e with a tsc path argument is untouched" "[ \"\$(node -e 'console.log(\"eval ran\")' node_modules/typescript/bin/tsc)\" = 'eval ran' ]"
before=$(wc -l <"$TSC_RS_LOG")
(echo '{"seq":0,"type":"request","command":"exit"}' | node node_modules/typescript/bin/tsserver >/dev/null 2>&1) &
tp=$!; sleep 3; kill $tp 2>/dev/null; wait $tp 2>/dev/null
check "tsserver is untouched" "[ \$(wc -l <\"$TSC_RS_LOG\") -eq $before ]"
check "KNOWN BYPASS: replacing NODE_OPTIONS runs upstream" "NODE_OPTIONS=--max-old-space-size=4096 node node_modules/typescript/bin/tsc -v | grep -q 'Version 5.9.3'"
check "appending to NODE_OPTIONS keeps tsc-rs" "NODE_OPTIONS=\"\$NODE_OPTIONS --max-old-space-size=4096\" node node_modules/typescript/bin/tsc -v | grep -q '7\.'"
check "unrelated node processes are untouched" "[ \"\$(node -e 'console.log(40+2)')\" = 42 ]"
check "the log records version, source, bin, argv and exit" "[ \$(grep '\"outcome\":\"ran\"' \"$TSC_RS_LOG\" | grep -c '\"version\":\"$PIN\".*\"bin_real\":.*\"exit\":') -gt 0 ] && grep -q '\"version_source\":\"ASDF_TSC_RS_VERSION\"' \"$TSC_RS_LOG\""
before=$(wc -l <"$TSC_RS_LOG")
env -u TSC_RS_LOG node node_modules/typescript/bin/tsc -v >/dev/null
check "without TSC_RS_LOG nothing is logged" "[ \$(wc -l <\"$TSC_RS_LOG\") -eq $before ]"

echo "# through a real profile"
asdf cmd tsc-rs enable shell "$WORK/profile.sh" >/dev/null 2>&1
check "bash: a script sourcing the profile redirects npm run" "env -u NODE_OPTIONS bash -c '. \"$WORK/profile.sh\"; cd \"$FX/npm\" && npm run -s v' | grep -q '7\.'"
if command -v zsh >/dev/null 2>&1; then
	asdf cmd tsc-rs enable >/dev/null 2>&1
	check "zsh: a non-interactive zsh reads ~/.zshenv and redirects" "env -u NODE_OPTIONS zsh -c 'cd \"$FX/npm\" && npm run -s v' | grep -q '7\.'"
	asdf cmd tsc-rs disable >/dev/null 2>&1
	check "zsh: after disable the project's TypeScript runs" "env -u NODE_OPTIONS zsh -c 'cd \"$FX/npm\" && npm run -s v' | grep -q 'Version 5.9.3'"
fi

echo "# signals"
# SIGTERM to the node process (or to npm) must reach tsc-rs, not orphan it, and
# the exit status must match what tsc-rs itself does on SIGTERM.
watchers() { pgrep -f "tsc-rs/$PIN/bin/tsc-rs --watch" | tr '\n' ' '; }
"$INST/bin/tsc-rs" --watch --noEmit >/dev/null 2>&1 & np=$!
sleep 3; kill -TERM $np; wait $np; direct=$?
node node_modules/typescript/bin/tsc --watch --noEmit >/dev/null 2>&1 & np=$!
sleep 3; before="$(watchers)"; kill -TERM $np; wait $np; code=$?; sleep 1
check "SIGTERM to node: tsc-rs --watch was running" "[ -n \"$before\" ]"
check "SIGTERM to node: exit matches tsc-rs's own ($direct)" "[ $code -eq $direct ]"
check "SIGTERM to node: no orphaned tsc-rs" "[ -z \"\$(watchers)\" ]"
# Whether npm's SIGTERM reaches the compiler depends on /bin/sh: bash execs
# the script's command, dash (Ubuntu) does not, so there the node process is
# left running even without the redirect. The redirect must do no worse.
upstream() { pgrep -f "bin/tsc --watch --noEmit" | tr '\n' ' '; }
npm run -s w >/dev/null 2>&1 & np=$!
sleep 4; before="$(watchers)"; kill -TERM $np; wait $np 2>/dev/null; sleep 2
orphan_rs="$(watchers)"
for p in $orphan_rs $(upstream); do kill -TERM "$p" 2>/dev/null; done; sleep 1
TSC_RS=typescript npm run -s w >/dev/null 2>&1 & np=$!
sleep 6; kill -TERM $np; wait $np 2>/dev/null; sleep 2
orphan_up="$(upstream)"
for p in $orphan_up; do kill -TERM "$p" 2>/dev/null; done
check "SIGTERM to npm: tsc-rs --watch was running" "[ -n \"$before\" ]"
check "SIGTERM to npm: tsc-rs is stopped wherever upstream tsc is (orphans: tsc-rs '$orphan_rs', upstream '$orphan_up')" "[ -z \"$orphan_rs\" ] || [ -n \"$orphan_up\" ]"
for p in $(watchers); do kill -TERM "$p" 2>/dev/null; done

echo "# $PASS passed, $FAIL failed (work dir $WORK)"
[ "$FAIL" -eq 0 ]
