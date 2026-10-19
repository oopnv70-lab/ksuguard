#!/system/bin/sh
# ksuguard / post-fs-data.sh
#
# 时机：标准启动模式下的 post-fs-data；以及 —— 关键 ——
# ksud soft-reboot 内部会重跑 on_post_fs_data()，走的就是这个脚本。
# 所以「软重启后重新判定挂不挂」靠的是这里，而不是 late-load.sh。
#
# 与 late-load.sh 的逻辑完全一致，两者共用 guard.sh。

# 必须用 dirname 而不是 ${0%/*}：以相对路径调用时 ${0%/*} 会得到脚本名本身，
# 拼出 "xxx.sh/guard.sh" 而 source 失败。
MODDIR=$(cd -P "$(dirname "$0")" 2>/dev/null && pwd)
[ -f "$MODDIR/guard.sh" ] || { echo "找不到 $MODDIR/guard.sh" >&2; exit 1; }
. "$MODDIR/guard.sh"

load_conf
# 准入检查。软重启走的是本脚本（on_post_fs_data），不经过 late-load.sh，
# 所以这里必须同样检查一次，否则「改成 2 + 软重启」不会生效。
check_mode
consume_panic