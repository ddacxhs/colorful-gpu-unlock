#!/bin/bash
# colorful-gpu-unlock: 启用 GPU 满血功耗 (固件 CTGP 置位 + powerd 重协商)
# 适用: 七彩虹隐星 G16 Pro 及同方模具机型 (需先确认 ACPI 对象存在, 见 README)
# 依赖: acpi_call 模块 (acpi-call-dkms)
set -u

fail() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "run as root (sudo)"

modprobe acpi_call 2>/dev/null
[ -w /proc/acpi/call ] || fail "/proc/acpi/call not available (acpi_call module loaded?)"

# 1) 前置检查: NPCF.CTGP 对象必须存在 (防止在不适用的机型上盲调)
echo '\_SB.NPCF.CTGP' > /proc/acpi/call
CUR=$(tr -d '\0' < /proc/acpi/call)
case "$CUR" in
  0x*) echo "CTGP current: $CUR" ;;
  *)   fail "path \\_SB.NPCF.CTGP not found on this machine — not applicable, aborting" ;;
esac

# 2) 调固件自己的启用路径: RCAP(0,0) → CTGP=1, DTGP=1
echo '\_SB.PC00.LPCB.EC0.RCAP 0 0' > /proc/acpi/call
RET=$(tr -d '\0' < /proc/acpi/call)
echo "RCAP(0,0) returned: $RET"

# 3) 确认置位
echo '\_SB.NPCF.CTGP' > /proc/acpi/call
NOW=$(tr -d '\0' < /proc/acpi/call)
echo "CTGP now: $NOW"
[ "$NOW" = "0x1" ] || fail "CTGP did not become 0x1 (got: $NOW) — not applying"

# 4) 重启 nvidia-powerd 触发 NVPCF 重协商
if systemctl is-active --quiet nvidia-powerd; then
    systemctl restart nvidia-powerd
    echo "nvidia-powerd restarted (NVPCF renegotiated)"
else
    echo "WARN: nvidia-powerd not active; start it to finish negotiation" >&2
fi

logger -t gpu-boost-unlock "applied: CTGP $CUR -> $NOW"
echo "Done. Verify with: nvidia-smi -q -d POWER | grep 'Current Power Limit'"
