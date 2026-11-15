# IRIScan Express 4 — protocol notes

Findings from reading the vendor driver (static analysis, Nov 2026). Items marked
**(unverified)** still need confirming against a live trace.

## Device

| | |
|---|---|
| USB VID:PID | `0A38:0161` ("IRIS" / "IRIScanExpress4") |
| USB class | Mass Storage (class 8), SCSI transparent (subclass 6), Bulk-Only Transport (protocol 0x50) |
| SCSI peripheral type | 0 (direct access), vendor `IRIS`, product `IRIScanExpress4` |
| Internals | Avision design, Novatek ASIC (driver probes it with vendor CDB `C5 07 …`, reply `NOVA`) |
| Firmware | Lives on the device; the driver bundle ships no firmware file |
| Sibling models (same driver) | `0A38:0162` IRIScan Executive 4, `0A38:0163` IRIScan Pro 5 |

## Vendor software stack (all of it is going away)

1. `/Applications/Capture Tool.app` — x86_64 TWAIN host (Avision "Capture Tool" 3.0, 2019). UI only.
2. `/Library/Image Capture/TWAIN Data Sources/IRIS.ds` — TWAIN data source. Model code in
   `Versions/A/Resources/IRIScanExpress4.dylib` (x86_64/i386 only). Settings in `Versions/A/avscan.plist`.
3. `/Library/Extensions/AvKernel.kext` (`com.AvKernel` 1.9) — subclasses `IOSCSIPeripheralDeviceNub`,
   exposes user client `com_AvKernelUserClient` that is a plain SCSI pass-through.
   Needs Reduced Security on Apple Silicon.

On Apple Silicon 1+2 need Rosetta 2 and 3 needs a third-party kext — both are being retired.

### Kext user-client ABI (IOConnectCallStructMethod selectors)

| Selector | Meaning |
|---|---|
| 0 | open / lock |
| 1 | close / unlock |
| 2 | submit command: 0x4C-byte struct, Windows `SCSI_PASS_THROUGH_DIRECT`-like. `+0x08` data-in flag, `+0x0C` transfer length, `+0x10` timeout (s), `+0x18` CDB[16] |
| 3 | host→device data, ≤ 4096 bytes per call (input struct) |
| 4 | device→host data, ≤ 4096 bytes per call (output struct) |

## Transport: Avision SCSI tunneled in Novatek `C5 07` (confirmed by live trace)

The kext never sends Avision opcodes directly. Every CDB on the wire is a 12-byte Novatek
vendor command:

```
C5 07 00 00 00 00 00 00 00 <LEN> <A> <B>
```

`LEN` = transfer length (bytes 8–9), `A B` = sub-command, byte 12 `C` = phase for `02 01`/`02 02`:
`00` data, `01` status, `02` image band header (`03`/`04` read USB VID/PID). Seen at startup:

| `A B` | Dir | Len | Meaning (inferred) |
|---|---|---|---|
| `FF 02` | in | 4 | identity, reply `NOVA` |
| `FF 03` / `FF 04` / `FF 05` / `FF 06` | in | 16 | transport status polls, reply `10 00 00 00 01 00 00 00 0x …` |
| `02 03` | out | 10 | **tunneled Avision CDB** (10 bytes, e.g. `12 00 00 00 a5 …` INQUIRY, `28 00 69 00 0a 0d 00 00 80 00` READ type 0x69) |
| `02 01 <n>` | in | var | read result / status block of tunneled command |
| `02 02 <n>` | in | var | read data of tunneled command (INQUIRY → `IRIS    IRIScanExpress4 0.11 …`) |

`02 02 03` → `0a38`, `02 02 04` → `0161` (VID/PID). Device info (type 0x69) carries the serial.
Each tunneled step is surrounded by `FF 04/06/03/05` status polls, i.e. a handshake per stage.

A replacement app sends exactly these 12-byte CDBs, wrapped in USB Bulk-Only Transport
(31-byte CBW, data stage, 13-byte CSW) on interface 0 — no kext needed.

### Per-command handshake (from scan trace)

For every tunneled Avision command:

1. `FF 02` → `NOVA` (sometimes), then status polls `FF 04, FF 06, FF 04, FF 03, FF 05`.
2. `02 03` OUT: the Avision CDB, **with any small host→device data appended** (SEND10 and
   SET WINDOW carry their payload in the same transfer; total length = 10 + data).
3. Data-in phase (if any): `02 01 <len>` returns a small header (`10 00` for 2-byte reads,
   a 24-byte block for image reads), `02 02 <len>` returns the data.
4. Status phase: `02 01 04` → `10 00 00 00`, `02 02 04` → 4-byte SCSI status (`00 00 00 00` = GOOD).

## Image data: Novatek memory reads `C3 07`

Image data does not come through `02 02`. A READ10 type 0x00 returns a 24-byte block
pair describing a ready band, then the host pulls it from device RAM:

```
C3 07 <addr: 4 bytes BE> <len: 4 bytes BE> 00 …     e.g. c3 07 00 46 22 40 | 00 01 00 00
```

- `02 01` block (24 B): `… | f0 00 00 00 | 40 22 46 00` → 240 lines ready at address `0x00462240` (LE).
- `02 02` block (24 B): `… | 20 0a 00 00 | f0 00 00 00 …` → 0x0A20 = 2592 bytes/line, 240 lines.
- Band = 240 × 2592 = 622 080 B, read as 9 × 64 KiB + 32 256 B. Last band in the trace was 6 lines.
- End of page: header ends `06 00 00 00 …` and the `02 02` block starts `03 00 00 00` → no more data.

**Pixel format:** 8-bit grayscale, 2592 px/line (8.64″ at 300 dpi, full sensor width), paper on a
black background. **Vertical sampling is ~3× the horizontal** (~900 lines/inch at the
"300 dpi" window): a receipt that Capture Tool saves as 1929 px tall arrives as ~5750 lines.
The vendor software scales Y down by ~1/3 (see `docs/requirements.md`). The vendor driver does crop, deskew and B/W thresholding in software
(`SmartImage.dylib`). (The trace tools used to find this are kept out of the repo.)

## One scan, as Capture Tool does it (300 dpi, trace `scan1`)

| Step | Tunneled command | Notes |
|---|---|---|
| idle | INQUIRY `12 00 00 00 a5`, READ10 type `0x69` (128 B device info, has serial) | at app start |
| 1 | MEDIA CHECK `08 00 00 00 02 00` | reply `01 00` = **paper present**, `00 00` = none |
| 2 | READ10 type `0xA0`, 2 B | reply `01 00` (paper/ADF status, unverified meaning) |
| 3 | (repeat 1–2) | |
| 4 | SEND10 type `0x95`, data `00 78`; SEND10 type `0x96`, data `00 78` | unknown, possibly timeouts/power |
| 5 | SEND10 type `0x83`, 18 B | unknown setting block |
| 6 | SET WINDOW, 79-byte payload: `0000000000000000 0047 0000 012c 012c …` | 300×300 dpi, 8 bpp |
| 7 | RESERVE UNIT | |
| 8 | SCAN `1b 00 00 00 00 80` | paper feeds |
| 9 | READ10 type `0x00`, len `0x1feae0` → band header → `C3 07` reads; repeat | ~0.17 s per 240-line band |
| 10 | RELEASE UNIT, MEDIA CHECK → `00 00` | |
| 11 | SEND10 type `0xA2`, data `00 01` | at close, unknown |

Full SET WINDOW payload (scan1):
`00000000000000470000012c012c0000000000000000000028800000438080808005080000030000` +
`0000000000000000ff1de0ff001e6010e01000006400640064c00000000b000000000000000000` (79 bytes)

## Button (confirmed with scanprobe)

READ10 type `0xA1`, 16 bytes (`28 00 a1 00 0a 0d 00 00 10 00`). Idle: all zero.
A press is latched and reported once, then cleared:

| Event | Reply |
|---|---|
| short press | `81 03 00 00 00 00 01 00 …` |
| long press (~2 s) | `c1 03 00 00 00 00 01 00 …` (bit 0x40 = long) |

Capture Tool never reads it, which is why the button "did nothing". Poll every ~200 ms.

## Native status (Nov 2026)

`scanprobe` (arm64, no Rosetta) does identity, INQUIRY, device info, paper sensor, button and a
full 300 dpi gray scan (2592×~6300 in 6.5 s), replaying Capture Tool's setup bytes, over either:

- `--usb` **direct USB, no kext** (`Sources/CUSBHost`, `USBTransport.swift`): IOUSBHost
  `DeviceCapture` takes interface 0 from Apple's mass-storage driver, then plain Bulk-Only
  Transport (31-byte CBW `USBC`, CDB length 16, data, 13-byte CSW `USBS`). Needs root (or the
  restricted `com.apple.vm.device-access` entitlement). On release macOS resets the device and
  re-attaches its drivers, so the vendor stack keeps working. If the process dies without
  releasing, the drivers stay detached until the next clean run or a replug.
- default: the vendor `AvKernel.kext` user client (`AvKernelTransport`), kept for comparison.

**In the app** the root part is `ScanlineHelper`, started by the app as its own child through one
sudo rule (`/etc/sudoers.d/local.scanline.helper`: this user may run exactly
`/Library/PrivilegedHelperTools/local.scanline.helper --stdio` as root) and spoken to over a pipe.
A LaunchDaemon does **not** work: running outside the user's login session, it can capture the
device but is refused when it opens the USB interface (`IOServiceOpen failed`), while a root
process inside the session (sudo) succeeds. The helper exits when the pipe closes.

Nothing from the vendor stack is needed for `--usb`: not Capture Tool, `IRIS.ds`, Rosetta or the kext.

## SCSI command set (Avision, tunneled)

CDB templates built in `IoObject::IoObject()`:

| Opcode | Command | Use |
|---|---|---|
| `0x00` | TEST UNIT READY | readiness |
| `0x03` | REQUEST SENSE | error details |
| `0x08` | MEDIA CHECK | paper sensor. Driver sends `08 00 00 <type> <len≥2> 00`; `GetADFStatus` uses type 0, byte 0 of reply = status |
| `0x12` | INQUIRY | model / ability block |
| `0x16` / `0x17` | RESERVE / RELEASE UNIT | job lock |
| `0x1B` | SCAN | start |
| `0x24` | SET WINDOW | resolution, mode, area (window descriptor) |
| `0x28` | READ(10) | data type in CDB[2]: `0x00` image, **`0xA1` button status (16 bytes)** |
| `0x2A` | SEND(10) | gamma / calibration / settings |
| `0x31` | OBJECT POSITION | CDB[1]: paper load / eject **(unverified mapping)** |

Matches the SANE `avision` backend, which is the best public reference for window descriptor
and data-type layouts.

## Button and auto-load

- Exported `CheckPushButton` / `ResetPushButton` / `DoPaperFeed` in the vendor driver are stubs
  (log only) — that is why the top button does nothing in Capture Tool.
- `CAsicIO::GetButtonStatus` reads READ(10) type `0xA1`, 16 bytes. **(unverified that the button
  sets a bit there on this model)**
- Auto-load plan: poll MEDIA CHECK, on paper present wait 2 s, then run the scan sequence.

## Open questions

- Meaning of SEND10 types `0x83`, `0x95`, `0x96`, `0xA2` and READ10 type `0xA0`.
- Exact vertical scale (~2.98–3.0): scan a ruler or a receipt of measured length.
- Calibration/shading: none needed so far (none in the trace; native scan looks right).
- App packaging: capture needs root, so the app needs a privileged helper (launchd daemon via SMAppService).
