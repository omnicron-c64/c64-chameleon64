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
- **Palette RAM** with a custom slot and **.vpl** (VICE palette) loading from the menu.
- **Freezer cartridges**: Action Replay, Super Snapshot V5, Final Cartridge III, Retro Replay, Epyx FastLoad
  (fixes: cartridge SDRAM requests limited to C64 slots, Ultimax write protection from upstream MiSTer,
  SID bus-latch decay so `$D600` reads `$00` on a C64).
- **Empty drive** behaves like a real 1541 (no SYNC) - `74, DRIVE NOT READY`.
- **Buttons**: left = menu, middle = cartridge freeze, right = C64 reset (keeps settings and mounted disk),
  middle + right held = back to the Chameleon menu (slot 0).
- **USB debugging** with `chacocmd` while the core runs (pwsoft `chameleon_usb.vhd`):
  - `--addr 0x0000 --len N --dumpmem|--readmem|--writemem` - C64 RAM
  - `--addr 0x40000000 --len 0x100 --dumpmem` - debug window: byte 2 = CPU `$01`, 3 = cart/EXROM/GAME,
    4-5 = turbo cycles per frame, 6 = IEC hold/turbo state, other even/odd pairs = live CPU address samples
  - write `0x40000010`: turbo override (0 menu, 1 off, 2 on, 3 software)
  - **flash only after `chacocmd --start 0`**, with the SD card removed

## Building

Requires Quartus II 13.1 (Cyclone III) and the DeMiSTify toolchain (vbcc / EightThirtyTwo).

```
git clone https://github.com/robinsonb5/DeMiSTify.git ../DeMiSTify
cd ../DeMiSTify && git checkout 4a073448b16446d642b887b9276852259f5efddf && git submodule update --init --recursive
git apply ../c64-chameleon64/patches/demistify-chameleon-c64.patch
cd ../c64-chameleon64 && ln -s ../DeMiSTify DeMiSTify
make BOARDS=chameleon64 firmware init compile
```

Output: `chameleon64/output_files/c64_chameleon64.rbf` - flash with
`chacocmd --flashrbf <slot> c64_chameleon64.rbf`. The SD card needs `C64.ROM` (32 KB: BASIC + KERNAL + 1541 DOS).

## License

GPL, as the original C64 core and DeMiSTify. `chameleon64/chameleon_usb.vhd` is LGPL (Peter Wendrich, fpga_examples).
