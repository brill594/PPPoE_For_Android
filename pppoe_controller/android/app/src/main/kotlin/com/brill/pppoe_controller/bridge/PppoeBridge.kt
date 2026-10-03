package com.brill.pppoe_controller.bridge

import com.brill.pppoe_controller.su.RootShell
import java.util.UUID

object PppoeBridge {
    private const val DIR = "/data/local/tmp"
    private fun f(name: String) = "$DIR/$name"
    private val ifacePattern = Regex("[a-zA-Z0-9_.:-]{1,15}")

    fun checkConnectivity(): Boolean = RootShell.run(
        "ip -4 addr show dev ppp0 | grep -q 'inet '",
        "ping -I ppp0 -c 1 -W 1 1.1.1.1 >/dev/null 2>&1 || " +
            "ping -I ppp0 -c 1 -W 1 8.8.4.4 >/dev/null 2>&1"
    )

    private fun writeFile(name: String, value: String): Boolean {
        val target = f(name)
        val temporary = "$target.${UUID.randomUUID()}.tmp"
        return RootShell.run(
            "umask 077; printf '%s' ${RootShell.quote(value)} > $temporary && " +
                "mv -f $temporary $target; rc=\$?; rm -f $temporary; exit \$rc"
        )
    }

    fun writeCreds(user: String, pass: String): Boolean {
        require(user.isNotBlank() && pass.isNotEmpty()) { "Username and password are required" }
        require(listOf(user, pass).none { it.any { c -> c == '\n' || c == '\r' || c == '\u0000' } }) {
            "Credentials cannot contain line breaks or NUL"
        }
        return writeFile("pppoe_user", user) && writeFile("pppoe_pass", pass)
    }

    fun writeIface(iface: String?): Boolean {
        if (iface.isNullOrBlank()) return RootShell.run("rm -f ${f("pppoe_iface")}")
        require(ifacePattern.matches(iface)) { "Invalid network interface" }
        return writeFile("pppoe_iface", iface)
    }

    fun writeMtuMru(mtu: Int?, mru: Int?): Boolean {
        require(mtu != null && mtu in 576..1492 && mru != null && mru in 576..1492) {
            "MTU and MRU must be between 576 and 1492"
        }
        return writeFile("pppoe_mtu", mtu.toString()) && writeFile("pppoe_mru", mru.toString())
    }

    @Synchronized
    fun control(cmd: String): Boolean {
        require(cmd in setOf("start", "stop", "cycle")) { "Unsupported command" }
        // A stop can supersede an unconsumed start; a later start must not erase a stop.
        if (cmd != "stop" && !RootShell.run(
                "for i in 1 2 3 4 5 6 7 8 9 10; do " +
                    "[ ! -e ${f("pppoe_control")} ] && break; sleep 1; done; " +
                    "[ ! -e ${f("pppoe_control")} ]"
            )) return false
        return writeFile("pppoe_control", cmd)
    }

    fun readPeerEnv(): Map<String, String> {
        val path = f("pppoe_peer.env")
        val text = RootShell.read("if [ -f $path ]; then cat $path; fi")
        return text.lineSequence().mapNotNull {
            val idx = it.indexOf('=')
            if (idx <= 0) null else it.substring(0, idx) to it.substring(idx + 1)
        }.toMap()
    }
}
