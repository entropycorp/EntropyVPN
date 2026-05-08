package com.example.entropy_vpn

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.widget.Toast
import androidx.annotation.RequiresApi
import java.util.Locale

@RequiresApi(Build.VERSION_CODES.N)
class EntropyVpnTileService : TileService() {
    companion object {
        fun requestStateUpdate(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
                return
            }
            runCatching {
                requestListeningState(
                    context,
                    ComponentName(context, EntropyVpnTileService::class.java),
                )
            }
        }
    }

    override fun onTileAdded() {
        super.onTileAdded()
        updateTile()
    }

    override fun onStartListening() {
        super.onStartListening()
        updateTile()
    }

    override fun onClick() {
        super.onClick()

        val snapshot = EntropyVpnRuntimeStore.snapshot()
        val phase = snapshot["phase"]?.toString().orEmpty()
        if (phase == "connecting" || phase == "disconnecting") {
            updateTile()
            return
        }

        if (snapshot["running"] == true || phase == "connected") {
            EntropyVpnService.stop(this)
            updateTile(phaseOverride = "disconnecting")
            return
        }

        val payload = EntropyVpnStartPayloadStore.load(this)
        if (payload == null) {
            Toast.makeText(
                this,
                "Open EntropyVPN and connect once first.",
                Toast.LENGTH_SHORT,
            ).show()
            openApp()
            updateTile()
            return
        }

        if (VpnService.prepare(this) != null) {
            Toast.makeText(
                this,
                "Allow VPN permission in EntropyVPN first.",
                Toast.LENGTH_SHORT,
            ).show()
            openApp()
            updateTile()
            return
        }

        EntropyVpnService.start(
            context = this,
            core = payload.core,
            config = payload.config,
            profileName = payload.profileName,
            serverAddress = payload.serverAddress,
            serverCountryCode = payload.serverCountryCode,
            language = payload.language,
            tunIpMode = payload.tunIpMode,
            splitTunnelMode = payload.splitTunnelMode,
            splitTunnelPackages = payload.splitTunnelPackages,
        )
        updateTile(phaseOverride = "connecting")
    }

    private fun updateTile(phaseOverride: String? = null) {
        val tile = qsTile ?: return
        val snapshot = EntropyVpnRuntimeStore.snapshot()
        val payload = EntropyVpnStartPayloadStore.load(this)
        val phase = phaseOverride ?: snapshot["phase"]?.toString().orEmpty()
        val isConnecting = phase == "connecting"
        val isDisconnecting = phase == "disconnecting"
        val isConnected =
            phase == "connected" ||
                (snapshot["running"] == true && !isConnecting && !isDisconnecting)
        val isOn = isConnected || isConnecting
        val profileName =
            snapshot["profileName"]?.toString()?.trim()?.takeIf(String::isNotEmpty)
                ?: payload?.profileName
        val serverCountryCode =
            snapshot["serverCountryCode"]?.toString()?.trim()?.takeIf(String::isNotEmpty)
                ?: payload?.serverCountryCode
        val profileSubtitle = profileNameWithCountryFlag(profileName, serverCountryCode)

        tile.label = "EntropyVPN"
        tile.state =
            when {
                isOn -> Tile.STATE_ACTIVE
                isDisconnecting -> Tile.STATE_INACTIVE
                else -> Tile.STATE_INACTIVE
            }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle =
                when {
                    isConnecting -> "Connecting"
                    isDisconnecting -> "Disconnecting"
                    isConnected -> profileSubtitle ?: "Connected"
                    payload == null -> "Open app first"
                    else -> "Tap to connect"
                }
        }
        tile.updateTile()
    }

    private fun profileNameWithCountryFlag(
        profileName: String?,
        countryCode: String?,
    ): String? {
        val name = profileName?.trim()?.takeIf(String::isNotEmpty) ?: return null
        val flag = flagEmojiForCountryCode(countryCode) ?: return name
        return if (name.startsWith(flag)) name else "$flag $name"
    }

    private fun flagEmojiForCountryCode(countryCode: String?): String? {
        val normalized = normalizeCountryCode(countryCode) ?: return null
        val first = 0x1F1E6 + (normalized[0].code - 'A'.code)
        val second = 0x1F1E6 + (normalized[1].code - 'A'.code)
        return String(Character.toChars(first)) + String(Character.toChars(second))
    }

    private fun normalizeCountryCode(countryCode: String?): String? {
        val normalized = countryCode.orEmpty().trim().uppercase(Locale.US)
        if (normalized.length != 2 || normalized.any { it !in 'A'..'Z' }) {
            return null
        }
        return normalized
    }

    private fun openApp() {
        val launchIntent =
            packageManager.getLaunchIntentForPackage(packageName)
                ?: Intent(this, MainActivity::class.java).apply {
                    action = Intent.ACTION_MAIN
                    addCategory(Intent.CATEGORY_LAUNCHER)
                }
        launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            val pendingIntent = PendingIntent.getActivity(this, 0, launchIntent, flags)
            startActivityAndCollapse(pendingIntent)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(launchIntent)
        }
    }
}
