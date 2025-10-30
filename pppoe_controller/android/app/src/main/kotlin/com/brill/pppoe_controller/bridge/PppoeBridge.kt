package com.brill.pppoe_controller.bridge
import com.brill.pppoe_controller.su.RootShell
import java.io.File
import android.util.Log
object PppoeBridge {
    private const val DIR = "/data/local/tmp"
    private fun f(name: String) = "$DIR/$name"
    fun checkConnectivity(): Boolean {

        Log.d("PppoeBridge", "Attempting ping check...")
        val success = RootShell.run("ping -c 1 -W 1 1.1.1.1") or RootShell.run("ping -c 1 -W 1 8.8.4.4")
        Log.d("PppoeBridge", "Ping check result: $success")
        return success
    }
    fun writeCreds(user: String, pass: String): Boolean {
        return RootShell.run(
            "printf '%s' '${user.replace("'", "'\\''")}' > ${f("pppoe_user")}",
            "printf '%s' '${pass.replace("'", "'\\''")}' > ${f("pppoe_pass")}",
            "chmod 0600 ${f("pppoe_pass")} ${f("pppoe_user")}"
        )
    }

    fun writeIface(iface: String?): Boolean {
        return if (iface.isNullOrBlank()) RootShell.run("rm -f ${f("pppoe_iface")}")
        else RootShell.run("printf '%s' '$iface' > ${f("pppoe_iface")}")
    }

    fun writeMtuMru(mtu: Int?, mru: Int?): Boolean {
        val cmds = mutableListOf<String>()
        mtu?.let { cmds += "printf '%d' $it > ${f("pppoe_mtu")}" }
        mru?.let { cmds += "printf '%d' $it > ${f("pppoe_mru")}" }
        if (cmds.isEmpty()) return true
        return RootShell.run(*cmds.toTypedArray())
    }

    fun control(cmd: String): Boolean {
        val escapedCmd = cmd.replace("'", "'\\''")
        return RootShell.run("echo '$escapedCmd' > ${f("pppoe_control")}")
    }

    fun readLog(): String = runCatching { File(f("pppoe.log")).readText() }.getOrElse { "" }

    fun readPeerEnv(): Map<String,String> {
        val text = runCatching { File(f("pppoe_peer.env")).readText() }.getOrElse { "" }
        return text.lineSequence().mapNotNull {
            val idx = it.indexOf('=')
            if (idx <= 0) null else it.substring(0, idx) to it.substring(idx + 1)
        }.toMap()
    }
}