package com.brill.pppoe_controller.bridge

import com.brill.pppoe_controller.su.RootShell
import java.util.UUID

object PppoeBridge {
    private const val DIR = "/data/local/tmp"
    private fun f(name: String) = "$DIR/$name"
    private val ifacePattern = Regex("[a-zA-Z0-9_.:-]{1,15}")

    data class ConnectionState(
        val peer: Map<String, String>,
        val connected: Boolean,
        val running: Boolean,
        val pendingCommand: String?
    )

    internal fun parseConnectionState(text: String): ConnectionState {
        val lines = text.lineSequence().toList()
        val peer = lines.filter { it.startsWith("peer:") }.mapNotNull {
            val value = it.removePrefix("peer:")
            val index = value.indexOf('=')
            if (index <= 0) null else value.substring(0, index) to value.substring(index + 1)
        }.toMap()
        val addresses = lines.filter { it.startsWith("address:") }.map { it.removePrefix("address:") }
        val connected = peer["IF"] == "ppp0" && !peer["IPLOCAL"].isNullOrBlank() &&
            peer["IPLOCAL"] in addresses
        return ConnectionState(peer, connected, "running:1" in lines,
            lines.firstOrNull { it.startsWith("pending:") }?.removePrefix("pending:")
                ?.takeIf { it in setOf("start", "stop", "cycle") })
    }

    fun getConnectionState(): ConnectionState = parseConnectionState(RootShell.read("""
        [ "${'$'}(id -u)" = 0 ] || exit 1
        if [ -f $DIR/pppoe_peer.env ]; then
            sed 's/^/peer:/' $DIR/pppoe_peer.env || exit 1
        fi
        addresses=${'$'}(ip -4 -o addr show) || exit 1
        printf '%s\n' "${'$'}addresses" | awk '${'$'}2 == "ppp0" && ${'$'}3 == "inet" {split(${'$'}4, a, "/"); print "address:" a[1]}'
        pid=${'$'}(cat $DIR/pppd-pppoe0.pid 2>/dev/null)
        case "${'$'}pid" in ''|*[!0-9]*|0|1) ;;
            *) if [ -r "/proc/${'$'}pid/cmdline" ]; then
                args=${'$'}(tr '\000' '\n' < "/proc/${'$'}pid/cmdline")
                if printf '%s\n' "${'$'}args" | grep -qxF '$DIR/ppp_daemon' &&
                   printf '%s\n' "${'$'}args" | grep -qxF '$DIR/ppp.options' &&
                   kill -0 "${'$'}pid" 2>/dev/null; then printf 'running:1\n'; fi
            fi ;;
        esac
        for control in $DIR/pppoe_control $DIR/pppoe_control.processing; do
            if [ -f "${'$'}control" ]; then
                pending=${'$'}(cat "${'$'}control") || exit 1
                case "${'$'}pending" in start|stop|cycle) printf 'pending:%s\n' "${'$'}pending"; break ;; esac
            fi
        done
        exit 0
    """.trimIndent()))

    fun checkConnectivity(): Boolean = getConnectionState().connected

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
