package com.brill.pppoe_controller.su
import com.topjohnwu.superuser.Shell
object RootShell {
    init { Shell.setDefaultBuilder(
        Shell.Builder.create().setFlags(Shell.FLAG_REDIRECT_STDERR)
    ) }

    fun run(vararg cmds: String): Boolean {
        val job = Shell.cmd(*cmds).exec()
        return job.isSuccess
    }
}