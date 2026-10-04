package com.brill.pppoe_controller

import com.brill.pppoe_controller.bridge.PppoeBridge
import org.junit.Assert.*
import org.junit.Test

class ConnectionStateTest {
    @Test
    fun stalePeerFileCannotClaimAConnectedLink() {
        val peer = "peer:IF=ppp0\npeer:IPLOCAL=10.0.0.2"
        assertFalse(PppoeBridge.parseConnectionState(peer).connected)
        assertFalse(PppoeBridge.parseConnectionState("$peer\naddress:10.0.0.3").connected)
        assertTrue(PppoeBridge.parseConnectionState("$peer\naddress:10.0.0.2").connected)
    }

    @Test
    fun onlyThePppInterfaceWithAnAddressCanBeConnected() {
        assertFalse(PppoeBridge.parseConnectionState(
            "peer:IF=eth0\npeer:IPLOCAL=10.0.0.2\naddress:10.0.0.2").connected)
        assertFalse(PppoeBridge.parseConnectionState("peer:IF=ppp0\npeer:IPLOCAL=\naddress:").connected)
    }

    @Test
    fun aRunningDialerIsNotYetAConnectedLink() {
        val state = PppoeBridge.parseConnectionState("running:1\npending:start")
        assertTrue(state.running)
        assertFalse(state.connected)
        assertEquals("start", state.pendingCommand)
    }

    @Test
    fun peerDataCannotInventProcessOrPendingState() {
        val state = PppoeBridge.parseConnectionState(
            "peer:running:1\npeer:pending:stop\npending:unexpected\npeer:DNS1=1.1.1.1")
        assertFalse(state.running)
        assertNull(state.pendingCommand)
        assertEquals(mapOf("DNS1" to "1.1.1.1"), state.peer)
    }
}
