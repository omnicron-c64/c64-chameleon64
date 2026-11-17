# c64-chameleon64

The MiST C64 core (mist-devel/c64, itself derived from the MiSTer C64 core and Peter Wendrich's FPGA-64)
ported to the **Turbo Chameleon 64 V1** (Cyclone III EP3C25) with [DeMiSTify](https://github.com/robinsonb5/DeMiSTify),
plus Ultimate 64-style extras.

## Features added for the Chameleon

- **Chameleon V1 board support** via DeMiSTify (832 controller CPU, OSD, SD card), standalone with the
  joystick adapter/docking station, or on a real C64's cartridge port using its keyboard and joysticks.
- **1541 DOS ROM in SDRAM** (frees 16 M9K blocks), with dedicated SDRAM slots and a sector splitter for the
  DeMiSTify SD protocol.
- **Turbo 2x** (System menu): `Off` / `Software ($D030/31)` / `On`.
  - extra CPU cycle in the free CPU4-7 SDRAM slot (whole screen, not just the border)
  - I/O accesses (VIC-II, SID, CIAs, colour RAM, cartridge I/O) always get a full 1 MHz cycle
  - 1 MHz while the drive motor runs and on serial-bus activity (fastloaders stay exact)
  - C128 `$D030` bit and U64-style `$D031` register in Software mode
- **Ultimate UCI** (`$DF1C-$DF1F`, System menu) with ID `$C9`; local palette commands (target `$F0`).
- **UCI DOS** (target `$01`) served by the 832 firmware from the SD card: IDENTIFY, OPEN/CLOSE (read only),
  READ_DATA, FILE_INFO, CHANGE_DIR, GET_PATH, OPEN_DIR/READ_DIR and LOAD_REU. The virtual root holds
  `/SD`, `/Usb0` (both the SD card) and `/Flash` (the SD folder `Flash`), so software written for the
  Ultimate finds its usual paths. LOAD_REU streams through a 512-byte FIFO that the firmware paces, so
  loads stay intact while a program keeps the REU busy (Dragon's Lair FMV plays all scenes).
- **SID wave tables compressed** (deduplicated 16-byte blocks + index ROM, bit-exact) to free block RAM
  for the larger firmware.
- **Palette RAM** with a custom slot and **.vpl** (VICE palette) loading from the menu.
- **Freezer cartridges**: Action Replay, Super Snapshot V5, Final Cartridge III, Retro Replay, Epyx FastLoad
  (fixes: cartridge SDRAM requests limited to C64 slots, Ultimax write protection from upstream MiSTer,
  SID bus-latch decay so `$D600` reads `$00` on a C64).
- **Empty drive** behaves like a real 1541 (no SYNC) - `74, DRIVE NOT READY`.
- **CIA interrupt timing** passes VICE `dd0dtest` in both CIA modes - see below.
- **Buttons**: left = menu, middle = cartridge freeze, right = C64 reset (keeps settings and mounted disk),
  middle + right held = back to the Chameleon menu (slot 0).
- **USB debugging** with `chacocmd` while the core runs (pwsoft `chameleon_usb.vhd`):
  - `--addr 0x0000 --len N --dumpmem|--readmem|--writemem` - C64 RAM
  - `--addr 0x40000000 --len 0x100 --dumpmem` - debug window: byte 2 = CPU `$01`, 3 = cart/EXROM/GAME,
    4-5 = turbo cycles per frame, 6 = IEC hold/turbo state, other even/odd pairs = live CPU address samples
  - write `0x40000010`: turbo override (0 menu, 1 off, 2 on, 3 software)
  - **flash only after `chacocmd --start 0`**, with the SD card removed

## CIA accuracy: dd0dtest passes

The CIA model this core inherits from MiST/MiSTer (`rtl/mos6526.v`) has long carried the note
"passes all CIA tests from VICE, except dd0dtest". Wilfred Bos's
[dd0dtest](https://github.com/libsidplayfp/VICE-testprogs/tree/master/CIA/dd0dtest) checks, cycle by
cycle, what `$DD0D` (the interrupt control register) returns and when the NMI fires while instructions
read and write it - including read-modify-write instructions such as `INC $DD0D,X`.

As of v0.2.1 it **passes completely in both CIA modes** on a Chameleon V1 (verified on hardware):

| Mode | Fixed cases | Change |
|------|-------------|--------|
| New (8521) | `$17`, `$18`, `$19` | A `$DD0D` read keeps its clear active through the next cycle: an interrupt arriving then sets ICR bit 7 but asserts /IRQ one cycle later (never, if a further read acknowledges it). ICR bit 7 is its own latch, and flags cleared by a read stay visible on the next read. |
| Old (6526) | `$11` | When `$DD0D` is written in two consecutive cycles (read-modify-write), the second write changes the interrupt mask immediately, before the CPU samples the interrupt line. |

Each change is gated to its own CIA mode. The behaviour follows Dag Lem's
[reDIP-CIA](https://github.com/daglem/reDIP-CIA) (`cia_interrupt.sv`); every case was compared with
reDIP in bus-level simulation (Icarus Verilog against reDIP's Verilator model) and then run on hardware,
where a CPU cycle trace captured over USB showed the failing cycles. The fixes are plain RTL in
`rtl/mos6526.v`, so they should carry over to other cores that use this CIA model.

## Building

Requires Quartus II 13.1 (Cyclone III) and the DeMiSTify toolchain (vbcc / EightThirtyTwo).

```
git clone https://github.com/robinsonb5/DeMiSTify.git ../DeMiSTify
cd ../DeMiSTify && git checkout 4a073448b16446d642b887b9276852259f5efddf && git submodule update --init --recursive
git apply ../c64-chameleon64/patches/demistify-chameleon-c64.patch
cd ../c64-chameleon64 && ln -s ../DeMiSTify DeMiSTify
git submodule update --init --recursive
git -C rtl/mist/mist-modules apply ../../../patches/mist-modules-uci.patch
make BOARDS=chameleon64 firmware init compile
```

Output: `chameleon64/output_files/c64_chameleon64.rbf` - flash with
`chacocmd --flashrbf <slot> c64_chameleon64.rbf`. The SD card needs `C64.ROM` (32 KB: BASIC + KERNAL + 1541 DOS).

## License

GPL, as the original C64 core and DeMiSTify. `chameleon64/chameleon_usb.vhd` is LGPL (Peter Wendrich, fpga_examples).
