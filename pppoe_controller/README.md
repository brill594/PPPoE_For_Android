# PPPoE Controller 开发说明

应用声明的最低版本为 Android 10；实际运行还需要 ARM64 设备、Root、内核 PPP 支持和配套 Magisk 模块（模块元数据标注 Android 13+）。其他平台目录保留 Flutter 工程骨架，不具备原生 PPPoE 通道实现。

## 代码职责

- `lib/main.dart`：配置和页面状态、拨号/VPN 操作协调。
- `lib/motion.dart`：共享按压反馈、页面过渡及减少动画策略；不拦截按钮手势。
- `lib/speed_test.dart`：单次下载测速的连接、超时与取消，不依赖 Widget 生命周期。
- `lib/pppoe_bridge.dart`：Flutter MethodChannel/EventChannel 契约和日志模型。
- `lib/log_diagnostics.dart` / `log_view.dart`：确定性日志解析、脱敏、诊断和实时/历史共用展示。
- `lib/history_screen.dart` / `log_detail_screen.dart`：历史列表、备注、分享。
- `android/app/src/main/kotlin/com/brill/pppoe_controller/MainActivity.kt`：原生通道调度、VPN 授权、拨号记录。
- 原生 `bridge/`、`su/`：Root 文件协议、输入校验、shell 转义。命令内容不得记录到日志。
- 原生 `logging/`：按字节读取、UTF-8 分行、会话边界、采集重试和脱敏；拨号期间不依赖 UI 订阅。
- 原生 `vpn/`：前台 DNS 容器及 TUN 资源管理；原生 `db/`：Room 日志持久化。
- `../pppoe-enabler/service.sh`：pppd、接口选择、路由和 DNS hooks。

## 构建与检查

本项目使用 Flutter **3.47.6 stable / Dart 3.13.5**，`pubspec.yaml` 声明最低 SDK 版本。Android 工具链为 Gradle 8.14.5、AGP 8.13.0、Kotlin 2.2.20、KSP 2.2.20-2.0.4、Room 2.8.4，使用 JDK 17+ 和 Android SDK 35。安装对应 Flutter SDK 后，在本地 `android/local.properties` 配置实际 SDK 路径，或由 `flutter pub get` 自动更新；不要提交本机路径。锁文件保留原包源，只更新 SDK 所需的间接依赖。

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
cd android
./gradlew :app:testDebugUnitTest
```

Widget 测试模拟原生通道，验证失败不会继续拨号、重复启动/停止竞争、轮询取消和历史错误处理；测速测试使用本地 HTTP 服务。Android JVM 测试验证 shell 特殊字符不被执行、非法配置在调用 Root 前被拒绝。模块测试和真机验收范围见仓库根 README。


## 日志与诊断

模块输出 `UTC时间 [级别] [module] event=事件 字段=值`，App 事件使用 `[app]` 并附带拨号 `attempt` 标识。未带时间的 pppd 原文使用 App 观察时间（`pppd (observed)`），不能当作精确的协议发生时间。默认界面隐藏 Debug、心跳和旧 xtrace；相邻重复项显示次数及末次时间，详细模式与脱敏原文仍可展开。

拨号记录从发送命令前的文件位置开始，保存前再读取一次，避免混入旧日志或遗漏最后一批错误；主动取消也保存记录。VPN 授权/启动结果及 DNS 来源追加到最近拨号记录。历史记录是拨号窗口的快照，不是永久后台连接审计；应用进程被强杀时不能保证保存尚未完成的记录。模块独立保留运行日志。

采集每次最多读取 64 KiB，单行上限 8 KiB；历史拨号窗口最多 1000 行/约 26 万字符，实时窗口最多 500 行。发生截断、文件重置或读取失败时会显示证据不完整提示。模块在日志超过 1 MiB 后保留一个 `.1` 归档并原位截断，以保留运行中的文件描述符；复制与截断之间存在短暂写入竞争，因此不宣称日志完全无损。

显示、保存新记录和报告导出会屏蔽已识别的账号/密码字段、认证报文、凭据命令和 URL 凭据；旧记录在展示和导出时也经过脱敏。含凭据的模糊行会保守删除其后半部分。不要把自定义备注或服务端任意文本视为自动脱敏的保证。

### Windows 错误码参考

Android/pppd 不返回 Windows RAS 错误码。这里根据明确的协议证据提供**类比参考**，不是原生错误码，也不是对具体账号问题的断言。依据 [Microsoft RAS 错误码](https://learn.microsoft.com/en-us/windows/win32/rras/routing-and-remote-access-error-codes) 和 [pppd 手册](https://ppp.samba.org/pppd.html)。

| 日志证据 | Windows 参考 | 限制 |
| --- | --- | --- |
| PAP/CHAP 本机认证被拒、收到 AuthNak/Failure、pppd exit=19 | 691 | 不能据此断言密码错误，仍可能是账户状态或运营商策略 |
| 等待 PADO/PADS 超时 | 678 / 815 | 检查物理连接、接口、VLAN 和接入服务器 |
| LCP 配置协商超时 | 718 | 不包括普通 Ping 或 LCP 心跳超时 |
| 明确拒绝本机 IP 地址 | 735 | 不包括拒绝 DNS 选项 |
| 无法获得本机 IP 地址 | 738 | 需要 IPCP/地址证据 |
| LCP 被对端终止 | 734 | 优先保留前面更具体的认证等根因 |
| 本机 PPP 设备/驱动不可用 | 651 | 仅为设备层错误类比，不用于所有拨号失败 |

Root、路由、日志读取、DNS、VPN 权限和未知错误显示各自的原因与建议，不强行赋予 RAS 码。`pppd exit=11` 表示认证方向不同，`exit=10` 也不足以判断特定 IP 配置问题。测试覆盖这些负例，避免“看到失败就猜一个号码”。


## 交互动效

保留黑白红和 VT323 风格。按钮内容按压时轻微缩放，保留 Material 水波纹、原始点击区域和禁用逻辑；拨号/停止状态淡入淡出，测速数字平滑变化，错误提示展开，Android 页面及设置对话框采用短过渡。操作按钮本身不会被切换动画复制或延迟触发。

新增动画在系统请求减少动画或辅助导航时关闭。日志更新不做逐行动画，也不引入无限循环的装饰动画或第三方动画依赖。Widget 测试覆盖按压/释放、禁用、点击区域、单次触发及动画中立即停止等行为。
