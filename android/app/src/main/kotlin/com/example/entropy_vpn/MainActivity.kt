package com.example.entropy_vpn

import android.Manifest
import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.nekohasekai.libbox.Libbox
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
    companion object {
        private const val controlChannelName = "entropy_vpn/control"
        private const val eventsChannelName = "entropy_vpn/events"
        private const val incomingLinksChannelName = "entropy_vpn/incoming_links"
        private const val incomingLinksEventsChannelName = "entropy_vpn/incoming_links/events"
        private const val vpnPermissionRequestCode = 1108
        private const val notificationPermissionRequestCode = 1109
        private const val updateNotificationRequestCode = 1110
        private const val updateNotificationId = 1111
        private const val updateNotificationChannelId = "entropy_vpn.updates"
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
            "setKillswitchPreference" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                // Persists the flag to SharedPreferences. If the service is
                // running it picks the change up via its preference listener;
                // otherwise the flag just waits for the next service start.
                EntropyVpnService.writeKillswitchPreference(this, enabled)
                result.success(true)
            }
            "getState" -> result.success(EntropyVpnRuntimeStore.snapshot())
            "getAppDataDirectory" -> result.success(filesDir.absolutePath)
            "getCoreVersions" -> getCoreVersions(result)
            "listInstalledApps" -> listInstalledApps(result)
            "showUpdateNotification" -> showUpdateNotification(call, result)
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

    private fun showUpdateNotification(call: MethodCall, result: MethodChannel.Result) {
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            result.success(false)
            return
        }

        val title = call.argument<String>("title").orEmpty().ifBlank { "New update" }
        val body =
            call.argument<String>("body")
                .orEmpty()
                .ifBlank { "A new EntropyVPN update is available" }
        val releaseUrl =
            call.argument<String>("releaseUrl")
                .orEmpty()
                .ifBlank { "https://github.com/entropycorp/EntropyVPN/releases" }

        ensureUpdateNotificationChannel()

        val releaseIntent =
            Intent(Intent.ACTION_VIEW, Uri.parse(releaseUrl))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val pendingIntent =
            PendingIntent.getActivity(
                this,
                updateNotificationRequestCode,
                releaseIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        val notification =
            NotificationCompat.Builder(this, updateNotificationChannelId)
                .setSmallIcon(R.drawable.ic_notification_entropy)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setContentIntent(pendingIntent)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .build()

        getSystemService(NotificationManager::class.java).notify(
            updateNotificationId,
            notification,
        )
        result.success(true)
    }

    private fun ensureUpdateNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(
                updateNotificationChannelId,
                "Updates",
                NotificationManager.IMPORTANCE_DEFAULT,
            ),
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
            dnsServers = startPayload.dnsServers,
            splitTunnelMode = startPayload.splitTunnelMode,
            splitTunnelPackages = startPayload.splitTunnelPackages,
            socksUsername = startPayload.socksUsername,
            socksPassword = startPayload.socksPassword,
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
        val dnsServers =
            call.argument<List<Any?>>("dnsServers")
                .orEmpty()
                .mapNotNull { item ->
                    item?.toString()?.trim()?.takeIf(String::isNotEmpty)
                }
        val splitTunnelMode =
            call.argument<String>("splitTunnelMode").orEmpty().ifBlank { "off" }
        val splitTunnelPackages =
            call.argument<List<Any?>>("splitTunnelPackages")
                .orEmpty()
                .mapNotNull { item ->
                    item?.toString()?.trim()?.takeIf(String::isNotEmpty)
                }
        val socksUsername = call.argument<String>("socksUsername").orEmpty()
        val socksPassword = call.argument<String>("socksPassword").orEmpty()

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
            dnsServers = dnsServers,
            splitTunnelMode = splitTunnelMode,
            splitTunnelPackages = splitTunnelPackages,
            socksUsername = socksUsername,
            socksPassword = socksPassword,
        )
    }

    private fun getCoreVersions(result: MethodChannel.Result) {
        appCatalogExecutor.execute {
            val versions = mutableMapOf<String, String?>(
                "xray" to probeXrayVersion(),
                "singBox" to probeSingBoxVersion(),
            )
            mainHandler.post { result.success(versions) }
        }
    }

    private fun probeSingBoxVersion(): String? =
        runCatching { Libbox.version().takeIf(String::isNotBlank) }.getOrNull()

    private fun probeXrayVersion(): String? {
        val binary = File(applicationInfo.nativeLibraryDir, "libxray.so")
        if (!binary.canExecute()) {
            return null
        }
        return runCatching {
            val process = ProcessBuilder(binary.absolutePath, "version")
                .redirectErrorStream(true)
                .start()
            val output = process.inputStream.bufferedReader().use { it.readText() }
            if (!process.waitFor(5, TimeUnit.SECONDS)) {
                process.destroyForcibly()
                return@runCatching null
            }
            if (process.exitValue() != 0) {
                return@runCatching null
            }
            Regex("""\b(\d+\.\d+\.\d+(?:[-+][\w.]+)?)""")
                .find(output)
                ?.groupValues
                ?.getOrNull(1)
        }.getOrNull()
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
