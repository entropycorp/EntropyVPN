import 'dart:ffi';

class WindowsProcessInfo {
  const WindowsProcessInfo({
    required this.pid,
    required this.parentPid,
    required this.path,
  });

  final int pid;
  final int parentPid;
  final String? path;
}

class WindowsProcessSnapshotCacheEntry {
  const WindowsProcessSnapshotCacheEntry({
    required this.createdAt,
    required this.processes,
  });

  final DateTime createdAt;
  final List<WindowsProcessInfo> processes;
}

class WindowsRouteInfo {
  const WindowsRouteInfo({
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
  const WindowsTunSetup({
    required this.routes,
    required this.networkChanged,
    this.fastConfigureMethod,
  });

  final List<WindowsTunRoute> routes;
  final bool networkChanged;
  final WindowsTunFastConfigureMethod? fastConfigureMethod;
}

enum WindowsTunSetupKind { full, fastNativeApi, fastNetsh, routeOnly }

enum WindowsTunFastConfigureMethod {
  nativeApi('native_configure'),
  netsh('netsh_configure');

  const WindowsTunFastConfigureMethod(this.timingLabel);

  final String timingLabel;
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
    this.removalTool = WindowsRouteRemovalTool.powerShell,
    this.removeWhenUnused = true,
  });

  final String destinationPrefix;
  final String interfaceAlias;
  final int interfaceIndex;
  final String nextHop;
  final WindowsRouteRemovalTool removalTool;
  final bool removeWhenUnused;
}

enum WindowsRouteRemovalTool { powerShell, routeExe }

class Ipv4DefaultRoute {
  const Ipv4DefaultRoute({
    required this.gateway,
    required this.interfaceAddress,
    required this.metric,
  });

  final String gateway;
  final String interfaceAddress;
  final int metric;
}

class RouteExeIpv4Destination {
  const RouteExeIpv4Destination({required this.address, required this.mask});

  final String address;
  final String mask;
}

class NetshIpv4Interface {
  const NetshIpv4Interface({
    required this.index,
    required this.name,
    required this.status,
  });

  final int index;
  final String name;
  final String status;
}

const int windowsTokenQuery = 0x0008;
const int windowsTokenElevation = 20;
const int windowsTh32csSnapProcess = 0x00000002;
const int windowsInvalidHandleValue = -1;
const int windowsProcessQueryLimitedInformation = 0x1000;
const int windowsProcessTerminate = 0x0001;
const int windowsSynchronize = 0x00100000;
const int windowsGenericRead = 0x80000000;
const int windowsGenericWrite = 0x40000000;
const int windowsOpenExisting = 3;
const int windowsFileAttributeNormal = 0x00000080;
const int windowsPipeReadmodeMessage = 0x00000002;
const int windowsErrorMoreData = 234;
const int maxWindowsPathBufferChars = 32768;

final class ProcessEntry32W extends Struct {
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

typedef WaitNamedPipeWNative =
    Int32 Function(Pointer<Uint16> pipeName, Uint32 timeoutMs);
typedef WaitNamedPipeWDart =
    int Function(Pointer<Uint16> pipeName, int timeoutMs);

typedef CreateFileWNative =
    IntPtr Function(
      Pointer<Uint16> fileName,
      Uint32 desiredAccess,
      Uint32 shareMode,
      Pointer<Void> securityAttributes,
      Uint32 creationDisposition,
      Uint32 flagsAndAttributes,
      IntPtr templateFile,
    );
typedef CreateFileWDart =
    int Function(
      Pointer<Uint16> fileName,
      int desiredAccess,
      int shareMode,
      Pointer<Void> securityAttributes,
      int creationDisposition,
      int flagsAndAttributes,
      int templateFile,
    );

typedef SetNamedPipeHandleStateNative =
    Int32 Function(
      IntPtr pipe,
      Pointer<Uint32> mode,
      Pointer<Uint32> maxCollectionCount,
      Pointer<Uint32> collectDataTimeout,
    );
typedef SetNamedPipeHandleStateDart =
    int Function(
      int pipe,
      Pointer<Uint32> mode,
      Pointer<Uint32> maxCollectionCount,
      Pointer<Uint32> collectDataTimeout,
    );

typedef WriteFileNative =
    Int32 Function(
      IntPtr file,
      Pointer<Void> buffer,
      Uint32 bytesToWrite,
      Pointer<Uint32> bytesWritten,
      Pointer<Void> overlapped,
    );
typedef WriteFileDart =
    int Function(
      int file,
      Pointer<Void> buffer,
      int bytesToWrite,
      Pointer<Uint32> bytesWritten,
      Pointer<Void> overlapped,
    );

typedef ReadFileNative =
    Int32 Function(
      IntPtr file,
      Pointer<Void> buffer,
      Uint32 bytesToRead,
      Pointer<Uint32> bytesRead,
      Pointer<Void> overlapped,
    );
typedef ReadFileDart =
    int Function(
      int file,
      Pointer<Void> buffer,
      int bytesToRead,
      Pointer<Uint32> bytesRead,
      Pointer<Void> overlapped,
    );

typedef FlushFileBuffersNative = Int32 Function(IntPtr file);
typedef FlushFileBuffersDart = int Function(int file);

typedef GetLastErrorNative = Uint32 Function();
typedef GetLastErrorDart = int Function();

typedef CreateToolhelp32SnapshotNative =
    IntPtr Function(Uint32 flags, Uint32 processId);
typedef CreateToolhelp32SnapshotDart = int Function(int flags, int processId);

typedef Process32Native =
    Int32 Function(IntPtr snapshot, Pointer<ProcessEntry32W> entry);
typedef Process32Dart =
    int Function(int snapshot, Pointer<ProcessEntry32W> entry);

typedef OpenProcessNative =
    IntPtr Function(
      Uint32 desiredAccess,
      Int32 inheritHandle,
      Uint32 processId,
    );
typedef OpenProcessDart =
    int Function(int desiredAccess, int inheritHandle, int processId);

typedef QueryFullProcessImageNameNative =
    Int32 Function(
      IntPtr process,
      Uint32 flags,
      Pointer<Uint16> exeName,
      Pointer<Uint32> size,
    );
typedef QueryFullProcessImageNameDart =
    int Function(
      int process,
      int flags,
      Pointer<Uint16> exeName,
      Pointer<Uint32> size,
    );

typedef TerminateProcessNative =
    Int32 Function(IntPtr process, Uint32 exitCode);
typedef TerminateProcessDart = int Function(int process, int exitCode);

typedef WaitForSingleObjectNative =
    Uint32 Function(IntPtr handle, Uint32 milliseconds);
typedef WaitForSingleObjectDart = int Function(int handle, int milliseconds);
