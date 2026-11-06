'use strict';
// asdf-tsc-rs redirect: runs tsc-rs wherever node would run the upstream TypeScript CLI.
//
// Loaded into every node process through NODE_OPTIONS=--require <this file>
// (set up by `asdf cmd tsc-rs enable`). When the process entry script is the
// upstream TypeScript CLI (`typescript/bin/tsc`, `typescript/lib/tsc.js` or
// `typescript/lib/_tsc.js`), however it was reached (node_modules/.bin/tsc,
// npm/pnpm/yarn/bun scripts, npx, pnpm exec, `node .../tsc`), it runs tsc-rs
// instead, with the same arguments, working directory, environment and stdio.
// It forwards termination signals and mirrors tsc-rs's exit code or signal.
// Every other node process is left alone after a string check, and
// `require("typescript")` is never redirected.
//
// Version: chosen exactly as asdf chooses it for the tsc-rs plugin:
//   1. ASDF_TSC_RS_VERSION
//   2. the nearest .tool-versions (ASDF_TOOL_VERSIONS_FILENAME) from the working
//      directory upwards, walking $PWD as asdf does when it names the same directory
//   3. the one in the home directory
// Each source may list several versions; the first installed one is used.
// "system" runs the upstream compiler; "path:<absolute dir>" runs <dir>/bin/tsc-rs.
//
// Opt-out:  TSC_RS=typescript runs the upstream compiler for that command.
// Failure:  no version, or a version that is not installed, exits 127 with the
//           command that fixes it. There is no silent fallback.
// Logging:  TSC_RS_LOG=<file> appends one JSON line per intercepted run.
// Bypass:   a command that *replaces* NODE_OPTIONS drops this preload. Append instead.
// Source:   https://github.com/Brandon-Gottshall/asdf-tsc-rs

(function tscRsProxy() {
  const entry = process.argv[1];
  if (!entry || entry.indexOf('tsc') === -1) return;
  // `node -e/-p/-i` treats argv[1] as data, not as the program.
  const ev = process.execArgv;
  for (let i = 0; i < ev.length; i++) {
    if (/^(-e|--eval|-p|--print|-i|--interactive)(=|$)/.test(ev[i])) return;
  }

  const fs = require('fs');
  const path = require('path');
  const os = require('os');
  let real = entry;
  try { real = fs.realpathSync(entry); } catch (_) { /* keep as given */ }
  if (!/[\\/]typescript[\\/](bin[\\/]tsc|lib[\\/]_?tsc\.js)$/.test(real)) return;
  // Another copy of a tsc redirect already took this run (it stubs the entry
  // module before spawning); running a second compiler would double the work.
  if (require.cache[real]) return;

  const env = process.env;
  const started = Date.now();
  const args = process.argv.slice(2);
  const record = {
    ts: new Date(started).toISOString(),
    pid: process.pid,
    ppid: process.ppid,
    cwd: process.cwd(),
    entry,
    entry_real: real,
    argc: args.length,
    argv: args.length > 40 ? args.slice(0, 40).concat([`...(${args.length - 40} more)`]) : args,
  };
  const logFile = env.TSC_RS_LOG || null;
  const log = (extra) => {
    if (!logFile) return;
    try {
      fs.mkdirSync(path.dirname(logFile), { recursive: true });
      try { if (fs.statSync(logFile).size > 5 * 1024 * 1024) fs.renameSync(logFile, logFile + '.1'); } catch (_) {}
      fs.appendFileSync(logFile, JSON.stringify(Object.assign(record, extra)) + '\n');
    } catch (_) { /* logging never changes the compile result */ }
  };
  const fail = (code, reason, message) => {
    process.stderr.write('tsc-rs: ' + message + '\n');
    log({ selected: 'tsc-rs', outcome: 'failed', reason, exit: code, ms: Date.now() - started });
    process.exit(code);
  };
  const passthrough = (why) => {
    let version = null;
    try { version = JSON.parse(fs.readFileSync(path.join(path.dirname(real), '..', 'package.json'), 'utf8')).version; } catch (_) {}
    record.selected = 'typescript';
    record.selected_by = why;
    record.typescript_version = version;
    process.on('exit', (code) => log({ outcome: 'passthrough', exit: code, ms: Date.now() - started }));
  };
  const OPT_OUT = 'or run this command with TSC_RS=typescript to use the TypeScript it would normally run.';

  const choice = env.TSC_RS || 'tsc-rs';
  if (choice === 'typescript') return passthrough('TSC_RS');
  if (choice !== 'tsc-rs') {
    fail(64, 'bad-selection', `TSC_RS="${choice}" is not supported; use "tsc-rs" (the default) or "typescript".`);
  }
  if (env.TSC_RS_PROXY_ACTIVE === '1') {
    fail(70, 'recursion', `refusing to redirect ${real} again from inside a tsc-rs run; ` +
      'the selected tsc-rs binary appears to run the upstream TypeScript CLI.');
  }

  // Version resolution, matching asdf (internal/resolve/resolve.go).
  const toolVersionsName = env.ASDF_TOOL_VERSIONS_FILENAME || env.ASDF_DEFAULT_TOOL_VERSIONS_FILENAME || '.tool-versions';
  const split = (s) => s.split(/\s+/).filter(Boolean);
  const fromFile = (dir) => {
    const file = path.join(dir, toolVersionsName);
    let text;
    try { text = fs.readFileSync(file, 'utf8'); } catch (_) { return null; }
    for (const line of text.split('\n')) {
      const tokens = split(line.split('#')[0]);
      if (tokens.length > 1 && tokens[0] === 'tsc-rs') return { versions: tokens.slice(1), source: file };
    }
    return null;
  };
  // asdf (Go's os.Getwd) starts from $PWD when it names the working directory,
  // so a project reached through a symlink uses the .tool-versions above the link.
  let start = record.cwd;
  if (env.PWD && env.PWD !== start && path.isAbsolute(env.PWD)) {
    try { if (fs.realpathSync(env.PWD) === fs.realpathSync(start)) start = env.PWD; } catch (_) {}
  }
  const dataDir = env.ASDF_DATA_DIR || path.join(os.homedir(), '.asdf');
  // When the plugin itself is gone, the fix is to remove the redirect, not to install.
  const removedHint = () => fs.existsSync(path.join(dataDir, 'plugins', 'tsc-rs')) ? null :
    'the tsc-rs asdf plugin is not installed (was it removed?), but NODE_OPTIONS still loads ' + __filename +
    '. Remove the asdf-tsc-rs block from your shell profile, or that --require from NODE_OPTIONS, ' +
    'or run this command with TSC_RS=typescript.';
  let found = null;
  if (env.ASDF_TSC_RS_VERSION) {
    found = { versions: split(env.ASDF_TSC_RS_VERSION), source: 'ASDF_TSC_RS_VERSION' };
  } else {
    let dir = start;
    for (;;) {
      found = fromFile(dir);
      if (found) break;
      const parent = path.dirname(dir);
      if (parent === dir) { found = fromFile(os.homedir()); break; }
      dir = parent;
    }
  }
  if (!found || found.versions.length === 0) {
    if (removedHint()) fail(127, 'plugin-removed', removedHint());
    fail(127, 'no-version',
      `no tsc-rs version is set for ${record.cwd}. Set one with "asdf set tsc-rs <version>" ` +
      '(this directory) or "asdf set -u tsc-rs <version>" (everywhere), then "asdf install tsc-rs <version>"; ' + OPT_OUT);
  }
  record.versions = found.versions;
  record.version_source = found.source;

  let bin = null;
  for (const v of found.versions) {
    if (v === 'system') {
      record.version = 'system';
      return passthrough('system');
    }
    if (v.startsWith('ref:')) {
      fail(127, 'unsupported-version', `"${v}" (from ${found.source}) is not supported; the tsc-rs plugin installs released versions only.`);
    }
    // A relative path: or a version naming another directory would let any
    // parent .tool-versions run an arbitrary binary; asdf versions are plain names.
    if (v.startsWith('path:') && !path.isAbsolute(v.slice(5))) {
      fail(127, 'unsupported-version', `"${v}" (from ${found.source}) is not supported; path: versions must be absolute.`);
    }
    if (!v.startsWith('path:') && (/[\\/]/.test(v) || v === '.' || v === '..')) {
      fail(127, 'unsupported-version', `"${v}" (from ${found.source}) is not a valid tsc-rs version.`);
    }
    const candidate = v.startsWith('path:')
      ? path.join(v.slice(5), 'bin', 'tsc-rs')
      : path.join(dataDir, 'installs', 'tsc-rs', v, 'bin', 'tsc-rs');
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      bin = candidate;
      record.version = v;
      break;
    } catch (_) { /* try the next listed version, as asdf does */ }
  }
  if (!bin) {
    if (removedHint()) fail(127, 'plugin-removed', removedHint());
    const v = found.versions[0];
    fail(127, 'not-installed',
      `tsc-rs ${found.versions.join(' ')} (from ${found.source}) is not installed. ` +
      (v.startsWith('path:') ? `Expected an executable at ${path.join(v.slice(5), 'bin', 'tsc-rs')}; ` : `Install it with "asdf install tsc-rs ${v}"; `) +
      OPT_OUT);
  }
  record.bin = bin;
  try { record.bin_real = fs.realpathSync(bin); } catch (_) {}

  // Stop the upstream CLI from running as this process's main module: the entry
  // is CommonJS, and a loaded cache entry for it makes node skip executing it.
  const stub = new (require('module'))(real);
  stub.filename = real;
  stub.loaded = true;
  require.cache[real] = stub;

  const child = require('child_process').spawn(bin, args, {
    stdio: 'inherit',
    env: Object.assign({}, env, { TSC_RS_PROXY_ACTIVE: '1' }),
  });
  const forward = ['SIGINT', 'SIGTERM', 'SIGHUP', 'SIGQUIT', 'SIGUSR1', 'SIGUSR2'];
  for (const sig of forward) process.on(sig, () => { try { child.kill(sig); } catch (_) {} });
  child.on('error', (err) => fail(127, 'spawn-error', `could not run ${bin}: ${err.message}`));
  child.on('exit', (code, signal) => {
    log({ selected: 'tsc-rs', outcome: 'ran', exit: code, signal: signal || null, ms: Date.now() - started });
    if (signal) {
      for (const sig of forward) process.removeAllListeners(sig);
      try { process.kill(process.pid, signal); } catch (_) {}
      const num = os.constants.signals[signal];
      process.exit(num ? 128 + num : 1); // reached for signals node ignores (e.g. SIGPIPE)
    }
    process.exit(code === null ? 1 : code);
  });
})();
