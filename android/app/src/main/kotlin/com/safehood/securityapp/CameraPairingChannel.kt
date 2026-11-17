package com.safehood.securityapp

import android.Manifest
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.MacAddress
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.net.Inet4Address
import java.net.InetAddress
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.Future

@Suppress("DEPRECATION") // WifiManager scan/SSID APIs, including Android 10–12.
internal class CameraPairingChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private data class Candidate(
        val ssid: String,
        val bssid: String,
        val security: String,
        val level: Int,
    )

    private data class PermissionRequest(
        val required: String,
        val reply: MethodChannel.Result,
        val onGranted: () -> Unit,
    )

    private data class VerifiedCamera(
        val network: Network,
        val onvif: CameraPairingOnvif,
        val device: CameraPairingOnvif.Device,
        val credentials: CameraPairingOnvif.Credentials,
    )

    private val channel = MethodChannel(messenger, "safehood/camera_hotspot_pairing")
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val wifi = activity.applicationContext.getSystemService(WifiManager::class.java)
    private val connectivity = activity.getSystemService(ConnectivityManager::class.java)
    private var permission: PermissionRequest? = null
    private var receiver: BroadcastReceiver? = null
    private var scanReply: MethodChannel.Result? = null
    private var connectReply: MethodChannel.Result? = null
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var pairingNetwork: Network? = null
    private var links: LinkProperties? = null
    private var operation: MethodChannel.Result? = null
    private var task: Future<*>? = null
    private var activeBssid: String? = null
    private var candidates = emptyMap<String, Candidate>()
    private var homeSsid: String? = null
    private var verified: VerifiedCamera? = null
    private var needsReboot = false

    init {
        channel.setMethodCallHandler(::handle)
    }

    private fun handle(call: MethodCall, reply: MethodChannel.Result) {
        if (call.method == "disconnect") {
            reset()
            reply.success(null)
            return
        }
        if (Build.VERSION.SDK_INT < 29 || wifi == null || connectivity == null) {
            fail(reply, "unsupportedPlatform")
            return
        }
        if (permission != null || scanReply != null || connectReply != null || operation != null) {
            fail(reply, "busy")
            return
        }
        when (call.method) {
            "scan" -> {
                if (!wifi.isWifiEnabled) return fail(reply, "wifiOff")
                val location = activity.getSystemService(LocationManager::class.java)
                if (location?.isLocationEnabled != true) return fail(reply, "locationOff")
                releaseNetwork()
                requirePermission(Manifest.permission.ACCESS_FINE_LOCATION, reply) { scan(reply) }
            }
            "connect" -> {
                val candidate = candidates[call.argument<String>("bssid")]
                    ?: return fail(reply, "scanAgain")
                val passphrase = call.argument<String>("password").orEmpty()
                val required = if (Build.VERSION.SDK_INT >= 33) {
                    Manifest.permission.NEARBY_WIFI_DEVICES
                } else {
                    Manifest.permission.ACCESS_FINE_LOCATION
                }
                requirePermission(required, reply) { connect(candidate, passphrase, reply) }
            }
            "inspect" -> inspect(call, reply)
            "inspectDvrip" -> inspectDvrip(call, reply)
            "configure" -> configure(call, reply)
            "reboot" -> reboot(reply)
            "wifiSettings", "locationSettings" -> {
                val action = if (call.method == "wifiSettings") {
                    Settings.ACTION_WIFI_SETTINGS
                } else {
                    Settings.ACTION_LOCATION_SOURCE_SETTINGS
                }
                activity.startActivity(Intent(action))
                reply.success(null)
            }
            else -> reply.notImplemented()
        }
    }

    private fun requirePermission(
        required: String,
        reply: MethodChannel.Result,
        action: () -> Unit,
    ) {
        if (activity.checkSelfPermission(required) == PackageManager.PERMISSION_GRANTED) {
            action()
            return
        }
        permission = PermissionRequest(required, reply, action)
        val permissions = if (required == Manifest.permission.ACCESS_FINE_LOCATION) {
            arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION, required)
        } else {
            arrayOf(required)
        }
        activity.requestPermissions(permissions, PERMISSION_REQUEST)
    }

    fun onPermissionResult(requestCode: Int) {
        if (requestCode != PERMISSION_REQUEST) return
        val pending = permission ?: return
        permission = null
        if (activity.checkSelfPermission(pending.required) == PackageManager.PERMISSION_GRANTED) {
            pending.onGranted()
        } else {
            fail(pending.reply, if (pending.required == Manifest.permission.ACCESS_FINE_LOCATION) {
                "locationPermission"
            } else {
                "nearbyPermission"
            })
        }
    }

    private fun scan(reply: MethodChannel.Result) {
        val manager = wifi ?: return fail(reply, "wifiOff")
        val scanReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action == WifiManager.SCAN_RESULTS_AVAILABLE_ACTION && scanReply === reply) {
                    finishScan(intent.getBooleanExtra(WifiManager.EXTRA_RESULTS_UPDATED, false))
                }
            }
        }
        scanReply = reply
        try {
            val filter = IntentFilter(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION)
            if (Build.VERSION.SDK_INT >= 33) {
                activity.registerReceiver(scanReceiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                activity.registerReceiver(scanReceiver, filter)
            }
            receiver = scanReceiver
            if (!manager.startScan()) {
                finishScan(false)
                return
            }
            main.postDelayed({ if (scanReply === reply) finishScan(false) }, 7_000)
        } catch (_: SecurityException) {
            clearScan()
            fail(reply, "locationPermission")
        }
    }

    private fun finishScan(fresh: Boolean) {
        val reply = clearScan() ?: return
        val manager = wifi ?: return fail(reply, "wifiOff")
        try {
            val current = manager.connectionInfo?.ssid?.removeSurrounding("\"")
            homeSsid = current?.takeUnless { it.isEmpty() || it == "<unknown ssid>" }
            val list = manager.scanResults.mapNotNull { scan ->
                val ssid = scan.SSID ?: return@mapNotNull null
                val bssid = scan.BSSID ?: return@mapNotNull null
                if (ssid.isBlank() || ssid == homeSsid || ssid.toByteArray().size > 32) {
                    return@mapNotNull null
                }
                val caps = scan.capabilities.orEmpty().uppercase(Locale.ROOT)
                val security = when {
                    "PSK" in caps && ("WPA2" in caps || "RSN" in caps) -> "wpa2"
                    "SAE" in caps -> "wpa3"
                    listOf("WPA", "RSN", "WEP", "EAP", "OWE", "WAPI", "PRIVACY")
                        .none { it in caps } -> "open"
                    else -> return@mapNotNull null
                }
                Candidate(ssid, bssid, security, scan.level)
            }.sortedByDescending { it.level }.distinctBy { it.bssid }.take(60)
            candidates = list.associateBy { it.bssid }
            reply.success(mapOf(
                "fresh" to fresh,
                "homeSsid" to homeSsid,
                "networks" to list.map {
                    mapOf("ssid" to it.ssid, "bssid" to it.bssid, "security" to it.security)
                },
            ))
        } catch (_: SecurityException) {
            fail(reply, "locationPermission")
        }
    }

    private fun clearScan(): MethodChannel.Result? {
        receiver?.let { activity.unregisterReceiver(it) }
        receiver = null
        val reply = scanReply
        scanReply = null
        return reply
    }

    private fun connect(candidate: Candidate, password: String, reply: MethodChannel.Result) {
        val manager = connectivity ?: return fail(reply, "unsupportedPlatform")
        releaseNetwork()
        val request = try {
            val specifier = WifiNetworkSpecifier.Builder()
                .setSsid(candidate.ssid)
                .setBssid(MacAddress.fromString(candidate.bssid))
            when (candidate.security) {
                "wpa2" -> {
                    if (!password.matches(Regex("[ -~]{8,63}"))) return fail(reply, "apPassword")
                    specifier.setWpa2Passphrase(password)
                }
                "wpa3" -> {
                    if (!password.matches(Regex("[ -~]{8,63}"))) return fail(reply, "apPassword")
                    specifier.setWpa3Passphrase(password)
                }
            }
            NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .setNetworkSpecifier(specifier.build())
                .build()
        } catch (_: IllegalArgumentException) {
            return fail(reply, "apPassword")
        }

        val lease = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if (callback === this) pairingNetwork = network
            }

            override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {
                if (callback !== this || pairingNetwork != network) return
                links = properties
                if (properties.linkAddresses.any { it.address is Inet4Address }) {
                    val pending = connectReply
                    connectReply = null
                    pending?.success(null)
                }
            }

            override fun onUnavailable() {
                if (callback === this) releaseNetwork("hotspotUnavailable")
            }

            override fun onLost(network: Network) {
                if (callback === this && pairingNetwork == network) {
                    pairingNetwork = null
                    links = null
                    val pending = connectReply
                    connectReply = null
                    pending?.let { fail(it, "hotspotLost") }
                }
            }
        }
        callback = lease
        activeBssid = candidate.bssid
        connectReply = reply
        try {
            manager.requestNetwork(request, lease, main, 35_000)
            // requestNetwork's timeout covers availability; DHCP also has a limit here.
            main.postDelayed({
                if (callback === lease && connectReply != null) releaseNetwork("hotspotUnavailable")
            }, 40_000)
        } catch (_: RuntimeException) {
            releaseNetwork("hotspotUnavailable")
        }
    }

    private fun inspect(call: MethodCall, reply: MethodChannel.Result) {
        val network = pairingNetwork ?: return fail(reply, "hotspotLost")
        val properties = links ?: return fail(reply, "hotspotLost")
        val manualHost = call.argument<String>("host").orEmpty().trim()
        val manualPort = call.argument<Int>("port")
        val hosts = if (manualHost.isEmpty()) {
            hotspotHosts(properties)
        } else {
            val parsed = ipv4(manualHost)
            if (parsed == null || !onHotspot(properties, parsed)) return fail(reply, "invalidAddress")
            listOf(parsed)
        }
        if (hosts.isEmpty() || (manualPort != null && manualPort !in 1..65535)) {
            return fail(reply, "invalidAddress")
        }
        val ports = if (manualPort == null) listOf(80, 8899, 8080, 8000, 5000, 9000) else listOf(manualPort)
        val user = call.argument<String>("username").orEmpty()
        val password = call.argument<String>("password").orEmpty()
        if (user.length > 128 || user.any { it.isISOControl() } || password.length > 256) {
            return fail(reply, "cameraAuth")
        }
        val credentials = CameraPairingOnvif.Credentials(user, password)
        verifiedDvrip = null
        verified = null
        needsReboot = false
        runOperation(reply, {
            val factory = network.socketFactory
            for (host in hosts) {
                for (port in ports) {
                    if (Thread.currentThread().isInterrupted) {
                        throw CameraPairingOnvif.PairingException("cancelled")
                    }
                    val probe = CameraPairingOnvif(CameraPairingHttp(factory, host, port, 800))
                    if (try { probe.probe() } catch (_: IOException) { false }) {
                        // Re-use the same client (HTTP challenge and camera clock), with more
                        // time for authenticated requests than for discovery.
                        val client = CameraPairingOnvif(CameraPairingHttp(factory, host, port, 3_500))
                        if (!(try { client.probe() } catch (_: IOException) { false })) continue
                        return@runOperation VerifiedCamera(network, client, client.inspect(credentials), credentials)
                    }
                }
            }
            throw CameraPairingOnvif.PairingException("onvifNotFound")
        }, { camera ->
            if (pairingNetwork != network) throw CameraPairingOnvif.PairingException("hotspotLost")
            verified = camera
            camera.device.label()
        })
    }

    private data class VerifiedDvrip(
        val network: android.net.Network, val host: Inet4Address, val user: String, val password: String,
    )
    private var verifiedDvrip: VerifiedDvrip? = null

    private fun inspectDvrip(call: MethodCall, reply: MethodChannel.Result) {
        val network = pairingNetwork ?: return fail(reply, "hotspotLost")
        val props = links ?: return fail(reply, "hotspotLost")
        val ssid = candidates.values.firstOrNull { it.bssid == activeBssid }?.ssid.orEmpty()
        if (!ssid.matches(Regex("(?i)robot[_-]?[0-9a-f]{4,12}"))) {
            return fail(reply, "dvripProfile")
        }
        val host = hotspotHosts(props).firstOrNull() ?: return fail(reply, "invalidAddress")
        val user = call.argument<String>("username").orEmpty().trim().ifEmpty { "admin" }
        val password = call.argument<String>("password").orEmpty()
        if (user.length > 128 || user.any { it.isISOControl() } || password.length > 256) {
            return fail(reply, "dvripAuth")
        }
        verified = null
        verifiedDvrip = null
        needsReboot = false
        runOperation(reply, {
            CameraPairingDvrip.inspect(network.socketFactory, host, user, password)
            VerifiedDvrip(network, host, user, password)
        }, { found ->
            if (pairingNetwork != network) throw CameraPairingOnvif.PairingException("hotspotLost")
            verifiedDvrip = found
            "Kamera XMEye (DVRIP)"
        })
    }

    private fun configureDvrip(call: MethodCall, reply: MethodChannel.Result, camera: VerifiedDvrip) {
        if (camera.network != pairingNetwork) return fail(reply, "hotspotLost")
        val ssid = call.argument<String>("ssid").orEmpty()
        val key = call.argument<String>("password").orEmpty()
        if (candidates.values.any { it.bssid == activeBssid && it.ssid == ssid }) {
            return fail(reply, "sameSsid")
        }
        runOperation(reply, {
            CameraPairingDvrip.configure(camera.network.socketFactory, camera.host,
                camera.user, camera.password, ssid, key)
        }, { result ->
            verifiedDvrip = null
            releaseNetwork()
            result
        })
    }

    private fun configure(call: MethodCall, reply: MethodChannel.Result) {
        val xm = verifiedDvrip
        if (xm != null) return configureDvrip(call, reply, xm)
        val camera = verified ?: return fail(reply, "inspectFirst")
        if (camera.network != pairingNetwork) return fail(reply, "hotspotLost")
        if (needsReboot) return fail(reply, "inspectFirst")
        val ssid = call.argument<String>("ssid").orEmpty()
        val password = call.argument<String>("password").orEmpty()
        if (candidates.values.any { it.ssid == ssid && it.bssid == activeBssid }) {
            return fail(reply, "sameSsid")
        }
        runOperation(reply, {
            camera.onvif.configure(camera.device, camera.credentials, ssid, password)
        }, { outcome ->
            needsReboot = outcome == CameraPairingOnvif.Outcome.REBOOT_NEEDED && pairingNetwork != null
            if (!needsReboot) releaseNetwork()
            outcome.name
        })
    }

    private fun reboot(reply: MethodChannel.Result) {
        val camera = verified ?: return fail(reply, "hotspotLost")
        if (!needsReboot || camera.network != pairingNetwork) return fail(reply, "hotspotLost")
        runOperation(reply, { camera.onvif.reboot(camera.credentials) }, { outcome ->
            releaseNetwork()
            outcome.name
        })
    }

    private fun <T> runOperation(
        reply: MethodChannel.Result,
        work: () -> T,
        finish: (T) -> Any?,
    ) {
        operation = reply
        task = worker.submit {
            val outcome = runCatching(work)
            main.post {
                if (operation !== reply) return@post
                operation = null
                task = null
                try {
                    reply.success(finish(outcome.getOrThrow()))
                } catch (error: CameraPairingOnvif.PairingException) {
                    fail(reply, error.code)
                } catch (_: Exception) {
                    fail(reply, "cameraConnection")
                }
            }
        }
    }

    private fun releaseNetwork(code: String = "cancelled") {
        val oldCallback = callback
        callback = null
        if (oldCallback != null) {
            try {
                connectivity?.unregisterNetworkCallback(oldCallback)
            } catch (_: IllegalArgumentException) {
                // Already released by Android.
            }
        }
        connectReply?.let { fail(it, code) }
        connectReply = null
        pairingNetwork = null
        links = null
        verifiedDvrip = null
        verified = null
        needsReboot = false
        activeBssid = null
    }

    private fun reset() {
        clearScan()?.let { fail(it, "cancelled") }
        permission?.reply?.let { fail(it, "cancelled") }
        permission = null
        operation?.let { fail(it, "cancelled") }
        operation = null
        task?.cancel(true)
        task = null
        releaseNetwork()
        candidates = emptyMap()
        homeSsid = null
    }

    fun close() {
        channel.setMethodCallHandler(null)
        reset()
        main.removeCallbacksAndMessages(null)
        worker.shutdownNow()
    }

    private fun fail(reply: MethodChannel.Result, code: String) {
        reply.error(code, null, null)
    }

    companion object {
        private const val PERMISSION_REQUEST = 7051

        private fun hotspotHosts(links: LinkProperties): List<Inet4Address> {
            val possibilities = links.routes.mapNotNull { it.gateway as? Inet4Address }.toMutableList()
            if (Build.VERSION.SDK_INT >= 30) {
                links.dhcpServerAddress?.let(possibilities::add)
            }
            for (link in links.linkAddresses) {
                val address = link.address as? Inet4Address ?: continue
                if (link.prefixLength !in 8..30) continue
                val mask = -1 shl (32 - link.prefixLength)
                val first = (intAddress(address) and mask) + 1
                val bytes = ByteArray(4) { (first ushr (24 - 8 * it)).toByte() }
                possibilities.add(InetAddress.getByAddress(bytes) as Inet4Address)
            }
            return possibilities.distinct().filter { onHotspot(links, it) }.take(3)
        }

        private fun onHotspot(links: LinkProperties, host: Inet4Address): Boolean {
            if (!host.isSiteLocalAddress && !host.isLinkLocalAddress) return false
            if (links.linkAddresses.any { it.address == host }) return false
            return links.linkAddresses.any {
                val ip = it.address as? Inet4Address ?: return@any false
                if (it.prefixLength !in 8..31) return@any false
                val mask = -1 shl (32 - it.prefixLength)
                val address = intAddress(host)
                val network = intAddress(ip) and mask
                (address and mask) == network &&
                    (it.prefixLength == 31 || (address != network && address != (network or mask.inv())))
            }
        }

        private fun intAddress(host: Inet4Address): Int = host.address.fold(0) { acc, byte ->
            (acc shl 8) or (byte.toInt() and 255)
        }

        private fun ipv4(value: String): Inet4Address? {
            val parts = value.split('.')
            if (parts.size != 4 || parts.any { !it.matches(Regex("[0-9]{1,3}")) }) return null
            val numbers = parts.map { it.toInt() }
            if (numbers.any { it !in 0..255 }) return null
            return InetAddress.getByAddress(numbers.map { it.toByte() }.toByteArray()) as Inet4Address
        }
    }
}
