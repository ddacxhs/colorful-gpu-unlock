# colorful-gpu-unlock

[English](README.en.md) | 简体中文

解锁七彩虹（Colorful）隐星系列游戏本在 Linux 下的满血 GPU 功耗。

在七彩虹隐星 G16 Pro（i9-14900HX + RTX 5090 Laptop 24GB）上开发验证，
对同方（Tongfang）模具的其他七彩虹/隐星机型大概率同样适用。

**效果：GPU 功耗墙 95W/120W → 175W（硬件上限），实测 decode 吞吐 +75%。**

```
修复前:  95W 墙, SM 800MHz,  decode ~29 tok/s
中间态: 120W 墙, SM 930MHz,  decode ~33 tok/s
解锁后: 175W 墙, SM 1545MHz, decode 49~53 tok/s  (500-token 稳定压测)
```

## 背景

- Windows 下 OEM 控制中心（性能档位：办公/游戏/狂暴）切换时会通过 WMI → EC
  通知固件"授权"GPU 高功耗档；此后 NVIDIA powerd 与固件的 NVPCF 协商才能拿到
  完整 boost 预算。
- Linux 下没人做这个切换动作，固件授权标志 (`\_SB.NPCF.CTGP`) 永远是 0。
  即使 nvidia-powerd 正常运行，NVPCF 也只批底值预算（本机为 120W），
  且 powerd 日志出现：
  `ERROR! Client (presumably SBIOS) has requested to disable Dynamic Boost DC controller`
- 本项目调用固件**自己的启用路径** `\_SB.PC00.LPCB.EC0.RCAP(0,0)` 置位 CTGP，
  再重启 nvidia-powerd 触发重协商，绕过 Windows 完成同样的解锁。

⚠️ 注意这不是"硬拉功耗"：不修改任何 VBIOS/EC 固件数据，只是调用 OEM 固件
已经提供的官方入口。固件自带的温度墙（狂暴档 75°C）、电源档位逻辑全部保留。

## 适用性自查

满足以下全部条件的机型可以尝试：

1. `nvidia-smi -q -d POWER` 显示 Default Power Limit 远低于 Max Power Limit
   （本机 95W vs 175W）
2. nvidia-powerd 已正常运行（`systemctl status nvidia-powerd`），
   但功耗墙仍然低于 Max；日志含上面的 "disable Dynamic Boost" 错误
3. ACPI 反编译后存在 `Device (NPCF)`（HID `NVDA0820`）与
   `\_SB.PC00.LPCB.EC0` 下的 `RCAP` 方法 —— 见 [docs/reverse-notes.md](docs/reverse-notes.md)

## 使用

依赖：`acpi_call` 内核模块（`sudo apt install acpi-call-dkms` 或等效包，
编译需要 `linux-headers-$(uname -r)`），NVIDIA 驱动 + nvidia-powerd 已装好。

> **Deepin / UOS 用户注意**：这些发行版的 NVIDIA 驱动包不安装
> `nvidia-dbus.conf`，导致 nvidia-powerd 空转（这是解锁前的第一道坎）。
> 手动补上并重启服务：
>
> ```bash
> sudo cp /usr/share/doc/NVIDIA_GLX-1.0/nvidia-dbus.conf /etc/dbus-1/system.d/
> sudo systemctl restart nvidia-powerd
> ```

重装系统后从零开始：

```bash
sudo apt install acpi-call-dkms
git clone https://github.com/ddacxhs/colorful-gpu-unlock.git
cd colorful-gpu-unlock
sudo scripts/apply-boost.sh

# 验证: 应看到 Current Power Limit = Max Power Limit
nvidia-smi -q -d POWER | grep -E "Current|Max Power Limit"
```

开机自动解锁：

```bash
sudo cp scripts/apply-boost.sh /usr/local/sbin/
sudo cp scripts/gpu-boost-unlock.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now gpu-boost-unlock.service
```

睡眠唤醒/切换电源后如发现功耗墙回落，重跑一次即可：
`sudo systemctl start gpu-boost-unlock`

## 工作原理

```
apply-boost.sh
  ├─ modprobe acpi_call
  ├─ echo '\_SB.PC00.LPCB.EC0.RCAP 0 0' > /proc/acpi/call
  │     └─ 固件内部路径: CTGP=1, DTGP=1 (GPU boost + Dynamic Boost 授权)
  └─ systemctl restart nvidia-powerd
        └─ powerd 重新与 NVPCF 协商 → 拿到完整 boost 预算 (本机 175W)
```

关键 ACPI 对象（隐星 G16 Pro 实测）：

| 对象 | 含义 |
|---|---|
| `\_SB.PC00.LPCB.EC0.RCAP` | 档位应用入口（RCAP(0,0) = 启用 GPU boost 授权） |
| `\_SB.NPCF.CTGP` | GPU boost 授权标志（0=禁用 1=启用），解锁后应为 1 |
| `\_SB.NPCF.ACBT` | AC 侧 boost TGP 目标（本机 0x1B8） |
| `\_SB.PC00.LPCB.EC0.APMD` (EC 0x95) | 性能档位 0=办公 1=游戏 2=狂暴 |

不同机型的方法名/路径可能不同，务必先按 [docs/reverse-notes.md](docs/reverse-notes.md)
在自己机器的 ACPI 表里确认同名对象存在，再执行解锁。

## 风险与免责

- 本脚本仅调用固件已有方法，不写裸 EC 寄存器、不改固件数据；
  但 ACPI 操作本身具有平台相关性，**不保证在所有机型上安全**。
- 固件自带的温度墙/电流保护仍然生效，但高功耗档意味着更高的发热与风扇转速，
  请确保散热正常。
- 使用本项目产生的任何问题由使用者自行承担。请先在你的机型上完成
  适用性自查（第 3 步尤其重要），再执行解锁。

## 验证环境

| 项 | 值 |
|---|---|
| 机型 | 七彩虹隐星 G16 Pro（DMI: COLORFUL / G16 Pro） |
| CPU / GPU | i9-14900HX / RTX 5090 Laptop 24GB (10de:2c18) |
| 系统 | Deepin 23 (beige), kernel 6.6.155-amd64-desktop-hwe |
| 驱动 | NVIDIA 595.99.02 + nvidia-powerd 595.99.02 |
| acpi_call | 1.2.2 (dkms) |

## 致谢与参考

- [IzzieBoopers/5080-Unlock_Linux](https://github.com/IzzieBoopers/5080-Unlock_Linux) —
  HP OMEN 5080 同类问题（WMI CTGP/DTGP 标志位）的先行者，本项目思路来源
- NVIDIA 官方论坛帖（含完整排查过程）:
  [RTX 5090 Laptop Dynamic Boost capped at 120W](https://forums.developer.nvidia.com/t/385659)

## License

MIT
