#!/usr/bin/env bash
# asdf < 0.16 looks for command-<name>.bash.
exec "$(dirname "${BASH_SOURCE[0]}")/command-enable" "$@"
