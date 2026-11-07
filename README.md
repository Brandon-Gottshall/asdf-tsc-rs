# asdf-tsc-rs

[![CI](https://github.com/Brandon-Gottshall/asdf-tsc-rs/actions/workflows/ci.yml/badge.svg)](https://github.com/Brandon-Gottshall/asdf-tsc-rs/actions/workflows/ci.yml)

An [asdf](https://asdf-vm.com) plugin for [tsc-rs](https://github.com/pingdotgg/ts-rust), the Rust
port of the TypeScript compiler. It does two things:

1. **Installs tsc-rs** as a normal asdf tool, verified against checksums, as the `tsc-rs` command.
2. **Optionally runs tsc-rs wherever `tsc` would run**, including `npm run build`, `pnpm tsc`,
   `npx tsc` and a project's own `node_modules/.bin/tsc`, without editing the project. You turn this
   on with one command and off with another.

tsc-rs 0.8.0 reports itself as TypeScript 7 (`Version 7.1.0-dev`). Read
[Differences from TypeScript 5](#differences-from-typescript-5) before turning on the redirect for
existing projects.

## Install tsc-rs

Requires asdf 0.16 or later, and macOS or Linux on arm64 or x64.

```bash
asdf plugin add tsc-rs https://github.com/Brandon-Gottshall/asdf-tsc-rs.git
asdf install tsc-rs latest
asdf set -u tsc-rs latest        # or `asdf set tsc-rs <version>` for one project
tsc-rs --version
```

The plugin never creates a `tsc` command, so installing it changes nothing else on its own.

## Run tsc-rs wherever `tsc` would run

```bash
asdf cmd tsc-rs enable           # adds one block to your shell profile
asdf cmd tsc-rs status           # what is enabled, and which version applies here
asdf cmd tsc-rs disable          # removes it from everywhere enable added it
asdf cmd tsc-rs help             # the commands and their targets
```

Then open a new shell. From then on, whenever node is about to run the TypeScript compiler's CLI,
tsc-rs runs instead. It gets the same arguments, working directory, environment and terminal, and
its exit code is passed back. Every way of reaching the CLI is covered:

- package scripts: `npm run`, `pnpm run`, and `bun run` without `--bun`
- `npx tsc` and `pnpm exec tsc`
- `node node_modules/typescript/bin/tsc`, `…/lib/tsc.js` and `…/lib/_tsc.js`

That includes a project that pins its own `typescript` in `node_modules`: the redirect happens inside
node, after the package manager has picked the project's `tsc`. Code that imports TypeScript as a
library, with `require("typescript")`, is never redirected.

### Where `enable` writes

| Command | Writes to |
|---|---|
| `enable` or `enable shell` | your shell profile, chosen from `$SHELL`: `~/.zshenv` (zsh), `~/.bashrc` (bash) or `~/.config/fish/conf.d/asdf-tsc-rs.fish` (fish) |
| `enable shell <file>` | that file: POSIX sh syntax, or fish syntax for a `*.fish` file. Files for csh, nushell and other shells are refused. |
| `enable claude [file]` | the `env.NODE_OPTIONS` of a [Claude Code](https://claude.com/claude-code) settings file, by default `~/.claude/settings.json`, so the agent's commands use tsc-rs too |
| `enable print` | nowhere: installs the redirect and prints the `NODE_OPTIONS` value, for CI or other tools |

`enable` does the following:
- It copies the redirect script to `~/.local/share/asdf-tsc-rs/tsc-proxy.cjs` (or `$XDG_DATA_HOME`),
  so updating or removing the plugin never leaves `NODE_OPTIONS` pointing at a missing file.
- It adds to an existing `NODE_OPTIONS` instead of replacing it, and loads the redirect only once
  however often the profile is read.
- It edits a symlinked profile in place, keeping the symlink and the file's permissions.
- It keeps a copy of each file it changes in `~/.local/share/asdf-tsc-rs/backups/`, the newest 10
  per file. These include copies of Claude Code settings, which can hold secrets.
- It refuses a profile whose asdf-tsc-rs block is damaged (a start marker without an end, or two
  blocks), and leaves the file unchanged for you to fix.

`asdf plugin update tsc-rs` refreshes the installed redirect, after checking that node still starts
with the new copy. `asdf plugin remove tsc-rs` runs `disable` first. If that can't undo a target,
it names the file, and asdf removes the plugin anyway, so remove the block from that file by hand.

### Which version runs

The same version asdf would choose for the `tsc-rs` command in that directory, including a
directory reached through a symlink:
1. `ASDF_TSC_RS_VERSION`
2. otherwise the nearest `.tool-versions` from the working directory upwards
3. otherwise the one in your home directory

If an entry lists several versions, the first installed one wins. `system` means "use the project's
own TypeScript", and `path:<absolute dir>` runs `<dir>/bin/tsc-rs`. `path:` is accepted only from
`ASDF_TSC_RS_VERSION` or `~/.tool-versions`, never from a project's `.tool-versions`. Versions
containing `/` are refused too. So a repository you check out can't make `tsc` run a binary of its
choosing.

Set your default with `asdf set -u tsc-rs <version>`, which writes `~/.tool-versions`. A project
without a `tsc-rs` line, or with no `.tool-versions` at all, then uses it, and a project can still
opt out or pin another version in its own file.

`ASDF_TSC_RS_VERSION` comes first, so setting it in an environment overrides every project's file,
including `tsc-rs system`. Use it only where no project should be able to opt out, such as a CI
job that must check everything with tsc-rs.

### Opting out

- **For one project:** run `asdf set tsc-rs system` in it, or add this line to its `.tool-versions`
  (other tools' lines stay as they are):

  ```
  tsc-rs system
  ```

  Everything under that directory then runs the project's own TypeScript. Commit the line to opt
  the project out for everyone who uses the redirect.
- **For one command:** `TSC_RS=typescript npm run build` runs the TypeScript the project would
  normally run.
- **Everywhere:** `asdf cmd tsc-rs disable`.

### When tsc-rs can't run

The command fails rather than quietly running the other compiler:
- **Exit 127** when no version is set, or the chosen version is not installed. The message names
  the `asdf` command that fixes it. If the plugin itself was removed, the message says to remove
  the redirect instead.
- **Exit 64** when `TSC_RS` has a value other than `tsc-rs` or `typescript`.
- **Exit 70** when the selected binary would itself run the TypeScript CLI.

### Logging

Set `TSC_RS_LOG=<file>` to append one JSON line per redirected run. Each line records the time,
working directory, arguments, chosen version and where it came from, the binary, exit code and
duration. The file rotates to `<file>.1` at 5 MB. Nothing is logged unless the variable is set.

### Known gaps

- **Replacing `NODE_OPTIONS` drops the redirect silently.** A command such as
  `NODE_OPTIONS=--max-old-space-size=8192 tsc`, or the same through `cross-env`, runs the project's
  TypeScript. Append instead: `NODE_OPTIONS="$NODE_OPTIONS --max-old-space-size=8192"`.
- **Tools that load TypeScript as a library keep the project's TypeScript.** These include Next.js
  `next build`, tsup's `dts`, typescript-eslint, ts-jest, ts-node, vue-tsc and editors. Switching
  them is a dependency change in each project.
- **Other runtimes and wiped environments:** `bun --bun`, and processes started with `NODE_OPTIONS`
  cleared, are not covered.
- **Non-interactive shells:** bash doesn't read `~/.bashrc`, so scripts run outside your terminal
  aren't covered unless they source it. zsh reads `~/.zshenv` for every shell.
- **bash login shells on macOS** read `~/.bash_profile`, not `~/.bashrc`. If yours doesn't source
  `~/.bashrc`, run `asdf cmd tsc-rs enable shell ~/.bash_profile` as well.
- **Containers and remote machines:** a `NODE_OPTIONS` passed into an environment where the
  redirect file doesn't exist stops node from starting there. Don't forward it, or run `enable`
  inside that environment too.

## Uninstall

```bash
asdf cmd tsc-rs disable          # check that it names every file it changed
asdf plugin remove tsc-rs        # also removes the installed tsc-rs versions
rm -rf ~/.local/share/asdf-tsc-rs
```

Delete `~/.local/share/asdf-tsc-rs` (or `$XDG_DATA_HOME/asdf-tsc-rs`) only after `disable`, and
after restarting shells and sessions that were started with the redirect: node refuses to start while
`NODE_OPTIONS` requires a file that no longer exists.

## Differences from TypeScript 5

These differences show up when existing projects move from TypeScript 5.9 to tsc-rs 0.8.0:
- **`@types` packages:** they are no longer included automatically. Errors such as TS2591
  ("Cannot find name 'process'") usually need `"types": ["node"]` in `tsconfig.json`.
- **Side-effect imports:** imports such as `import './globals.css'` are checked (TS2882). A
  `declare module '*.css';` file fixes them.
- **Exit code:** `tsc -b` exits 2 on type errors, where 5.9 exits 1.
- **`rootDir` layout:** without `rootDir`, the output layout can differ (TS5011).
- **Source maps:** they differ. The emitted `.js` and `.d.ts` matched on the projects compared.

## How the install is verified

- The plugin downloads `tsc-rs-<version>-<os>-<arch>.tar.gz` and the release's `SHA256SUMS`, and
  refuses an archive that is missing from `SHA256SUMS` or doesn't match it.
- It also checks the archive against [`checksums`](checksums), pinned in this repository. That
  catches a release that was replaced after publication, which a `SHA256SUMS` from the same
  release can't. A version with no pinned checksum installs with a notice.
- It refuses archives containing absolute paths, `..` segments or links, and removes a failed
  install instead of leaving half of it.
- The upstream archive is installed unchanged in `libexec/`, with the `tsc` executable next to its
  `lib.*.d.ts` files. `bin/tsc-rs` is a symlink to it.

## Development

```bash
test/run.sh [work-dir]               # end-to-end tests in an isolated asdf, HOME and data dir
scripts/pin-release.sh 0.9.0         # pin a new upstream release's checksums
```

The tests need node, npm and pnpm, and use bun, zsh and fish when present. They download from
GitHub and the npm registry, and never touch your own profiles or settings.

## License

[MIT](LICENSE). tsc-rs itself is MIT-licensed by its authors.
