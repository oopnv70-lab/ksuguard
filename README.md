# ksuguard

KernelSU 模块的准入开关：用一个纯文本文件，决定**这次启动到底挂不挂模块**。

适用于「某个模块把系统改坏、导致连屏幕都点不了」这种场景——包括临时 root
（内存级、硬重启即失效）下没有管理器可用的情况。

## 它解决的问题

模块坏掉时的常规解法是「进管理器把模块关掉」，但这要求你有 root。而如果是
内存级临时 root，硬重启之后 root 就没了，管理器作为一个普通 App 读不到
`/data/adb`（该目录是 `drwx------ root:root`），连模块列表都看不到。于是：

```
提权 → 坏模块自动挂上 → 又黑屏 → 再硬重启 → 再提权 → 再黑屏
```

`ksuguard` 把干预点放在**模块挂载之前**那一瞬间：`ksud` 在每个 stage 脚本
执行完毕、真正挂载 overlay 之前会读一个开关文件。开关是普通文件，位于
`/data/local/tmp`（属主 `shell`，`adb shell` 身份即可写入），所以**不需要
root 也能改**。

## 快速使用

开关文件：`/data/local/tmp/ksuguard.mode`

| 内容 | 行为 |
| --- | --- |
| `1`（默认，或文件不存在） | 正常，模块照常挂载 |
| `2` | 禁用除自身与元模块外的**所有**模块 |
| 其它任意值 | 按「正常」处理 |

最后一行是刻意的：误写一个字不应该导致系统起不来，宁可漏拦也不误拦。

### 临时改一下（立即生效）

```sh
adb shell 'echo 2 > /data/local/tmp/ksuguard.mode'
```

改完约 5 秒内，看门狗会检测到变化并：

1. 给所有模块打上 `disable`
2. 把开关自动重置回 `1`（避免下次启动又禁一遍）
3. 软重启用户空间，让 `disable` 真正生效

恢复：

```sh
adb shell 'echo 1 > /data/local/tmp/ksuguard.mode'   # 恢复正常状态
```

模块恢复挂载：

```sh
su -c 'sh /data/adb/modules/ksuguard/action.sh resume'
```

### root 完全拿不到的时候

这是本模块的主场景。此时**只能**用 `adb shell` 改写开关文件，然后重启：

```sh
adb shell 'echo 2 > /data/local/tmp/ksuguard.mode'
adb reboot
```

重启后系统会正常进桌面（因为坏模块被拦在挂载之前），但**依然没有 root**。
想恢复具体模块，得先想办法把 root 拿回来。

## 安装

```sh
# KernelSU 管理器里直接安装 zip
ksud module install /sdcard/ksu_guard/ksuguard-v2.7.zip
```

安装后默认是**观察模式**：开关文件不存在 → 一切照旧，不做任何干预。

## 两套开关，别搞混

| 开关 | 文件 | 管什么 | 时机 |
| --- | --- | --- | --- |
| `mode` | `/data/local/tmp/ksuguard.mode` | 这次启动挂不挂模块 | 事前，每次启动 |
| `gate` | `/data/local/tmp/ksuguard.arm` | 崩溃后要不要自动自救 | 事后，检测到故障时 |

`gate` 属于崩溃自保守卫（默认关闭，需手动 `arm`）：看门狗监视
`surfaceflinger` 的 pid 变化，超过阈值判定显示链路已坏，自动禁用其他模块并
软重启。

> **已知局限**：这个判据只能看出「surfaceflinger 进程被杀」，看不出「驱动
> 活着但渲染出错」。所以它只适合做兜底，不能替代 `mode` 的事前拦截——后者
> 更可靠，因为它根本不依赖判断。

## 命令行

```sh
sh /data/adb/modules/ksuguard/action.sh <命令>
```

| 命令 | 说明 |
| --- | --- |
| （无参数）/ `init` | 初始化开关文件（建好 + 修正属主权限），不覆盖已有内容 |
| `status` | 打印全部状态与最近一次决策 |
| `mode` | 只看准入开关 |
| `modecheck` | 立刻按当前值执行一次准入检查 |
| `gate` / `arm` / `disarm` | 闸门（崩溃自保）的查看 / 放行 / 收回 |
| `dry` | 只预演「会禁用哪些模块」，绝不写文件 |
| `panic` / `force` | 手动触发判定 / 无视闸门强制自救 |
| `resume` | 清掉所有模块的 `disable`，并清空 panic 与重启计数 |

管理器模块卡片的「执行」按钮等价于 `init`，可以重复点，**不会**覆盖你已经
写好的 `2`。

## 为什么开关文件放在 `/data/local/tmp`

1. 在 `/data` 卷（f2fs）上，跨硬重启保留，且 `post-fs-data` 阶段就已挂好；
   而 `/sdcard` 是 FUSE、依赖 vold，早期可能读不到。
2. 属主是 `shell`、权限 `drwxrwx--x`，`adb shell`（uid 2000）**无需 root**
   即可读写。
3. `ksud` 的 `clean_trash` 只清 `/data/adb/ksu/hot_install_trash/`，不动这里。

文件创建时会把属主改成 `2000:2000`、权限设为 `0644`。原因是 root 创建的
文件默认是 `0644 root:root`，`adb`（uid 2000）连覆盖写入都会被拒绝，只剩
「先删再建」这一条路。

不用 `0666` 的原因：`/data/local/tmp` 的 others 位是 `--x`，给 `0666` 等于
把开关交给设备上任意一个应用去改。

## 生效时机

`ksud` 的 stage 执行顺序决定了这件事（源码可查 `ksud_init_event.rs`）：

```
on_post_fs_data():
    metamodule::exec_stage_script("post-fs-data")
    module::exec_stage_script("post-fs-data")    ← 本模块在此读开关、写 disable
    metamodule::exec_mount_script(module_dir)    ← 挂载发生在这之后
```

所以写 `disable` 来得及。本模块在**两条**路径上都做了检查：

- `late-load.sh` — 漏洞工具提权时 `ksud late-load` 执行
- `post-fs-data.sh` — 软重启 / 正常开机执行

只做前者的话，「改 2 + 软重启」不会生效。这个坑实际踩过。

## 环境要求

- KernelSU / SukiSU / 支持 `ksud` 的同类方案
- 需要在元模块（如 Magic Mount）之前执行；本模块不含 `system/` 目录，自身不
  参与挂载
- 走 `late-load` 时需要 `ksud` 可用

## 目录结构

```
.
├── module.prop           模块元信息
├── customize.sh          安装时初始化开关文件
├── guard.sh              唯一逻辑源（被下面几个 stage 脚本 source）
├── late-load.sh          ksud late-load，挂载前
├── post-fs-data.sh       软重启 / 正常开机，挂载前
├── service.sh            ksud late-load 之后，起看门狗
├── boot-completed.sh     兜底再拉一次看门狗
├── action.sh             手动通道
└── uninstall.sh          卸载清理
```

状态与日志在 `/data/adb/ksuguard/`（`log`、`decision`、`watchdog.pid` 等）。

## 已经验证过的

在 Android 15 / 内核 6.6（KMI `android15-6.6`）上实测：

- 文件不存在 / 内容 `1` / 内容 `abc` → 禁用 0 个
- 内容 `2` → 禁用 10 个，正确排除自身与元模块
- 改成 `2` → 5 秒内实时响应，禁用 + 自动软重启 + 开关重置
- 手动软重启路径（`post-fs-data.sh`）同样生效
- 禁用失败时最多重试 3 次后停手，不刷日志

**未验证**：`boot_id` 在硬重启后确实变化这一条。软重启不变是反复实测过的，
硬重启会变按内核常识应成立，但没有在不重启整机的前提下验证的途径。

## 风险提示

- 会在系统里写 `/data/adb/modules/*/disable`，这是**持久**标记，硬重启仍在。
  恢复要用 `action.sh resume`，或手动删掉那些 `disable` 文件。
- `resume` 之后需要重新挂载模块才生效：`ksud soft-reboot`。
- 不要把它当成「防一切」的保险。它只能拦「模块导致的挂载期问题」；如果问题
  来自系统本身或内核，这套机制帮不上。

## License

GPL-3.0
