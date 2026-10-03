package com.brill.pppoe_controller.su

import com.topjohnwu.superuser.Shell

object RootShell {
    fun quote(value: String): String = "'${value.replace("'", "'\\''")}'"

    fun run(vararg cmds: String): Boolean =
        Shell.cmd(cmds.joinToString(" && ") { "($it)" }).exec().isSuccess

    fun read(command: String): String {
        val result = Shell.cmd(command).exec()
        check(result.isSuccess) { "Root command failed (exit ${result.code})" }
        return result.out.joinToString("\n")
    }
}
