package com.example.entropy_vpn

class EntropyHevTunnel private constructor() {
    companion object {
        init {
            System.loadLibrary("hev-socks5-tunnel")
        }

        @JvmStatic
        @Suppress("FunctionName")
        external fun TProxyStartService(configPath: String, fd: Int)

        @JvmStatic
        @Suppress("FunctionName")
        external fun TProxyStopService()

        @JvmStatic
        @Suppress("FunctionName")
        external fun TProxyGetStats(): LongArray?
    }
}
