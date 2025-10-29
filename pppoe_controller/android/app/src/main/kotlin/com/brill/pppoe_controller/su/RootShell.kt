package com.brill.pppoe_controller.su
import com.topjohnwu.superuser.Shell
import android.util.Log // 添加 import

object RootShell {
    fun run(vararg cmds: String): Boolean {
        Log.d("RootShell", "Executing: ${cmds.joinToString(" && ")}") // 打印命令
        val job = Shell.cmd(*cmds).exec()
        Log.d("RootShell", "Result code: ${job.code}") // 打印退出码
        Log.d("RootShell", "Success: ${job.isSuccess}")
        Log.d("RootShell", "Error output: ${job.err}") // 打印错误流
        return job.isSuccess
    }
}