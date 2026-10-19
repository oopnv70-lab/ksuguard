#!/system/bin/sh
# ksuguard / guard.sh
#
# 唯一逻辑源。由下列 stage 脚本 source：
#   late-load.sh     ksud late-load 第 8 步（首次加载，早于 overlay 挂载）
#   post-fs-data.sh  ksud soft-reboot 内部重跑的 post-fs-data（同样早于挂载）
#   service.sh       ksud late-load 第 12 步（overlay 已挂完）→ 启看门狗
#   action.sh        手动触发
#
# 状态目录 /data/adb/ksuguard/
#   panic        存在 = 已判定显示链路损坏，挂载前必须禁用其他模块
#   panic.done   已处理过的 panic（归档，防止反复触发）
#   reboot.count 本次启动已自动软重启的次数
#   watchdog.pid 看门狗进程号
#   log          运行日志
#   config       可选覆盖

STATE=/data/adb/ksuguard
PANIC=$STATE/panic
LOG=$STATE/log
CONF=$STATE/config

SELF_ID=ksuguard
MODULES_DIR=/data/adb/modules
KSud=/data/adb/ksud

# 模块所在目录。source 本文件时 $0 仍是外层 stage 脚本的路径，
# 直接执行 guard.sh 时 $0 就是 guard.sh，两种情况 dirname 都是模块目录。
SELF_DIR=$(cd -P "$(dirname "$0")" 2>/dev/null && pwd)

# ---------- 基础 ----------

mkdir -p "$STATE" 2>/dev/null
chmod 700 "$STATE" 2>/dev/null

log() {
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "$*" >>"$LOG" 2>/dev/null
    # 裁剪：超过 2000 行保留后 1000 行
    _n=$(wc -l <"$LOG" 2>/dev/null || echo 0)
    if [ "$_n" -gt 2000 ] 2>/dev/null; then
        tail -n 1000 "$LOG" >"$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG" 2>/dev/null
    fi
}

load_conf() {
    CRASH_THRESHOLD=2
    CRASH_WINDOW=90
    MAX_REBOOT=2
    DO_UMOUNT=0
    [ -f "$CONF" ] && . "$CONF"
}

# 真开机（boot_id 变了）才清零软重启计数；软重启不改 boot_id，
# 所以同一次内核生命周期内的反复触发会被 MAX_REBOOT 拦住。
sync_boot_id() {
    _cur_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    _old_id=$(cat "$STATE/boot.id" 2>/dev/null)
    if [ "$_cur_id" != "$_old_id" ]; then
        echo "$_cur_id" >"$STATE/boot.id"
        rm -f "$STATE/reboot.count"
        log "sync_boot_id: 新内核周期 $_cur_id，软重启计数已清零"
    fi
}

# ---------- 禁用其他模块 ----------
# 直接建 disable 文件，不调 ksud：ksud module disable 会 switch_mnt_ns 并
# regenerate_preinit，而 late-load 模式不读 preinit，直接落盘更可靠。
disable_others() {
    # 参数 dry = 只统计不写文件，用于「决策留痕」和观察模式。
    _dry=${1:-}
    _d=
    _id=
    _n=0
    _plan=
    # 元模块是「挂载系统的实现者」本身。把它 disable 掉，等于所有模块
    # 全部失效、连恢复路径都没了 —— 这是实测踩到的真事故，必须排除。
    # 两种识别方式同时用：符号链接目标 + module.prop 的 metamodule=1。
    _meta=$(readlink -f /data/adb/metamodule 2>/dev/null)
    _meta_id=${_meta##*/}

    for _d in "$MODULES_DIR"/*; do
        [ -d "$_d" ] || continue
        _id=${_d##*/}
        [ "$_id" = "$SELF_ID" ] && continue
        [ -n "$_meta_id" ] && [ "$_id" = "$_meta_id" ] && continue
        if grep -qs '^metamodule=1' "$_d/module.prop" 2>/dev/null; then
            log "disable_others: $_id 是元模块，跳过"
            continue
        fi
        [ -f "$_d/disable" ] && continue
        if [ "$_dry" = "dry" ]; then
            _plan="$_plan $_id"
            _n=$((_n + 1))
        else
            : >"$_d/disable" 2>/dev/null && _n=$((_n + 1))
        fi
    done
    DISABLE_PLAN=${_plan# }
    if [ "$_dry" = "dry" ]; then
        log "disable_others[dry]: 将禁用 $_n 个 -> ${DISABLE_PLAN:-无}（已排除自身与元模块 ${_meta_id:-无}）"
    else
        log "disable_others: $_n 个模块被标记 disable（已排除自身与元模块 ${_meta_id:-无}）"
    fi
}

# ---------- 拆除模块挂载 ----------
# 实机事实（本机核实）：元模块是 magic_mount_rs（Magic Mount-rs v4.0.11），
# 用 bind mount + tmpfs 实现，不是 overlayfs。所以：
#   1) 按 $3=="overlay" 通配 umount 是错的 —— 会拆掉荣耀自带的 8 个
#      /product/* overlay（source 都是字面量 "overlay"），当场把机型搞坏。
#   2) 也不需要自己拆：ksud soft_reboot() 第一步就是
#      run_stage("emulated-soft-reboot")，而 run_stage 会优先执行元模块的
#      emulated-soft-reboot.sh → meta-mm emulated-soft-reboot，
#      其帮助文本明写 "Unmount persisted mounts for an emulated soft reboot"。
# 因此默认 DO_UMOUNT=0（交给元模块），设为 1 时才提前手工调一次，
# 且只调元模块、绝不按文件系统类型通配。
umount_overlays() {
    if [ "$DO_UMOUNT" != "1" ]; then
        log "umount_overlays: 跳过（交给 ksud soft-reboot 的 emulated-soft-reboot 阶段）"
        return 0
    fi

    _mm=
    if [ -L /data/adb/metamodule ] || [ -d /data/adb/metamodule ]; then
        _mm=/data/adb/metamodule/meta-mm
    fi

    if [ -x "$_mm" ]; then
        log "umount_overlays: 调用 $_mm emulated-soft-reboot"
        "$_mm" emulated-soft-reboot >>"$LOG" 2>&1
        log "umount_overlays: 元模块返回 $?"
        return 0
    fi

    log "umount_overlays: 未找到元模块 meta-mm，不做任何 umount（避免误拆 OEM overlay）"
    return 0
}

# ---------- 软重启用户空间 ----------
# ksud soft-reboot 内部：stop → on_post_fs_data()（重算挂载，读 disable）
# → start → on_services → on_boot_completed。它是唯一能让 disable 当场生效的路径。
do_soft_reboot() {
    # 参数 manual = 用户主动触发（把准入开关改成 2）。
    # 这种情况不计入 reboot.count、也不受 MAX_REBOOT 约束：
    # MAX_REBOOT 是为了拦住「崩溃 → 软重启 → 又崩」的自动循环，
    # 而用户手动改开关是一次性动作，不存在循环风险。
    _manual=${1:-}

    if [ "$_manual" = "manual" ]; then
        log "do_soft_reboot: 用户主动触发，不计入自动重启预算"
        _c=-
    else
        _cf=$STATE/reboot.count
        _c=$(cat "$_cf" 2>/dev/null || echo 0)
        case "$_c" in '' | *[!0-9]*) _c=0 ;; esac
        _c=$((_c + 1))
        echo "$_c" >"$_cf"

        if [ "$_c" -gt "$MAX_REBOOT" ]; then
            log "do_soft_reboot: 次数已用尽（$_c > $MAX_REBOOT），停止。磁盘状态已干净，硬重启一次即可。"
            return 1
        fi
    fi

    if [ -x "$KSud" ]; then
        if [ "$_c" = "-" ]; then
            log "do_soft_reboot: 调用 $KSud soft-reboot（主动触发）"
        else
            log "do_soft_reboot: 调用 $KSud soft-reboot（第 $_c/$MAX_REBOOT 次）"
        fi
        "$KSud" soft-reboot >>"$LOG" 2>&1
        log "do_soft_reboot: ksud 返回 $?"
    else
        log "do_soft_reboot: 找不到 ksud，退回 setprop ctl.restart zygote"
        setprop ctl.restart zygote
    fi
}

# ---------- 外部授权闸门（用户保底开关） ----------
# 位置 /data/local/tmp 的理由（实机核实）：
#   1) 它在 /data 卷（f2fs dm-88）上，post-fs-data 阶段就已挂好；
#      /sdcard 是 fuse 依赖 vold，早期可能读不到，所以不用 /sdcard。
#   2) ksud 的 clean_trash 只清 /data/adb/ksu/hot_install_trash/，
#      不会碰 /data/local/tmp，文件不会被守卫自己或 ksud 弄丢。
#   3) 目录属 shell drwxrwx--x，没 root 时也能用 adb / Termux 创建或删除。
# 语义：文件不存在 或 内容不是放行值 → 一律不执行任何破坏性动作。
GATE=/data/local/tmp/ksuguard.arm

gate_state() {
    if [ -f "$GATE" ]; then
        _g=$(head -n1 "$GATE" 2>/dev/null | tr -d ' \t\r\n')
        case "$_g" in
            1|on|ON|yes|YES|arm|ARM) echo armed; return 0 ;;
            *) echo off; return 0 ;;   # 文件在但内容不是放行值 = 明确否决
        esac
    fi
    echo missing
}

# 创建放行文件。
# 属主必须是 shell（uid 2000），权限必须 world-writable：
# 否则 root 建出的 0644 root:root 文件会挡住 `adb shell`（同为 uid 2000 但非 root）
# 的 `echo 1 > $GATE` 覆盖写——那时用户就只剩 `rm` 后重建一条路。
# 这里一次做对，使 root 建的文件和 adb 建的完全等价。
gate_arm() {
    mkdir -p "${GATE%/*}" 2>/dev/null
    printf '1\n' >"$GATE" 2>/dev/null || return 1
    # 关键：属主必须是 shell(2000)。root 建出来的 0644 root:root 会让
    # `adb shell`（uid 2000 但无 root）连 `echo 1 > $GATE` 都写不进去，
    # 只能走「先 rm 再建」。chown 一次，两种创建方式结果就等价了。
    _bb=/data/adb/ksu/bin/busybox
    if [ -x "$_bb" ]; then
        "$_bb" chown 2000:2000 "$GATE" 2>/dev/null
    else
        chown 2000:2000 "$GATE" 2>/dev/null
    fi
    chmod 0644 "$GATE" 2>/dev/null
    return 0
}

gate_disarm() {
    rm -f "$GATE" 2>/dev/null
    return 0
}

# ---------- 准入检查（1/2 开关，挂载前生效） ----------
# 与上面的 GATE（事后授权）是两回事，互不影响：
#   GATE      ：检测到崩溃后，要不要执行自救
#   MODE_FILE ：这次启动，到底挂不挂模块
#
# 位置仍在 /data/local/tmp：跨硬重启保留（在 /data 的 f2fs 上），
# 属主 shell，`adb shell`（uid 2000，无需 root）即可改。
# 这是临时 root 失效期间唯一还能被用户操作的干预点。
#
# 语义只有两个值：
#   内容 1 或文件不存在 → 正常，什么都不做（默认）
#   内容 2              → 禁用除自身与元模块外的全部模块
# 其它任何内容都按「正常」处理：宁可不拦，也不要因为误写一个字导致系统起不来。
MODE_FILE=/data/local/tmp/ksuguard.mode

mode_state() {
    [ -f "$MODE_FILE" ] || { echo normal; return 0; }
    _m=$(head -n1 "$MODE_FILE" 2>/dev/null | tr -d ' \t\r\n')
    case "$_m" in
        2) echo deny; return 0 ;;
        *) echo normal; return 0 ;;
    esac
}

mode_raw() {
    [ -f "$MODE_FILE" ] || { echo "(不存在)"; return 0; }
    head -n1 "$MODE_FILE" 2>/dev/null | tr -d ' \t\r\n'
}

# 禁用全部模块。直接复用 disable_others：它已经带「排除自身 + 排除元模块」
# 这道实测换来的保护，不必另写一份。
apply_deny_all() {
    log "MODE: $MODE_FILE = 2 → 禁用所有模块（元模块与自身除外）"
    disable_others
    write_plan "mode=2" "准入检查：禁用所有模块（不软重启）"
}

# 统计当前处于 disable 状态的模块数（排除自身与元模块）。
# 用途：确认「禁用」确实落地了，才允许把开关从 2 重置回 1。
# 否则一旦 disable 写入失败又把 2 抹掉，这次启动等于毫无保护。
count_disabled() {
    _c=0
    _m2=$(readlink -f /data/adb/metamodule 2>/dev/null)
    _m2=${_m2##*/}
    for _d2 in "$MODULES_DIR"/*; do
        [ -d "$_d2" ] || continue
        _i2=${_d2##*/}
        [ "$_i2" = "$SELF_ID" ] && continue
        [ -n "$_m2" ] && [ "$_i2" = "$_m2" ] && continue
        [ -f "$_d2/disable" ] && _c=$((_c+1))
    done
    echo "$_c"
}

# 准入检查入口。在 late-load 的挂载前环节被调用。
# 只读一个值、只在值为 2 时动作，不做任何猜测。
check_mode() {
    _ms=$(mode_state)
    _mv=$(mode_raw)
    if [ "$_ms" = "deny" ]; then
        apply_deny_all

        # 一次性语义：禁用成功后，立刻把 2 改回 1。
        # 不这么做的话，文件永远停在 2，每次启动都会再禁用一遍，
        # 系统会长期卡在「所有模块都不挂载」的状态，想恢复必须手动改文件。
        # 而 disable 文件写在 /data/adb/modules/<id>/disable 上，是持久的，
        # 重置成 1 之后保护依然生效，下一次启动只是不再重复干预。
        _n_dis=$(count_disabled)
        if [ "$_n_dis" -gt 0 ] 2>/dev/null; then
            printf '1\n' >"$MODE_FILE" 2>/dev/null
            chmod 0644 "$MODE_FILE" 2>/dev/null
            log "MODE: 已禁用 $_n_dis 个模块，并把 $MODE_FILE 重置为 1（一次性动作）"
            log "MODE: disable 标记是持久的，重启后仍生效；要恢复模块请用 action.sh resume"
        else
            # 没有禁用成功（可能模块目录为空或写入失败），保留 2 让下次重试
            log "MODE: 警告：本次没有禁用任何模块，保留 $MODE_FILE = 2 以便下次重试"
        fi
    else
        log "MODE: 正常（content=$_mv）→ 不做干预"
    fi
    return 0
}

# 初始化准入文件（管理器「执行」按钮的默认动作）。
# 目的只有一个：把文件建好，并把属主/权限设成「无 root 也能改」。
#
# 为什么必须先 chown 2000:2000：
#   adb shell 的身份是 uid 2000(shell) 但没有 root。
#   若文件由 root 创建（0644 root:root），adb 写它会 Permission denied，
#   那时用户只剩「rm 后重建」一条路，多一步就可能出错。
#   chown 到 shell 后，adb 直接 echo 就能覆盖写。
#
# 为什么是 0644 而不是 0666：
#   /data/local/tmp 目录对 others 有 --x（可穿过、不可列目录），
#   若文件设 0666，任何普通 App 只要知道路径就能写 —— 等于把开关交给任意应用。
#   0644 + 属主 2000，只有 shell 能写，够用且不放大权限。
#
# 内容不会被覆盖：已存在就只修权限，避免误点按钮把 2 改回 1 而意外挂回坏模块。
mode_init() {
    if [ -f "$MODE_FILE" ]; then
        _exist=1
    else
        _exist=0
        printf '1\n' >"$MODE_FILE" 2>/dev/null || return 1
    fi
    _bb=/data/adb/ksu/bin/busybox
    if [ -x "$_bb" ]; then
        "$_bb" chown 2000:2000 "$MODE_FILE" 2>/dev/null
    else
        chown 2000:2000 "$MODE_FILE" 2>/dev/null
    fi
    chmod 0644 "$MODE_FILE" 2>/dev/null
    log "MODE: 初始化 $MODE_FILE（exists=$_exist content=$(mode_raw) owner=$(ls -ln "$MODE_FILE" 2>/dev/null | awk '{print $3":"$4}' )) "
    return 0
}

# 决策留痕：把「准备做什么」写到 fixed 文件，供事后审阅
write_plan() {
    _p=$STATE/decision
    {
        printf 'time    : %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf 'reason  : %s\n' "$1"
        printf 'gate    : %s (%s)\n' "$(gate_state)" "$GATE"
        printf 'action  : %s\n' "$2"
        printf 'disable : %s\n' "${DISABLE_PLAN:-无}"
        printf 'umount  : DO_UMOUNT=%s\n' "$DO_UMOUNT"
        printf 'reboot  : 已用 %s / 上限 %s\n' "$(cat "$STATE/reboot.count" 2>/dev/null || echo 0)" "$MAX_REBOOT"
    } >"$_p" 2>/dev/null
    chmod 644 "$_p" 2>/dev/null
}

# ---------- panic ----------
do_panic() {
    _reason=$1
    log "PANIC: $_reason（gate=$(gate_state)）"

    # 第一段：只判定，不动系统。任何模式下都先算出「会怎样」。
    disable_others dry

    _gs=$(gate_state)
    case "$_gs" in
        armed)
            log "PANIC: 闸门已放行，开始执行"
            ;;
        missing)
            log "PANIC: $GATE 不存在 → 观察模式，只记录不执行"
            log "PANIC: 已否决；如需放行执行 echo 1 > $GATE"
            log "PANIC: 若确认要自救，可手动：sh ${SELF_DIR:-/data/adb/modules/ksuguard}/guard.sh force"
            write_plan "$_reason" "已否决（闸门文件不存在，观察模式）"
            return 0
            ;;
        off)
            log "PANIC: $GATE 内容非放行值 → 已否决，只记录不执行"
            write_plan "$_reason" "已否决（闸门文件存在但内容非放行值）"
            return 0
            ;;
    esac

    write_plan "$_reason" "已放行，执行 disable + 软重启"

    printf '%s reason=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$_reason" >"$PANIC" 2>/dev/null

    # 结束看门狗。若当前就是看门狗本进程，跳过自杀，否则后面的动作全跑不到。
    _wp=$(cat "$STATE/watchdog.pid" 2>/dev/null)
    if [ -n "$_wp" ] && [ "$_wp" != "$$" ] && [ -d "/proc/$_wp" ]; then
        kill "$_wp" 2>/dev/null
        log "PANIC: 已结束看门狗 $_wp"
    fi
    rm -f "$STATE/watchdog.pid"

    disable_others
    umount_overlays
    do_soft_reboot
}

# force：无视闸门强制走一遍（人工确认后的通道，等价于原来的 action.sh panic）
do_force() {
    _reason=${1:-force}
    log "FORCE: 人工强制触发（忽略闸门 $_GATE）"
    disable_others dry
    write_plan "$_reason" "人工 force，执行 disable + 软重启"

    printf '%s reason=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$_reason" >"$PANIC" 2>/dev/null
    _wp=$(cat "$STATE/watchdog.pid" 2>/dev/null)
    if [ -n "$_wp" ] && [ "$_wp" != "$$" ] && [ -d "/proc/$_wp" ]; then
        kill "$_wp" 2>/dev/null
        log "FORCE: 已结束看门狗 $_wp"
    fi
    rm -f "$STATE/watchdog.pid"

    disable_others
    umount_overlays
    do_soft_reboot
}

# 挂载前调用：有 panic 就按闸门决定是否禁用。此时还没有任何模块被挂上，不需要 umount。
consume_panic() {
    sync_boot_id
    [ -f "$PANIC" ] || return 0
    _reason=$(head -n1 "$PANIC" 2>/dev/null)
    log "pre-mount: 发现 panic（$_reason）"

    # 挂载前也要过闸门：否则「已经写下的 panic 文件」会绕过授权直接禁用模块。
    _gs=$(gate_state)
    if [ "$_gs" != "armed" ]; then
        log "pre-mount: 闸门未放行（$_gs）→ 只归档不执行"
        disable_others dry
        write_plan "$_reason" "pre-mount 已否决（gate=$_gs）"
        mv -f "$PANIC" "$STATE/panic.done" 2>/dev/null
        return 0
    fi

    log "pre-mount: 闸门已放行 → 禁用其他模块"
    disable_others
    write_plan "$_reason" "pre-mount 已放行，禁用其他模块（不软重启）"
    mv -f "$PANIC" "$STATE/panic.done" 2>/dev/null
    log "pre-mount: panic 已归档到 panic.done"
}

# ---------- 看门狗 ----------
# 判据只有一条：surfaceflinger 的 pid 发生变化。
# barrier 是「进程被杀」，不是「渲染出错」。驱动活着但画面错误，这里看不出来。
guard_watchdog() {
    load_conf

    # 以独立进程（sh guard.sh watchdog）运行时，$$ 才是本进程真实 pid
    _self=$$
    _old=$(cat "$STATE/watchdog.pid" 2>/dev/null)
    if [ -n "$_old" ] && [ "$_old" != "$_self" ] && [ -d "/proc/$_old" ]; then
        kill "$_old" 2>/dev/null && log "watchdog: 结束旧实例 $_old"
    fi
    echo "$_self" >"$STATE/watchdog.pid"

    log "watchdog: 启动 pid=$_self，阈值=$CRASH_THRESHOLD 次 / 窗口=${CRASH_WINDOW}s"

    _last=$(pidof surfaceflinger 2>/dev/null)

    # 若启动时 surfaceflinger 尚未就绪（pidof 为空），先等它出现再取基线，
    # 否则「基线为空」会让下面 [ -n "$_last" ] 的守卫把后续所有变化都跳过，
    # 崩溃循环时永远不计数（这是上一稿的真·漏判）。
    if [ -z "$_last" ]; then
        _w=0
        while [ -z "$_last" ] && [ "$_w" -lt 24 ]; do
            sleep 5
            _w=$((_w + 1))
            _last=$(pidof surfaceflinger 2>/dev/null)
        done
        [ -n "$_last" ] && log "watchdog: 等待 ${_w}0s 后取得基线"
    fi

    _t0=0
    _crash=0
    # 准入开关的实时监听：记住上一轮的值，值一变化就立刻响应。
    _mode_last=$(mode_state)
    _mode_try=0
    log "watchdog: surfaceflinger 基线 pid=${_last:-仍为空}，准入开关=${_mode_last}"

    while :; do
        sleep 5
        _cur=$(pidof surfaceflinger 2>/dev/null)

        # ---- 准入开关实时监听 ----
        # 用户把文件改成 2 的那一刻就要生效，不能等到下次开机。
        # 每 5 秒读一次，代价只是 head 一个 2 字节文件。
        _mcur=$(mode_state)
        if [ "$_mcur" != "$_mode_last" ]; then
            log "watchdog: 准入开关变化 $_mode_last → $_mcur"
            _mode_last=$_mcur
            # 值一变就重置重试预算，避免「上次失败过」影响这次。
            [ "$_mcur" = "deny" ] && _mode_try=0
        fi
        if [ "$_mcur" = "deny" ]; then
            if [ "$_mode_try" -ge 3 ]; then
                # 连续 3 次都没禁用成功，停止重试。否则每 5 秒重写一遍日志，
                # 而失败原因（多半是权限/元模块异常）不会靠重试自愈。
                if [ "$_mode_try" -eq 3 ]; then
                    log "watchdog: 连续 3 次禁用失败，停止重试；开关保留 2 等下个启动周期"
                    _mode_try=4
                fi
            else
                _mode_try=$((_mode_try + 1))
                log "watchdog: 检测到 mode=2（立即响应，第 $_mode_try 次）"
                apply_deny_all
                _n_dis=$(count_disabled)
                if [ "$_n_dis" -gt 0 ] 2>/dev/null; then
                    # 先重置再软重启：避免软重启时 post-fs-data 又读到 2 再禁一遍。
                    # disable 文件是持久的，重置成 1 不影响这次禁用结果。
                    printf '1\n' >"$MODE_FILE" 2>/dev/null
                    chmod 0644 "$MODE_FILE" 2>/dev/null
                    _mode_last=normal
                    log "watchdog: 已禁用 $_n_dis 个模块，开关已重置为 1"
                    log "watchdog: 模块仍在挂载中，软重启才能实际卸载"
                    rm -f "$STATE/watchdog.pid"
                    do_soft_reboot manual
                    return 0
                else
                    log "watchdog: 禁用未生效（0 个），保留 2 稍后重试"
                fi
            fi
        fi

        # 空 ↔ 非空也算变化：崩溃后进程消失，正是要看的情况。
        if [ "$_cur" != "$_last" ]; then
            _now=$(date +%s)
            if [ "$_crash" -eq 0 ]; then
                _crash=1
                _t0=$_now
            else
                _crash=$((_crash + 1))
                if [ $((_now - _t0)) -gt "$CRASH_WINDOW" ]; then
                    _crash=1
                    _t0=$_now
                fi
            fi
            log "watchdog: surfaceflinger $_last → ${_cur:-已消失}（第 $_crash 次）"

            if [ "$_crash" -ge "$CRASH_THRESHOLD" ]; then
                log "watchdog: 达到阈值，触发自救"
                do_panic "surfaceflinger 在 ${CRASH_WINDOW}s 内异常 ${_crash} 次"
                return 0
            fi
        fi
        _last=$_cur
    done
}

# ---------- 状态 ----------
show_status() {
    echo "state dir  : $STATE"
    echo "mode       : $(mode_state)  content=$(mode_raw)  ($MODE_FILE)"
    echo "gate       : $(gate_state)  ($GATE)"
    echo "panic      : $(if [ -f "$PANIC" ]; then head -n1 "$PANIC"; else echo none; fi)"
    if [ -f "$STATE/panic.done" ]; then
        echo "panic.done : $(head -n1 "$STATE/panic.done")"
    fi
    if [ -f "$STATE/decision" ]; then
        echo "--- 最近一次决策 ---"
        sed 's/^/  /' "$STATE/decision" 2>/dev/null
        echo "--------------------"
    fi
    echo "reboot cnt : $(cat "$STATE/reboot.count" 2>/dev/null || echo 0)/$MAX_REBOOT"
    echo "watchdog   : $(if [ -n "$(cat "$STATE/watchdog.pid" 2>/dev/null)" ]; then cat "$STATE/watchdog.pid"; else echo none; fi)"
    echo "sf pid     : $(pidof surfaceflinger 2>/dev/null || echo '(未运行)')"
    echo "kernel     : $(uname -r)"
    echo "boot_id    : $(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
    echo "ksud       : $(if [ -x "$KSud" ]; then echo "$KSud ok"; else echo missing; fi)"
    echo "mm         : $(if [ -x /data/adb/metamodule/meta-mm ]; then /data/adb/metamodule/meta-mm version 2>/dev/null | head -c 200; else echo none; fi)"
    echo "kmi        : $(getprop ro.kernelsu.version 2>/dev/null)"
    echo "uapi       : $(/data/adb/ksud --version 2>/dev/null | head -1)"
    echo "modules:"
    for _d in "$MODULES_DIR"/*; do
        [ -d "$_d" ] || continue
        _i=${_d##*/}
        if [ -f "$_d/disable" ]; then echo "  $_i  [disabled]"; else echo "  $_i"; fi
    done
}

# ---------- 启动看门狗 ----------
# 必须以独立进程启动，不能用 `guard_watchdog &`：
# ash 的子 shell 里 $$ 等于父 shell 的 pid，子 shell 中写 pid 文件再用 $$
# 判断「是不是自己」会误判成别人而自杀，导致 panic 后的 disable /
# soft-reboot 全部执行不到。`sh guard.sh watchdog` 是新进程，$$ 天然正确；
# setsid 只作附加保护（父进程退出时不被 SIGHUP 带走），不可用时也能work。
start_watchdog() {
    # 必须取绝对目录：以相对路径调用（如 `sh guard.sh start`）时
    # ${0%/*} 会得到 "guard.sh"，拼出 "guard.sh/guard.sh" 这种不存在的路径。
    _self_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
    if [ -z "$_self_dir" ]; then
        log "start_watchdog: 无法解析模块目录（\$0=$0），放弃"
        return 1
    fi
    if [ ! -f "$_self_dir/guard.sh" ]; then
        log "start_watchdog: $_self_dir/guard.sh 不存在，放弃"
        return 1
    fi

    _wp=$(cat "$STATE/watchdog.pid" 2>/dev/null)
    if [ -n "$_wp" ] && [ "$_wp" != "$$" ] && [ -d "/proc/$_wp" ]; then
        log "start_watchdog: 已有实例 pid=$_wp，跳过"
        return 0
    fi

    _bb=/data/adb/ksu/bin/busybox
    if [ -x "$_bb" ] && "$_bb" setsid true >/dev/null 2>&1; then
        "$_bb" setsid sh "$_self_dir/guard.sh" watchdog >>"$LOG" 2>&1 &
    elif setsid true >/dev/null 2>&1; then
        setsid sh "$_self_dir/guard.sh" watchdog >>"$LOG" 2>&1 &
    else
        sh "$_self_dir/guard.sh" watchdog >>"$LOG" 2>&1 &
    fi
    log "start_watchdog: 已拉起（sh=$_self_dir/guard.sh），实际 pid 见 watchdog.pid"
}

# ---------- 直接执行时的分发 ----------
# 用 $0 的 basename 判断：被 source 时 $0 是外层脚本（late-load.sh 等），
# 只有直接 `sh guard.sh ...` 调用才会进入。
case "${0##*/}" in
    guard.sh)
        case "${1:-status}" in
            watchdog) guard_watchdog ;;
            start) load_conf; sync_boot_id; start_watchdog ;;
            panic) load_conf; do_panic "${2:-manual}" ;;
            force) load_conf; do_force "${2:-force}" ;;
            gate) load_conf; echo "gate=$(gate_state) file=$GATE" ;;
            arm) load_conf; gate_arm; log "GATE: 已放行（$GATE）"; echo "已放行：$(gate_state)"; ls -ln "$GATE" 2>/dev/null | awk '{print "  属主 "$3":"$4"  权限 "$1}' ;;
            disarm) load_conf; gate_disarm; log "GATE: 已收回（删除 $GATE）"; echo "已收回：$(gate_state)" ;;
            consume) load_conf; consume_panic ;;
            mode) load_conf; echo "mode=$(mode_state) content=$(mode_raw) file=$MODE_FILE" ;;
            modecheck) load_conf; check_mode; echo "mode=$(mode_state) content=$(mode_raw)" ;;
            status) load_conf; show_status ;;
            *) echo "用法: $0 {watchdog|start|panic [原因]|force [原因]|gate|arm|disarm|mode|modecheck|consume|status}" >&2; exit 2 ;;
        esac
        ;;
esac