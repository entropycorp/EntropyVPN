part of 'core_runtime_service.dart';

class _WindowsProcessInfo {
  const _WindowsProcessInfo({
    required this.pid,
    required this.parentPid,
    required this.path,
  });

  final int pid;
  final int parentPid;
  final String? path;
}

class _WindowsProcessSnapshotCacheEntry {
  const _WindowsProcessSnapshotCacheEntry({
    required this.createdAt,
    required this.processes,
  });

  final DateTime createdAt;
  final List<_WindowsProcessInfo> processes;
}

class _WindowsRouteInfo {
  const _WindowsRouteInfo({
    required this.interfaceAlias,
    this.interfaceIndex,
    this.sourceAddress,
    this.nextHop,
    this.hardwareInterface,
    this.virtual,
  });

  final String interfaceAlias;
  final int? interfaceIndex;
  final String? sourceAddress;
  final String? nextHop;
  final bool? hardwareInterface;
  final bool? virtual;
}

class _TunRoutingPreparation {
  const _TunRoutingPreparation({
    this.outboundBindInterface,
    this.serverAddressOverride,
    this.hasHostRoute = false,
    this.hostRoutes = const <_WindowsHostRoute>[],
  });

  final String? outboundBindInterface;
  final String? serverAddressOverride;
  final bool hasHostRoute;
  final List<_WindowsHostRoute> hostRoutes;
}

class _WindowsTunSetup {
  const _WindowsTunSetup({
    required this.routes,
    required this.networkChanged,
    this.fastConfigureMethod,
  });

  final List<_WindowsTunRoute> routes;
  final bool networkChanged;
  final _WindowsTunFastConfigureMethod? fastConfigureMethod;
}

enum _WindowsTunSetupKind { full, fastNativeApi, fastNetsh, routeOnly }

enum _WindowsTunFastConfigureMethod {
  nativeApi('native_configure'),
  netsh('netsh_configure');

  const _WindowsTunFastConfigureMethod(this.timingLabel);

  final String timingLabel;
}

class _WindowsTunRoute {
  const _WindowsTunRoute({
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

class _WindowsHostRoute {
  const _WindowsHostRoute({
    required this.destinationPrefix,
    required this.interfaceAlias,
    required this.interfaceIndex,
    required this.nextHop,
    this.removalTool = _WindowsRouteRemovalTool.powerShell,
    this.removeWhenUnused = true,
  });

  final String destinationPrefix;
  final String interfaceAlias;
  final int interfaceIndex;
  final String nextHop;
  final _WindowsRouteRemovalTool removalTool;
  final bool removeWhenUnused;
}

enum _WindowsRouteRemovalTool { powerShell, routeExe }

class _Ipv4DefaultRoute {
  const _Ipv4DefaultRoute({
    required this.gateway,
    required this.interfaceAddress,
    required this.metric,
  });

  final String gateway;
  final String interfaceAddress;
  final int metric;
}

class _RouteExeIpv4Destination {
  const _RouteExeIpv4Destination({required this.address, required this.mask});

  final String address;
  final String mask;
}

class _NetshIpv4Interface {
  const _NetshIpv4Interface({
    required this.index,
    required this.name,
    required this.status,
  });

  final int index;
  final String name;
  final String status;
}

const int _tokenQuery = 0x0008;
const int _tokenElevation = 20;
const int _th32csSnapProcess = 0x00000002;
const int _invalidHandleValue = -1;
const int _processQueryLimitedInformation = 0x1000;
const int _processTerminate = 0x0001;
const int _synchronize = 0x00100000;
const int _maxWindowsPathBufferChars = 32768;

final class _ProcessEntry32W extends Struct {
  @Uint32()
  external int dwSize;

  @Uint32()
  external int cntUsage;

  @Uint32()
  external int th32ProcessID;

  @IntPtr()
  external int th32DefaultHeapID;

  @Uint32()
  external int th32ModuleID;

  @Uint32()
  external int cntThreads;

  @Uint32()
  external int th32ParentProcessID;

  @Int32()
  external int pcPriClassBase;

  @Uint32()
  external int dwFlags;

  @Array(260)
  external Array<Uint16> szExeFile;
}

typedef _GetCurrentProcessNative = IntPtr Function();
typedef _GetCurrentProcessDart = int Function();

typedef _OpenProcessTokenNative =
    Int32 Function(IntPtr processHandle, Uint32 desiredAccess, Pointer<IntPtr>);
typedef _OpenProcessTokenDart =
    int Function(int processHandle, int desiredAccess, Pointer<IntPtr>);

typedef _GetTokenInformationNative =
    Int32 Function(
      IntPtr tokenHandle,
      Int32 tokenInformationClass,
      Pointer<Void> tokenInformation,
      Uint32 tokenInformationLength,
      Pointer<Uint32> returnLength,
    );
typedef _GetTokenInformationDart =
    int Function(
      int tokenHandle,
      int tokenInformationClass,
      Pointer<Void> tokenInformation,
      int tokenInformationLength,
      Pointer<Uint32> returnLength,
    );

typedef _CloseHandleNative = Int32 Function(IntPtr handle);
typedef _CloseHandleDart = int Function(int handle);

typedef _CreateToolhelp32SnapshotNative =
    IntPtr Function(Uint32 flags, Uint32 processId);
typedef _CreateToolhelp32SnapshotDart = int Function(int flags, int processId);

typedef _Process32Native =
    Int32 Function(IntPtr snapshot, Pointer<_ProcessEntry32W> entry);
typedef _Process32Dart =
    int Function(int snapshot, Pointer<_ProcessEntry32W> entry);

typedef _OpenProcessNative =
    IntPtr Function(
      Uint32 desiredAccess,
      Int32 inheritHandle,
      Uint32 processId,
    );
typedef _OpenProcessDart =
    int Function(int desiredAccess, int inheritHandle, int processId);

typedef _QueryFullProcessImageNameNative =
    Int32 Function(
      IntPtr process,
      Uint32 flags,
      Pointer<Uint16> exeName,
      Pointer<Uint32> size,
    );
typedef _QueryFullProcessImageNameDart =
    int Function(
      int process,
      int flags,
      Pointer<Uint16> exeName,
      Pointer<Uint32> size,
    );

typedef _TerminateProcessNative =
    Int32 Function(IntPtr process, Uint32 exitCode);
typedef _TerminateProcessDart = int Function(int process, int exitCode);

typedef _WaitForSingleObjectNative =
    Uint32 Function(IntPtr handle, Uint32 milliseconds);
typedef _WaitForSingleObjectDart = int Function(int handle, int milliseconds);
