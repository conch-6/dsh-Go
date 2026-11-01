package io.github.ccch1mneyyy.dsh_app.phone.background

import java.net.InetAddress
import org.junit.Assert.*
import org.junit.Test

class AdbEndpointTest {
    @Test fun incompleteDiscoveryCannotBecomeAConnectTarget() {
        val address = InetAddress.getByName("127.0.0.1")
        assertNull(AdbEndpoint.discovered(null, 37123))
        for (port in listOf(-1, 0, 65536)) assertNull(AdbEndpoint.discovered(address, port))
    }

    @Test fun aCompleteResponseKeepsItsOwnAddressAndPort() {
        val address = InetAddress.getByName("192.168.1.87")
        val target = AdbEndpoint.discovered(address, 45269)!!
        assertEquals(address, target.address)
        assertEquals(45269, target.port)
        assertNotNull(AdbEndpoint.discovered(address, 1))
        assertNotNull(AdbEndpoint.discovered(address, 65535))
    }
}
