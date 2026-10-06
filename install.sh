#!/usr/bin/env bash
# install.sh - copy the repository's etc/ and usr/ trees onto the system root.
#
# Run it from anywhere:  sudo /path/to/repo/install.sh [--dry-run] [--force]
#
# Behaviour:
#   - usr/*  files are installed/overwritten (the repo is the source of truth).
#   - etc/*  files that already exist and differ are NOT overwritten; the repo
#            version is written next to them as <file>.new (like pacman's
#            .pacnew). With --force the old file is saved as <file>.bak and
#            then replaced.
#   - File modes are taken from the repo (git keeps the executable bit).
#   - Only regular files are copied; .gitkeep files are skipped.
set -Eeuo pipefail

SRC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="/"
DIRS=(etc usr)
dry_run=false
force=false

n_new=0 n_updated=0 n_same=0 n_pending=0 n_backup=0

log_info()    { echo -e "\033[1;32m==>\033[0m $*"; }
log_warning() { echo -e "\033[1;33mWARNING: $*\033[0m" >&2; }
log_error()   { echo -e "\033[1;31mERROR: $*\033[0m" >&2; }

trap 'log_error "Unexpected failure at line $LINENO: $BASH_COMMAND"' ERR

usage() {
    cat <<EOF
Usage: ${0##*/} [options]

  -n, --dry-run    show what would be done, change nothing
  -f, --force      replace differing files under etc/ (old one saved as .bak)
  -r, --root DIR   install into DIR instead of / (staging or testing)
  -h, --help       show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run) dry_run=true ;;
        -f|--force)   force=true ;;
        -r|--root)
            if [[ $# -lt 2 ]]; then
                log_error "--root needs a directory"
                exit 1
            fi
            ROOT="$2"
            shift
            ;;
        -h|--help)    usage; exit 0 ;;
        *)            log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
done

ROOT="${ROOT%/}"
if [[ -z "$ROOT" ]]; then
    ROOT=""            # "/" -> paths become /etc/..., /usr/...
fi

if [[ -n "$ROOT" && ! -d "$ROOT" ]]; then
    log_error "Root directory does not exist: ${ROOT}"
    exit 1
fi

if [[ -z "$ROOT" && "$dry_run" == false && "$EUID" -ne 0 ]]; then
    log_error "Run as root (e.g. sudo $0), or use --dry-run / --root DIR"
    exit 1
fi

install_file() {
    local src="$1" dst="$2" mode="$3"
    local owner_args=()

    if [[ "$EUID" -eq 0 ]]; then
        owner_args=(-o root -g root)
    fi

    if [[ "$dry_run" == true ]]; then
        return 0
    fi
    install -D -m "$mode" "${owner_args[@]}" -- "$src" "$dst"
}

for d in "${DIRS[@]}"; do
    if [[ ! -d "${SRC}/${d}" ]]; then
        log_warning "Missing directory in repo, skipping: ${d}/"
        continue
    fi

    while IFS= read -r -d '' src; do
        rel="${src#"${SRC}"/}"
        dst="${ROOT}/${rel}"
        mode=$(stat -c '%a' "$src")
        # Scripts (shebang) must be executable even if the exec bit was lost
        # (zip download, filesystem without modes, ...)
        if [[ "$(head -c2 -- "$src")" == '#!' && ! -x "$src" ]]; then
            mode=755
        fi

        if [[ ! -e "$dst" ]]; then
            log_info "new       /${rel}"
            install_file "$src" "$dst" "$mode"
            n_new=$((n_new + 1))
        elif cmp -s -- "$src" "$dst"; then
            n_same=$((n_same + 1))
            # content equal; still make sure the mode matches the repo
            if [[ "$(stat -c '%a' "$dst")" != "$mode" && "$dry_run" == false ]]; then
                chmod "$mode" "$dst"
            fi
        elif [[ "$rel" == etc/* && "$force" == false ]]; then
            log_warning "exists    /${rel} differs -> wrote /${rel}.new (merge it by hand)"
            install_file "$src" "${dst}.new" "$mode"
            n_pending=$((n_pending + 1))
        else
            if [[ "$rel" == etc/* ]]; then
                log_info "replace   /${rel} (old saved as .bak)"
                if [[ "$dry_run" == false ]]; then
                    cp -a -- "$dst" "${dst}.bak"
                fi
                n_backup=$((n_backup + 1))
            else
                log_info "update    /${rel}"
            fi
            install_file "$src" "$dst" "$mode"
            n_updated=$((n_updated + 1))
        fi
    done < <(find "${SRC}/${d}" -type f ! -name '.gitkeep' -print0 | sort -z)
done

echo
if [[ "$dry_run" == true ]]; then
    log_info "Dry run, nothing was changed."
fi
log_info "new: ${n_new}, updated: ${n_updated}, unchanged: ${n_same}, pending .new: ${n_pending}, backed up: ${n_backup}"

if [[ "$n_pending" -gt 0 ]]; then
    log_warning "Review the *.new files, merge your changes, then delete them."
fi

cat <<EOF

Next steps (first install):
  sudo uki-pcr-setup.sh        # creates /etc/kernel/cmdline and the PCR keys
  sudoedit /etc/kernel-setup.conf
  sudo uki-build.sh --all      # first build
EOF
