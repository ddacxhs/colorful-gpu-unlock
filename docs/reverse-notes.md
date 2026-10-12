# 逆向笔记：七彩虹隐星 G16 Pro GPU 功耗解锁

本文记录完整的逆向与验证过程，供适配其他机型参考。
开发机：七彩虹隐星 G16 Pro（i9-14900HX + RTX 5090 Laptop），Deepin 23，
kernel 6.6.155，NVIDIA 驱动 595.99.02。

## 1. 问题定位

`nvidia-smi -q -d POWER`：Default 95W / Max 175W，负载时 Current 只到 120W。
`journalctl -u nvidia-powerd` 出现：

```
ERROR! Client (presumably SBIOS) has requested to disable Dynamic Boost DC controller
```

即 powerd 活着、DBus 正常，但固件侧不授权完整 boost 预算。

## 2. 提取并反编译 ACPI 表

```bash
sudo apt install acpica-tools acpi-call-dkms
sudo acpidump > acpidump.out
acpixtract -a acpidump.out
iasl -d DSDT.dat      # 产出 DSDT.dsl (本机 ~11.8 万行 ASL 源码)
for f in ssdt*.dat; do iasl -d "$f"; done
```

## 3. 解析 WMI 注册表 (_WDG)

`_WDG` 缓冲区每 20 字节一条记录：GUID(16) + objectId(2 ASCII) + flags(1) + instance(1)。
flags & 0x10 = method。解析脚本要点：

```python
def fmt(b):  # GUID 混端序
    return f"{b[3]:02X}{b[2]:02X}{b[1]:02X}{b[0]:02X}-{b[5]:02X}{b[4]:02X}-" \
           f"{b[7]:02X}{b[6]:02X}-{b[8:10].hex()}-{b[10:16].hex()}"
```

本机关键映射（DSDT 内 4 个 _WDG，共 10 条记录）：

| GUID | objId | 方法 |
|---|---|---|
| 644C5791-B7B0-4123-A90B-E93876E0DAAD | 'AA' | WQAA / WSAA（主控制，档位/灯效/相机等） |
| 101F83BB-30B7-DF11-8D81-0800200C9A66 | 'CB' | WMCB（电池/充电策略） |
| ABBC0F40..48-8EA1-... | BV/B1/.../CT | WQxx/WSxx（键盘、风扇等） |
| 05901221-D566-11D1-B2F0-00A0C9062910 | CC/AB/AE | 事件/数据 |

## 4. 档位控制链路（核心发现）

`WSAA`（GUID 644C5791）内部按 `GWF1` 子命令分发，与本任务相关的：

- `GWF1 == 0x0300`：**性能档位切换**。DAT2 = 0/1/2（办公/游戏/狂暴），
  写入 EC 寄存器 `APMD`，随后调用 `RCAP(One, Local0)` 并 `Notify(NPCF, 0xC0)`
- `GWF1 == 0x0206`：写 `OMCC`（档位切换确认标志）
- `GWF1 == 0x0202`：读档位状态（`ENTP` 狂暴位、`AWMI` 等）

Windows 控制中心切档走的就是这条 WMI 路径。

## 5. EC 寄存器（OperationRegion ERAM, EmbeddedControl 0x00-0xFF）

| 偏移 | 字段 | 含义 |
|---|---|---|
| 0x95 | APMD | 性能档位 0=办公 1=游戏 2=狂暴 |
| 0x5F bit3 | ENTP | 狂暴模式启用位 |
| 0x62 bit0 | OMCC | 档位切换确认 |
| 0xA2 | CBSC | 命令状态（0x0F 触发 TPST 翻转） |

## 6. NVPCF（NVIDIA Platform Control Framework）

`Device (\_SB.PC00.PEG1.PEGP.NPCF)`，HID `NVDA0820`。关键 Name：

| 对象 | 本机值 | 含义 |
|---|---|---|
| CTGP | 初始 0 | GPU boost 授权标志（**解锁的关键**） |
| DTGP | 1 | Dynamic Boost 授权 |
| ACBT | 0x1B8 | AC 侧 boost TGP 目标（编码值，经 NVPCF 协商后落地 175W） |
| ATPP | 0x280 | 平台功耗总预算 |

`RCAP(Arg0, Arg1)` 尾部的 `Switch(Arg0)`：

```
Case 0/1: CTGP=One, DTGP=One, DBAC=Zero, DBDC=Zero   ← 启用路径
Case 0x2: 仅 Notify(IETM, 0x88)
```

`NPCF._DSM`（UUID `36b49710-2483-11e7-9598-0800200c9a66`）func 0x02 中：

```
If CTGP == One: TGPA = ACBT   ← 授权后预算才下发
Else:           TGPA = Zero
```

温度墙：`ODV0==2`（狂暴档）时 TGPU=0x4B（75°C），否则 0x57（87°C）。

## 7. 运行时验证（acpi_call，只读）

```bash
echo '\_SB.NPCF.CTGP' > /proc/acpi/call; cat /proc/acpi/call   # 0x0
echo '\_SB.NPCF.ACBT' > /proc/acpi/call; cat /proc/acpi/call   # 0x1b8
echo '\SAPD'           > /proc/acpi/call; cat /proc/acpi/call   # 0x4
echo '\GPUM'           > /proc/acpi/call; cat /proc/acpi/call   # 0x0
```

结论：Linux 下从未执行过 RCAP 启用路径 → CTGP 恒 0 → 预算被压。

## 8. 解锁与验证

```bash
# 置位（固件自己的启用路径，非盲写）
echo '\_SB.PC00.LPCB.EC0.RCAP 0 0' > /proc/acpi/call
# 确认
echo '\_SB.NPCF.CTGP' > /proc/acpi/call   # → 0x1

# 重启 powerd 触发 NVPCF 重协商（必须，否则预算不更新）
sudo systemctl restart nvidia-powerd

nvidia-smi -q -d POWER   # Current Power Limit: 95W → 150W → 175W (Max)
```

注意：仅置 CTGP 不重启 powerd 时，功耗墙反而回落 95W（协商状态被打断），
重启 powerd 后立即恢复并升至满血。

## 9. 实测数据

500-token 固定压测（qwen3.8-27b, ninfer, fp8 KV, ctx 163840）：

| 状态 | Power Limit | SM 时钟 | decode |
|---|---|---|---|
| powerd 空转 | 95W | ~800MHz | ~29 tok/s |
| powerd 正常, CTGP=0 | 120W | ~930MHz | ~33 tok/s |
| CTGP=1 + 重协商 | 175W | ~1545MHz | 49~53 tok/s |

满载 dmon：168~169W 稳定，温度 69°C（狂暴档温墙 75°C 未触发）。

## 10. 适配其他机型的检查清单

1. ACPI 中存在 `Device (NPCF)` / HID `NVDA0820`（grep `NVDA0820` DSDT.dsl SSDT*.dsl）
2. 存在 `\_SB.PC00.LPCB.EC0.RCAP`（或同名启用路径），且尾部 Switch 有
   `CTGP=One` 分支
3. `\_SB.NPCF.CTGP` 可读且初值为 0
4. nvidia-powerd 日志含 "disable Dynamic Boost DC controller"

四条都满足 → `apply-boost.sh` 可直接尝试；任一不满足 → 方法名/路径不同，
需按本文第 3-6 节重新梳理，**不要盲调**。
