# colorful-gpu-unlock

English | [简体中文](README.md)

Unlock the full GPU power budget on Colorful (七彩虹) gaming laptops under Linux.

Developed and verified on a Colorful G16 Pro (i9-14900HX + RTX 5090 Laptop 24GB).
Likely applies to other Colorful / Tongfang machines of the same generation.

**Result: GPU power limit 95W/120W → 175W (hardware max), +75% sustained compute throughput.**

```
Before:     95W cap,  SM 800MHz,  ~29 tok/s decode
Interim:   120W cap,  SM 930MHz,  ~33 tok/s decode
Unlocked:  175W cap,  SM 1545MHz, 49–53 tok/s decode  (stable 500-token runs)
```

## Background

- On Windows, the OEM Control Center (performance profiles: Office / Game / Turbo)
  notifies the firmware via WMI → EC whenever the profile changes. Only after that
  "activation" will NVIDIA powerd's NVPCF negotiation receive the full boost budget.
- Under Linux nobody performs this switch, so the firmware authorization flag
  (`\_SB.NPCF.CTGP`) stays 0 forever. Even with nvidia-powerd running perfectly,
  NVPCF only grants the base budget (120W on this machine), and powerd logs:
  `ERROR! Client (presumably SBIOS) has requested to disable Dynamic Boost DC controller`
- This project calls the firmware's **own activation path**
  `\_SB.PC00.LPCB.EC0.RCAP(0,0)` to set CTGP, then restarts nvidia-powerd to
  renegotiate — replicating what the Windows tool does, without Windows.

⚠️ This is NOT a hack that forces power: no VBIOS/EC data is modified. It only
invokes an entry point the OEM firmware already provides. All firmware-side
protections (turbo-profile temperature target of 75°C, platform limits) stay active.

## Is this applicable to my machine?

All of the following must be true:

1. `nvidia-smi -q -d POWER` shows Default Power Limit far below Max Power Limit
   (95W vs 175W on this machine)
2. nvidia-powerd is running (`systemctl status nvidia-powerd`) but the power
   cap still sits below Max; journal contains the "disable Dynamic Boost" error above
3. Your decompiled ACPI tables contain `Device (NPCF)` with HID `NVDA0820` and
   an `RCAP` method under `\_SB.PC00.LPCB.EC0` — see
   [docs/reverse-notes.md](docs/reverse-notes.md)

## Usage

Requires the `acpi_call` kernel module (`sudo apt install acpi-call-dkms` or
equivalent; kernel headers `linux-headers-$(uname -r)` needed for the DKMS
build), plus NVIDIA driver + nvidia-powerd already working.

> **Deepin / UOS users**: these distros' NVIDIA driver packages ship
> `nvidia-dbus.conf` but never install it, leaving nvidia-powerd dead
> (the first hurdle before this unlock). Fix it manually:
>
> ```bash
> sudo cp /usr/share/doc/NVIDIA_GLX-1.0/nvidia-dbus.conf /etc/dbus-1/system.d/
> sudo systemctl restart nvidia-powerd
> ```

From scratch on a fresh install:

```bash
sudo apt install acpi-call-dkms
git clone https://github.com/ddacxhs/colorful-gpu-unlock.git
cd colorful-gpu-unlock
sudo scripts/apply-boost.sh

# Verify: Current Power Limit should now equal Max Power Limit
nvidia-smi -q -d POWER | grep -E "Current|Max Power Limit"
```

Unlock automatically at boot:

```bash
sudo cp scripts/apply-boost.sh /usr/local/sbin/
sudo cp scripts/gpu-boost-unlock.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gpu-boost-unlock.service
```

After suspend/resume or AC/battery transitions the cap may drop back —
just run `sudo systemctl start gpu-boost-unlock` again.

## How it works

```
apply-boost.sh
  ├─ modprobe acpi_call
  ├─ echo '\_SB.PC00.LPCB.EC0.RCAP 0 0' > /proc/acpi/call
  │     └─ firmware path: CTGP=1, DTGP=1 (GPU boost + Dynamic Boost authorization)
  └─ systemctl restart nvidia-powerd
        └─ powerd renegotiates NVPCF → full boost budget granted (175W here)
```

Key ACPI objects (verified on G16 Pro):

| Object | Meaning |
|---|---|
| `\_SB.PC00.LPCB.EC0.RCAP` | Profile-application entry (RCAP(0,0) = enable GPU boost authorization) |
| `\_SB.NPCF.CTGP` | GPU boost authorization flag (0=off, 1=on); must read 1 after unlock |
| `\_SB.NPCF.ACBT` | AC-side boost TGP target (0x1B8 on this machine) |
| `\_SB.PC00.LPCB.EC0.APMD` (EC 0x95) | Performance profile: 0=Office 1=Game 2=Turbo |

Object names and paths may differ on other machines — always confirm the objects
exist in your own ACPI tables first ([docs/reverse-notes.md](docs/reverse-notes.md)),
then run the unlock.

## Risks & disclaimer

- The script only calls existing firmware methods — no raw EC writes, no firmware
  patches — but ACPI operations are platform-specific and **not guaranteed safe
  on every model**.
- Firmware thermal targets and current protections remain active, but the unlocked
  profile does mean more heat and fan noise. Make sure your cooling is healthy.
- Use at your own risk. Complete the applicability checklist first — step 3 in
  particular — before running the unlock.

## Verified on

| Item | Value |
|---|---|
| Laptop | Colorful G16 Pro (DMI: COLORFUL / G16 Pro) |
| CPU / GPU | i9-14900HX / RTX 5090 Laptop 24GB (10de:2c18) |
| OS | Deepin 23 (beige), kernel 6.6.155-amd64-desktop-hwe |
| Driver | NVIDIA 595.99.02 + nvidia-powerd 595.99.02 |
| acpi_call | 1.2.2 (dkms) |

## Credits & references

- [IzzieBoopers/5080-Unlock_Linux](https://github.com/IzzieBoopers/5080-Unlock_Linux) —
  prior art for the same problem on HP OMEN 5080 (WMI CTGP/DTGP flags); the
  inspiration for this project
- NVIDIA forum thread with the full troubleshooting saga:
  [RTX 5090 Laptop Dynamic Boost capped at 120W](https://forums.developer.nvidia.com/t/385659)

## License

MIT
