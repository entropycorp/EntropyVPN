package com.example.entropy_vpn

import android.content.Context

data class EntropyVpnStartPayload(
    val core: String,
    val config: String,
    val profileName: String,
    val serverAddress: String,
    val serverCountryCode: String,
    val language: String,
    val tunIpMode: String,
    val splitTunnelMode: String,
    val splitTunnelPackages: List<String>,
)

object EntropyVpnStartPayloadStore {
    private const val prefsName = "entropy_vpn_start_payload"
    private const val currentVersion = 2
    private const val keyVersion = "version"
    private const val keyCore = "core"
    private const val keyConfig = "config"
    private const val keyProfileName = "profileName"
    private const val keyServerAddress = "serverAddress"
    private const val keyServerCountryCode = "serverCountryCode"
    private const val keyLanguage = "language"
    private const val keyTunIpMode = "tunIpMode"
    private const val keySplitTunnelMode = "splitTunnelMode"
    private const val keySplitTunnelPackages = "splitTunnelPackages"

    fun save(context: Context, payload: EntropyVpnStartPayload) {
        context
            .getSharedPreferences(prefsName, Context.MODE_PRIVATE)
            .edit()
            .putInt(keyVersion, currentVersion)
            .putString(keyCore, payload.core)
            .putString(keyConfig, payload.config)
            .putString(keyProfileName, payload.profileName)
            .putString(keyServerAddress, payload.serverAddress)
            .putString(keyServerCountryCode, payload.serverCountryCode)
            .putString(keyLanguage, payload.language)
            .putString(keyTunIpMode, payload.tunIpMode)
            .putString(keySplitTunnelMode, payload.splitTunnelMode)
            .putStringSet(
                keySplitTunnelPackages,
                payload.splitTunnelPackages
                    .mapNotNull { it.trim().takeIf(String::isNotEmpty) }
                    .toSet(),
            )
            .apply()
    }

    fun load(context: Context): EntropyVpnStartPayload? {
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        val core = prefs.getString(keyCore, null)?.trim()
        val config = prefs.getString(keyConfig, null)
        if (core.isNullOrEmpty() || config.isNullOrBlank()) {
            return null
        }

        val version = prefs.getInt(keyVersion, 1)
        val storedTunIpMode = prefs.getString(keyTunIpMode, null).orEmpty()
        val tunIpMode =
            when {
                storedTunIpMode.isBlank() -> "ipv4"
                version < 2 && storedTunIpMode == "dualStack" -> "ipv4"
                else -> storedTunIpMode
            }

        return EntropyVpnStartPayload(
            core = core,
            config = config,
            profileName =
                prefs
                    .getString(keyProfileName, null)
                    ?.trim()
                    ?.takeIf(String::isNotEmpty)
                    ?: "EntropyVPN",
            serverAddress = prefs.getString(keyServerAddress, null).orEmpty(),
            serverCountryCode = prefs.getString(keyServerCountryCode, null).orEmpty(),
            language = prefs.getString(keyLanguage, null).orEmpty().ifBlank { "en" },
            tunIpMode = tunIpMode,
            splitTunnelMode = prefs.getString(keySplitTunnelMode, null).orEmpty().ifBlank { "off" },
            splitTunnelPackages =
                prefs
                    .getStringSet(keySplitTunnelPackages, emptySet())
                    .orEmpty()
                    .mapNotNull { it.trim().takeIf(String::isNotEmpty) }
                    .sorted(),
        )
    }
}
