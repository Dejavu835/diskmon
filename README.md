# diskmon

菜单栏里看外接盘的温度和 SMART。读不到就写「—」，不拿 0°C 充数。

4.0.1。macOS 14 及以上，Apple Silicon。

## What it does

- Menu bar extra + popover: live temperature, health level, I/O, drop watch
- Reads NVMe / ATA SMART via IOKit first, then `smartctl` when needed
- Persists samples in SwiftData; volume UUID survives Thunderbolt replug
- Honest empty state: USB bridges that cannot pass SMART show "—", not 0 °C

## What it cannot do

macOS does not pass SCSI / NVMe SMART through USB UAS. On this project’s test machine, a USB 3.2 Gen2 enclosure (`Realtek RTL9210`, `0bda:9210`) reports `SMART Status: Not Supported`. The same SSD in a Thunderbolt / USB4 NVMe enclosure works (temperature, spare, percentage used).

Linux can often read those USB-NVMe bridges (`smartctl -d sntrealtek` / `sntasmedia` / `sat`). Darwin cannot.

## Requirements

- macOS 14 or later, Apple Silicon
- Full Disk Access for `smartctl` (optional: IOKit still reads many TB / PCIe NVMe drives)
- [smartmontools](https://www.smartmontools.org/) recommended: `brew install smartmontools`

## Build

```bash
swift test
./build_v4.sh
```

Ad-hoc signed app + DMG land in `dist/v4/` (`diskmon.app`, `diskmon-4.0.1.dmg`). Gatekeeper will warn until the app is notarized. Right-click → Open.

`dist/` is gitignored. Local archives of 4.0.0 live under `dist/kept/4.0.0/`.

## Layout

```
Package.swift                 # SPM, macOS 14+
Sources/DiskMonCore/          # health policy, SMART parse, drop watch
Sources/DiskMonIOKitSMART/    # NVMe / ATA IOKit plugins
Sources/diskmon/              # SwiftUI app
Tests/DiskMonCoreTests/
docs/notes/                   # work notes
```

## Authors

- déjà vu_tao（mian）
- Cursor Agent
- MiniMax Agent
- gorkbuild

## License

MIT © 2026 déjà vu_tao（mian）, Cursor Agent, MiniMax Agent, gorkbuild.

Optional NTFS format helpers may bundle NTFSKit / libntfs-3g (GPL-2.0); see `Sources/diskmon/Resources/NTFSKit-LICENSE.GPL2` when present. `vendor/` is not required to build the monitor.
