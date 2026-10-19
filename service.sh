#!/system/bin/sh
# ksuguard / service.sh
#
# 时机：ksud late-load 第 12 步（overlay 已挂完），非阻塞 NoWait。
# 也可由 ksud soft-reboot 内部的 on_services() 触发。
# 职责：启动看门狗。真正的启动逻辑在 guard.sh 的 start_watchdog()，
# 这里只做委派，避免三处脚本各写一份 setsid 判断。

# 必须用 dirname 而不是 ${0%/*}：以相对路径调用时 ${0%/*} 会得到脚本名本身，
# 拼出 "xxx.sh/guard.sh" 而 source 失败。
MODDIR=$(cd -P "$(dirname "$0")" 2>/dev/null && pwd)
[ -f "$MODDIR/guard.sh" ] || { echo "找不到 $MODDIR/guard.sh" >&2; exit 1; }
. "$MODDIR/guard.sh"

load_conf
sync_boot_id
start_watchdog