package com.brill.pppoe_controller.bridge
import com.brill.pppoe_controller.su.RootShell
import java.io.File

object PppoeBridge {
    private const val DIR = "/data/local/tmp"
    private fun f(name: String) = "$DIR/$name"

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
        // e.g. "start" / "stop" / "cycle" / "switch eth0"
        // 使用 echo 并确保对命令中的特殊字符进行转义 (虽然 start/stop/cycle 通常不需要)
        // 注意：简单的 echo 可能不足以处理复杂的 cmd，但对于 start/stop/cycle 足够
        val escapedCmd = cmd.replace("'", "'\\''") // 基本的单引号转义
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