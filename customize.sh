#!/system/bin/sh
# ksuguard / customize.sh —— 安装期定制
#
# KernelSU 在解压模块后 source 本脚本（在 /data/adb/modules_update/<id>/ 下）。
# 不写 META-INF/update-binary —— 那是 Magisk 规范，KernelSU 不需要。

SKIPUNZIP=0

# installer.sh 已默认做过 set_perm_recursive "$MODPATH" 0 0 0755 0644，
# 这里只需单独把脚本置可执行。注意 set_perm_recursive 的第 6 参是 SELinux
# context 而不是通配符，不能拿来按扩展名过滤，所以直接用 find。
find "$MODPATH" -type f -name '*.sh' -exec chmod 0755 {} + 2>/dev/null
set_perm "$MODPATH/module.prop" 0 0 0644

STATE=/data/adb/ksuguard
mkdir -p "$STATE"
chmod 700 "$STATE"

# 首次安装写入默认配置，已存在则不覆盖
if [ ! -f "$STATE/config" ]; then
    cat >"$STATE/config" <<'EOF'
# ksuguard 运行参数，改完立即生效（每次 watchdog/启动脚本读取）
#
# CRASH_THRESHOLD  surfaceflinger 在窗口内异常几次判定为坏
# CRASH_WINDOW     窗口长度（秒）
# MAX_REBOOT       同一内核周期内最多自动软重启几次
# DO_UMOUNT        0=交给 ksud soft-reboot 自带的 emulated-soft-reboot 阶段拆挂载（推荐）
#                  1=panic 时额外先手工调一次 meta-mm emulated-soft-reboot
CRASH_THRESHOLD=2
CRASH_WINDOW=90
MAX_REBOOT=2
DO_UMOUNT=0
EOF
    chmod 600 "$STATE/config"
fi

# 安装时就建好准入文件并修正权限，省得用户还要手点一次按钮。
# 属主设为 2000(shell)：保证日后无 root 时 `adb shell` 能直接覆盖写。
# 内容为 1（正常）—— 装完默认不拦任何模块。
MODE_FILE=/data/local/tmp/ksuguard.mode
if [ ! -f "$MODE_FILE" ]; then
    printf '1\n' >"$MODE_FILE" 2>/dev/null
fi
if [ -f "$MODE_FILE" ]; then
    chown 2000:2000 "$MODE_FILE" 2>/dev/null
    chmod 0644 "$MODE_FILE" 2>/dev/null
fi

ui_print " "
ui_print "KSU Guard 已安装"
ui_print "状态目录: $STATE"
ui_print "准入开关: $MODE_FILE  (1=正常 2=禁用所有模块)"
ui_print "无 root 时用 adb 改: adb shell 'echo 2 > $MODE_FILE'"
ui_print "安装后需重新执行 late-load 才会加载守卫"
ui_print "验证: su -c 'sh /data/adb/modules/ksuguard/action.sh status'"
ui_print " "