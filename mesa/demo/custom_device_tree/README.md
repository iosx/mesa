# MESA custom device trees

MESA/imggen.rb consumes **prebuilt** `.dtb` files; the MESA build has no
`.dts -> .dtb` rule. Board device trees that belong to MESA rather than to the
in-kernel `arch/arm64/boot/dts/microchip` tree therefore live here, as sources,
and are compiled by `build_custom_dtb.sh`. This mirrors webstax's
`build/custom_device_tree` + `vpath %.dts` + `compile_dtc` mechanism, reduced to
what MESA needs.

## Contents

| File | Purpose |
| --- | --- |
| `sparx5_appl_pcb135_aiu.dts` | Galaxy Space AIU board (dual VSC7558, `pcb=135 pcb_var=33`) |
| `build_custom_dtb.sh` | cpp + dtc pipeline, same flags as webstax's `compile_dtc` |

Built `.dtb` files are generated next to their sources and are git-ignored.

## Adding a board

1. Drop `<board>.dts` here. Include the stock board `.dtsi` you are deriving
   from, e.g. `#include "sparx5_appl_pcb135_board.dtsi"`; quoted includes are
   resolved from this directory first and from the kernel DTS directory after,
   so a local `.dtsi` can shadow the in-kernel one.
2. Add an entry to the `:dt` list of the matching machine in
   `mesa/demo/imggen.rb`:

   ```ruby
   { :name => "pcb135", :file => "#{$p_custom_dtb}/sparx5_appl_pcb135_aiu.dtb"},
   ```

   `:name` becomes the FIT configuration label, i.e. what U-Boot passes as
   `bootm <addr>#<name>` (`pcb=...` in the U-Boot environment).

The CMake build compiles every `*.dts` in this directory for `aarch64` and
makes the `fit`/`ext4` images of the machines listed in `CUSTOM_DTB_MACHINES`
depend on it, so the `.dtb` is always fresh before `mkimage` packs the FIT.

## Building by hand

```sh
# Kernel tree inside a BSP, dtc taken from the same BSP:
./build_custom_dtb.sh --bsp /opt/mchp/mchp-brsdk-arm64-2026.03

# Explicit kernel source tree:
./build_custom_dtb.sh --kernel-dir ~/src/linux

# One file, output elsewhere:
./build_custom_dtb.sh --kernel-dir ~/src/linux -o /tmp/dtb sparx5_appl_pcb135_aiu.dts
```

Also honoured: `$KERNEL_DTS_PATH` (as used by webstax), `$KERNEL_SRC`, `$BSP`,
`$DTC` and `$HOSTCC`.

The BSP `dtc` is a Linux/x86-64 binary; when the script runs on another OS it
falls back to a `dtc` from `$PATH` (or `$DTC`). The host `cc` is looked up the
same way, because a BSP host bindir has no generic `cc`.

## AIU board

`sparx5_appl_pcb135_aiu.dts` derives from `sparx5_appl_pcb135.dts` and removes
the PCB135 peripherals that the AIU board does not have (SPI NAND on CS14,
CPLD/SyncE on SPI CS1-CS3, the SFP I2C mux and cages, and the MDIO PHY
children). Board identity is carried in a `meba` node, which MEBA reads from
`/proc/device-tree/meba/*` in preference to the U-Boot environment:

```
meba {
        board   = "AIU";
        pcb     = "135";
        pcb_var = "33";
        target  = "0x47558";
};
```

Keep `pcb` containing `"135"` (it is matched with `strstr()`) and `pcb_var` at
`33` (`AIU_PORT_COUNT`) - that pair selects `VTSS_BOARD_CONF_AIU_33` in
`meba/src/sparx5/meba.c`.

`&switch` (the native `sparx5-switch` driver) must stay disabled: the AIU is
driven from user space through `uio0` (interrupt mux) and `ifh0`, exactly like
the stock APPL tree. Enabling `&switch` runs the native driver against the AIU
port layout and faults in the GIC IRQ path.

### FIT configuration name

The AIU U-Boot hard-codes the board name (`board_late_init()` in
`board/mscc/sparx5/sparx5.c`, case `BOARD_TYPE_PCB135_YINHE` sets
`pcb=pcb135`) and `ramboot` boots `bootm ${loadaddr}#${pcb}`. There is nothing to
set on the target, so the FIT configuration named **`pcb135`** is the one that
must carry the AIU device tree:

```ruby
{ :name => "pcb135",     :file => "#{$p_custom_dtb}/sparx5_appl_pcb135_aiu.dtb"},
{ :name => "pcb135_ref", :file => ".../release/sparx5_appl_pcb135.dtb"},
```

The stock PCB135 reference tree is still shipped, under `pcb135_ref`, for
bring-up comparisons. It can be booted explicitly with
`bootm ${loadaddr}#pcb135_ref` without touching the environment.
