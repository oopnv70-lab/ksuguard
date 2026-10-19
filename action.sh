#!/system/bin/sh
# ksuguard / action.sh
#
# 手动通道。KernelSU 管理器的模块卡片「执行」按钮会跑这个（默认 panic），
# 也可以直接命令行调用：
#   su -c 'sh /data/adb/modules/ksuguard/action.sh status'
#
# 参数：
#   （无参数） 初始化准入文件 /data/local/tmp/ksuguard.mode：建好并设为 2000:2000 0644
#              管理器模块卡片的「执行」按钮走这里，可重复点，不覆盖已有内容
#   status   打印状态 + 最近一次决策（安全，不动任何东西）
#   mode     只看准入开关（/data/local/tmp/ksuguard.mode 的内容）
#   modecheck 立刻按当前值跑一次准入检查（1=不动，2=禁用所有模块）
#   panic    触发一次判定，但仍受闸门约束（闸门未放行则只记录）
#   force    无视闸门强制执行（人工确认后的通道）
#   arm      放行：创建 /data/local/tmp/ksuguard.arm
#   disarm   收回：删除该文件
#   gate     只看闸门状态
#   resume   清掉其他模块的 disable，并清 panic/reboot 计数
#   dry      只算「会禁用哪些模块」，绝不写文件（纯预演）
#
# 两套开关不要搞混：
#   mode  = 这次启动挂不挂模块（事前，1/2）
#   gate  = 崩溃后要不要自救（事后，文件在/不在）

# 必须用 dirname 而不是 ${0%/*}：以相对路径调用时 ${0%/*} 会得到脚本名本身，
# 拼出 "xxx.sh/guard.sh" 而 source 失败。
MODDIR=$(cd -P "$(dirname "$0")" 2>/dev/null && pwd)
[ -f "$MODDIR/guard.sh" ] || { echo "找不到 $MODDIR/guard.sh" >&2; exit 1; }
. "$MODDIR/guard.sh"

load_conf

# 管理器模块卡片的「执行」按钮会不带参数跑这个脚本。
# 默认动作 = 初始化准入文件（建好 + 修权限），不触发任何破坏性动作。
case "${1:-init}" in
    init|"")
        mode_init || { echo "创建失败: $MODE_FILE" >&2; exit 1; }
        echo "已就绪: $MODE_FILE"
        echo "内容   : $(mode_raw)  （1=正常  2=禁用所有模块）"
        ls -ln "$MODE_FILE" 2>/dev/null | awk '{print "属主   : "$3":"$4"   权限: "$1}'
        echo
        echo "无 root 时用 adb 改："
        echo "  adb shell 'echo 2 > $MODE_FILE'   # 下次启动禁用所有模块"
        echo "  adb shell 'echo 1 > $MODE_FILE'   # 恢复正常"
        echo
        echo "其它：sh $SELF_DIR/action.sh {status|mode|gate}"
        ;;
    status)
        show_status
        ;;
    gate)
        echo "gate = $(gate_state)"
        echo "file = $GATE"
        echo "放行: sh $SELF_DIR/action.sh arm"
        echo "收回: sh $SELF_DIR/action.sh disarm"
        ;;
    arm)
        gate_arm || { echo "创建失败: $GATE" >&2; exit 1; }
        log "GATE: 已放行（$GATE）"
        echo "gate = $(gate_state)"
        ls -ln "$GATE" 2>/dev/null | awk '{print "属主 "$3":"$4"  权限 "$1}'
        echo "现在自动自救已生效。收回: sh $SELF_DIR/action.sh disarm"
        echo "adb 侧也可直接改: adb shell 'echo 1 > $GATE' / adb shell 'rm $GATE'"
        ;;
    disarm)
        gate_disarm
        log "GATE: 已收回（删除 $GATE）"
        echo "gate = $(gate_state)"
        echo "现在即使判定到故障也只记录、不执行。"
        ;;
    mode)
        echo "mode = $(mode_state)   content = $(mode_raw)"
        echo "file = $MODE_FILE"
        echo "1 = 正常（默认）  2 = 禁用所有模块"
        ;;
    modecheck)
        check_mode
        echo "mode = $(mode_state)   content = $(mode_raw)"
        echo "（已按当前值执行一次准入检查，结果见上方日志）"
        ;;
    dry)
        disable_others dry
        echo "gate   = $(gate_state)"
        echo "会禁用 = ${DISABLE_PLAN:-无}"
        ;;
    panic)
        echo "触发判定（闸门=$(gate_state)）"
        do_panic "action.sh 手动触发"
        ;;
    force)
        echo "强制自救（忽略闸门）"
        do_force "action.sh 强制触发"
        ;;
    resume)
        _n=0
        # 元模块也在恢复范围内：若它被误 disable，所有模块都挂不上。
        _meta=$(readlink -f /data/adb/metamodule 2>/dev/null)
        _meta_id=${_meta##*/}
        for _d in "$MODULES_DIR"/*; do
            [ -d "$_d" ] || continue
            [ "${_d##*/}" = "$SELF_ID" ] && continue
            if [ -f "$_d/disable" ]; then
                rm -f "$_d/disable" && _n=$((_n + 1))
            fi
        done
        rm -f "$PANIC" "$STATE/panic.done" "$STATE/reboot.count"
        echo "已恢复 $_n 个模块的 disable 标记（元模块 ${_meta_id:-无} 也在恢复范围内）"
        echo "panic 状态已清除，reboot.count 已清零"
        echo "需要重新挂载才能生效：ksud soft-reboot"
        ;;
    *)
        echo "用法: action.sh [init|status|mode|modecheck|gate|arm|disarm|dry|panic|force|resume]" >&2
        exit 2
        ;;
esac