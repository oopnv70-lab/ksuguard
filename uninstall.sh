#!/system/bin/sh
# ksuguard / uninstall.sh —— 卸载时清理
#
# 注意：不会自动恢复被禁用的模块。需要恢复请先手动执行：
#   sh /data/adb/modules/ksuguard/action.sh resume
# 再卸载。否则其他模块会保持 disable 状态，需逐个删 disable 文件。

STATE=/data/adb/ksuguard

# 结束看门狗
_wp=$(cat "$STATE/watchdog.pid" 2>/dev/null)
[ -n "$_wp" ] && kill "$_wp" 2>/dev/null

# 保留 log 与 config 到下一次安装会重生成，这里全清
rm -rf "$STATE"