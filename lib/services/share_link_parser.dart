import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../models/vpn_profile.dart';

class ShareLinkParser {
  ShareLinkParser() : _native = _NativeShareLinkParser.create();

  final _NativeShareLinkParser _native;

  ParsedVpnProfile parse(String rawInput) => _native.parse(rawInput);

  List<ParsedVpnProfile> parseAll(String rawInput) =>
      _native.parseAll(rawInput);

  String? tryDecodeSubscriptionBase64(String rawInput) =>
      _native.tryDecodeSubscriptionBase64(rawInput);

  ParsedVpnProfile? tryParse(String rawInput) {
    try {
      return parse(rawInput);
    } on FormatException {
      return null;
    }
  }
}

typedef _NativeParseShareLink =
    ffi.Pointer<Utf8> Function(
      ffi.Pointer<Utf8> rawInput,
      ffi.Pointer<ffi.Pointer<Utf8>> errorMessage,
    );
typedef _NativeParseShareLinkDart =
    ffi.Pointer<Utf8> Function(
      ffi.Pointer<Utf8> rawInput,
      ffi.Pointer<ffi.Pointer<Utf8>> errorMessage,
    );
typedef _NativeParseShareLinks =
    ffi.Pointer<Utf8> Function(
      ffi.Pointer<Utf8> rawInput,
      ffi.Pointer<ffi.Pointer<Utf8>> errorMessage,
    );
typedef _NativeParseShareLinksDart =
    ffi.Pointer<Utf8> Function(
      ffi.Pointer<Utf8> rawInput,
      ffi.Pointer<ffi.Pointer<Utf8>> errorMessage,
    );
typedef _NativeTryDecodeSubscriptionBase64 =
    ffi.Pointer<Utf8> Function(
      ffi.Pointer<Utf8> rawInput,
      ffi.Pointer<ffi.Pointer<Utf8>> errorMessage,
    );
typedef _NativeTryDecodeSubscriptionBase64Dart =
    ffi.Pointer<Utf8> Function(
      ffi.Pointer<Utf8> rawInput,
      ffi.Pointer<ffi.Pointer<Utf8>> errorMessage,
    );
typedef _NativeFreeString = ffi.Void Function(ffi.Pointer<Utf8> value);
typedef _NativeFreeStringDart = void Function(ffi.Pointer<Utf8> value);

class _NativeShareLinkParser {
  _NativeShareLinkParser._(
    this._parseShareLink,
    this._parseShareLinks,
    this._tryDecodeSubscriptionBase64,
    this._freeString,
  );

  final _NativeParseShareLinkDart _parseShareLink;
  final _NativeParseShareLinksDart _parseShareLinks;
  final _NativeTryDecodeSubscriptionBase64Dart _tryDecodeSubscriptionBase64;
  final _NativeFreeStringDart _freeString;

  static _NativeShareLinkParser create() {
    final library = _openLibrary();
    return _NativeShareLinkParser._(
      library.lookupFunction<_NativeParseShareLink, _NativeParseShareLinkDart>(
        'entropy_parse_share_link',
      ),
      library
          .lookupFunction<_NativeParseShareLinks, _NativeParseShareLinksDart>(
            'entropy_parse_share_links',
          ),
      library.lookupFunction<
        _NativeTryDecodeSubscriptionBase64,
        _NativeTryDecodeSubscriptionBase64Dart
      >('entropy_try_decode_subscription_base64'),
      library.lookupFunction<_NativeFreeString, _NativeFreeStringDart>(
        'entropy_free_string',
      ),
    );
  }

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
    throw UnsupportedError('Native share link parser is unavailable.');
  }

  ParsedVpnProfile parse(String rawInput) {
    final input = rawInput.toNativeUtf8();
    final errorPointer = calloc<ffi.Pointer<Utf8>>();
    ffi.Pointer<Utf8> resultPointer = ffi.nullptr;
    try {
      resultPointer = _parseShareLink(input, errorPointer);
      if (resultPointer == ffi.nullptr) {
        final messagePointer = errorPointer.value;
        final message = messagePointer == ffi.nullptr
            ? 'Unsupported link format.'
            : messagePointer.toDartString();
        if (messagePointer != ffi.nullptr) {
          _freeString(messagePointer);
        }
        throw FormatException(message);
      }

      final decoded = jsonDecode(resultPointer.toDartString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Native parser returned invalid JSON.');
      }
      return ParsedVpnProfile.fromJson(decoded);
    } finally {
      calloc.free(input);
      calloc.free(errorPointer);
      if (resultPointer != ffi.nullptr) {
        _freeString(resultPointer);
      }
    }
  }

  List<ParsedVpnProfile> parseAll(String rawInput) {
    final input = rawInput.toNativeUtf8();
    final errorPointer = calloc<ffi.Pointer<Utf8>>();
    ffi.Pointer<Utf8> resultPointer = ffi.nullptr;
    try {
      resultPointer = _parseShareLinks(input, errorPointer);
      if (resultPointer == ffi.nullptr) {
        final messagePointer = errorPointer.value;
        final message = messagePointer == ffi.nullptr
            ? 'Failed to parse subscription links.'
            : messagePointer.toDartString();
        if (messagePointer != ffi.nullptr) {
          _freeString(messagePointer);
        }
        throw FormatException(message);
      }

      final decoded = jsonDecode(resultPointer.toDartString());
      if (decoded is! List) {
        throw const FormatException('Native parser returned invalid JSON.');
      }
      return decoded
          .whereType<Map>()
          .map(
            (item) => ParsedVpnProfile.fromJson(
              item.map((key, value) => MapEntry(key.toString(), value)),
            ),
          )
          .toList(growable: false);
    } finally {
      calloc.free(input);
      calloc.free(errorPointer);
      if (resultPointer != ffi.nullptr) {
        _freeString(resultPointer);
      }
    }
  }

  String? tryDecodeSubscriptionBase64(String rawInput) {
    final input = rawInput.toNativeUtf8();
    final errorPointer = calloc<ffi.Pointer<Utf8>>();
    ffi.Pointer<Utf8> resultPointer = ffi.nullptr;
    try {
      resultPointer = _tryDecodeSubscriptionBase64(input, errorPointer);
      if (resultPointer == ffi.nullptr) {
        final messagePointer = errorPointer.value;
        if (messagePointer != ffi.nullptr) {
          _freeString(messagePointer);
        }
        return null;
      }
      return resultPointer.toDartString();
    } finally {
      calloc.free(input);
      calloc.free(errorPointer);
      if (resultPointer != ffi.nullptr) {
        _freeString(resultPointer);
      }
    }
  }
}
