package com.safehood.securityapp

import java.io.IOException
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.Locale
import javax.net.SocketFactory
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

internal object CameraPairingDvrip {
    private const val WIFI = "NetWork.Wifi"
    private const val DHCP = "NetWork.NetDHCP"
    private fun failure(code: String) = CameraPairingOnvif.PairingException(code)

    private class Client(private val socket: Socket) {
        private val input = socket.getInputStream()
        private val output = socket.getOutputStream()
        private var session = 0
        private var sequence = 0

        private fun request(op: Int, obj: JSONObject): JSONObject {
            val body = (obj.toString() + "\n\u0000").toByteArray(Charsets.UTF_8)
            val header = ByteBuffer.allocate(20).order(ByteOrder.LITTLE_ENDIAN)
            header.put(0, 255.toByte()).putInt(4, session).putInt(8, sequence++)
                .putShort(14, op.toShort()).putInt(16, body.size)
            output.write(header.array())
            output.write(body)
            output.flush()

            val deadline = System.nanoTime() + 4_000_000_000L
            fun read(dst: ByteArray, offset: Int, size: Int) {
                var pos = offset
                while (pos < offset + size) {
                    if (Thread.currentThread().isInterrupted) throw IOException("Interrupted")
                    val left = (deadline - System.nanoTime()) / 1_000_000L
                    if (left < 1) throw IOException("DVRIP timeout")
                    socket.soTimeout = left.toInt().coerceAtMost(4000)
                    val n = input.read(dst, pos, offset + size - pos)
                    if (n < 0) throw IOException("DVRIP EOF")
                    pos += n
                }
            }

            val raw = ByteArray(20)
            var found = false
            for (i in 0..8) {
                read(raw, 0, 1)
                if ((raw[0].toInt() and 255) == 255) { found = true; break }
            }
            if (!found) throw IOException("Invalid DVRIP header")
            read(raw, 1, 19)
            val reply = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN)
            val replyOp = reply.getShort(14).toInt() and 65535
            val length = reply.getInt(16)
            if ((replyOp != op && replyOp != op + 1) || length !in 2..65536 ||
                raw[12].toInt() !in 0..1 || raw[13].toInt() != 0) {
                throw IOException("Invalid DVRIP frame")
            }
            val data = ByteArray(length)
            read(data, 0, length)
            val json = JSONObject(data.toString(Charsets.UTF_8).trimEnd('\u0000', '\r', '\n', ' ', '\t'))
            if (op == 1000) {
                val token = json.optString("SessionID").removePrefix("0x").removePrefix("0X")
                session = token.toLongOrNull(16)?.takeIf { it in 1L..0xffffffffL }?.toInt()
                    ?: reply.getInt(4)
            }
            return json
        }

        fun login(user: String, password: String) {
            val digest = MessageDigest.getInstance("MD5").digest(password.toByteArray(Charsets.UTF_8))
            val alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
            val hash = (0 until 16 step 2).joinToString("") {
                val sum = (digest[it].toInt() and 255) + (digest[it + 1].toInt() and 255)
                alphabet[sum % 62].toString()
            }
            val result = request(1000, JSONObject().put("EncryptType", "MD5")
                .put("LoginType", "DVRIP-Web").put("UserName", user).put("PassWord", hash))
            if (result.optInt("Ret") != 100) throw failure("dvripAuth")
        }

        private fun envelope(name: String) = JSONObject().put("Name", name)
            .put("SessionID", String.format(Locale.ROOT, "0x%08x", session))

        private fun get(name: String): Any {
            val result = request(1042, envelope(name))
            if (result.optInt("Ret") != 100) throw failure("dvripRead")
            return result.opt(name) ?: throw failure("dvripRead")
        }

        fun readWifi(): JSONObject {
            val wifi = get(WIFI) as? JSONObject ?: throw failure("dvripRead")
            if (wifi.optString("NetType") != "Infra" || wifi.optInt("Channel", -1) != 0 ||
                listOf("SSID", "Keys", "HostIP", "GateWay", "Submask").any { wifi.opt(it) !is String }) {
                throw failure("dvripProfile")
            }
            val dhcp = get(DHCP) as? JSONArray ?: throw failure("dvripDhcp")
            val active = (0 until dhcp.length()).mapNotNull { dhcp.optJSONObject(it) }
                .filter { it.opt("Enable") == true }.map { it.optString("Interface") }
            if (active != listOf("eth0")) throw failure("dvripDhcp")
            return wifi
        }

        fun setWifi(wifi: JSONObject): String {
            val payload = envelope(WIFI).put(WIFI, wifi)
            val result = try { request(1040, payload) }
                catch (_: IOException) { return "UNCONFIRMED" }
                catch (_: JSONException) { return "UNCONFIRMED" }
            if (result.optInt("Ret") != 100) throw failure("dvripWrite")
            return "ACCEPTED"
        }
    }

    private fun <T> connect(
        factory: SocketFactory, host: Inet4Address, user: String, password: String,
        action: (Client) -> T,
    ): T = try {
        factory.createSocket().use { socket ->
            socket.connect(InetSocketAddress(host, 34567), 3000)
            Client(socket).let { client -> client.login(user, password); action(client) }
        }
    } catch (_: IOException) { throw failure("dvripRead") }
      catch (_: JSONException) { throw failure("dvripRead") }

    fun inspect(factory: SocketFactory, host: Inet4Address, user: String, password: String) {
        connect(factory, host, user, password) { it.readWifi() }
    }

    fun configure(
        factory: SocketFactory, host: Inet4Address, user: String, password: String,
        ssid: String, key: String,
    ): String {
        val hex = key.matches(Regex("[0-9a-fA-F]{64}"))
        if (ssid.toByteArray(Charsets.UTF_8).size !in 1..32 || ssid.isBlank() ||
            ssid.any { it.isISOControl() } || (!hex && !key.matches(Regex("[ -~]{8,63}")))) {
            throw failure("invalidHomeWifi")
        }
        return connect(factory, host, user, password) { client ->
            val wifi = client.readWifi().put("SSID", ssid).put("Keys", key)
                .put("Enable", true).put("Auth", "WPA2PSK").put("EncrypType", "AES")
                .put("KeyType", if (hex) 0 else 1)
            client.setWifi(wifi)
        }
    }
}
