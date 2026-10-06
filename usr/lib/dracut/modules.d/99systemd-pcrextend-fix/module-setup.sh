#!/bin/bash
# This file is part of dracut.
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Installs the systemd >= 262 TPM2 / PCR units: systemd-tpm2-setup(-early),
# pcrextend, pcrnvdone, pcrosseparator and the NvPCR definitions.

# Prerequisite check(s) for module.
check() {
    # systemd-255 renamed systemd-pcrphase to systemd-pcrextend, check for old and new location.
    if ! require_any_binary \
        "$systemdutildir"/systemd-pcrextend \
        "$systemdutildir"/systemd-pcrphase; then
        return 1
    fi

    return 0
}

# Module dependency requirements.
depends() {
    local deps="systemd"
    local module

    # optional dependencies
    for module in tpm2-tss; do
        module_check "$module" > /dev/null 2>&1
        if [[ $? == 255 ]]; then
            deps+=" $module"
        fi
    done

    echo "$deps"
    return 0
}

# Config adjustments before installing anything.
config() {
    add_dlopen_features+=" libsystemd-shared-*.so:libcrypto "
}

# Install the required file(s) and directories for the module in the initramfs.
install() {
    local unit

    inst_multiple -o \
        "$systemdutildir"/systemd-pcrphase \
        "$systemdutildir"/systemd-pcrextend \
        "$systemdutildir"/systemd-tpm2-setup \
        "$systemdsystemunitdir"/systemd-pcrphase-initrd.service \
        "$systemdsystemunitdir/systemd-pcrphase-initrd.service.d/*.conf" \
        "$systemdsystemunitdir"/systemd-tpm2-setup-early.service \
        "$systemdsystemunitdir/systemd-tpm2-setup-early.service.d/*.conf" \
        "$systemdsystemunitdir"/systemd-pcrnvdone.service \
        "$systemdsystemunitdir/systemd-pcrnvdone.service.d/*.conf" \
        "$systemdsystemunitdir"/systemd-pcrosseparator.service \
        "$systemdsystemunitdir/systemd-pcrosseparator.service.d/*.conf" \
        "$systemdsystemunitdir"/systemd-pcrextend.socket \
        "$systemdsystemunitdir/systemd-pcrextend.socket.d/*.conf" \
        "$systemdsystemunitdir"/systemd-pcrextend@.service \
        "$systemdsystemunitdir/systemd-pcrextend@.service.d/*.conf" \
        "$systemdsystemunitdir"/sockets.target.wants/systemd-pcrextend.socket \
        "$systemdsystemunitdir"/initrd.target.wants/systemd-pcrphase-initrd.service \
        "$systemdsystemunitdir"/sysinit.target.wants/systemd-tpm2-setup-early.service \
        "$systemdsystemunitdir"/sysinit.target.wants/systemd-pcrnvdone.service \
        "$systemdsystemunitdir"/sysinit.target.wants/systemd-pcrosseparator.service \
        "/usr/lib/nvpcr/*.nvpcr"

    # The host may not ship these enablement symlinks (they are not guaranteed
    # to exist outside an initrd), so create any that are missing.
    for unit in \
        systemd-tpm2-setup-early.service \
        systemd-pcrnvdone.service \
        systemd-pcrosseparator.service; do
        if [[ -e "$initdir$systemdsystemunitdir/$unit" \
            && ! -e "$initdir$systemdsystemunitdir/sysinit.target.wants/$unit" ]]; then
            mkdir -p "$initdir$systemdsystemunitdir/sysinit.target.wants"
            ln_r "$systemdsystemunitdir/$unit" \
                "$systemdsystemunitdir/sysinit.target.wants/$unit"
        fi
    done

    if [[ -e "$initdir$systemdsystemunitdir/systemd-pcrextend.socket" \
        && ! -e "$initdir$systemdsystemunitdir/sockets.target.wants/systemd-pcrextend.socket" ]]; then
        mkdir -p "$initdir$systemdsystemunitdir/sockets.target.wants"
        ln_r "$systemdsystemunitdir/systemd-pcrextend.socket" \
            "$systemdsystemunitdir/sockets.target.wants/systemd-pcrextend.socket"
    fi

    # Install the hosts local user configurations if enabled.
    if [[ $hostonly ]]; then
        inst_multiple -H -o \
            "$systemdsystemconfdir"/systemd-pcrphase-initrd.service \
            "$systemdsystemconfdir/systemd-pcrphase-initrd.service.d/*.conf" \
            "$systemdsystemconfdir"/systemd-tpm2-setup-early.service \
            "$systemdsystemconfdir/systemd-tpm2-setup-early.service.d/*.conf" \
            "$systemdsystemconfdir"/systemd-pcrnvdone.service \
            "$systemdsystemconfdir/systemd-pcrnvdone.service.d/*.conf" \
            "$systemdsystemconfdir"/systemd-pcrosseparator.service \
            "$systemdsystemconfdir/systemd-pcrosseparator.service.d/*.conf" \
            "$systemdsystemconfdir"/systemd-pcrextend.socket \
            "$systemdsystemconfdir/systemd-pcrextend.socket.d/*.conf" \
            "$systemdsystemconfdir"/systemd-pcrextend@.service \
            "$systemdsystemconfdir/systemd-pcrextend@.service.d/*.conf" \
            "$systemdsystemconfdir"/sockets.target.wants/systemd-pcrextend.socket \
            "$systemdsystemconfdir"/initrd.target.wants/systemd-pcrphase-initrd.service \
            "$systemdsystemconfdir"/sysinit.target.wants/systemd-tpm2-setup-early.service \
            "$systemdsystemconfdir"/sysinit.target.wants/systemd-pcrnvdone.service \
            "$systemdsystemconfdir"/sysinit.target.wants/systemd-pcrosseparator.service
    fi
}
