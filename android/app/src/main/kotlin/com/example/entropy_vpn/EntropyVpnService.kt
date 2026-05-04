package com.example.entropy_vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.DnsResolver
import android.net.IpPrefix
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.OsConstants
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.nekohasekai.libbox.CommandClient
import io.nekohasekai.libbox.CommandClientHandler
import io.nekohasekai.libbox.CommandClientOptions
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.ConnectionEvents
import io.nekohasekai.libbox.ConnectionOwner
import io.nekohasekai.libbox.ExchangeContext
import io.nekohasekai.libbox.InterfaceUpdateListener
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LocalDNSTransport
import io.nekohasekai.libbox.LogEntry
import io.nekohasekai.libbox.LogIterator
import io.nekohasekai.libbox.NeighborEntryIterator
import io.nekohasekai.libbox.NeighborUpdateListener
import io.nekohasekai.libbox.NetworkInterface
import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.Notification as BoxNotification
import io.nekohasekai.libbox.OutboundGroupItemIterator
import io.nekohasekai.libbox.OutboundGroupIterator
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.RoutePrefix
import io.nekohasekai.libbox.RoutePrefixIterator
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libbox.StatusMessage
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.SystemProxyStatus
import io.nekohasekai.libbox.TunOptions
import io.nekohasekai.libbox.WIFIState
import java.io.File
import java.io.IOException
import java.io.InputStreamReader
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.InterfaceAddress
import java.net.NetworkInterface as JNetworkInterface
import java.net.UnknownHostException
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

class EntropyVpnService : VpnService(), PlatformInterface, CommandClientHandler {
    companion object {
        private const val tag = "EntropyVpnService"
        private const val actionStart = "com.example.entropy_vpn.START"
        private const val actionStop = "com.example.entropy_vpn.STOP"
        private const val extraCore = "core"
        private const val extraConfig = "config"
        private const val extraProfileName = "profileName"
        private const val extraServerAddress = "serverAddress"
        private const val extraServerCountryCode = "serverCountryCode"
        private const val extraLanguage = "language"
        private const val extraTunIpMode = "tunIpMode"
        private const val extraSplitTunnelMode = "splitTunnelMode"
        private const val extraSplitTunnelPackages = "splitTunnelPackages"
        private const val notificationChannelId = "entropy_vpn.runtime"
        private const val notificationId = 1107
        private const val xrayNativeLibraryName = "libxray.so"
        private const val xraySocksHost = "127.0.0.1"
        private const val xraySocksPort = 2080
        private const val hevConfigFileName = "hev-socks5-tunnel.yaml"
        private const val hevMtu = 1500
        private const val hevIpv4Address = "172.19.0.1"
        private const val hevIpv4Prefix = 30
        private const val hevIpv6Address = "fdfe:dcba:9876::1"
        private const val hevIpv6Prefix = 126
        private const val tunIpModeIpv4 = "ipv4"
        private const val tunIpModeDualStack = "dualStack"
        private const val tunIpModeIpv6 = "ipv6"
        private const val splitTunnelModeOff = "off"
        private const val splitTunnelModeWhitelist = "whitelist"
        private const val splitTunnelModeBlacklist = "blacklist"
        private const val dnsRcodeNxDomain = 3
        private const val localDnsTimeoutSeconds = 10L
        private val hevIpv4DnsServers = listOf("1.1.1.1", "8.8.8.8")
        private val hevIpv6DnsServers =
            listOf("2606:4700:4700::1111", "2001:4860:4860::8888")

        fun start(
            context: Context,
            core: String,
            config: String,
            profileName: String,
            serverAddress: String,
            serverCountryCode: String,
            language: String,
            tunIpMode: String,
            splitTunnelMode: String,
            splitTunnelPackages: List<String>,
        ) {
            val intent = Intent(context, EntropyVpnService::class.java).apply {
                action = actionStart
                putExtra(extraCore, core)
                putExtra(extraConfig, config)
                putExtra(extraProfileName, profileName)
                putExtra(extraServerAddress, serverAddress)
                putExtra(extraServerCountryCode, serverCountryCode)
                putExtra(extraLanguage, language)
                putExtra(extraTunIpMode, tunIpMode)
                putExtra(extraSplitTunnelMode, splitTunnelMode)
                putStringArrayListExtra(
                    extraSplitTunnelPackages,
                    ArrayList(splitTunnelPackages),
                )
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, EntropyVpnService::class.java).apply {
                action = actionStop
            }
            ContextCompat.startForegroundService(context, intent)
        }
    }

    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val dnsResolverExecutor: ExecutorService = Executors.newCachedThreadPool()
    private val connectivityManager by lazy {
        getSystemService(ConnectivityManager::class.java)
    }
    private val notificationManager by lazy {
        getSystemService(NotificationManager::class.java)
    }

    private var commandServer: CommandServer? = null
    private var commandClient: CommandClient? = null
    @Volatile
    private var process: Process? = null
    private var tunFileDescriptor: ParcelFileDescriptor? = null
    private var hevTunnelStarted = false
    @Volatile
    private var expectedStop = false
    private var libboxInitialized = false
    private var currentCore: String? = null
    private var currentConfig: String? = null
    private var currentProfileName: String = "EntropyVPN"
    private var currentServerAddress: String = ""
    private var currentServerCountryCode: String = ""
    private var currentLanguage: String = "en"
    private var currentTunIpMode: String = tunIpModeIpv4
    private var currentSplitTunnelMode: String = splitTunnelModeOff
    private var currentSplitTunnelPackages: Set<String> = emptySet()
    private var defaultInterfaceListener: InterfaceUpdateListener? = null
    private var defaultNetwork: Network? = null
    private var defaultNetworkMonitorStarted = false
    private val localDnsTransport =
        object : LocalDNSTransport {
            override fun raw(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

            @RequiresApi(Build.VERSION_CODES.Q)
            override fun exchange(ctx: ExchangeContext, message: ByteArray) {
                val network = requireDefaultNetworkForDns()
                val signal = CancellationSignal()
                val latch = CountDownLatch(1)
                var failure: Throwable? = null

                ctx.onCancel { signal.cancel() }
                DnsResolver.getInstance().rawQuery(
                    network,
                    message,
                    DnsResolver.FLAG_NO_RETRY,
                    dnsResolverExecutor,
                    signal,
                    object : DnsResolver.Callback<ByteArray> {
                        override fun onAnswer(answer: ByteArray, rcode: Int) {
                            if (rcode == 0) {
                                ctx.rawSuccess(answer)
                            } else {
                                ctx.errorCode(rcode)
                            }
                            latch.countDown()
                        }

                        override fun onError(error: DnsResolver.DnsException) {
                            val cause = error.cause
                            if (cause is ErrnoException) {
                                ctx.errnoCode(cause.errno)
                            } else {
                                failure = error
                            }
                            latch.countDown()
                        }
                    },
                )

                awaitLocalDnsCallback(latch) { failure }
            }

            override fun lookup(ctx: ExchangeContext, network: String, domain: String) {
                val defaultNetwork = requireDefaultNetworkForDns()

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    lookupWithDnsResolver(ctx, defaultNetwork, network, domain)
                    return
                }

                val answer =
                    try {
                        defaultNetwork.getAllByName(domain)
                    } catch (_: UnknownHostException) {
                        ctx.errorCode(dnsRcodeNxDomain)
                        return
                    }
                ctx.success(answer.mapNotNull { it.hostAddress }.joinToString("\n"))
            }
        }

    private val defaultNetworkRequest by lazy {
        NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
    }

    private val defaultNetworkCallback =
        object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                updateDefaultNetwork(network)
            }

            override fun onCapabilitiesChanged(
                network: Network,
                networkCapabilities: NetworkCapabilities,
            ) {
                if (defaultNetwork == network || networkCapabilities.isUsableDefaultNetwork()) {
                    updateDefaultNetwork(network)
                }
            }

            override fun onLost(network: Network) {
                if (defaultNetwork == network) {
                    defaultNetwork = null
                    updateDefaultNetwork(null)
                }
            }
        }

    private val serverHandler =
        object : CommandServerHandler {
            override fun serviceStop() {
                dispatchRuntime {
                    if (expectedStop) {
                        return@dispatchRuntime
                    }
                    handleFailure("sing-box requested service stop.")
                }
            }

            override fun serviceReload() {
                dispatchRuntime {
                    if (currentCore == "singBox" && currentConfig != null) {
                        runCatching {
                            commandServer?.startOrReloadService(
                                currentConfig,
                                io.nekohasekai.libbox.OverrideOptions(),
                            )
                        }.onFailure {
                            handleFailure("sing-box reload failed: ${it.message}")
                        }
                    }
                }
            }

            override fun getSystemProxyStatus(): SystemProxyStatus {
                return SystemProxyStatus().apply {
                    available = false
                    enabled = false
                }
            }

            override fun setSystemProxyEnabled(isEnabled: Boolean) {
                EntropyVpnRuntimeStore.addLog(
                    "[app] Ignoring sing-box system proxy toggle on Android.",
                )
            }

            override fun triggerNativeCrash() {
                throw RuntimeException("Native crash requested.")
            }

            override fun writeDebugMessage(message: String) {
                EntropyVpnRuntimeStore.addLog("[box] $message")
            }
        }

    override fun onCreate() {
        super.onCreate()
        ensureNotificationChannel()
        currentLanguage =
            normalizeLanguage(
                EntropyVpnStartPayloadStore.load(this)?.language
                    ?: Locale.getDefault().language,
            )
        startForeground(notificationId, buildNotification(preparingNotificationText()))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            actionStop -> dispatchRuntime { stopRuntime(clearError = true) }
            actionStart -> dispatchRuntime { startRuntime(intent) }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        expectedStop = true
        runCatching {
            stopActiveRuntime(waitForProcess = false)
        }
        executor.shutdownNow()
        dnsResolverExecutor.shutdownNow()
        super.onDestroy()
    }

    override fun onRevoke() {
        expectedStop = true
        dispatchRuntime { stopRuntime(clearError = true) }
    }

    private fun startRuntime(intent: Intent) {
        val core = intent.getStringExtra(extraCore) ?: return
        val config = intent.getStringExtra(extraConfig) ?: return
        val profileName =
            intent.getStringExtra(extraProfileName).orEmpty().ifBlank {
                "EntropyVPN"
            }
        val serverAddress = intent.getStringExtra(extraServerAddress).orEmpty()
        val serverCountryCode =
            normalizeCountryCode(intent.getStringExtra(extraServerCountryCode)).orEmpty()
        val language = normalizeLanguage(intent.getStringExtra(extraLanguage))
        val tunIpMode = normalizeTunIpMode(intent.getStringExtra(extraTunIpMode))
        val splitTunnelMode =
            normalizeSplitTunnelMode(intent.getStringExtra(extraSplitTunnelMode))
        val splitTunnelPackages =
            intent
                .getStringArrayListExtra(extraSplitTunnelPackages)
                .orEmpty()
                .mapNotNull { it.trim().takeIf(String::isNotEmpty) }
                .toSet()

        expectedStop = false
        stopActiveRuntime()

        currentCore = core
        currentConfig = config
        currentProfileName = profileName
        currentServerAddress = serverAddress
        currentServerCountryCode = serverCountryCode
        currentLanguage = language
        currentTunIpMode = tunIpMode
        currentSplitTunnelMode = splitTunnelMode
        currentSplitTunnelPackages = splitTunnelPackages

        EntropyVpnRuntimeStore.resetForStart(core, profileName)
        updateNotification(
            notificationText("Connecting", "Подключение", profileName),
        )

        runCatching {
            when (core) {
                "singBox" -> startSingBox(config)
                "xray" -> startXray(config)
                else -> error("Unsupported core: $core")
            }
        }.onSuccess {
            EntropyVpnRuntimeStore.markConnected()
            updateNotification(
                notificationText("Connected", "Подключено", profileName),
            )
        }.onFailure { error ->
            handleFailure(error.describeForUser("Failed to start VPN runtime."))
        }
    }

    private fun startSingBox(config: String) {
        startLibboxService(config)
    }

    private fun startLibboxService(config: String) {
        ensureLibboxInitialized()
        val server = CommandServer(serverHandler, this)
        server.start()
        try {
            server.startOrReloadService(config, io.nekohasekai.libbox.OverrideOptions())
        } catch (error: Throwable) {
            runCatching { server.close() }
            throw error
        }
        commandServer = server

        val options = CommandClientOptions().apply {
            addCommand(Libbox.CommandLog)
            addCommand(Libbox.CommandStatus)
            statusInterval = 1_000_000_000L
        }
        val client = CommandClient(this, options)
        client.connect()
        commandClient = client
    }

    private fun startXray(config: String) {
        val startedProcess = startXrayProcess(config)
        try {
            startHevTunToSocksBridge()
        } catch (error: Throwable) {
            if (process === startedProcess) {
                process = null
            }
            runCatching {
                if (hevTunnelStarted) {
                    EntropyHevTunnel.TProxyStopService()
                }
            }
            hevTunnelStarted = false
            runCatching {
                tunFileDescriptor?.close()
            }
            tunFileDescriptor = null
            runCatching {
                startedProcess.destroy()
                startedProcess.waitFor()
            }
            throw error
        }
    }

    private fun startHevTunToSocksBridge() {
        startDefaultNetworkMonitor()

        val pfd = openHevTunInterface()
        val configFile = File(filesDir, hevConfigFileName)
        val config = buildHevConfig()
        configFile.writeText(config)

        EntropyVpnRuntimeStore.addLog(
            "[app] Starting hev-socks5-tunnel bridge to Xray SOCKS on " +
                "$xraySocksHost:$xraySocksPort.",
        )

        EntropyHevTunnel.TProxyStartService(configFile.absolutePath, pfd.fd)
        hevTunnelStarted = true
    }

    private fun openHevTunInterface(): ParcelFileDescriptor {
        val includeIpv4 = currentTunIpMode.includesIpv4()
        val includeIpv6 = currentTunIpMode.includesIpv6()
        val dnsServers = hevDnsServersFor(currentTunIpMode)
        val builder =
            Builder()
                .setSession(currentProfileName)
                .setMtu(hevMtu)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }

        applyAppSplitTunnel(builder)
        if (includeIpv4) {
            builder.addAddress(hevIpv4Address, hevIpv4Prefix)
            builder.addRoute("0.0.0.0", 0)
        }
        if (includeIpv6) {
            builder.addAddress(hevIpv6Address, hevIpv6Prefix)
            builder.addRoute("::", 0)
        }
        for (server in dnsServers) {
            builder.addDnsServer(server)
        }

        EntropyVpnRuntimeStore.addLog(
            "[app] Opening Xray VPN TUN via hev: sdk=${Build.VERSION.SDK_INT}, " +
                "mode=$currentTunIpMode, mtu=$hevMtu, " +
                "addr4=${formatHevPrefix(includeIpv4, hevIpv4Address, hevIpv4Prefix)}, " +
                "addr6=${formatHevPrefix(includeIpv6, hevIpv6Address, hevIpv6Prefix)}, " +
                "route4=${if (includeIpv4) "0.0.0.0/0" else "-"}, " +
                "route6=${if (includeIpv6) "::/0" else "-"}, " +
                "dns=${dnsServers.joinToString(",")}.",
        )

        val pfd =
            builder.establish()
                ?: error("Android VpnService establish() returned null.")
        tunFileDescriptor = pfd
        updateDefaultNetwork(defaultNetwork)
        return pfd
    }

    private fun buildHevConfig(): String =
        buildString {
            val includeIpv4 = currentTunIpMode.includesIpv4()
            val includeIpv6 = currentTunIpMode.includesIpv6()
            appendLine("tunnel:")
            appendLine(" mtu: $hevMtu")
            if (includeIpv4) {
                appendLine(" ipv4: $hevIpv4Address")
            }
            if (includeIpv6) {
                appendLine(" ipv6: $hevIpv6Address")
            }
            appendLine("socks5:")
            appendLine(" port: $xraySocksPort")
            appendLine(" address: $xraySocksHost")
            appendLine(" udp: 'udp'")
            appendLine("misc:")
            appendLine(" tcp-read-write-timeout: 300000")
            appendLine(" udp-read-write-timeout: 60000")
            appendLine(" log-level: warn")
        }

    private fun startXrayProcess(config: String): Process {
        val binary = resolveXrayExecutable()
        val configFile = File(cacheDir, "xray-runtime.json")
        configFile.writeText(config)

        val processBuilder =
            ProcessBuilder(binary.absolutePath, "run", "-c", configFile.absolutePath)
                .directory(configFile.parentFile)
                .redirectErrorStream(true)

        val startedProcess = processBuilder.start()
        process = startedProcess

        thread(name = "xray-log-reader", isDaemon = true) {
            try {
                InputStreamReader(startedProcess.inputStream).buffered().useLines { lines ->
                    lines.forEach { line ->
                        EntropyVpnRuntimeStore.addLog(line)
                    }
                }
            } catch (error: IOException) {
                if (!expectedStop && process === startedProcess) {
                    EntropyVpnRuntimeStore.addLog(
                        "[app] xray log stream closed: ${error.describeForUser("log stream closed")}",
                    )
                }
            }
        }

        thread(name = "xray-exit-waiter", isDaemon = true) {
            val exitCode = startedProcess.waitFor()
            dispatchRuntime {
                if (process !== startedProcess) {
                    return@dispatchRuntime
                }
                process = null
                if (!expectedStop) {
                    handleFailure("xray exited with code $exitCode.")
                }
            }
        }

        return startedProcess
    }

    private fun resolveXrayExecutable(): File {
        val nativeBinary = File(applicationInfo.nativeLibraryDir, xrayNativeLibraryName)
        if (nativeBinary.canExecute()) {
            return nativeBinary
        }
        EntropyVpnRuntimeStore.addLog(
            "[app] Native Xray binary is not executable at ${nativeBinary.absolutePath}.",
        )
        error("Native Xray binary is missing or not executable.")
    }

    private fun handleFailure(message: String) {
        EntropyVpnRuntimeStore.addLog("[app] $message")
        EntropyVpnRuntimeStore.markError(message)
        updateNotification(notificationText("Error", "Ошибка"))
        expectedStop = true
        stopActiveRuntime()
        stopSelf()
    }

    private fun stopRuntime(clearError: Boolean) {
        expectedStop = true
        EntropyVpnRuntimeStore.markStopping()
        updateNotification(notificationText("Disconnecting", "Отключение"))
        stopActiveRuntime()
        EntropyVpnRuntimeStore.markDisconnected(clearError = clearError)
        requestQuickSettingsTileUpdate()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun stopActiveRuntime() {
        stopActiveRuntime(waitForProcess = true)
    }

    private fun stopActiveRuntime(waitForProcess: Boolean) {
        stopDefaultNetworkMonitor()

        runCatching {
            commandClient?.disconnect()
        }
        commandClient = null

        runCatching {
            commandServer?.closeService()
        }
        runCatching {
            commandServer?.close()
        }
        commandServer = null

        runCatching {
            if (hevTunnelStarted) {
                EntropyVpnRuntimeStore.addLog("[app] Stopping hev-socks5-tunnel bridge.")
                EntropyHevTunnel.TProxyStopService()
            }
        }
        hevTunnelStarted = false

        runCatching {
            process?.destroy()
            if (waitForProcess) {
                process?.waitFor()
            }
        }
        process = null

        runCatching {
            tunFileDescriptor?.close()
        }
        tunFileDescriptor = null
    }

    private fun dispatchRuntime(block: () -> Unit) {
        try {
            executor.execute { block() }
        } catch (_: RejectedExecutionException) {

        }
    }

    private fun ensureLibboxInitialized() {
        if (libboxInitialized) {
            return
        }
        runCatching {
            Libbox.setLocale(Locale.getDefault().toLanguageTag().replace("-", "_"))
        }
        val workingDir = getExternalFilesDir(null) ?: filesDir
        val options =
            SetupOptions().apply {
                basePath = filesDir.absolutePath
                workingPath = workingDir.absolutePath
                tempPath = cacheDir.absolutePath
                fixAndroidStack = true
                logMaxLines = 400
                debug = false
                crashReportSource = "EntropyVpnService"
            }
        Libbox.setup(options)
        libboxInitialized = true
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        notificationManager.createNotificationChannel(
            NotificationChannel(
                notificationChannelId,
                "EntropyVPN runtime",
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
    }

    private fun preparingNotificationText(): String =
        if (isRussianLanguage()) {
            "Подготовка VPN..."
        } else {
            "Preparing VPN runtime..."
        }

    private fun notificationText(
        englishLabel: String,
        russianLabel: String,
        profileName: String = currentProfileName,
    ): String {
        val label =
            if (isRussianLanguage()) {
                russianLabel
            } else {
                englishLabel
            }
        return "$label: ${notificationProfileName(profileName)}"
    }

    private fun notificationProfileName(profileName: String): String {
        val flag = flagEmojiForCountryCode(currentServerCountryCode) ?: return profileName
        return "$flag $profileName"
    }

    private fun disconnectActionLabel(): String =
        if (isRussianLanguage()) {
            "Отключить"
        } else {
            "Disconnect"
        }

    private fun isRussianLanguage(): Boolean = currentLanguage == "ru"

    private fun normalizeLanguage(language: String?): String =
        if (language.orEmpty().trim().lowercase(Locale.US).startsWith("ru")) {
            "ru"
        } else {
            "en"
        }

    private fun normalizeCountryCode(countryCode: String?): String? {
        val normalized = countryCode.orEmpty().trim().uppercase(Locale.US)
        if (normalized.length != 2 || normalized.any { it !in 'A'..'Z' }) {
            return null
        }
        return normalized
    }

    private fun flagEmojiForCountryCode(countryCode: String?): String? {
        val normalized = normalizeCountryCode(countryCode) ?: return null
        val first = 0x1F1E6 + (normalized[0].code - 'A'.code)
        val second = 0x1F1E6 + (normalized[1].code - 'A'.code)
        return String(Character.toChars(first)) + String(Character.toChars(second))
    }

    private fun updateNotification(text: String) {
        notificationManager.notify(notificationId, buildNotification(text))
        requestQuickSettingsTileUpdate()
    }

    private fun buildNotification(text: String): Notification {
        val intent = Intent(this, MainActivity::class.java)
        val flags =
            PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    PendingIntent.FLAG_IMMUTABLE
                } else {
                    0
                })
        val pendingIntent = PendingIntent.getActivity(this, 0, intent, flags)
        val stopIntent = Intent(this, EntropyVpnService::class.java).apply {
            action = actionStop
        }
        val stopPendingIntent = PendingIntent.getService(this, 1, stopIntent, flags)

        return NotificationCompat.Builder(this, notificationChannelId)
            .setSmallIcon(R.drawable.ic_notification_entropy)
            .setContentTitle("EntropyVPN")
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(pendingIntent)
            .addAction(R.drawable.ic_qs_vpn, disconnectActionLabel(), stopPendingIntent)
            .build()
    }

    private fun requestQuickSettingsTileUpdate() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            EntropyVpnTileService.requestStateUpdate(this)
        }
    }

    private fun addSelfBypass(builder: Builder) {
        if (addDisallowedApplication(builder, packageName)) {
            EntropyVpnRuntimeStore.addLog(
                "[app] Excluding $packageName from Android VPN capture.",
            )
        } else {
            EntropyVpnRuntimeStore.addLog(
                "[app] Failed to exclude $packageName from Android VPN capture.",
            )
        }
    }

    private fun applyAppSplitTunnel(builder: Builder) {
        val selectedPackages = currentSplitTunnelPackages
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .toSet()

        when (currentSplitTunnelMode) {
            splitTunnelModeWhitelist -> {
                if (selectedPackages.isEmpty()) {
                    error("Select at least one app for Android tunnel whitelist.")
                }

                var allowedCount = 0
                for (appPackageName in selectedPackages) {
                    if (appPackageName == packageName) {
                        EntropyVpnRuntimeStore.addLog(
                            "[app] Skipping EntropyVPN package in split whitelist.",
                        )
                        continue
                    }
                    if (addAllowedApplication(builder, appPackageName)) {
                        allowedCount += 1
                    }
                }
                if (allowedCount == 0) {
                    error("No selected Android split-tunnel apps could be applied.")
                }
                EntropyVpnRuntimeStore.addLog(
                    "[app] Android split tunneling: whitelist, allowed apps=$allowedCount.",
                )
            }
            splitTunnelModeBlacklist -> {
                addSelfBypass(builder)
                var disallowedCount = 0
                for (appPackageName in selectedPackages) {
                    if (appPackageName == packageName) {
                        continue
                    }
                    if (addDisallowedApplication(builder, appPackageName)) {
                        disallowedCount += 1
                    }
                }
                EntropyVpnRuntimeStore.addLog(
                    "[app] Android split tunneling: blacklist, bypass apps=$disallowedCount.",
                )
            }
            else -> {
                addSelfBypass(builder)
                EntropyVpnRuntimeStore.addLog(
                    "[app] Android split tunneling: off.",
                )
            }
        }
    }

    private fun addAllowedApplication(
        builder: Builder,
        appPackageName: String,
    ): Boolean =
        try {
            builder.addAllowedApplication(appPackageName)
            true
        } catch (_: PackageManager.NameNotFoundException) {
            EntropyVpnRuntimeStore.addLog(
                "[app] Split tunnel package not found: $appPackageName.",
            )
            false
        }

    private fun addDisallowedApplication(
        builder: Builder,
        appPackageName: String,
    ): Boolean =
        try {
            builder.addDisallowedApplication(appPackageName)
            true
        } catch (_: PackageManager.NameNotFoundException) {
            EntropyVpnRuntimeStore.addLog(
                "[app] Split tunnel package not found: $appPackageName.",
            )
            false
        }

    override fun connected() {
        EntropyVpnRuntimeStore.addLog("[app] sing-box log stream connected.")
    }

    override fun disconnected(message: String?) {
        if (expectedStop) {
            return
        }
        dispatchRuntime {
            if (commandServer != null) {
                handleFailure(message ?: "sing-box log stream disconnected.")
            }
        }
    }

    override fun setDefaultLogLevel(level: Int) {
        EntropyVpnRuntimeStore.addLog("[app] sing-box log level: $level")
    }

    override fun clearLogs() {

    }

    override fun writeLogs(messageList: LogIterator?) {
        if (messageList == null) {
            return
        }
        while (messageList.hasNext()) {
            val entry = messageList.next()
            EntropyVpnRuntimeStore.addLog(entry.render())
        }
    }

    override fun writeStatus(message: StatusMessage?) {
        if (message == null) {
            return
        }
        EntropyVpnRuntimeStore.addLog(
            "[status] up=${message.uplinkTotal} down=${message.downlinkTotal} conns=${message.connectionsOut}",
        )
    }

    override fun writeGroups(message: OutboundGroupIterator?) {}

    override fun writeOutbounds(message: OutboundGroupItemIterator?) {}

    override fun initializeClashMode(modeList: StringIterator?, currentMode: String?) {}

    override fun updateClashMode(newMode: String?) {}

    override fun writeConnectionEvents(events: ConnectionEvents?) {}

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun autoDetectInterfaceControl(fd: Int) {
        if (!protect(fd)) {
            EntropyVpnRuntimeStore.addLog(
                "[app] Failed to protect outbound socket fd=$fd from VPN capture.",
            )
        }
    }

    override fun openTun(options: TunOptions): Int {
        startDefaultNetworkMonitor()

        val builder =
            Builder()
                .setSession(currentProfileName)
                .setMtu(options.mtu)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }

        applyAppSplitTunnel(builder)

        val inet4Addresses = options.inet4Address.toRoutePrefixList()
        for (address in inet4Addresses) {
            builder.addAddress(address.address(), address.prefix())
        }

        val inet6Addresses = options.inet6Address.toRoutePrefixList()
        for (address in inet6Addresses) {
            builder.addAddress(address.address(), address.prefix())
        }

        var dnsServerAddress = "-"
        var route4Description = "-"
        var route6Description = "-"
        var exclude4Description = "-"
        var exclude6Description = "-"

        if (options.autoRoute) {
            dnsServerAddress = options.dnsServerAddress.value
            builder.addDnsServer(dnsServerAddress)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val inet4RouteAddresses = options.inet4RouteAddress.toRoutePrefixList()
                route4Description =
                    if (inet4RouteAddresses.isEmpty() && inet4Addresses.isNotEmpty()) {
                        "0.0.0.0/0"
                    } else {
                        inet4RouteAddresses.describePrefixes()
                    }
                for (address in inet4RouteAddresses) {
                    builder.addRoute(address.toIpPrefix())
                }
                if (inet4RouteAddresses.isEmpty() && inet4Addresses.isNotEmpty()) {
                    builder.addRoute("0.0.0.0", 0)
                }

                val inet6RouteAddresses = options.inet6RouteAddress.toRoutePrefixList()
                route6Description =
                    if (inet6RouteAddresses.isEmpty() && inet6Addresses.isNotEmpty()) {
                        "::/0"
                    } else {
                        inet6RouteAddresses.describePrefixes()
                    }
                for (address in inet6RouteAddresses) {
                    builder.addRoute(address.toIpPrefix())
                }
                if (inet6RouteAddresses.isEmpty() && inet6Addresses.isNotEmpty()) {
                    builder.addRoute("::", 0)
                }

                val inet4RouteExcludeAddresses =
                    options.inet4RouteExcludeAddress.toRoutePrefixList()
                exclude4Description = inet4RouteExcludeAddresses.describePrefixes()
                for (address in inet4RouteExcludeAddresses) {
                    builder.excludeRoute(address.toIpPrefix())
                }

                val inet6RouteExcludeAddresses =
                    options.inet6RouteExcludeAddress.toRoutePrefixList()
                exclude6Description = inet6RouteExcludeAddresses.describePrefixes()
                for (address in inet6RouteExcludeAddresses) {
                    builder.excludeRoute(address.toIpPrefix())
                }
            } else {
                val inet4RouteRanges = options.inet4RouteRange.toRoutePrefixList()
                route4Description = inet4RouteRanges.describePrefixes()
                for (address in inet4RouteRanges) {
                    builder.addRoute(address.address(), address.prefix())
                }

                val inet6RouteRanges = options.inet6RouteRange.toRoutePrefixList()
                route6Description = inet6RouteRanges.describePrefixes()
                for (address in inet6RouteRanges) {
                    builder.addRoute(address.address(), address.prefix())
                }
            }
        }

        EntropyVpnRuntimeStore.addLog(
            "[app] Opening TUN: sdk=${Build.VERSION.SDK_INT}, mtu=${options.mtu}, " +
                "autoRoute=${options.autoRoute}, dns=$dnsServerAddress, " +
                "addr4=${inet4Addresses.describePrefixes()}, addr6=${inet6Addresses.describePrefixes()}, " +
                "route4=$route4Description, route6=$route6Description, " +
                "exclude4=$exclude4Description, exclude6=$exclude6Description.",
        )

        val pfd =
            builder.establish()
                ?: error("Android VpnService establish() returned null.")
        tunFileDescriptor = pfd
        updateDefaultNetwork(defaultNetwork)
        return pfd.fd
    }

    override fun useProcFS(): Boolean = false

    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): ConnectionOwner {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            return runCatching {
                val uid =
                    connectivityManager.getConnectionOwnerUid(
                        ipProtocol,
                        InetSocketAddress(sourceAddress, sourcePort),
                        InetSocketAddress(destinationAddress, destinationPort),
                    )
                val owner = ConnectionOwner()
                owner.userId = uid
                owner.userName =
                    packageManager.getPackagesForUid(uid)?.firstOrNull().orEmpty()
                owner
            }.getOrDefault(ConnectionOwner())
        }
        return ConnectionOwner()
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener?) {
        defaultInterfaceListener = listener
        startDefaultNetworkMonitor()
        updateDefaultNetwork(defaultNetwork)
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener?) {
        if (defaultInterfaceListener === listener) {
            defaultInterfaceListener = null
        }
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        val interfaces = mutableListOf<NetworkInterface>()
        val systemInterfaces = JNetworkInterface.getNetworkInterfaces()?.toList().orEmpty()

        for (network in connectivityManager.allNetworks) {
            val linkProperties = connectivityManager.getLinkProperties(network) ?: continue
            val capabilities = connectivityManager.getNetworkCapabilities(network) ?: continue
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
                continue
            }
            val name = linkProperties.interfaceName ?: continue
            val systemInterface = systemInterfaces.firstOrNull { it.name == name } ?: continue

            val item =
                NetworkInterface().apply {
                    this.name = name
                    index = systemInterface.index
                    dnsServer =
                        SimpleStringIterator(
                            linkProperties.dnsServers
                                .mapNotNull { it.toHostAddressWithoutScope().takeIf(String::isNotBlank) }
                                .iterator(),
                        )
                    type =
                        when {
                            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Libbox.InterfaceTypeWIFI
                            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Libbox.InterfaceTypeCellular
                            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> Libbox.InterfaceTypeEthernet
                            else -> Libbox.InterfaceTypeOther
                        }
                    mtu = runCatching { systemInterface.mtu }.getOrDefault(1500)
                    addresses =
                        SimpleStringIterator(
                            systemInterface.interfaceAddresses.map { it.toPrefix() }.iterator(),
                        )
                    flags = systemInterface.dumpFlags(capabilities)
                    metered =
                        !capabilities.hasCapability(
                            NetworkCapabilities.NET_CAPABILITY_NOT_METERED,
                        )
                }
            interfaces.add(item)
        }

        return object : NetworkInterfaceIterator {
            private val iterator = interfaces.iterator()

            override fun hasNext(): Boolean = iterator.hasNext()

            override fun next(): NetworkInterface = iterator.next()
        }
    }

    override fun underNetworkExtension(): Boolean = false

    override fun includeAllNetworks(): Boolean = false

    override fun readWIFIState(): WIFIState? = null

    override fun localDNSTransport(): LocalDNSTransport? = localDnsTransport

    override fun systemCertificates(): StringIterator {
        return SimpleStringIterator(emptyList<String>().iterator())
    }

    override fun clearDNSCache() {}

    override fun sendNotification(notification: BoxNotification?) {
        if (notification == null) {
            return
        }
        EntropyVpnRuntimeStore.addLog("[notify] ${notification.title}: ${notification.body}")
    }

    override fun startNeighborMonitor(listener: NeighborUpdateListener?) {}

    override fun registerMyInterface(name: String?) {}

    override fun closeNeighborMonitor(listener: NeighborUpdateListener?) {}

    private fun normalizeTunIpMode(mode: String?): String =
        when (mode?.trim()) {
            tunIpModeIpv4 -> tunIpModeIpv4
            tunIpModeDualStack, "dual_stack", "dual-stack" -> tunIpModeDualStack
            tunIpModeIpv6 -> tunIpModeIpv6
            else -> tunIpModeIpv4
        }

    private fun normalizeSplitTunnelMode(mode: String?): String =
        when (mode?.trim()) {
            splitTunnelModeWhitelist -> splitTunnelModeWhitelist
            splitTunnelModeBlacklist -> splitTunnelModeBlacklist
            else -> splitTunnelModeOff
        }

    private fun String.includesIpv4(): Boolean = this != tunIpModeIpv6

    private fun String.includesIpv6(): Boolean = this != tunIpModeIpv4

    private fun hevDnsServersFor(mode: String): List<String> =
        when (mode) {
            tunIpModeIpv4 -> hevIpv4DnsServers
            tunIpModeIpv6 -> hevIpv6DnsServers
            else -> hevIpv4DnsServers + hevIpv6DnsServers
        }

    private fun formatHevPrefix(enabled: Boolean, address: String, prefix: Int): String =
        if (enabled) {
            "$address/$prefix"
        } else {
            "-"
        }

    private fun LogEntry.render(): String {
        return message?.trim().orEmpty().ifBlank { toString() }
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun RoutePrefix.toIpPrefix(): IpPrefix {
        return IpPrefix(InetAddress.getByName(address()), prefix())
    }

    private fun RoutePrefixIterator.toRoutePrefixList(): List<RoutePrefix> {
        val prefixes = mutableListOf<RoutePrefix>()
        while (hasNext()) {
            prefixes.add(next())
        }
        return prefixes
    }

    private fun List<RoutePrefix>.describePrefixes(): String =
        if (isEmpty()) {
            "-"
        } else {
            joinToString(",") { it.string() }
        }

    private fun InterfaceAddress.toPrefix(): String =
        "${address.toHostAddressWithoutScope()}/$networkPrefixLength"

    private fun InetAddress.toHostAddressWithoutScope(): String {
        val normalized =
            if (this is Inet6Address) {
                Inet6Address.getByAddress(address).hostAddress
            } else {
                hostAddress
            }
        return normalized.substringBefore('%')
    }

    private fun startDefaultNetworkMonitor() {
        if (defaultNetworkMonitorStarted) {
            return
        }
        defaultNetworkMonitorStarted = true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            updateDefaultNetwork(connectivityManager.activeNetwork)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            runCatching {
                connectivityManager.requestNetwork(defaultNetworkRequest, defaultNetworkCallback)
            }.onFailure {
                EntropyVpnRuntimeStore.addLog(
                    "[app] Failed to request default network: ${it.describeForUser("network callback failed")}",
                )
            }
        }
    }

    private fun stopDefaultNetworkMonitor() {
        if (!defaultNetworkMonitorStarted) {
            return
        }
        defaultNetworkMonitorStarted = false
        runCatching {
            connectivityManager.unregisterNetworkCallback(defaultNetworkCallback)
        }
        defaultNetwork = null
        runCatching { setUnderlyingNetworks(null) }
        defaultInterfaceListener?.updateDefaultInterface("", -1, false, false)
    }

    private fun updateDefaultNetwork(network: Network?) {
        val physicalNetwork = resolveUsableDefaultNetwork(network)
        defaultNetwork = physicalNetwork
        runCatching {
            setUnderlyingNetworks(if (physicalNetwork == null) null else arrayOf(physicalNetwork))
        }

        val listener = defaultInterfaceListener ?: return
        if (physicalNetwork == null) {
            listener.updateDefaultInterface("", -1, false, false)
            return
        }

        for (attempt in 0 until 10) {
            val interfaceName =
                connectivityManager.getLinkProperties(physicalNetwork)?.interfaceName
            if (interfaceName.isNullOrBlank()) {
                Thread.sleep(100)
                continue
            }
            val index =
                runCatching { JNetworkInterface.getByName(interfaceName)?.index }
                    .getOrNull()
            if (index == null) {
                Thread.sleep(100)
                continue
            }
            listener.updateDefaultInterface(interfaceName, index, false, false)
            return
        }

        listener.updateDefaultInterface("", -1, false, false)
    }

    private fun requireDefaultNetworkForDns(): Network {
        startDefaultNetworkMonitor()
        resolveUsableDefaultNetwork(defaultNetwork)?.let { return it }

        repeat(10) {
            Thread.sleep(100)
            resolveUsableDefaultNetwork(defaultNetwork)?.let { return it }
        }

        error("missing default network")
    }

    private fun resolveUsableDefaultNetwork(preferredNetwork: Network?): Network? {
        preferredNetwork?.takeIf { it.isUsableDefaultNetwork() }?.let { return it }
        defaultNetwork?.takeIf { it.isUsableDefaultNetwork() }?.let { return it }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            connectivityManager.activeNetwork
                ?.takeIf { it.isUsableDefaultNetwork() }
                ?.let { return it }
        }

        return connectivityManager.allNetworks.firstOrNull { it.isUsableDefaultNetwork() }
    }

    private fun Network.isUsableDefaultNetwork(): Boolean {
        val capabilities =
            connectivityManager.getNetworkCapabilities(this) ?: return false
        if (!capabilities.isUsableDefaultNetwork()) {
            return false
        }
        val interfaceName = connectivityManager.getLinkProperties(this)?.interfaceName
        return !interfaceName.isNullOrBlank()
    }

    private fun NetworkCapabilities.isUsableDefaultNetwork(): Boolean {
        return hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            !hasTransport(NetworkCapabilities.TRANSPORT_VPN)
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun lookupWithDnsResolver(
        ctx: ExchangeContext,
        defaultNetwork: Network,
        network: String,
        domain: String,
    ) {
        val signal = CancellationSignal()
        val latch = CountDownLatch(1)
        var failure: Throwable? = null
        val callback =
            object : DnsResolver.Callback<Collection<InetAddress>> {
                override fun onAnswer(answer: Collection<InetAddress>, rcode: Int) {
                    if (rcode == 0) {
                        ctx.success(answer.mapNotNull { it.hostAddress }.joinToString("\n"))
                    } else {
                        ctx.errorCode(rcode)
                    }
                    latch.countDown()
                }

                override fun onError(error: DnsResolver.DnsException) {
                    val cause = error.cause
                    if (cause is ErrnoException) {
                        ctx.errnoCode(cause.errno)
                    } else {
                        failure = error
                    }
                    latch.countDown()
                }
            }

        ctx.onCancel { signal.cancel() }
        val queryType =
            when {
                network.endsWith("4") -> DnsResolver.TYPE_A
                network.endsWith("6") -> DnsResolver.TYPE_AAAA
                else -> null
            }
        if (queryType == null) {
            DnsResolver.getInstance().query(
                defaultNetwork,
                domain,
                DnsResolver.FLAG_NO_RETRY,
                dnsResolverExecutor,
                signal,
                callback,
            )
        } else {
            DnsResolver.getInstance().query(
                defaultNetwork,
                domain,
                queryType,
                DnsResolver.FLAG_NO_RETRY,
                dnsResolverExecutor,
                signal,
                callback,
            )
        }

        awaitLocalDnsCallback(latch) { failure }
    }

    private fun awaitLocalDnsCallback(
        latch: CountDownLatch,
        failure: () -> Throwable?,
    ) {
        if (!latch.await(localDnsTimeoutSeconds, TimeUnit.SECONDS)) {
            throw IOException("local DNS query timed out.")
        }
        failure()?.let { throw it }
    }

    private fun JNetworkInterface.dumpFlags(capabilities: NetworkCapabilities): Int {
        var flags = 0
        if (capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
            flags = flags or OsConstants.IFF_UP or OsConstants.IFF_RUNNING
        }
        if (isLoopback) {
            flags = flags or OsConstants.IFF_LOOPBACK
        }
        if (isPointToPoint) {
            flags = flags or OsConstants.IFF_POINTOPOINT
        }
        if (runCatching { supportsMulticast() }.getOrDefault(false)) {
            flags = flags or OsConstants.IFF_MULTICAST
        }
        return flags
    }

    private fun Throwable.describeForUser(fallback: String): String {
        val message = this.message?.trim().orEmpty()
        return if (message.isEmpty()) {
            fallback
        } else {
            "${javaClass.simpleName}: $message"
        }
    }

    private class SimpleStringIterator(private val iterator: Iterator<String>) : StringIterator {
        override fun len(): Int = 0

        override fun hasNext(): Boolean = iterator.hasNext()

        override fun next(): String = iterator.next()
    }
}
