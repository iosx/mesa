#!/usr/bin/env bash
#
# Copyright (c) 2026 Microchip Technology Inc. and its subsidiaries.
# SPDX-License-Identifier: MIT
#
# Compile MESA custom board device trees (.dts) against a Linux kernel tree.
#
# MESA/imggen.rb only knows about prebuilt .dtb files - there is no dts -> dtb
# rule in the MESA build. Custom device trees therefore live in this directory
# (the equivalent of webstax's build/custom_device_tree) and are compiled by
# this script.
#
# The pipeline mirrors webstax's build/make/target-brsdk.mk compile_dtc():
#
#   $(HOST_CC) -E -nostdinc -I$(KERNEL_DTS_PATH) -undef -D__DTS__ \
#       -x assembler-with-cpp -o x.dts.tmp x.dts
#   dtc -o x.dtb -i $(KERNEL_DTS_PATH)/$(ARCH) x.dts.tmp
#
# Quoted includes inside a custom .dts are resolved from this directory first
# and from the kernel DTS directory afterwards, so a local copy of e.g.
# sparx5_appl_pcb135_board.dtsi shadows the in-kernel one.
#
# Examples:
#   ./build_custom_dtb.sh --bsp /opt/mchp/mchp-brsdk-arm64-2026.03
#   ./build_custom_dtb.sh --kernel-dir ~/linux sparx5_appl_pcb135_aiu.dts

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KERNEL_DIR="${KERNEL_DIR:-}"
BSP_DIR="${BSP_DIR:-}"
OUT_DIR="${OUT_DIR:-}"
EXTRA_INC=()
DTS_FILES=()
HOSTCC="${HOSTCC:-}"
DTC="${DTC:-}"

# A preprocessor is only needed for #include/#define, any host cc will do.
# The BSP host bindir has no "cc", so fall back until one runs.
if [ -z "$HOSTCC" ]; then
    for c in cc gcc cpp; do
        if command -v "$c" >/dev/null 2>&1 && \
           echo '' | "$c" -E -x assembler-with-cpp - >/dev/null 2>&1; then
            HOSTCC="$c"
            break
        fi
    done
fi
if [ -z "$HOSTCC" ]; then
    echo "$(basename "$0"): no usable host preprocessor (tried cc, gcc, cpp); set \$HOSTCC" >&2
    exit 1
fi

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [dts-file ...]

Compile MESA custom device trees found in $HERE.

Options:
  -k, --kernel-dir DIR  Linux kernel source tree, or the
                        arch/arm64/boot/dts/microchip directory itself.
                        Defaults to \$KERNEL_DTS_PATH, \$KERNEL_SRC, or an
                        auto-detected kernel under --bsp.
  -b, --bsp DIR         BSP root (e.g. /opt/mchp/mchp-brsdk-arm64-2026.03).
                        Auto-detects the kernel tree shipped in the BSP
                        sysroot (<bsp>/*/*/release/x86_64-linux/*/sysroot/
                        usr/src/linux) and, unless --dtc/DTC is given, the
                        host dtc in <bsp>/*/*/release/x86_64-linux/bin.
                        Defaults to \$BSP.
  -o, --outdir DIR      Where to write the .dtb. Default: next to the .dts.
  -i, --include DIR     Extra include directory, may be repeated.
      --dtc CMD         dtc to use. Defaults to \$DTC or "dtc".
  -h, --help            This text.

With no dts-file argument every *.dts in $HERE is built.
EOF
}

DTC_GIVEN=0
while [ $# -gt 0 ]; do
    case "$1" in
        -k|--kernel-dir) KERNEL_DIR="$2"; shift 2 ;;
        -b|--bsp)        BSP_DIR="$2"; shift 2 ;;
        -o|--outdir)     OUT_DIR="$2"; shift 2 ;;
        -i|--include)    EXTRA_INC+=("$2"); shift 2 ;;
        --dtc)           DTC="$2"; DTC_GIVEN=1; shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        -*)              echo "$(basename "$0"): unknown option $1" >&2; usage >&2; exit 1 ;;
        *)               DTS_FILES+=("$1"); shift ;;
    esac
done

# ---------------------------------------------------------------- kernel tree
# Normalise DIR into DTS_DIR (<kernel>/arch/arm64/boot/dts/microchip) and
# KDIR (<kernel>).
DTS_DIR=""
KDIR=""

try_kernel_dir() {
    local d="$1"
    [ -n "$d" ] && [ -d "$d" ] || return 1

    if [ -f "$d/sparx5.dtsi" ]; then
        DTS_DIR="$(cd "$d" && pwd)"
    elif [ -f "$d/arch/arm64/boot/dts/microchip/sparx5.dtsi" ]; then
        DTS_DIR="$(cd "$d/arch/arm64/boot/dts/microchip" && pwd)"
    else
        return 1
    fi

    # <kernel>/arch/arm64/boot/dts/microchip -> <kernel>
    KDIR="$(cd "$DTS_DIR/../../../../.." && pwd)"
    [ -f "$KDIR/scripts/dtc/include-prefixes/dt-bindings/gpio/gpio.h" ] || \
    [ -f "$KDIR/include/dt-bindings/gpio/gpio.h" ] || return 1
    return 0
}

if ! try_kernel_dir "$KERNEL_DIR"; then
    try_kernel_dir "${KERNEL_DTS_PATH:-}" || try_kernel_dir "${KERNEL_SRC:-}" || true
fi

if [ -z "$KDIR" ] && [ -n "$BSP_DIR" ] && [ -d "$BSP_DIR" ]; then
    # Buildroot source tree first, then the kernel that ships inside the BSP
    # sysroot: <bsp>/<soc>-linux-gnu/<release>/x86_64-linux/*/sysroot/usr/src/linux
    # The xstax release matches the arch this script builds, prefer it over the
    # other releases shipped in the same BSP.
    for d in "$BSP_DIR"/output/build/linux-*/ \
             "$BSP_DIR"/*/xstax/release/x86_64-linux/*/sysroot/usr/src/linux/ \
             "$BSP_DIR"/*/*/release/x86_64-linux/*/sysroot/usr/src/linux/; do
        try_kernel_dir "${d%/}" && break
    done
fi

# Prefer the BSP's own host dtc, it is the one webstax/the kernel build uses.
if [ "$DTC_GIVEN" = 0 ] && [ -z "${DTC:-}" ] && [ -n "$BSP_DIR" ] && [ -d "$BSP_DIR" ]; then
    for d in "$BSP_DIR"/*/*/release/x86_64-linux/bin/dtc; do
        # The BSP dtc is a Linux/x86-64 binary; skip it when it cannot run on
        # this host (e.g. when the script is called from macOS).
        if [ -x "$d" ] && "$d" --version >/dev/null 2>&1; then
            DTC="$d"
            break
        fi
    done
fi
DTC="${DTC:-dtc}"

if [ -z "$KDIR" ]; then
    cat >&2 <<EOF
$(basename "$0"): cannot locate a Linux kernel tree that contains
    arch/arm64/boot/dts/microchip/sparx5.dtsi

Point at one explicitly, for example:
    $(basename "$0") --kernel-dir /path/to/linux \\
        --bsp /opt/mchp/mchp-brsdk-arm64-2026.03

The kernel source is the one listed in the BSP, e.g. under
    <bsp-source>/output/build/linux-*/
or from the tarball in
    <bsp-source>/dl/linux/*.tar.gz
EOF
    exit 1
fi

# ------------------------------------------------------------ include prefixes
if [ -d "$KDIR/scripts/dtc/include-prefixes" ]; then
    INCLUDE_PREFIXES="$KDIR/scripts/dtc/include-prefixes"
else
    # include-prefixes/ is generated by the kernel build; fall back to the raw
    # source layout (-I <kernel>/include plus the arch dts directory).
    INCLUDE_PREFIXES="$KDIR/include"
fi

CPP_FLAGS=(-nostdinc -undef -D__DTS__ -x assembler-with-cpp)
CPP_FLAGS+=(-I "$INCLUDE_PREFIXES")
CPP_FLAGS+=(-I "$KDIR/arch/arm64/boot/dts")
CPP_FLAGS+=(-I "$DTS_DIR")
CPP_FLAGS+=(-I "$HERE")
for d in ${EXTRA_INC+"${EXTRA_INC[@]}"}; do
    CPP_FLAGS+=(-I "$d")
done

# The suppression list is the one webstax uses, but not every dtc build knows
# every check (graph_child_address was dropped in dtc 1.8), so probe first.
DTC_QUIET=(unit_address_vs_reg unit_address_format avoid_unnecessary_addr_size
           alias_paths graph_child_address simple_bus_reg unique_unit_address
           interrupt_provider pci_device_reg)

probe_tmp="$(mktemp -t mchp-dtc-probe.XXXXXX)"
trap 'rm -f "$probe_tmp"' EXIT
printf '/dts-v1/;\n/ {};\n' > "$probe_tmp"

DTC_FLAGS=(-i "$DTS_DIR" -i "$HERE")
for w in "${DTC_QUIET[@]}"; do
    if "$DTC" -I dts -O dtb -o /dev/null "-Wno-$w" "$probe_tmp" >/dev/null 2>&1; then
        DTC_FLAGS+=("-Wno-$w")
    fi
done
for d in ${EXTRA_INC+"${EXTRA_INC[@]}"}; do
    DTC_FLAGS+=(-i "$d")
done

# ------------------------------------------------------------------ dts files
if [ ${#DTS_FILES[@]} -eq 0 ]; then
    shopt -s nullglob
    for f in "$HERE"/*.dts; do
        DTS_FILES+=("$f")
    done
    shopt -u nullglob
fi

if [ ${#DTS_FILES[@]} -eq 0 ]; then
    echo "$(basename "$0"): no .dts file to build in $HERE" >&2
    exit 1
fi

echo "kernel : $KDIR"
echo "dts    : $DTS_DIR"

for src in "${DTS_FILES[@]}"; do
    case "$src" in
        /*) ;;
        *) src="$HERE/$src" ;;
    esac
    if [ ! -f "$src" ]; then
        echo "$(basename "$0"): $src does not exist" >&2
        exit 1
    fi

    if [ -n "$OUT_DIR" ]; then
        mkdir -p "$OUT_DIR"
        dst="$OUT_DIR/$(basename "${src%.dts}").dtb"
        tmp="$OUT_DIR/$(basename "${src%.dts}").dts.tmp"
    else
        dst="${src%.dts}.dtb"
        tmp="${src%.dts}.dts.tmp"
    fi

    echo "[CPP] $(basename "$src")"
    "$HOSTCC" -E "${CPP_FLAGS[@]}" -o "$tmp" "$src"

    echo "[DTC] $(basename "$dst")"
    "$DTC" -I dts -O dtb -o "$dst" "${DTC_FLAGS[@]}" "$tmp"

    rm -f "$tmp"
done
