#!/usr/bin/env bash
# uki-build.sh - build UKIs with dracut (+ ukify), with optional PCR signing,
# Secure Boot signing and fallback images. Configured by /etc/kernel-setup.conf.
#
# Pacman hook:  targets are read from stdin (hook needs NeedsTargets).
# Manual run:   uki-build.sh [--all|-a]   (rebuilds every kernel)
set -Eeuo pipefail
shopt -s extglob

CONFIG_FILE="/etc/kernel-setup.conf"

args=('--force' '--no-hostonly-cmdline' '-L' '3')

# Built-in full-rebuild triggers (package names or paths without a leading slash).
# More can be added with trigger_patterns in the config file.
TRIGGER_PATTERNS=(
    'dracut'
    'systemd'
    'systemd-ukify'
    'btrfs-progs'
    'e2fsprogs'
    'dosfstools'
    'amd-ucode'
    'intel-ucode'
    'linux-firmware'
    'grub'
)

declare -A conf=()          # "table.key" -> value, filled by load_config
declare -A to_build=()      # pkgbase -> newest kver
built=()
failed=()
trigger_full_rebuild=false

log_error() {
    echo -e "\033[1;31mERROR: $*\033[0m" >&2
}

log_warning() {
    echo -e "\033[1;33mWARNING: $*\033[0m" >&2
}

trap 'log_error "Unexpected failure at line $LINENO: $BASH_COMMAND"' ERR

usage() {
    cat <<EOF
Usage: ${0##*/} [--all|-a]

  (no option)  from a terminal: rebuild all UKIs; from a pacman hook: build
               what the transaction targets require
  --all, -a    rebuild all UKIs (also works from cron/systemd)
  --help, -h   show this help

Configuration: ${CONFIG_FILE}
EOF
}

# ---------------------------------------------------------------------------
# Config (TOML subset: [table], key = "string" | true/false, # comments)
# The file is parsed, never sourced or eval'd.
# ---------------------------------------------------------------------------
load_config() {
    local line section="" key val

    if [[ ! -r "$CONFIG_FILE" ]]; then
        return 0
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"                              # strip comments (no '#' inside values)
        line="${line#"${line%%[![:space:]]*}"}"         # trim leading whitespace
        line="${line%"${line##*[![:space:]]}"}"         # trim trailing whitespace
        if [[ -z "$line" ]]; then
            continue
        fi

        if [[ "$line" =~ ^\[([A-Za-z0-9_.-]+)\]$ ]]; then
            section="${BASH_REMATCH[1]}."
        elif [[ "$line" =~ ^([A-Za-z0-9_-]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            val="${val#\"}"; val="${val%\"}"            # strip surrounding quotes
            conf["${section}${key}"]="$val"
        else
            log_warning "Ignoring unparsable line in ${CONFIG_FILE}: ${line}"
        fi
    done < "$CONFIG_FILE"

    return 0
}

# conf_bool <table.key> <default>  -> exit status 0 if true
conf_bool() {
    local key="$1" default="$2" v
    v="${conf[$key]:-$default}"

    case "${v,,}" in
        true|yes|on|1)  return 0 ;;
        false|no|off|0) return 1 ;;
        *)
            log_warning "Invalid boolean for ${key}: '${v}', using default (${default})"
            if [[ "$default" == true ]]; then
                return 0
            fi
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Prints /proc/cmdline without BOOT_IMAGE= and initrd= (added by the bootloader).
# Returns 1 if /proc/cmdline is unreadable or nothing is left after cleaning.
clean_proc_cmdline() {
    local raw="" word
    local words=() kept=()

    if [[ ! -r /proc/cmdline ]]; then
        return 1
    fi

    read -r raw < /proc/cmdline || true
    read -ra words <<< "$raw" || true

    for word in "${words[@]}"; do
        case "$word" in
            BOOT_IMAGE=*|initrd=*) continue ;;
        esac
        kept+=("$word")
    done

    if [[ "${#kept[@]}" -eq 0 ]]; then
        return 1
    fi

    printf '%s\n' "${kept[*]}"
    return 0
}

# Keep only the newest version per pkgbase
add_kernel() {
    local pkgbase="$1" kver="$2"
    local current="${to_build[$pkgbase]:-}"

    if [[ -z "$current" ]]; then
        to_build["$pkgbase"]="$kver"
    elif [[ "$(printf '%s\n%s\n' "$current" "$kver" | sort -V | tail -n1)" == "$kver" ]]; then
        to_build["$pkgbase"]="$kver"
    fi
    return 0
}

# Sign an existing EFI binary in place for Secure Boot (plain dracut path only;
# the ukify path signs while building).
sign_secureboot() {
    local file="$1"
    local signed="${file}.signed"

    echo "==> Signing ${file##*/} for Secure Boot..."
    if sbsign --key "$sb_key" --cert "$sb_cert" --output "$signed" "$file" </dev/null 2>&1 | sed 's/^/\t/'; then
        mv -f -- "$signed" "$file" || return 1
        return 0
    fi

    rm -f -- "$signed"
    return 1
}

# Plain UKI: dracut builds the whole thing
build_plain() {
    local kver="$1" out="$2"

    dracut "${args[@]}" --uefi "$out" --kver "$kver" </dev/null 2>&1 | sed 's/^/\t/'
}

# PCR-signed UKI: dracut builds only the initramfs, ukify assembles + signs
build_pcr_signed() {
    local kver="$1" out="$2"
    local vmlinuz="/usr/lib/modules/${kver}/vmlinuz"
    local cmdline_file="" workdir initrd rc=1

    if [[ ! -f "$vmlinuz" ]]; then
        log_error "Kernel image not found: ${vmlinuz}"
        return 1
    fi

    workdir=$(mktemp -d /var/tmp/uki-build.XXXXXX) || return 1
    initrd="${workdir}/initramfs.img"

    # Kernel command line: /etc/kernel/cmdline, then /usr/lib/kernel/cmdline,
    # then (last resort) the cleaned /proc/cmdline
    if [[ -f /etc/kernel/cmdline ]]; then
        cmdline_file="/etc/kernel/cmdline"
    elif [[ -f /usr/lib/kernel/cmdline ]]; then
        cmdline_file="/usr/lib/kernel/cmdline"
    else
        log_warning "No /etc/kernel/cmdline or /usr/lib/kernel/cmdline found, falling back to /proc/cmdline"
        log_warning "It reflects the CURRENT boot (BOOT_IMAGE= and initrd= are removed). Run uki-pcr-setup.sh to create /etc/kernel/cmdline."

        if clean_proc_cmdline > "${workdir}/cmdline"; then
            cmdline_file="${workdir}/cmdline"
        else
            log_error "Could not build a kernel command line from /proc/cmdline (unreadable or empty)"
            rm -rf -- "$workdir"
            return 1
        fi
    fi

    local dracut_args=(
        '--force'
        '--hostonly'
        '--early-microcode'
        '--no-hostonly-cmdline'
        '-L' '3'
    )

    local ukify_args=(
        build
        --linux="$vmlinuz"
        --initrd="$initrd"
        --cmdline="@${cmdline_file}"
        --uname="$kver"
        --os-release="@/etc/os-release"
        --sign-initrd-pcrs
        --pcr-private-key="$pcr_priv"
        --pcr-public-key="$pcr_pub"
        --phases="$pcr_phases"
        --pcr-banks=sha256
        --output="$out"
    )

    if [[ "$enable_secureboot" == true ]]; then
        ukify_args+=(
            --secureboot-private-key="$sb_key"
            --secureboot-certificate="$sb_cert"
        )
    fi

    echo "==> Building initramfs for ${kver}..."
    if dracut "${dracut_args[@]}" "$initrd" --kver "$kver" </dev/null 2>&1 | sed 's/^/\t/'; then
        echo "==> Assembling PCR-signed UKI with ukify..."
        if ukify "${ukify_args[@]}" </dev/null 2>&1 | sed 's/^/\t/'; then
            rc=0
        fi
    fi

    rm -rf -- "$workdir"
    return "$rc"
}

uki_build() {
    local pkgbase="$1" kver="$2"
    local outfile="${outdir}/${pkgbase}.efi"
    local fallback="${outdir}/${pkgbase}-fallback.efi"
    local tmpfile="${outdir}/${pkgbase}.new.efi"
    local oldver="" ok=false

    if [[ -f "$outfile" ]] && command -v objcopy >/dev/null 2>&1; then
        oldver=$(objcopy -O binary --only-section=.uname "$outfile" /dev/stdout 2>/dev/null | tr -d '\0' || true)
    fi

    echo "==> Building UKI for ${pkgbase} (${kver})..."
    rm -f -- "$tmpfile"

    if [[ "$enable_pcr_signing" == true ]]; then
        echo "==> PCR signing enabled, building signed UKI"
        if build_pcr_signed "$kver" "$tmpfile"; then ok=true; fi
    else
        if build_plain "$kver" "$tmpfile"; then
            if [[ "$enable_secureboot" == true ]]; then
                if sign_secureboot "$tmpfile"; then ok=true; fi
            else
                ok=true
            fi
        fi
    fi

    if [[ "$ok" == false ]]; then
        log_error "Failed to build UKI for ${pkgbase} (${kver})"
        rm -f -- "$tmpfile"
        failed+=("$pkgbase")
        return 0
    fi

    # Save the previous UKI as fallback, only when the kernel version changed
    if [[ "$enable_fallback" == true && -f "$outfile" && "$oldver" != "$kver" ]]; then
        echo "==> Saving previous UKI as ${fallback}"
        if ! cp -f -- "$outfile" "$fallback"; then
            log_error "Could not create fallback for ${pkgbase}; keeping existing image"
            rm -f -- "$tmpfile"
            failed+=("$pkgbase")
            return 0
        fi
    fi

    if mv -f -- "$tmpfile" "$outfile"; then
        echo "==> UKI file built at ${outfile} for version ${kver}"
        built+=("$pkgbase")
    else
        log_error "Could not move new UKI into place for ${pkgbase}"
        rm -f -- "$tmpfile"
        failed+=("$pkgbase")
    fi

    return 0
}

# Abort before touching anything if an enabled feature is missing its prerequisites
validate_config() {
    local bad=false

    if [[ "$enable_pcr_signing" == true ]]; then
        if [[ ! -f "$pcr_pub" || ! -f "$pcr_priv" ]]; then
            log_error "pcr_signing is enabled but PCR keys are missing (${pcr_pub}, ${pcr_priv}). Run uki-pcr-setup.sh"
            bad=true
        fi
        if ! command -v ukify >/dev/null 2>&1; then
            log_error "pcr_signing is enabled but ukify was not found (install systemd-ukify)"
            bad=true
        fi
    fi

    if [[ "$enable_secureboot" == true ]]; then
        if [[ ! -f "$sb_key" || ! -f "$sb_cert" ]]; then
            log_error "secureboot is enabled but key/certificate are missing (${sb_key}, ${sb_cert})"
            bad=true
        fi
        if [[ "$enable_pcr_signing" == false ]] && ! command -v sbsign >/dev/null 2>&1; then
            log_error "secureboot is enabled but sbsign was not found (install sbsigntools)"
            bad=true
        fi
    fi

    if [[ "$bad" == true ]]; then
        exit 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

load_config

outdir="${conf[uki.outdir]:-/boot}"
outdir="${outdir%/}"                       # drop a trailing slash
if [[ -z "$outdir" || ! -d "$outdir" ]]; then
    log_error "outdir '${outdir}' is not a directory (check ${CONFIG_FILE})"
    exit 1
fi

enable_fallback=false
if conf_bool uki.fallback false; then enable_fallback=true; fi

enable_pcr_signing=false
if conf_bool uki.pcr_signing false; then enable_pcr_signing=true; fi

enable_secureboot=false
if conf_bool uki.secureboot false; then enable_secureboot=true; fi

pcr_pub="${conf[uki.pcr_public_key]:-/etc/systemd/tpm2-pcr-public-key.pem}"
pcr_priv="${conf[uki.pcr_private_key]:-/etc/systemd/tpm2-pcr-private-key.pem}"

default_phases="enter-initrd,enter-initrd:leave-initrd,enter-initrd:leave-initrd:sysinit,enter-initrd:leave-initrd:sysinit:ready"
pcr_phases="${conf[uki.pcr_phases]:-$default_phases}"
pcr_phases="${pcr_phases//[[:space:]]/}"   # tolerate spaces after commas
if [[ -z "$pcr_phases" ]]; then
    pcr_phases="$default_phases"
fi

sb_key="${conf[uki.secureboot_private_key]:-/var/lib/sbctl/keys/db/db.key}"
sb_cert="${conf[uki.secureboot_certificate]:-/var/lib/sbctl/keys/db/db.pem}"

# Append user-defined trigger patterns from the config
extra_patterns="${conf[uki.trigger_patterns]:-}"
if [[ -n "$extra_patterns" ]]; then
    IFS=',' read -ra extra_list <<< "$extra_patterns" || true
    for pattern in "${extra_list[@]}"; do
        pattern="${pattern//[[:space:]]/}"          # strip whitespace
        pattern="${pattern#/}"                      # pacman paths have no leading slash
        if [[ -z "$pattern" ]]; then
            continue
        fi
        already=false
        for existing in "${TRIGGER_PATTERNS[@]}"; do
            if [[ "$existing" == "$pattern" ]]; then
                already=true
                break
            fi
        done
        if [[ "$already" == false ]]; then
            TRIGGER_PATTERNS+=("$pattern")
        fi
    done
fi

# ---------------------------------------------------------------------------
# Work out what to build
# ---------------------------------------------------------------------------

# Manual run: terminal on stdin, or --all / -a
manual_run=false
if [[ "${1:-}" == "--all" || "${1:-}" == "-a" || -t 0 ]]; then
    manual_run=true
fi

if [[ "$manual_run" == true && "$EUID" -ne 0 ]]; then
    log_error "Run as root (e.g. sudo $0 --all)"
    exit 1
fi

targets_read=0

# Read ALL pacman targets (no early break, so the pipe is fully drained)
if [[ "$manual_run" == false ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        targets_read=$((targets_read + 1))    # not ((x++)): that returns 1 at 0 and trips set -e

        if [[ "$line" == 'usr/lib/modules/'+([^/])'/pkgbase' ]]; then
            if [[ -f "/${line}" ]]; then
                kver="${line#usr/lib/modules/}"
                kver="${kver%/pkgbase}"
                pkgbase=$(<"/${line}")
                add_kernel "$pkgbase" "$kver"
            fi
            continue
        fi

        if [[ "$trigger_full_rebuild" == false ]]; then
            for pattern in "${TRIGGER_PATTERNS[@]}"; do
                if [[ "$line" == $pattern ]]; then
                    trigger_full_rebuild=true
                    break
                fi
            done
        fi
    done

    # No targets at all: not called by pacman, treat as a manual run
    if [[ "$targets_read" -eq 0 ]]; then
        manual_run=true
    fi
fi

if [[ "$manual_run" == true ]]; then
    echo "==> Manual run, rebuilding all UKIs"
    trigger_full_rebuild=true
fi

# Full rebuild: add every installed kernel (same pkgbase => collapsed to newest)
if [[ "$trigger_full_rebuild" == true ]]; then
    echo "==> Full rebuild triggered, building UKI for all kernels..."

    for dir in /usr/lib/modules/*; do
        if [[ -d "$dir" && -f "$dir/pkgbase" ]]; then
            pkgbase=$(<"$dir/pkgbase")
            add_kernel "$pkgbase" "${dir#/usr/lib/modules/}"
        fi
    done
fi

if [[ "${#to_build[@]}" -gt 0 ]]; then
    validate_config
fi

# Build one UKI per pkgbase
for pkgbase in "${!to_build[@]}"; do
    uki_build "$pkgbase" "${to_build[$pkgbase]}"
done

# Update grub.cfg
if [[ "${#built[@]}" -gt 0 ]]; then
    echo "==> Regenerating GRUB menu..."
    if ! grub-mkconfig -o /boot/grub/grub.cfg </dev/null 2>&1 | sed 's/^/\t/'; then
        log_error "grub-mkconfig failed"
        failed+=("grub-mkconfig")
    fi
else
    echo "==> No kernel image rebuilding is required."
fi

if [[ "${#failed[@]}" -gt 0 ]]; then
    log_error "The following steps failed: ${failed[*]}"
    exit 1
fi

exit 0
