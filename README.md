# Android PPPoE Controller



这是一个在 **已 Root** 的 Android 设备上实现 PPPoE 拨号上网的解决方案。

本项目由两部分组成：

1. **Magisk 模块**: 负责在 Root 环境下运行 `pppd` 守护进程，处理底层的 PPPoE 协议和网络接口管理。
2. **Flutter 应用程序**: 提供用户界面 (UI) 来管理拨号配置，并启动一个 `VpnService` 提供 DNS 配置；流量路由由 Magisk 模块管理。



## 📸 截图

![demo.png](demo.png)



## ✨ 功能特性



- **完整的 PPPoE 拨号控制**: 支持启动、停止拨号。
- **智能网络接口管理**:
  - 自动检测可用的网络接口 (如 `eth0`, `usb0`, `rndis0` 甚至 `wlan0`)。
  - 支持用户手动选择特定接口进行拨号。
  - 支持接口优先级列表和一键“切换接口” (`cycle`) 功能。
- **配置高度自定义**:
  - 支持设置 PPPoE 账号和密码。
  - 支持自定义 MTU 和 MRU (最小 576，最大 1492)。
  - 支持启用自定义 DNS 服务器。
- **IPv4 路由**: Magisk 模块使用独立路由表将 IPv4 流量送往 `ppp0`；VPN 服务提供 DNS 配置，实际效果需要在目标 Android 系统验证。
- **详细的日志系统**:
  - 在 App 内按阶段、级别和时间显示日志，默认隐藏调试噪声并合并重复行。
  - 自动保存每一次拨号尝试到**历史记录**。
  - 实时与历史日志共用故障诊断、Windows RAS 类比参考及处理建议；复制/分享导出脱敏报告。
  - 支持查看历史详情和添加备注；诊断依据与日志保留边界见 [应用开发说明](pppoe_controller/README.md#日志与诊断)。
- **内置工具**:
  - 包含一个简单的下载速度测试工具 (MB/s)。
  - 允许用户自定义测速用的文件 URL。
- **简洁 UI**: 保留复古的 "Nothing" 风格与 `VT323` 字体，加入按钮按压、状态与数值过渡，并尊重系统减少动画设置。



## ⚙️ 工作原理



本项目巧妙地结合了 Magisk 的 Root 权限和 App 的 `VpnService`，解决了 Android 系统原生不支持 PPPoE 的问题。



### 1. Magisk 模块 (后台 `service.sh`)



- **身份**: 这是一个 Magisk `service.sh` 脚本，在设备启动时以 Root 权限在后台运行。
- **核心**: 它内置了 `pppd`、musl 动态链接器与运行库，以及 `pppoe.so` 插件。
- **控制**: 脚本通过原子替换的控制文件 (`/data/local/tmp/`) 接收来自 App 的命令（如 `start`, `stop`, `cycle`）。
- **执行**: 当收到 `start` 命令时，脚本：
  1. 读取 App 写入的配置（如 `pppoe_user`, `pppoe_pass`, `pppoe_iface`）。
  2. 调用 `pppd` 并加载 `pppoe.so` 插件，在指定的物理接口（如 `eth0`）上发起 PPPoE 连接。
  3. 连接成功后，`pppd` 会执行 `ip-up.sh` 脚本。
- **路由**: `ip-up.sh` 脚本是关键。它会**修改 Android 系统的内核路由表**，在表 `10000` 中设置指向 `ppp0` 的默认路由，并添加优先级 `10000` 的规则；断开时删除本模块规则和路由，不删除系统原有默认路由。该表和优先级应保留给本模块，避免与其他网络模块冲突。
- **状态**: 脚本将拨号状态（如获取到的 IP、DNS）写入 `pppoe_peer.env` 文件，供 App 读取。



### 2. Flutter 应用程序 (前台 UI 与 VPN)



- **UI**: 提供图形界面，让用户配置账号、接口、MTU 等。
- **通信**:
  - **App -> Magisk**: 当用户点击“启动”时，App 通过 `PppoeBridge` (MethodChannel) 调用原生 Java/Kotlin 代码，该代码负责将配置写入 `/data/local/tmp/` 下的对应文件，并最后写入 `start` 命令到 `pppoe_control` 文件，从而触发 Magisk 脚本。
  - **Magisk -> App**: App 通过 `PppoeBridge` 定时轮询 `pppoe_peer.env` 文件来获取连接状态，并通过 `EventChannel` (`pppoe/log_stream`) 实时读取 `pppoe.log` 文件的更新以显示日志。
- **DNS 容器 (VpnService)**:
  - 拨号检测通过后，App 请求 VPN 授权并建立 DNS 容器。
  - 当前服务配置一个 TUN 地址、`203.0.113.0/24` 占位路由和 DNS，不读取或转发 TUN 数据包。
  - 实际 IPv4 出口依赖模块的策略路由，而非将数据包从 TUN 自动交还内核。参见 [Android VPN 工作方式](https://developer.android.com/develop/connectivity/vpn)。
  - 自定义 DNS 仅在开关开启时生效，否则使用 PPP 协商的 DNS，最后回退到 `8.8.8.8`。
  - 建立成功后才向界面报告成功；撤销授权或服务销毁时释放 TUN。

拨号成功检测使用绑定 `ppp0` 的 ICMP 探测，避免被 Wi-Fi/移动网络误判。运营商屏蔽 ICMP 时仍可能显示探测超时；超时不代表 `pppd` 已停止重试，可点击“停止”明确结束连接。本项目未实现 IPv6 PPP 路由，不能将它当作防流量泄漏 VPN。

## 🚀 安装与使用





### 必备条件



1. 一台已经 **Root**、内核支持 PPP 的 ARM64 Android 设备（模块内置二进制为 aarch64）。
2. 已安装 **Magisk**。



### 安装步骤



1. **安装 Magisk 模块**:
   - 将项目中的 Magisk 模块 (`[你的模块ZIP包名称].zip`) 复制到手机中。
   - 打开 Magisk Manager，从本地刷入该模块。
   - 重启手机。
2. **安装 App**:
   - 安装 Flutter App (`[你的APP名称].apk`)。



### 使用方法



1. （如果使用外接网卡）请确保已通过 OTG 连接 USB 网卡，或已连接到启用了 PPPoE 透传的 Wi-Fi/有线网络。
2. 打开 PPPoE App。
3. 输入你的 **PPPoE 账号**和**密码**。
4. （可选）在“网络接口”下拉菜单中选择一个特定接口。默认“自动选择”会尝试 `pppoe_iface` -> `pppoe_iflist` -> 自动检测的顺序。
5. （可选）设置 MTU/MRU 或自定义 DNS。
6. 点击 **“启动拨号 + VPN”** 按钮。
7. 系统会弹出 VPN 连接请求，请点击 **“允许”**。（用于提供 DNS 配置）
8. 观察“日志”选项卡中的实时日志，等待拨号成功。
9. 连接成功后，App 首页会显示获取到的 IP 和 DNS，并且设备状态栏会出现 VPN 钥匙图标。


## 开发与验证

代码职责和本地检查命令见 [应用开发说明](pppoe_controller/README.md)。模块脚本的离线回归检查：

```sh
sh -n pppoe-enabler/service.sh
python3 -B -m unittest discover -s pppoe-enabler/tests -v
```

修改后的源码不会自动更新仓库中的 APK 或模块 ZIP。升级模块后需要重启设备，让旧守护进程和旧路由规则退出。真机验收应覆盖：正确/错误凭据、重复启动、拨号中停止、接口切换、拔插网卡、VPN 拒绝/撤销、切换 DNS、应用重建，以及停止后原网络恢复。离线测试不能替代 PPPoE 协商、SELinux 和厂商 Android 路由验证。
