package com.example.entropy_vpn

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    companion object {
        private const val controlChannelName = "entropy_vpn/control"
        private const val eventsChannelName = "entropy_vpn/events"
        private const val incomingLinksChannelName = "entropy_vpn/incoming_links"
        private const val incomingLinksEventsChannelName = "entropy_vpn/incoming_links/events"
        private const val vpnPermissionRequestCode = 1108
        private const val notificationPermissionRequestCode = 1109
        private const val permissionPrefsName = "entropy_vpn.permissions"
        private const val notificationPermissionAskedKey = "notification_permission_asked"
    }

    private var pendingPrepareResult: MethodChannel.Result? = null
    private var pendingInitialIncomingLink: String? = null
    private var incomingLinkSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val appCatalogExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    override fun onCreate(savedInstanceState: Bundle?) {
        pendingInitialIncomingLink = extractIncomingLink(intent)
        super.onCreate(savedInstanceState)
        requestNotificationPermissionOnLaunch()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            controlChannelName,
        ).setMethodCallHandler(::handleMethodCall)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            incomingLinksChannelName,
        ).setMethodCallHandler(::handleIncomingLinksMethodCall)

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            eventsChannelName,
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    EntropyVpnRuntimeStore.attachSink(events)
                }

                override fun onCancel(arguments: Any?) {
                    EntropyVpnRuntimeStore.attachSink(null)
                }
            },
        )

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            incomingLinksEventsChannelName,
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    incomingLinkSink = events
                }

                override fun onCancel(arguments: Any?) {
                    incomingLinkSink = null
                }
            },
        )
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepareVpn" -> prepareVpn(result)
            "saveVpnStartPayload" -> saveVpnStartPayload(call, result)
            "startVpn" -> startVpn(call, result)
            "stopVpn" -> {
                EntropyVpnService.stop(this)
                result.success(true)
            }
            "getState" -> result.success(EntropyVpnRuntimeStore.snapshot())
            "getAppDataDirectory" -> result.success(filesDir.absolutePath)
            "listInstalledApps" -> listInstalledApps(result)
            else -> result.notImplemented()
        }
    }

    private fun handleIncomingLinksMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getInitialLink" -> {
                result.success(pendingInitialIncomingLink)
                pendingInitialIncomingLink = null
            }
            else -> result.notImplemented()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val link = extractIncomingLink(intent) ?: return
        val sink = incomingLinkSink
        if (sink == null) {
            pendingInitialIncomingLink = link
        } else {
            sink.success(link)
        }
    }

    private fun extractIncomingLink(intent: Intent?): String? {
        if (intent == null) {
            return null
        }

        val value =
            when (intent.action) {
                Intent.ACTION_VIEW -> intent.dataString
                Intent.ACTION_SEND -> intent.getStringExtra(Intent.EXTRA_TEXT)
                else -> null
            }

        return value?.trim()?.takeIf(String::isNotEmpty)
    }

    private fun requestNotificationPermissionOnLaunch() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return
        }
        if (
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val permissionPrefs = getSharedPreferences(permissionPrefsName, MODE_PRIVATE)
        if (permissionPrefs.getBoolean(notificationPermissionAskedKey, false)) {
            return
        }
        permissionPrefs.edit().putBoolean(notificationPermissionAskedKey, true).apply()

        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            notificationPermissionRequestCode,
        )
    }

    private fun prepareVpn(result: MethodChannel.Result) {
        val intent = VpnService.prepare(this)
        if (intent == null) {
            result.success(true)
            return
        }
        if (pendingPrepareResult != null) {
            result.error("busy", "VPN permission request is already in progress.", null)
            return
        }
        pendingPrepareResult = result
        startActivityForResult(intent, vpnPermissionRequestCode)
    }

    private fun startVpn(call: MethodCall, result: MethodChannel.Result) {
        if (VpnService.prepare(this) != null) {
            result.error("vpn_permission", "VPN permission is required.", null)
            return
        }

        val startPayload = readStartPayload(call, result) ?: return
        EntropyVpnStartPayloadStore.save(this, startPayload)

        EntropyVpnService.start(
            context = this,
            core = startPayload.core,
            config = startPayload.config,
            profileName = startPayload.profileName,
            serverAddress = startPayload.serverAddress,
            serverCountryCode = startPayload.serverCountryCode,
            language = startPayload.language,
            tunIpMode = startPayload.tunIpMode,
            splitTunnelMode = startPayload.splitTunnelMode,
            splitTunnelPackages = startPayload.splitTunnelPackages,
        )
        result.success(true)
    }

    private fun saveVpnStartPayload(call: MethodCall, result: MethodChannel.Result) {
        val startPayload = readStartPayload(call, result) ?: return
        EntropyVpnStartPayloadStore.save(this, startPayload)
        result.success(true)
    }

    private fun readStartPayload(
        call: MethodCall,
        result: MethodChannel.Result,
    ): EntropyVpnStartPayload? {
        val core = call.argument<String>("core")
        val config = call.argument<String>("config")
        val profileName = call.argument<String>("profileName").orEmpty().ifBlank { "EntropyVPN" }
        val serverAddress = call.argument<String>("serverAddress").orEmpty()
        val serverCountryCode = call.argument<String>("serverCountryCode").orEmpty()
        val language = call.argument<String>("language").orEmpty().ifBlank { "en" }
        val tunIpMode = call.argument<String>("tunIpMode").orEmpty().ifBlank { "ipv4" }
        val splitTunnelMode =
            call.argument<String>("splitTunnelMode").orEmpty().ifBlank { "off" }
        val splitTunnelPackages =
            call.argument<List<Any?>>("splitTunnelPackages")
                .orEmpty()
                .mapNotNull { item ->
                    item?.toString()?.trim()?.takeIf(String::isNotEmpty)
                }

        if (core.isNullOrBlank() || config.isNullOrBlank()) {
            result.error("invalid_args", "Missing VPN runtime arguments.", null)
            return null
        }

        return EntropyVpnStartPayload(
            core = core,
            config = config,
            profileName = profileName,
            serverAddress = serverAddress,
            serverCountryCode = serverCountryCode,
            language = language,
            tunIpMode = tunIpMode,
            splitTunnelMode = splitTunnelMode,
            splitTunnelPackages = splitTunnelPackages,
        )
    }

    private fun listInstalledApps(result: MethodChannel.Result) {
        appCatalogExecutor.execute {
            try {
                val apps = buildInstalledAppsCatalog()
                mainHandler.post { result.success(apps) }
            } catch (error: Exception) {
                mainHandler.post {
                    result.error(
                        "app_catalog_failed",
                        error.message ?: "Failed to load installed applications.",
                        null,
                    )
                }
            }
        }
    }

    private fun buildInstalledAppsCatalog(): List<Map<String, String>> {
        val intent =
            Intent(Intent.ACTION_MAIN)
                .addCategory(Intent.CATEGORY_LAUNCHER)
        val appsByPackage = linkedMapOf<String, Map<String, String>>()

        for (resolveInfo in queryLauncherActivities(intent)) {
            val activityInfo = resolveInfo.activityInfo ?: continue
            val appPackageName = activityInfo.packageName?.trim().orEmpty()
            if (appPackageName.isEmpty() || appPackageName == packageName) {
                continue
            }
            val label =
                resolveInfo
                    .loadLabel(packageManager)
                    ?.toString()
                    ?.trim()
                    .orEmpty()
                    .ifBlank { appPackageName }

            appsByPackage[appPackageName] =
                mapOf(
                    "name" to label,
                    "path" to appPackageName,
                )
        }

        return appsByPackage.values.sortedWith(
            compareBy<Map<String, String>> { it["name"].orEmpty().lowercase() }
                .thenBy { it["path"].orEmpty() },
        )
    }

    private fun queryLauncherActivities(intent: Intent): List<ResolveInfo> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.queryIntentActivities(
                intent,
                PackageManager.ResolveInfoFlags.of(0),
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.queryIntentActivities(intent, 0)
        }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != vpnPermissionRequestCode) {
            return
        }
        val granted = resultCode == Activity.RESULT_OK && VpnService.prepare(this) == null
        pendingPrepareResult?.success(granted)
        pendingPrepareResult = null
    }

    override fun onDestroy() {
        appCatalogExecutor.shutdown()
        super.onDestroy()
    }
}
