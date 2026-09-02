#!/bin/bash
# Shared logging and command helpers for OSL smoke scripts.

log() { echo "==> $*"; }

die() { echo "Error: $*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}
