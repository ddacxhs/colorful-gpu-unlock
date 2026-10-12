# Reverse-engineering notes: Colorful G16 Pro GPU power unlock

Full record of the reverse-engineering and verification process, for anyone
adapting this to other machines.

Dev machine: Colorful G16 Pro (i9-14900HX + RTX 5090 Laptop), Deepin 23,
kernel 6.6.155, NVIDIA driver 595.99.02.

## 1. Problem identification

`nvidia-smi -q -d POWER`: Default 95W / Max 175W, but under load Current only
reaches 120W. `journalctl -u nvidia-powerd` shows:

```
ERROR! Client (presumably SBIOS) has requested to disable Dynamic Boost DC controller
```

So powerd is alive and DBus-connected, but the firmware side refuses to
authorize the full boost budget.

## 2. Extract and decompile ACPI tables

```bash
sudo apt install acpica-tools acpi-call-dkms
sudo acpidump > acpidump.out
acpixtract -a acpidump.out
iasl -d DSDT.dat      # → DSDT.dsl (~118k lines of ASL on this machine)
for f in ssdt*.dat; do iasl -d "$f"; done
```

## 3. Parsing the WMI registry (_WDG)

Each `_WDG` buffer record is 20 bytes: GUID(16) + objectId(2 ASCII) + flags(1)
+ instance(1). `flags & 0x10` = method. Parsing snippet:

```python
def fmt(b):  # GUID is mixed-endian
    return f"{b[3]:02X}{b[2]:02X}{b[1]:02X}{b[0]:02X}-{b[5]:02X}{b[4]:02X}-" \
           f"{b[7]:02X}{b[6]:02X}-{b[8:10].hex()}-{b[10:16].hex()}"
```

Key mappings found (4 `_WDG` buffers, 10 records total):

| GUID | objId | Methods |
|---|---|---|
| 644C5791-B7B0-4123-A90B-E93876E0DAAD | 'AA' | WQAA / WSAA (main control: profiles, LEDs, camera...) |
| 101F83BB-30B7-DF11-8D81-0800200C9A66 | 'CB' | WMCB (battery/charging policy) |
| ABBC0F40..48-8EA1-... | BV/B1/.../CT | WQxx/WSxx (keyboard, fans, etc.) |
| 05901221-D566-11D1-B2F0-00A0C9062910 | CC/AB/AE | events/data |

## 4. Profile control path (core finding)

`WSAA` (GUID 644C5791) dispatches on sub-command `GWF1`. Relevant branches:

- `GWF1 == 0x0300`: **performance profile switch**. DAT2 = 0/1/2
  (Office/Game/Turbo), written to EC register `APMD`, then calls
  `RCAP(One, Local0)` and `Notify(NPCF, 0xC0)`
- `GWF1 == 0x0206`: writes `OMCC` (profile-change confirmation flag)
- `GWF1 == 0x0202`: reads profile state (`ENTP` turbo bit, `AWMI`, ...)

This is exactly the WMI path the Windows Control Center uses when you switch
profiles.

## 5. EC registers (OperationRegion ERAM, EmbeddedControl 0x00-0xFF)

| Offset | Field | Meaning |
|---|---|---|
| 0x95 | APMD | performance profile: 0=Office 1=Game 2=Turbo |
| 0x5F bit3 | ENTP | turbo-mode enable bit |
| 0x62 bit0 | OMCC | profile-change confirmation |
| 0xA2 | CBSC | command status (0x0F triggers TPST flip) |

## 6. NVPCF (NVIDIA Platform Control Framework)

`Device (\_SB.PC00.PEG1.PEGP.NPCF)`, HID `NVDA0820`. Key Names:

| Object | Value here | Meaning |
|---|---|---|
| CTGP | init 0 | GPU boost authorization flag (**the key**) |
| DTGP | 1 | Dynamic Boost authorization |
| ACBT | 0x1B8 | AC-side boost TGP target (encoded; settles at 175W after negotiation) |
| ATPP | 0x280 | platform power budget |

The tail of `RCAP(Arg0, Arg1)`:

```
Case 0/1: CTGP=One, DTGP=One, DBAC=Zero, DBDC=Zero   ← activation path
Case 0x2: Notify(IETM, 0x88) only
```

Inside `NPCF._DSM` (UUID `36b49710-2483-11e7-9598-0800200c9a66`), func 0x02:

```
If CTGP == One: TGPA = ACBT   ← budget only granted when authorized
Else:           TGPA = Zero
```

Temperature target: `ODV0==2` (Turbo) → TGPU=0x4B (75°C), otherwise 0x57 (87°C).

## 7. Runtime verification (acpi_call, read-only)

```bash
echo '\_SB.NPCF.CTGP' > /proc/acpi/call; cat /proc/acpi/call   # 0x0
echo '\_SB.NPCF.ACBT' > /proc/acpi/call; cat /proc/acpi/call   # 0x1b8
echo '\SAPD'           > /proc/acpi/call; cat /proc/acpi/call   # 0x4
echo '\GPUM'           > /proc/acpi/call; cat /proc/acpi/call   # 0x0
```

Conclusion: the RCAP activation path never ran under Linux → CTGP stuck at 0
→ budget suppressed.

## 8. Unlock and verification

```bash
# Set the flag (firmware's own activation path, not a blind write)
echo '\_SB.PC00.LPCB.EC0.RCAP 0 0' > /proc/acpi/call
# Confirm
echo '\_SB.NPCF.CTGP' > /proc/acpi/call   # → 0x1

# Restart powerd to renegotiate NVPCF (mandatory, or the budget won't update)
sudo systemctl restart nvidia-powerd

nvidia-smi -q -d POWER   # Current Power Limit: 95W → 150W → 175W (Max)
```

Note: setting CTGP without restarting powerd actually drops the cap to 95W
(negotiation state interrupted); after the powerd restart it recovers and
climbs to the full 175W.

## 9. Measured results

Fixed 500-token benchmark (qwen3.8-27b, ninfer, fp8 KV, ctx 163840):

| State | Power Limit | SM clock | decode |
|---|---|---|---|
| powerd dead | 95W | ~800MHz | ~29 tok/s |
| powerd fine, CTGP=0 | 120W | ~930MHz | ~33 tok/s |
| CTGP=1 + renegotiation | 175W | ~1545MHz | 49–53 tok/s |

Sustained load (nvidia-smi dmon): 168–169W flat, 69°C (turbo 75°C target not hit).

## 10. Adaptation checklist for other machines

1. ACPI contains `Device (NPCF)` / HID `NVDA0820`
   (`grep NVDA0820 DSDT.dsl SSDT*.dsl`)
2. `\_SB.PC00.LPCB.EC0.RCAP` exists (or an equivalent activation method) with
   a `CTGP=One` branch in its tail Switch
3. `\_SB.NPCF.CTGP` is readable and reads 0 initially
4. nvidia-powerd journal contains "disable Dynamic Boost DC controller"

All four hold → `apply-boost.sh` is worth trying. Any fail → names/paths
differ; re-trace sections 3–6 on your own tables. **Do not blind-fire.**
