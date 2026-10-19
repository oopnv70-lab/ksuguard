#!/system/bin/sh
# ksuguard / late-load.sh
#
# 时机：ksud late-load 第 8 步，早于第 10 步 metamodule overlay 挂载。
# 挂载前是唯一能「决定这次挂不挂」的位置。

# 必须用 dirname 而不是 ${0%/*}：以相对路径调用时 ${0%/*} 会得到脚本名本身，
# 拼出 "xxx.sh/guard.sh" 而 source 失败。
MODDIR=$(cd -P "$(dirname "$0")" 2>/dev/null && pwd)
[ -f "$MODDIR/guard.sh" ] || { echo "找不到 $MODDIR/guard.sh" >&2; exit 1; }
. "$MODDIR/guard.sh"

load_conf
# 第一道门：准入检查。必须排在 consume_panic 之前——
# 它是「这次到底挂不挂模块」，优先级高于「上次崩了要不要自救」。
check_mode
consume_panic