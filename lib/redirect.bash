#!/usr/bin/env bash
# The optional redirect: `asdf cmd tsc-rs enable|disable|status`.
#
# The proxy is copied to a stable path outside the plugin directory, so
# reinstalling or removing the plugin never leaves NODE_OPTIONS pointing at a
# missing file (node refuses to start when a --require file is missing).
#
# Disabling never stops at the first problem: each target is handled on its
# own and every one that could not be undone is named, because asdf removes
# the plugin even when its pre-plugin-remove hook fails.

set -euo pipefail

REDIRECT_PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_TSC_RS_HOME="$HOME/.local/share/asdf-tsc-rs"
BEGIN_MARK="# >>> asdf-tsc-rs >>>"
END_MARK="# <<< asdf-tsc-rs <<<"
BACKUPS_KEPT=10

say() { echo "tsc-rs: $*" >&2; }
die() {
	say "$*"
	exit 1
}

# use_home <dir>: where the installed proxy, the target list and backups live.
use_home() {
	TSC_RS_HOME="$1"
	PROXY="$TSC_RS_HOME/tsc-proxy.cjs"
	TARGETS="$TSC_RS_HOME/targets"
}
use_home "${XDG_DATA_HOME:-$HOME/.local/share}/asdf-tsc-rs"

# Every state directory this plugin has used: the current one, the default,
# and any listed in the default one's "homes" file, so a later change of
# XDG_DATA_HOME does not hide earlier targets.
HOMES_FILE="$DEFAULT_TSC_RS_HOME/homes"
state_homes() {
	{
		echo "$TSC_RS_HOME"
		echo "$DEFAULT_TSC_RS_HOME"
		[ ! -f "$HOMES_FILE" ] || cat "$HOMES_FILE"
	} | awk 'NF && !seen[$0]++'
}
register_home() {
	[ "$TSC_RS_HOME" != "$DEFAULT_TSC_RS_HOME" ] || return 0
	mkdir -p "$DEFAULT_TSC_RS_HOME"
	touch "$HOMES_FILE"
	grep -qxF "$TSC_RS_HOME" "$HOMES_FILE" || echo "$TSC_RS_HOME" >>"$HOMES_FILE"
}

# find_node: sets NODE_BIN to a node that starts. An asdf `node` shim with no
# version set for the current directory does not, so other copies are tried.
# NODE_OPTIONS is cleared for these runs so a missing proxy cannot stop node.
find_node() {
	[ -n "${NODE_BIN:-}" ] && return 0
	local c
	while IFS= read -r c; do
		if [ -n "$c" ] && [ -x "$c" ] && NODE_OPTIONS='' "$c" -e 0 >/dev/null 2>&1; then
			NODE_BIN="$c"
			return 0
		fi
	done < <(
		type -ap node 2>/dev/null || true
		for c in "${ASDF_DATA_DIR:-$HOME/.asdf}"/installs/nodejs/*/bin/node; do echo "$c"; done
		printf '%s\n' /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node
	)
	return 1
}

# Characters that would need escaping in a shell file or in NODE_OPTIONS.
check_proxy_path() {
	case "$PROXY" in
	*[\"\'\\\$\`]* | *$'\n'*) die "the proxy path $PROXY contains a quote, backslash, \$ or backtick; set XDG_DATA_HOME to a plainer directory" ;;
	esac
}

require_fragment() { printf -- '--require "%s"' "${1:-$PROXY}"; }

# Copies the plugin's proxy into place, checking first that node starts with
# the new copy loaded, so a broken update never replaces a working redirect.
install_proxy() {
	check_proxy_path
	mkdir -p "$TSC_RS_HOME"
	local tmp="$PROXY.tmp.$$"
	cp "$REDIRECT_PLUGIN_DIR/proxy/tsc-proxy.cjs" "$tmp"
	chmod 0644 "$tmp"
	if find_node; then
		if ! NODE_OPTIONS="$(require_fragment "$tmp")" "$NODE_BIN" -e 'process.exit(0)'; then
			rm -f "$tmp"
			die "node failed to start with the new redirect loaded; kept ${PROXY} as it was"
		fi
	else
		say "warning: no working node found, so the redirect was installed without a start-up check"
	fi
	mv -f "$tmp" "$PROXY"
}

# Refresh an installed proxy after `asdf plugin update`; a no-op otherwise.
refresh_proxy() {
	local h
	while IFS= read -r h; do
		use_home "$h"
		[ -f "$PROXY" ] || continue
		install_proxy
		say "updated $PROXY"
	done < <(state_homes)
}

# abspath <file>: targets are recorded by absolute path, so disable works from
# any directory. Symlinks in the directory are resolved; the file itself is not.
abspath() {
	local p="$1" d
	case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
	d="$(dirname "$p")"
	if [ -d "$d" ]; then
		d="$(cd "$d" && pwd -P)" || return 1
		p="$d/$(basename "$p")"
	fi
	echo "$p"
}

record_target() { # kind file
	register_home
	mkdir -p "$TSC_RS_HOME"
	touch "$TARGETS"
	grep -qxF "$1	$2" "$TARGETS" || printf '%s\t%s\n' "$1" "$2" >>"$TARGETS"
}

forget_target() { # kind file
	[ -f "$TARGETS" ] || return 0
	local tmp="$TARGETS.tmp.$$"
	grep -vxF "$1	$2" "$TARGETS" >"$tmp" || true
	mv -f "$tmp" "$TARGETS"
}

# backup <file>: prints the copy's path; keeps the newest $BACKUPS_KEPT per name.
backup() {
	[ -e "$1" ] || return 0
	local dir="$TSC_RS_HOME/backups" name dest
	name="$(basename "$1")"
	mkdir -p "$dir" || return 1
	dest="$dir/$name.$(date +%Y%m%dT%H%M%S).$$"
	cp -p "$1" "$dest" || return 1
	local old=("$dir/$name".*)
	local n=$((${#old[@]} - BACKUPS_KEPT)) i
	for ((i = 0; i < n; i++)); do rm -f "${old[$i]}"; done
	echo "$dest"
}

default_shell_file() {
	case "$(basename "${SHELL:-}")" in
	# zsh reads ~/.zshenv first; a ZDOTDIR set there only affects later files.
	zsh)
		if [ -n "${ZDOTDIR:-}" ] && [ "$ZDOTDIR" != "$HOME" ] && [ ! -e "$HOME/.zshenv" ]; then
			echo "$ZDOTDIR/.zshenv"
		else
			echo "$HOME/.zshenv"
		fi
		;;
	bash) echo "$HOME/.bashrc" ;;
	fish) echo "${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/asdf-tsc-rs.fish" ;;
	*) die "cannot pick a profile for SHELL=${SHELL:-unset}; name one: asdf cmd tsc-rs enable shell <file>" ;;
	esac
}

# The block is POSIX sh, or fish for a *.fish file. Other shells are refused.
check_shell_file() {
	case "$(basename "$1")" in
	*csh* | *.nu | *.ps1 | *.xsh | *.elv | *.rc.ion)
		die "$1 looks like a file for a shell this plugin does not support; it writes POSIX sh, or fish for *.fish files"
		;;
	esac
}

shell_block() { # file
	echo "$BEGIN_MARK"
	echo "# Runs tsc-rs wherever node would run the TypeScript CLI. Undo: asdf cmd tsc-rs disable"
	case "$1" in
	*.fish)
		echo "if not string match -q -- '*$PROXY*' \"\$NODE_OPTIONS\""
		echo "    set -gx NODE_OPTIONS (string trim -- \"\$NODE_OPTIONS --require \\\"$PROXY\\\"\")"
		echo "end"
		;;
	*)
		echo "case \"\${NODE_OPTIONS:-}\" in"
		echo "*'$PROXY'*) ;;"
		echo "*) export NODE_OPTIONS=\"\${NODE_OPTIONS:+\$NODE_OPTIONS }--require \\\"$PROXY\\\"\" ;;"
		echo "esac"
		;;
	esac
	echo "$END_MARK"
}

# Rewrites a file in place (following symlinks, keeping its mode) without the
# marked block, then appends <block> when one is given. Refuses a file whose
# markers are unbalanced, rather than guess where a damaged block ends.
rewrite_shell_file() { # file [block]
	local file="$1" block="${2:-}" tmp begins ends
	mkdir -p "$(dirname "$file")" || return 1
	[ -e "$file" ] || : >"$file" || return 1
	begins="$(grep -cxF "$BEGIN_MARK" "$file" || true)"
	ends="$(grep -cxF "$END_MARK" "$file" || true)"
	if [ "$begins" -gt 1 ] || [ "$begins" != "$ends" ]; then
		say "$file has $begins \"$BEGIN_MARK\" and $ends \"$END_MARK\" lines; expected one of each or none. Fix the asdf-tsc-rs block by hand; the file was not changed"
		return 1
	fi
	tmp="$(mktemp "${TMPDIR:-/tmp}/asdf-tsc-rs.XXXXXX")" || return 1
	awk -v b="$BEGIN_MARK" -v e="$END_MARK" '$0 == b {skip = 1; next} $0 == e {skip = 0; next} !skip' "$file" >"$tmp" || {
		rm -f "$tmp"
		return 1
	}
	if [ -n "$block" ]; then
		# Keep one blank line between existing content and the block.
		if [ -s "$tmp" ] && [ -n "$(tail -c 1 "$tmp")" ]; then echo >>"$tmp"; fi
		if [ -s "$tmp" ] && [ -n "$(tail -n 1 "$tmp")" ]; then echo >>"$tmp"; fi
		printf '%s\n' "$block" >>"$tmp"
	fi
	cat "$tmp" >"$file" || {
		rm -f "$tmp"
		return 1
	}
	rm -f "$tmp"
}

# Edits the env.NODE_OPTIONS of a Claude Code settings file. Prints
# "unchanged" or "changed", after a "replaced <option>" line per older redirect.
#   mode "enable": drop any --require of a tsc-proxy.cjs, then append ours
#   mode "disable": drop our --require; remove the key when nothing is left
edit_claude_settings() { # mode file
	if ! find_node; then
		say "no working node was found to edit $2"
		return 1
	fi
	NODE_OPTIONS='' "$NODE_BIN" - "$1" "$2" "$PROXY" <<'NODE'
const fs = require('fs'), path = require('path');
const [mode, file, proxy] = process.argv.slice(2);
const stop = (why) => { console.error(`tsc-rs: ${file} ${why}; not changed`); process.exit(1); };
let text = '{}', exists = fs.existsSync(file);
if (exists) text = fs.readFileSync(file, 'utf8');
let data;
try { data = JSON.parse(text); } catch (e) { stop(`is not valid JSON (${e.message})`); }
const isObject = (v) => typeof v === 'object' && v !== null && !Array.isArray(v);
if (!isObject(data)) stop('is not a JSON object');
if ('env' in data && !isObject(data.env)) stop('has an "env" that is not an object');
const env = data.env || {};
if ('NODE_OPTIONS' in env && typeof env.NODE_OPTIONS !== 'string') stop('has an env.NODE_OPTIONS that is not a string');
const before = env.NODE_OPTIONS || '';
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
// enable removes any tsc-proxy.cjs (two redirects would both run); disable removes only ours.
const value = mode === 'enable'
  ? `"[^"]*tsc-proxy\\.cjs"|'[^']*tsc-proxy\\.cjs'|[^\\s"']*tsc-proxy\\.cjs`
  : `"${esc(proxy)}"|'${esc(proxy)}'|${esc(proxy)}`;
const re = new RegExp(`\\s*(?:--require|-r)(?:=|\\s+)(?:${value})(?=\\s|$)`, 'g');
const removed = before.match(re) || [];
let after = before.replace(re, '').trim();
if (mode === 'enable') after = (after ? after + ' ' : '') + `--require "${proxy}"`;
if (after === before) { console.log('unchanged'); process.exit(0); }
if (after) env.NODE_OPTIONS = after; else delete env.NODE_OPTIONS;
if (Object.keys(env).length) data.env = env; else delete data.env;
const indent = (text.match(/^[ \t]+(?=")/m) || ['  '])[0];
const real = exists ? fs.realpathSync(file) : file;
fs.mkdirSync(path.dirname(real), { recursive: true });
const tmp = `${real}.asdf-tsc-rs.${process.pid}`;
fs.writeFileSync(tmp, JSON.stringify(data, null, indent) + '\n', { mode: exists ? fs.statSync(real).mode & 0o777 : 0o644 });
fs.renameSync(tmp, real);
for (const r of removed) if (mode === 'enable' && !r.includes(proxy)) console.log(`replaced ${r.trim()}`);
console.log('changed');
NODE
}

enable_target() { # kind [file]
	local kind="$1" file="${2:-}" saved out
	case "$kind" in
	shell)
		[ -n "$file" ] || file="$(default_shell_file)"
		check_shell_file "$file"
		mkdir -p "$(dirname "$file")"
		file="$(abspath "$file")"
		saved="$(backup "$file")"
		rewrite_shell_file "$file" "$(shell_block "$file")"
		record_target shell "$file"
		if [ -n "$saved" ] && cmp -s "$saved" "$file"; then
			rm -f "$saved"
			say "already enabled in $file"
		else
			say "enabled in $file${saved:+ (previous copy: $saved)}"
		fi
		say "open a new shell, or run: source \"$file\""
		;;
	claude)
		[ -n "$file" ] || file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
		mkdir -p "$(dirname "$file")"
		file="$(abspath "$file")"
		saved="$(backup "$file")"
		out="$(edit_claude_settings enable "$file")" || {
			[ -z "$saved" ] || rm -f "$saved"
			exit 1
		}
		grep -vxE 'changed|unchanged' <<<"$out" | sed '/^$/d; s/^/tsc-rs: /' >&2 || true
		record_target claude "$file"
		if [ "$(tail -n 1 <<<"$out")" = unchanged ]; then
			[ -z "$saved" ] || rm -f "$saved"
			say "already enabled in $file (env.NODE_OPTIONS)"
		else
			say "enabled in $file (env.NODE_OPTIONS)${saved:+ (previous copy: $saved)}"
		fi
		say "sessions started from now on use it; running sessions keep their environment until restarted"
		;;
	*) die "unknown target \"$kind\"; use shell, claude or print" ;;
	esac
}

# disable_target <kind> <file>: returns 0 when the file no longer loads the
# redirect, 1 when that could not be done. Sets DISABLED_ANY when it changed
# a file. Written without relying on `set -e`, which callers testing its
# status turn off.
DISABLED_ANY=0
# shellcheck disable=SC2034 # DISABLED_ANY is read by command-disable, which sources this file
disable_target() {
	local kind="$1" file="$2" out
	case "$kind" in
	shell)
		if [ -f "$file" ] && grep -qxF "$BEGIN_MARK" "$file"; then
			backup "$file" >/dev/null || return 1
			rewrite_shell_file "$file" || return 1
			DISABLED_ANY=1
			say "disabled in $file"
		fi
		;;
	claude)
		if [ -f "$file" ] && grep -qF "$PROXY" "$file"; then
			backup "$file" >/dev/null || return 1
			out="$(edit_claude_settings disable "$file")" || return 1
			[ "$out" = unchanged ] || DISABLED_ANY=1
			say "disabled in $file"
		fi
		;;
	*)
		say "unknown target \"$kind\"; use shell or claude"
		return 1
		;;
	esac
	forget_target "$kind" "$file"
}

# Disables every recorded target in every state directory: shell profiles
# first, since they need no node. Returns 1 after naming any it could not undo.
disable_all() {
	local h kind file want failed=() seen=0
	while IFS= read -r h; do
		use_home "$h"
		[ -s "$TARGETS" ] || continue
		seen=1
		for want in shell claude; do
			while IFS=$'\t' read -r kind file; do
				[ "$kind" = "$want" ] || continue
				disable_target "$kind" "$file" || failed+=("$kind $file (loads $PROXY)")
			done < <(cat "$TARGETS")
		done
	done < <(state_homes)
	use_home "${XDG_DATA_HOME:-$HOME/.local/share}/asdf-tsc-rs"
	if [ "$seen" = 0 ]; then
		say "the redirect is not enabled anywhere this plugin recorded (under $(state_homes | paste -sd ' ' -))"
	fi
	if [ ${#failed[@]} -gt 0 ]; then
		say "could not disable:"
		for file in "${failed[@]}"; do say "  $file"; done
		say "remove the asdf-tsc-rs block or the --require of tsc-proxy.cjs from each by hand"
		return 1
	fi
	return 0
}

version_hint() {
	if ! asdf current tsc-rs >/dev/null 2>&1; then
		say "note: no tsc-rs version is set here, so tsc will fail with exit 127 until you run"
		say "  asdf install tsc-rs latest && asdf set -u tsc-rs latest"
	fi
}
