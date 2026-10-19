#!/system/bin/sh
# ksuguard / boot-completed.sh
#
# 时机：ksud late-load 第 13 步 / 标准启动 boot-completed，非阻塞。
#
# 重要：本脚本不能用作「上次是否黑屏」的判据。late-load 模式下屏幕黑了、
# SurfaceFlinger 死了，ksud 依然会执行到这一步。拿它当「活到桌面」的证据，
# 判据永远成立（这是上一版的致命缺陷）。
# 这里只做两件事：记录、以及看门狗兜底。

# 必须用 dirname 而不是 ${0%/*}：以相对路径调用时 ${0%/*} 会得到脚本名本身，
# 拼出 "xxx.sh/guard.sh" 而 source 失败。
MODDIR=$(cd -P "$(dirname "$0")" 2>/dev/null && pwd)
[ -f "$MODDIR/guard.sh" ] || { echo "找不到 $MODDIR/guard.sh" >&2; exit 1; }
. "$MODDIR/guard.sh"

load_conf
log "boot-completed: boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"

# 看门狗若没起来，兜底再拉一次（start_watchdog 内部已判断存活实例）
start_watchdog