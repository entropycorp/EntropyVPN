package com.example.entropy_vpn

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import java.util.ArrayDeque

object EntropyVpnRuntimeStore {
    private const val tag = "EntropyVpnRuntimeStore"
    private const val maxLogs = 400

    private val mainHandler = Handler(Looper.getMainLooper())
    private val logs = ArrayDeque<String>()

    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    @Volatile
    private var running = false

    @Volatile
    private var phase = "disconnected"

    @Volatile
    private var core: String? = null

    @Volatile
    private var profileName: String? = null

    @Volatile
    private var serverCountryCode: String? = null

    @Volatile
    private var error: String? = null

    @Volatile
    private var connectedAtEpochMillis: Long? = null

    fun attachSink(sink: EventChannel.EventSink?) {
        eventSink = sink
        if (sink != null) {
            publish()
        }
    }

    @Synchronized
    fun resetForStart(nextCore: String, nextProfileName: String, nextServerCountryCode: String) {
        logs.clear()
        core = nextCore
        profileName = nextProfileName
        serverCountryCode = nextServerCountryCode.trim().takeIf(String::isNotEmpty)
        error = null
        connectedAtEpochMillis = null
        running = false
        phase = "connecting"
        addLog("[app] Starting $nextCore for $nextProfileName.")
        publish()
    }

    @Synchronized
    fun markConnected() {
        running = true
        error = null
        connectedAtEpochMillis = connectedAtEpochMillis ?: System.currentTimeMillis()
        phase = "connected"
        publish()
    }

    @Synchronized
    fun markStopping() {
        phase = "disconnecting"
        publish()
    }

    @Synchronized
    fun markDisconnected(clearError: Boolean) {
        running = false
        phase = "disconnected"
        connectedAtEpochMillis = null
        if (clearError) {
            error = null
        }
        publish()
    }

    @Synchronized
    fun markError(message: String) {
        running = false
        phase = "error"
        error = message
        connectedAtEpochMillis = null
        publish()
    }

    @Synchronized
    fun addLog(line: String) {
        val trimmed = line.trim()
        if (trimmed.isEmpty()) {
            return
        }
        logs.addLast(trimmed)
        while (logs.size > maxLogs) {
            logs.removeFirst()
        }
        publish()
    }

    @Synchronized
    fun snapshot(): Map<String, Any?> {
        return mapOf(
            "running" to running,
            "phase" to phase,
            "core" to core,
            "profileName" to profileName,
            "serverCountryCode" to serverCountryCode,
            "error" to error,
            "connectedAtEpochMillis" to connectedAtEpochMillis,
            "logs" to logs.toList(),
        )
    }

    private fun publish() {
        val sink = eventSink ?: return
        val snapshot = snapshot()
        mainHandler.post {
            if (eventSink !== sink) {
                return@post
            }
            runCatching {
                sink.success(snapshot)
            }.onFailure {
                Log.w(tag, "Dropping runtime event for a detached Flutter sink.", it)
                if (eventSink === sink) {
                    eventSink = null
                }
            }
        }
    }
}
