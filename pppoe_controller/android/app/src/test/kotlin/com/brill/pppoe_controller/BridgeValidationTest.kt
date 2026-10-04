package com.brill.pppoe_controller

import com.brill.pppoe_controller.bridge.PppoeBridge
import com.brill.pppoe_controller.su.RootShell
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class BridgeValidationTest {
    @Test
    fun credentialsRemainLiteralShellData() {
        val value = "name 'quoted' \"double\" \\ $ ; `false` \$(false)\nnext"
        val process = ProcessBuilder("sh", "-c", "printf '%s' ${RootShell.quote(value)}").start()
        assertEquals(value, process.inputStream.bufferedReader().readText())
        assertEquals(0, process.waitFor())
    }

    @Test
    fun malformedConfigurationNeverReachesRootShell() {
        assertThrows(IllegalArgumentException::class.java) { PppoeBridge.writeIface("eth0'; exit 0") }
        assertThrows(IllegalArgumentException::class.java) { PppoeBridge.writeCreds("user\nplugin", "pass") }
        assertThrows(IllegalArgumentException::class.java) { PppoeBridge.writeCreds("user", "pass\u0000") }
        assertThrows(IllegalArgumentException::class.java) { PppoeBridge.writeMtuMru(575, 1492) }
        assertThrows(IllegalArgumentException::class.java) { PppoeBridge.writeMtuMru(1492, 1493) }
        assertThrows(IllegalArgumentException::class.java) { PppoeBridge.control("arbitrary command") }
    }
    @Test
    fun commandExitCannotTerminateTheReusableRootShell() {
        val process = ProcessBuilder("sh", "-c", "${RootShell.isolated("exit 0")}\nprintf alive").start()
        assertEquals("alive", process.inputStream.bufferedReader().readText())
        assertEquals(0, process.waitFor())
        val failure = ProcessBuilder("sh", "-c", RootShell.isolated("exit 7")).start()
        assertEquals(7, failure.waitFor())
    }

}
