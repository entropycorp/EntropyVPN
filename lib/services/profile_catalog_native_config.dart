part of 'profile_catalog_service.dart';

ParsedVpnProfile? _tryParseCoreConfig(
  String text, {
  String? sourceLabel,
  String? fallbackLabel,
  String? configDirectory,
}) {
  return _NativeCoreConfigParser.instance.tryParse(
    text,
    sourceLabel: sourceLabel,
    fallbackLabel: fallbackLabel,
    configDirectory: configDirectory,
  );
}

typedef _NativeParseCoreConfig =
    ffi.Pointer<Utf8> Function(
      ffi.Pointer<Utf8> rawInput,
      ffi.Pointer<Utf8> optionsJson,
      ffi.Pointer<ffi.Pointer<Utf8>> errorMessage,
    );
typedef _NativeParseCoreConfigDart =
    ffi.Pointer<Utf8> Function(
      ffi.Pointer<Utf8> rawInput,
      ffi.Pointer<Utf8> optionsJson,
      ffi.Pointer<ffi.Pointer<Utf8>> errorMessage,
    );
typedef _NativeFreeString = ffi.Void Function(ffi.Pointer<Utf8> value);
typedef _NativeFreeStringDart = void Function(ffi.Pointer<Utf8> value);

class _NativeCoreConfigParser {
  _NativeCoreConfigParser._(this._parseCoreConfig, this._freeString);

  static final _NativeCoreConfigParser instance = _NativeCoreConfigParser._(
    _openLibrary()
        .lookupFunction<_NativeParseCoreConfig, _NativeParseCoreConfigDart>(
          'entropy_parse_core_config',
        ),
    _openLibrary().lookupFunction<_NativeFreeString, _NativeFreeStringDart>(
      'entropy_free_string',
    ),
  );

  final _NativeParseCoreConfigDart _parseCoreConfig;
  final _NativeFreeStringDart _freeString;

  static ffi.DynamicLibrary _openLibrary() {
    if (Platform.isAndroid) {
      return ffi.DynamicLibrary.open('libentropy_vpn_native.so');
    }
    if (Platform.isWindows) {
      return ffi.DynamicLibrary.open('entropy_vpn_native.dll');
    }
    if (Platform.isLinux) {
      return ffi.DynamicLibrary.open('libentropy_vpn_native.so');
    }
    if (Platform.isMacOS) {
      return ffi.DynamicLibrary.open('libentropy_vpn_native.dylib');
    }
    throw UnsupportedError('Native core config parser is unavailable.');
  }

  ParsedVpnProfile? tryParse(
    String text, {
    String? sourceLabel,
    String? fallbackLabel,
    String? configDirectory,
  }) {
    final input = text.toNativeUtf8();
    final options = jsonEncode(<String, Object?>{
      'sourceLabel': sourceLabel,
      'fallbackLabel': fallbackLabel,
      'configDirectory': configDirectory,
    }).toNativeUtf8();
    final errorPointer = calloc<ffi.Pointer<Utf8>>();
    ffi.Pointer<Utf8> resultPointer = ffi.nullptr;
    try {
      resultPointer = _parseCoreConfig(input, options, errorPointer);
      if (resultPointer == ffi.nullptr) {
        final messagePointer = errorPointer.value;
        if (messagePointer != ffi.nullptr) {
          _freeString(messagePointer);
        }
        return null;
      }

      final decoded = jsonDecode(resultPointer.toDartString());
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      return ParsedVpnProfile.fromJson(decoded);
    } finally {
      calloc.free(input);
      calloc.free(options);
      calloc.free(errorPointer);
      if (resultPointer != ffi.nullptr) {
        _freeString(resultPointer);
      }
    }
  }
}
