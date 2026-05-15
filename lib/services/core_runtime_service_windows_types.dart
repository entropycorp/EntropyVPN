import 'dart:ffi';

class TunRoutingPreparation {
  const TunRoutingPreparation({
    this.outboundBindInterface,
    this.serverAddressOverride,
    this.hasHostRoute = false,
    this.hostRoutes = const <WindowsHostRoute>[],
  });

  final String? outboundBindInterface;
  final String? serverAddressOverride;
  final bool hasHostRoute;
  final List<WindowsHostRoute> hostRoutes;
}

class WindowsTunSetup {
  const WindowsTunSetup({required this.routes, required this.networkChanged});

  final List<WindowsTunRoute> routes;
  final bool networkChanged;
}

class WindowsTunRoute {
  const WindowsTunRoute({
    required this.destinationPrefix,
    required this.interfaceAlias,
    required this.interfaceIndex,
    required this.nextHop,
  });

  final String destinationPrefix;
  final String interfaceAlias;
  final int interfaceIndex;
  final String nextHop;
}

class WindowsHostRoute {
  const WindowsHostRoute({
    required this.destinationPrefix,
    required this.interfaceAlias,
    required this.interfaceIndex,
    required this.nextHop,
    this.removeWhenUnused = true,
  });

  final String destinationPrefix;
  final String interfaceAlias;
  final int interfaceIndex;
  final String nextHop;
  final bool removeWhenUnused;
}

const int windowsTokenQuery = 0x0008;
const int windowsTokenElevation = 20;

typedef GetCurrentProcessNative = IntPtr Function();
typedef GetCurrentProcessDart = int Function();

typedef OpenProcessTokenNative =
    Int32 Function(IntPtr processHandle, Uint32 desiredAccess, Pointer<IntPtr>);
typedef OpenProcessTokenDart =
    int Function(int processHandle, int desiredAccess, Pointer<IntPtr>);

typedef GetTokenInformationNative =
    Int32 Function(
      IntPtr tokenHandle,
      Int32 tokenInformationClass,
      Pointer<Void> tokenInformation,
      Uint32 tokenInformationLength,
      Pointer<Uint32> returnLength,
    );
typedef GetTokenInformationDart =
    int Function(
      int tokenHandle,
      int tokenInformationClass,
      Pointer<Void> tokenInformation,
      int tokenInformationLength,
      Pointer<Uint32> returnLength,
    );

typedef CloseHandleNative = Int32 Function(IntPtr handle);
typedef CloseHandleDart = int Function(int handle);
