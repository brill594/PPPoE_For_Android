package com.brill.pppoe_controller.vpn
import android.app.*
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import com.brill.pppoe_controller.bridge.PppoeBridge

class PppoeVpnService : VpnService() {
    companion object {
        const val ACT_START = "START_VPN"
        const val ACT_STOP  = "STOP_VPN"
        private const val NOTI_CH = "pppoe_vpn"
        private const val NOTI_ID = 101
    }

    private var tun: ParcelFileDescriptor? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACT_START -> startVpn()
            ACT_STOP  -> stopVpn()
        }
        return START_STICKY
    }

    private fun startVpn() {
        createNotification()
        val peer = PppoeBridge.readPeerEnv()
        val dns1 = peer["DNS1"]
        val dns2 = peer["DNS2"]

        val builder = Builder()
            .setSession("PPPoE-DNS-Container")
            .addAddress("10.0.0.1", 32)
            .addRoute("203.0.113.0", 24) // dummy route: 不黑洞真实流量
            .setBlocking(false)
            .setMetered(false)
            .allowBypass()

        if (!dns1.isNullOrBlank()) builder.addDnsServer(dns1)
        if (!dns2.isNullOrBlank()) builder.addDnsServer(dns2)

        // 可选：添加用户定义的 split routes（例如只为某些私网段声明）
        // routes.forEach { (cidr, prefix) -> builder.addRoute(cidr, prefix) }

        tun = builder.establish()
        if (tun == null) {
            // 权限未授予，或建立失败
            // 1. 发出一个“失败”或“需要权限”的通知
            startForeground(NOTI_ID, notification("VPN Permission Required"))
            // 2. 立即停止服务
            stopVpn()
            return // 退出 startVpn
        }
        startForeground(NOTI_ID, notification("DNS active: ${dns1 ?: "-"} ${dns2 ?: ""}"))
    }

    private fun stopVpn() {
        tun?.close()
        tun = null
        stopForeground(STOP_FOREGROUND_REMOVE)  // <-- 推荐
        stopSelf()
    }

    private fun createNotification() {
        val mgr = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            mgr.createNotificationChannel(NotificationChannel(NOTI_CH, "PPPoE VPN", NotificationManager.IMPORTANCE_LOW))
        }
    }

    private fun notification(text: String): Notification {
        val pi = PendingIntent.getActivity(this, 0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, NOTI_CH)
            .setContentTitle("PPPoE DNS Container")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentIntent(pi)
            .build()
    }

    override fun onRevoke() { stopVpn() }
}
