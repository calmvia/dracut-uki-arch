#!/usr/bin/env bash
# uki-pcr-setup.sh - prepare PCR signing for uki-build.sh
#
#  1. Creates /etc/kernel/cmdline
#       from the arguments, else from stdin, else from /proc/cmdline
#       (BOOT_IMAGE= and initrd= removed).
#  2. Creates the PCR signing key pair (RSA 2048) in the locations used by
#     /etc/kernel-setup.conf (default: /etc/systemd/tpm2-pcr-*-key.pem).
#
# Examples:
#   sudo uki-pcr-setup.sh
#   sudo uki-pcr-setup.sh "root=UUID=... rw quiet loglevel=3"
#   echo "root=UUID=... rw" | sudo uki-pcr-setup.sh
set -Eeuo pipefail

CONFIG_FILE="/etc/kernel-setup.conf"
CMDLINE_FILE="/etc/kernel/cmdline"
DRACUT_CMDLINE_FILE="/etc/dracut.conf.d/cmdline.conf"

force_cmdline=false
force_keys=false
assume_yes=false
cmdline_args=()

log_info()    { echo -e "\033[1;32m==>\033[0m $*"; }
log_warning() { echo -e "\033[1;33mWARNING: $*\033[0m" >&2; }
log_error()   { echo -e "\033[1;31mERROR: $*\033[0m" >&2; }

trap 'log_error "Unexpected failure at line $LINENO: $BASH_COMMAND"' ERR

usage() {
    cat <<EOF
Usage: ${0##*/} [options] [kernel command line...]

Options:
  --force-cmdline   overwrite an existing ${CMDLINE_FILE} (a .bak copy is kept)
  --force-keys      regenerate existing PCR keys (old ones are backed up).
                    This invalidates TPM2 slots enrolled against the old key!
  -y, --yes         do not ask for confirmation
  -h, --help        show this help

Command line source: arguments, else stdin, else /proc/cmdline.
EOF
}

# conf_get <key> <default>: read a string value from the [uki] table
conf_get() {
    local key="$1" default="$2" v=""

    if [[ -r "$CONFIG_FILE" ]]; then
        v=$(sed -n -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"?([^\"#]*)\"?.*$/\1/p" "$CONFIG_FILE" | head -n1 || true)
        v="${v%"${v##*[![:space:]]}"}"
    fi

    echo "${v:-$default}"
}

# Collapse whitespace and trim
normalize() {
    local s="$*"
    s="${s//$'\n'/ }"
    s="${s//$'\t'/ }"
    s=$(printf '%s' "$s" | tr -s ' ')
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

confirm() {
    local answer=""
    if [[ "$assume_yes" == true ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        log_error "Confirmation needed but stdin is not a terminal; use --yes"
        return 1
    fi
    read -r -p "$1 [y/N] " answer || true
    [[ "${answer,,}" == y || "${answer,,}" == yes ]]
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force-cmdline) force_cmdline=true ;;
        --force-keys)    force_keys=true ;;
        -y|--yes)        assume_yes=true ;;
        -h|--help)       usage; exit 0 ;;
        --)              shift; cmdline_args+=("$@"); break ;;
        *)               cmdline_args+=("$1") ;;
    esac
    shift
done

if [[ "$EUID" -ne 0 ]]; then
    log_error "Run as root (e.g. sudo $0)"
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Kernel command line
# ---------------------------------------------------------------------------
setup_cmdline() {
    local cmdline="" source="" stamp
    local cmdline_file_present=false

    if [[ -e "$CMDLINE_FILE" && -e "$DRACUT_CMDLINE_FILE"  && "$force_cmdline" == false ]]; then
        log_info "${CMDLINE_FILE} already exists, keeping it (use --force-cmdline to replace)"
        return 0
    fi

    if [[ "${#cmdline_args[@]}" -gt 0 ]]; then
        cmdline=$(normalize "${cmdline_args[*]}")
        source="arguments"
    elif [[ ! -t 0 ]]; then
        cmdline=$(normalize "$(cat || true)")
        source="stdin"
    fi

    if [[ -z "$cmdline" ]]; then
        local raw word kept=()
        local words=()
        if [[ ! -r /proc/cmdline ]]; then
            log_error "No command line given and /proc/cmdline is unreadable"
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
        cmdline=$(normalize "${kept[*]:-}")
        source="/proc/cmdline"

        if [[ -z "$cmdline" ]]; then
            log_error "Nothing usable left in /proc/cmdline; pass the command line as arguments"
            return 1
        fi
        log_warning "Using /proc/cmdline of the CURRENT boot. One-off parameters (rescue options, a different root=) would be baked in. Review ${CMDLINE_FILE}."
    fi

    mkdir -p "$(dirname "$CMDLINE_FILE")"
    mkdir -p "$(dirname "$DRACUT_CMDLINE_FILE")"

    stamp=$(date +%Y%m%d-%H%M%S)
    if [[ -e "$CMDLINE_FILE" ]]; then
        cp -a -- "$CMDLINE_FILE" "${CMDLINE_FILE}.bak.${stamp}"
        log_info "Backed up existing file to ${CMDLINE_FILE}.bak.${stamp}"
    fi
    if [[ -e "$DRACUT_CMDLINE_FILE" ]]; then
        cp -a -- "$DRACUT_CMDLINE_FILE" "${DRACUT_CMDLINE_FILE}.bak.${stamp}"
        log_info "Backed up existing file to ${CMDLINE_FILE}.bak.${stamp}"
    fi

    printf '%s\n' "$cmdline" > "$CMDLINE_FILE"
    printf 'kernel_cmdline="%s"\n' "$cmdline" > "$DRACUT_CMDLINE_FILE"
    chmod 644 "$CMDLINE_FILE" "$DRACUT_CMDLINE_FILE"
    log_info "Wrote ${CMDLINE_FILE} (from ${source}):"
    echo "    ${cmdline}"
}

# ---------------------------------------------------------------------------
# 2. PCR signing keys
# ---------------------------------------------------------------------------
setup_keys() {
    local pub priv stamp

    pub=$(conf_get pcr_public_key  /etc/systemd/tpm2-pcr-public-key.pem)
    priv=$(conf_get pcr_private_key /etc/systemd/tpm2-pcr-private-key.pem)

    if ! command -v openssl >/dev/null 2>&1; then
        log_error "openssl not found"
        return 1
    fi

    if [[ -e "$pub" || -e "$priv" ]]; then
        if [[ "$force_keys" == false ]]; then
            if [[ -e "$pub" && -e "$priv" ]]; then
                log_info "PCR keys already exist, keeping them (use --force-keys to regenerate):"
                echo "    ${pub}"
                echo "    ${priv}"
                chmod 600 "$priv"
                chmod 644 "$pub"
                return 0
            fi
            log_error "Only one of the PCR key files exists (${pub}, ${priv}). Fix this or use --force-keys"
            return 1
        fi

        log_warning "Regenerating the PCR keys invalidates every TPM2 slot enrolled against the old public key."
        log_warning "Keep a passphrase or recovery key slot, and re-enroll afterwards."
        if ! confirm "Replace the existing PCR keys?"; then
            log_info "Aborted, keys unchanged"
            return 0
        fi

        stamp=$(date +%Y%m%d-%H%M%S)
        if [[ -e "$pub" ]]; then cp -a -- "$pub" "${pub}.bak.${stamp}"; fi
        if [[ -e "$priv" ]]; then cp -a -- "$priv" "${priv}.bak.${stamp}"; fi
        log_info "Old keys backed up with suffix .bak.${stamp}"
    fi

    mkdir -p "$(dirname "$pub")" "$(dirname "$priv")"

    (
        umask 077
        ukify genkey \
        --pcr-private-key=/etc/systemd/tpm2-pcr-private-key.pem \
        --pcr-public-key=/etc/systemd/tpm2-pcr-public-key.pem
    )
    chown root:root "$priv" "$pub"
    chmod 600 "$priv"
    chmod 644 "$pub"

    log_info "Created PCR signing keys:"
    echo "    private: ${priv} (0600)"
    echo "    public:  ${pub} (0644)"
}

setup_cmdline
setup_keys

pub_path=$(conf_get pcr_public_key /etc/systemd/tpm2-pcr-public-key.pem)

cat <<EOF

Next steps:
  1. Enable signing in ${CONFIG_FILE}:      pcr_signing = true
  2. Build the signed UKIs:                  sudo uki-build.sh --all
  3. Enroll your LUKS device (if used):
       sudo systemd-cryptenroll --tpm2-device=auto \\
            --tpm2-public-key=${pub_path} /dev/<luks-device>
     Keep a passphrase or recovery key slot as a fallback.
EOF
