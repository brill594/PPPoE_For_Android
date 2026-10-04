package com.brill.pppoe_controller.su

import com.topjohnwu.superuser.Shell

object RootShell {
    fun quote(value: String): String = "'${value.replace("'", "'\\''")}'"

    // A command's exit/variables must never terminate or contaminate libsu's shared shell.
    internal fun isolated(command: String): String = "(\n$command\n)"

    fun run(vararg cmds: String): Boolean =
        Shell.cmd(cmds.joinToString(" && ") { isolated(it) }).exec().isSuccess

    fun read(command: String): String {
        val result = Shell.cmd(isolated(command)).exec()
        check(result.isSuccess) { "Root command failed (exit ${result.code})" }
        return result.out.joinToString("\n")
    }
}
