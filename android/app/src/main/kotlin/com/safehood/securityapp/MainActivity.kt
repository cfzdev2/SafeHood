package com.safehood.securityapp

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var cameraPairing: CameraPairingChannel? = null
    private var reolinkPairing: ReolinkPairingChannel? = null
    private var localCameras: LocalCameraChannel? = null
    private var localPlayer: LocalCameraPlayerChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        cameraPairing = CameraPairingChannel(this, messenger)
        reolinkPairing = ReolinkPairingChannel(this, messenger)
        localCameras = LocalCameraChannel(this, messenger)
        localPlayer = LocalCameraPlayerChannel(this, messenger, flutterEngine.renderer)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        cameraPairing?.onPermissionResult(requestCode)
        reolinkPairing?.onPermissionResult(requestCode)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        localPlayer?.close()
        localPlayer = null
        localCameras?.close()
        localCameras = null
        reolinkPairing?.close()
        reolinkPairing = null
        cameraPairing?.close()
        cameraPairing = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
