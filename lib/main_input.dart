import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, FileSystemException, Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:qr_code_dart_decoder/qr_code_dart_decoder.dart' as qrd;

import 'l10n/app_strings.dart';
import 'main_constants.dart';
import 'main_helpers.dart';
import 'services/vpn_controller.dart';

class InputPanel extends StatefulWidget {
  const InputPanel({
    super.key,
    required this.controller,
    required this.strings,
    required this.textController,
  });

  final VpnController controller;
  final AppStrings strings;
  final TextEditingController textController;

  @override
  State<InputPanel> createState() => InputPanelState();
}

class InputPanelState extends State<InputPanel> {
  late final FocusNode _inputFocusNode;
  final ImagePicker _imagePicker = ImagePicker();
  final MobileScannerController _imageScannerController =
      MobileScannerController(
        autoStart: false,
        formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
      );
  final qrd.QrCodeDartDecoder _desktopQrDecoder = qrd.QrCodeDartDecoder(
    formats: const <qrd.BarcodeFormat>[qrd.BarcodeFormat.qrCode],
  );

  @override
  void initState() {
    super.initState();
    _inputFocusNode = FocusNode();
    _inputFocusNode.addListener(_handleInputFocusChanged);
  }

  @override
  void dispose() {
    _inputFocusNode
      ..removeListener(_handleInputFocusChanged)
      ..dispose();
    unawaited(_imageScannerController.dispose());
    super.dispose();
  }

  void _handleInputFocusChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _pasteFromClipboard(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    final clipboardText = clipboardData?.text ?? '';

    if (clipboardText.trim().isEmpty) {
      messenger?.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(widget.strings.clipboardEmptyMessage),
        ),
      );
      return;
    }

    widget.textController.value = TextEditingValue(
      text: clipboardText,
      selection: TextSelection.collapsed(offset: clipboardText.length),
    );
    await widget.controller.pasteSourceInput(clipboardText);
  }

  Future<void> _showQrScanPicker(BuildContext context) async {
    if (Platform.isWindows) {
      await _showWindowsQrImportPicker(context);
      return;
    }

    final source = await showModalBottomSheet<QrScanSource>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final strings = widget.strings;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.photo_library_rounded),
                title: Text(strings.qrGalleryAction),
                onTap: () => Navigator.of(context).pop(QrScanSource.gallery),
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera_rounded),
                title: Text(strings.qrCameraAction),
                onTap: () => Navigator.of(context).pop(QrScanSource.camera),
              ),
            ],
          ),
        );
      },
    );

    if (!context.mounted || source == null) {
      return;
    }

    switch (source) {
      case QrScanSource.gallery:
        await _scanQrFromGallery(context);
        break;
      case QrScanSource.camera:
        await _scanQrFromCamera(context);
        break;
      case QrScanSource.clipboardImage:
      case QrScanSource.imageFile:
        break;
    }
  }

  Future<void> _showWindowsQrImportPicker(BuildContext context) async {
    final source = await showDialog<QrScanSource>(
      context: context,
      builder: (context) => _WindowsQrImportDialog(strings: widget.strings),
    );

    if (!context.mounted || source == null) {
      return;
    }

    switch (source) {
      case QrScanSource.clipboardImage:
        await _scanQrFromClipboardImage(context);
        break;
      case QrScanSource.imageFile:
        await _scanQrFromImageFile(context);
        break;
      case QrScanSource.gallery:
      case QrScanSource.camera:
        break;
    }
  }

  Future<void> _scanQrFromGallery(BuildContext context) async {
    try {
      final image = await _imagePicker.pickImage(source: ImageSource.gallery);
      if (!mounted || image == null) {
        return;
      }

      final capture = await _imageScannerController.analyzeImage(
        image.path,
        formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
      );
      if (!mounted || !context.mounted) {
        return;
      }

      final qrText = _firstQrValue(capture);
      if (qrText == null) {
        _showInputSnackBar(context, widget.strings.qrCodeNotFoundMessage);
        return;
      }

      await _importQrText(context, qrText);
    } catch (_) {
      if (mounted && context.mounted) {
        _showInputSnackBar(context, widget.strings.qrScanFailedMessage);
      }
    }
  }

  Future<void> _scanQrFromClipboardImage(BuildContext context) async {
    try {
      final imageBytes = await _clipboardImageBytes();
      if (!mounted || !context.mounted) {
        return;
      }

      if (imageBytes == null || imageBytes.isEmpty) {
        _showInputSnackBar(
          context,
          widget.strings.qrClipboardImageMissingMessage,
        );
        return;
      }

      await _importQrFromDesktopImageBytes(context, imageBytes);
    } catch (_) {
      if (mounted && context.mounted) {
        _showInputSnackBar(context, widget.strings.qrScanFailedMessage);
      }
    }
  }

  Future<void> _scanQrFromImageFile(BuildContext context) async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: qrImageFileExtensions,
        withData: true,
      );
      if (!mounted || !context.mounted || result == null) {
        return;
      }

      final imageBytes = await _selectedImageBytes(result.files.single);
      if (!mounted || !context.mounted) {
        return;
      }

      if (imageBytes == null || imageBytes.isEmpty) {
        _showInputSnackBar(context, widget.strings.qrScanFailedMessage);
        return;
      }

      await _importQrFromDesktopImageBytes(context, imageBytes);
    } catch (_) {
      if (mounted && context.mounted) {
        _showInputSnackBar(context, widget.strings.qrScanFailedMessage);
      }
    }
  }

  Future<void> _scanQrFromCamera(BuildContext context) async {
    final qrText = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        fullscreenDialog: true,
        builder: (context) => _QrCameraScannerPage(strings: widget.strings),
      ),
    );
    if (!mounted || !context.mounted || qrText == null) {
      return;
    }

    await _importQrText(context, qrText);
  }

  Future<void> _importQrFromDesktopImageBytes(
    BuildContext context,
    Uint8List imageBytes,
  ) async {
    final result = await _desktopQrDecoder.decodeFile(imageBytes);
    if (!mounted || !context.mounted) {
      return;
    }

    final qrText = result?.text.trim();
    if (qrText == null || qrText.isEmpty) {
      _showInputSnackBar(context, widget.strings.qrCodeNotFoundMessage);
      return;
    }

    await _importQrText(context, qrText);
  }

  Future<void> _importQrText(BuildContext context, String qrText) async {
    widget.textController.value = TextEditingValue(
      text: qrText,
      selection: TextSelection.collapsed(offset: qrText.length),
    );
    _inputFocusNode.unfocus();
    await widget.controller.pasteSourceInput(
      qrText,
      successTarget: AddSourceSuccessTarget.qr,
    );
  }

  Future<Uint8List?> _clipboardImageBytes() async {
    final imageBytes = await Pasteboard.image;
    if (imageBytes != null && imageBytes.isNotEmpty) {
      return imageBytes;
    }

    final files = await Pasteboard.files();
    for (final filePath in files) {
      final path = filePath.trim();
      if (path.isEmpty || !_isQrImageFilePath(path)) {
        continue;
      }

      try {
        final bytes = await File(path).readAsBytes();
        if (bytes.isNotEmpty) {
          return bytes;
        }
      } on FileSystemException {
        continue;
      }
    }

    return null;
  }

  Future<Uint8List?> _selectedImageBytes(PlatformFile file) async {
    final bytes = file.bytes;
    if (bytes != null) {
      return bytes;
    }

    final path = file.path?.trim();
    if (path == null || path.isEmpty) {
      return null;
    }
    return File(path).readAsBytes();
  }

  Future<void> _importFromJson(BuildContext context) async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['json'],
        withData: true,
      );
      if (!mounted || !context.mounted || result == null) {
        return;
      }

      final importedInput = _jsonImportInput(result.files.single);
      if (importedInput == null || importedInput.trim().isEmpty) {
        _showInputSnackBar(context, widget.strings.jsonImportFailedMessage);
        return;
      }

      widget.textController.value = TextEditingValue(
        text: importedInput,
        selection: TextSelection.collapsed(offset: importedInput.length),
      );
      _inputFocusNode.unfocus();
      widget.controller.setRawInput(importedInput);
      await widget.controller.addSource(
        successTarget: AddSourceSuccessTarget.json,
      );
    } on PlatformException {
      if (mounted && context.mounted) {
        _showInputSnackBar(context, widget.strings.jsonImportFailedMessage);
      }
    } on FormatException {
      if (mounted && context.mounted) {
        _showInputSnackBar(context, widget.strings.jsonImportFailedMessage);
      }
    }
  }

  String? _jsonImportInput(PlatformFile file) {
    final path = file.path?.trim();
    if (path != null && path.isNotEmpty) {
      return path;
    }

    final bytes = file.bytes;
    if (bytes == null) {
      return null;
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  void _showInputSnackBar(BuildContext context, String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(behavior: SnackBarBehavior.floating, content: Text(message)),
    );
  }

  void _clearInput() {
    widget.textController.clear();
    widget.controller.setRawInput('');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final controller = widget.controller;
    final strings = widget.strings;
    final textController = widget.textController;
    final showRecentSuccess =
        controller.didAddSourceRecently && !controller.isAddingSource;
    final showAddLoading =
        controller.isAddingSource &&
        controller.addingSourceTarget == AddSourceSuccessTarget.add;
    final showPasteLoading =
        controller.isAddingSource &&
        controller.addingSourceTarget == AddSourceSuccessTarget.paste;
    final showQrLoading =
        controller.isAddingSource &&
        controller.addingSourceTarget == AddSourceSuccessTarget.qr;
    final showJsonLoading =
        controller.isAddingSource &&
        controller.addingSourceTarget == AddSourceSuccessTarget.json;
    final showAddSuccess =
        showRecentSuccess &&
        controller.recentAddSuccessTarget == AddSourceSuccessTarget.add;
    final showPasteSuccess =
        showRecentSuccess &&
        controller.recentAddSuccessTarget == AddSourceSuccessTarget.paste;
    final showQrSuccess =
        showRecentSuccess &&
        controller.recentAddSuccessTarget == AddSourceSuccessTarget.qr;
    final showJsonSuccess =
        showRecentSuccess &&
        controller.recentAddSuccessTarget == AddSourceSuccessTarget.json;
    final actionBackground = showAddSuccess
        ? connectedColor
        : Colors.transparent;
    final actionForeground = showAddSuccess
        ? Colors.white
        : scheme.onSecondaryContainer;
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 620;
        final compact = constraints.maxWidth < 520;
        final isDesktop =
            theme.platform == TargetPlatform.windows ||
            theme.platform == TargetPlatform.macOS ||
            theme.platform == TargetPlatform.linux;
        final titleTopPadding = isDesktop && !compact
            ? 0.0
            : compact
            ? 6.0
            : 12.0;
        final titleInputGap = isDesktop && !compact ? 12.0 : 18.0;
        final inputMinLines = isDesktop && !compact ? 5 : 4;
        final inputMaxLines = isDesktop && !compact ? 7 : 6;
        const actionButtonSize = 36.0;
        const utilityActionSize = 32.0;
        final actionGap = compact ? 5.0 : 7.0;
        final utilityActionGap = compact ? 1.0 : 2.0;
        final titleTrailingInset = isWide ? actionButtonSize + actionGap : 0.0;
        ButtonStyle fullWidthImportStyle({required bool success}) =>
            OutlinedButton.styleFrom(
              backgroundColor: success
                  ? connectedColor
                  : const Color(0xFF4A4A4A),
              disabledBackgroundColor: success
                  ? connectedColor
                  : const Color(0xFF2F2F2F),
              foregroundColor: Colors.white,
              disabledForegroundColor: success ? Colors.white : Colors.white54,
              minimumSize: const Size(0, 46),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              side: BorderSide.none,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            );
        final jsonImportAction = SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: controller.canAddSource
                ? () => _importFromJson(context)
                : null,
            icon: _InputActionIcon(
              loading: showJsonLoading,
              success: showJsonSuccess,
              icon: Icons.data_object_rounded,
              loadingColor: Colors.white,
            ),
            label: Text(strings.importFromJsonAction),
            style: fullWidthImportStyle(success: showJsonSuccess),
          ),
        );
        final qrAction = Platform.isAndroid || Platform.isWindows
            ? SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: controller.canAddSource
                      ? () => _showQrScanPicker(context)
                      : null,
                  icon: _InputActionIcon(
                    loading: showQrLoading,
                    success: showQrSuccess,
                    icon: Icons.qr_code_scanner_rounded,
                    loadingColor: scheme.onSurface,
                  ),
                  label: Text(strings.scanQrAction),
                  style: fullWidthImportStyle(success: showQrSuccess),
                ),
              )
            : null;
        final action = _InputActionTooltip(
          message: strings.addSourceAction,
          child: IconButton.filled(
            onPressed: controller.canAddSource ? controller.addSource : null,
            iconSize: 21,
            style: IconButton.styleFrom(
              fixedSize: const Size.square(actionButtonSize),
              minimumSize: const Size.square(actionButtonSize),
              maximumSize: const Size.square(actionButtonSize),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              backgroundColor: actionBackground,
              foregroundColor: actionForeground,
              disabledBackgroundColor: Colors.transparent,
              disabledForegroundColor: scheme.onSurfaceVariant.withValues(
                alpha: 0.42,
              ),
              hoverColor: showAddSuccess
                  ? connectedColor.withValues(alpha: 0.82)
                  : scheme.onSurface.withValues(alpha: 0.12),
              highlightColor: showAddSuccess
                  ? connectedColor.withValues(alpha: 0.9)
                  : scheme.onSurface.withValues(alpha: 0.16),
              shape: const CircleBorder(),
            ),
            icon: _InputActionIcon(
              loading: showAddLoading,
              success: showAddSuccess,
              icon: Icons.add_rounded,
              loadingSize: 18,
              strokeWidth: 2.4,
              loadingColor: actionForeground,
              iconColor: actionForeground,
            ),
          ),
        );
        ButtonStyle inputActionStyle({bool success = false}) =>
            IconButton.styleFrom(
              fixedSize: const Size.square(utilityActionSize),
              minimumSize: const Size.square(utilityActionSize),
              maximumSize: const Size.square(utilityActionSize),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              foregroundColor: success ? Colors.white : scheme.onSurface,
              disabledForegroundColor: scheme.onSurfaceVariant.withValues(
                alpha: 0.36,
              ),
              backgroundColor: success ? connectedColor : Colors.transparent,
              disabledBackgroundColor: Colors.transparent,
              focusColor: Colors.transparent,
              hoverColor: success
                  ? connectedColor.withValues(alpha: 0.82)
                  : scheme.onSurface.withValues(alpha: 0.12),
              highlightColor: success
                  ? connectedColor.withValues(alpha: 0.9)
                  : scheme.onSurface.withValues(alpha: 0.16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(11),
              ),
            );
        final pasteAction = _InputActionTooltip(
          message: strings.pasteFromClipboardAction,
          child: IconButton(
            onPressed: controller.canAddSource
                ? () => _pasteFromClipboard(context)
                : null,
            icon: _InputActionIcon(
              loading: showPasteLoading,
              success: showPasteSuccess,
              icon: Icons.content_paste_rounded,
              loadingSize: 16,
              loadingColor: scheme.onSurface,
            ),
            iconSize: 20,
            style: inputActionStyle(success: showPasteSuccess),
          ),
        );
        final clearAction = _InputActionTooltip(
          message: strings.clearInputAction,
          child: IconButton(
            onPressed: controller.canAddSource ? _clearInput : null,
            icon: const Icon(Icons.backspace_outlined),
            iconSize: 20,
            style: inputActionStyle(),
          ),
        );

        return Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 6 : 24,
            titleTopPadding,
            compact ? 6 : 24,
            compact ? 6 : 12,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (!compact) ...<Widget>[
                Padding(
                  padding: EdgeInsets.only(right: titleTrailingInset),
                  child: Text(
                    strings.inputLabel,
                    textAlign: isWide ? TextAlign.center : TextAlign.start,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                SizedBox(height: titleInputGap),
              ],
              TextFieldTapRegion(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: textController,
                        focusNode: _inputFocusNode,
                        minLines: inputMinLines,
                        maxLines: inputMaxLines,
                        enabled: controller.canAddSource,
                        onTapOutside: (_) => _inputFocusNode.unfocus(),
                        style: monoStyle(
                          theme,
                          color: scheme.onSurface,
                          fontSize: 13.1,
                          weight: FontWeight.w500,
                        ),
                        decoration: InputDecoration(
                          hintText: _inputFocusNode.hasFocus
                              ? null
                              : strings.inputHint,
                          contentPadding: const EdgeInsets.fromLTRB(
                            20,
                            18,
                            20,
                            18,
                          ),
                        ),
                      ),
                    ),
                    SizedBox(width: actionGap),
                    SizedBox(
                      width: actionButtonSize,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          pasteAction,
                          SizedBox(height: utilityActionGap),
                          action,
                          SizedBox(height: utilityActionGap),
                          clearAction,
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (controller.previewError != null) ...<Widget>[
                const SizedBox(height: 14),
                MessageStrip(
                  containerColor: scheme.errorContainer,
                  foregroundColor: scheme.onErrorContainer,
                  icon: Icons.error_outline_rounded,
                  text: controller.previewError!,
                ),
              ],
              const SizedBox(height: 14),
              jsonImportAction,
              if (qrAction != null) ...<Widget>[
                const SizedBox(height: 14),
                qrAction,
              ],
            ],
          ),
        );
      },
    );
  }
}

class _InputActionIcon extends StatelessWidget {
  const _InputActionIcon({
    required this.loading,
    required this.success,
    required this.icon,
    this.loadingSize = 17,
    this.strokeWidth = 2.2,
    this.loadingColor,
    this.iconColor,
  });

  final bool loading;
  final bool success;
  final IconData icon;
  final double loadingSize;
  final double strokeWidth;
  final Color? loadingColor;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(scale: animation, child: child),
      ),
      child: loading
          ? SizedBox(
              key: ValueKey<String>('loading-${icon.codePoint}'),
              width: loadingSize,
              height: loadingSize,
              child: CircularProgressIndicator(
                strokeWidth: strokeWidth,
                color: loadingColor,
              ),
            )
          : Icon(
              success ? Icons.check_rounded : icon,
              key: ValueKey<String>('icon-${icon.codePoint}-$success'),
              color: iconColor,
            ),
    );
  }
}

class _PasteQrImageIntent extends Intent {
  const _PasteQrImageIntent();
}

class _WindowsQrImportDialog extends StatelessWidget {
  const _WindowsQrImportDialog({required this.strings});

  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return FocusableActionDetector(
      autofocus: true,
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyV, control: true):
            _PasteQrImageIntent(),
      },
      actions: <Type, Action<Intent>>{
        _PasteQrImageIntent: CallbackAction<_PasteQrImageIntent>(
          onInvoke: (_) {
            Navigator.of(context).pop(QrScanSource.clipboardImage);
            return null;
          },
        ),
      },
      child: AlertDialog(
        title: Text(strings.scanQrAction),
        contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 10),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _WindowsQrImportTile(
                icon: Icons.content_paste_go_rounded,
                title: strings.qrPasteImageAction,
                onTap: () =>
                    Navigator.of(context).pop(QrScanSource.clipboardImage),
              ),
              Divider(color: scheme.outlineVariant.withValues(alpha: 0.42)),
              _WindowsQrImportTile(
                icon: Icons.image_search_rounded,
                title: strings.qrBrowseImageAction,
                onTap: () => Navigator.of(context).pop(QrScanSource.imageFile),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
        ],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titleTextStyle: theme.textTheme.titleLarge?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _WindowsQrImportTile extends StatelessWidget {
  const _WindowsQrImportTile({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(icon),
      title: Text(title),
      onTap: onTap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
  }
}

class _QrCameraScannerPage extends StatefulWidget {
  const _QrCameraScannerPage({required this.strings});

  final AppStrings strings;

  @override
  State<_QrCameraScannerPage> createState() => _QrCameraScannerPageState();
}

class _QrCameraScannerPageState extends State<_QrCameraScannerPage> {
  late final MobileScannerController _scannerController;
  bool _handledDetection = false;

  @override
  void initState() {
    super.initState();
    _scannerController = MobileScannerController(
      cameraResolution: const Size(1920, 1080),
      detectionSpeed: DetectionSpeed.noDuplicates,
      lensType: CameraLensType.normal,
      formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
      autoZoom: true,
    );
  }

  @override
  void dispose() {
    unawaited(_scannerController.dispose());
    super.dispose();
  }

  void _handleDetect(BarcodeCapture capture) {
    if (_handledDetection) {
      return;
    }

    final qrText = _firstQrValue(capture);
    if (qrText == null) {
      return;
    }

    _handledDetection = true;
    unawaited(_scannerController.stop());
    Navigator.of(context).pop(qrText);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final scanGuide = _scanGuideFor(constraints.biggest);
                return MobileScanner(
                  controller: _scannerController,
                  fit: BoxFit.cover,
                  tapToFocus: true,
                  onDetect: _handleDetect,
                  placeholderBuilder: (context) => const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                  errorBuilder: (context, error) {
                    final message = error.errorDetails?.message;
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          message?.isNotEmpty == true
                              ? message!
                              : widget.strings.cameraUnavailableMessage,
                          textAlign: TextAlign.center,
                          style: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.copyWith(color: Colors.white),
                        ),
                      ),
                    );
                  },
                  overlayBuilder: (context, _) {
                    return ScanWindowOverlay(
                      controller: _scannerController,
                      scanWindow: scanGuide,
                      borderColor: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      borderWidth: 3,
                      color: Colors.black.withValues(alpha: 0.56),
                    );
                  },
                );
              },
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                child: Row(
                  children: <Widget>[
                    _ScannerIconButton(
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      icon: Icons.close_rounded,
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const Spacer(),
                    ValueListenableBuilder<MobileScannerState>(
                      valueListenable: _scannerController,
                      builder: (context, value, _) {
                        if (value.torchState == TorchState.unavailable) {
                          return const SizedBox.shrink();
                        }
                        final torchOn = value.torchState == TorchState.on;
                        return _ScannerIconButton(
                          tooltip: torchOn
                              ? widget.strings.turnFlashOffAction
                              : widget.strings.turnFlashOnAction,
                          icon: torchOn
                              ? Icons.flash_on_rounded
                              : Icons.flash_off_rounded,
                          onPressed: () =>
                              unawaited(_scannerController.toggleTorch()),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: <Color>[
                      Colors.black.withValues(alpha: 0.6),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: const SizedBox(height: 120),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Center(
                  child: Text(
                    widget.strings.scanQrAction,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Colors.white.withValues(alpha: 0.88),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Rect _scanGuideFor(Size size) {
    final shortestSide = size.shortestSide;
    final windowSize = (shortestSide * 0.84).clamp(260.0, 460.0).toDouble();
    return Rect.fromCenter(
      center: size.center(Offset.zero),
      width: windowSize,
      height: windowSize,
    );
  }
}

class _ScannerIconButton extends StatelessWidget {
  const _ScannerIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton.filledTonal(
        onPressed: onPressed,
        icon: Icon(icon),
        style: IconButton.styleFrom(
          backgroundColor: Colors.black.withValues(alpha: 0.48),
          foregroundColor: Colors.white,
          fixedSize: const Size.square(44),
          minimumSize: const Size.square(44),
          maximumSize: const Size.square(44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }
}

String? _firstQrValue(BarcodeCapture? capture) {
  if (capture == null) {
    return null;
  }

  for (final barcode in capture.barcodes) {
    final rawValue = barcode.rawValue?.trim();
    if (rawValue != null && rawValue.isNotEmpty) {
      return rawValue;
    }

    final displayValue = barcode.displayValue?.trim();
    if (displayValue != null && displayValue.isNotEmpty) {
      return displayValue;
    }
  }

  return null;
}

bool _isQrImageFilePath(String path) {
  final dotIndex = path.lastIndexOf('.');
  if (dotIndex == -1 || dotIndex == path.length - 1) {
    return false;
  }

  final extension = path.substring(dotIndex + 1).toLowerCase();
  return qrImageFileExtensions.contains(extension);
}

class _InputActionTooltip extends StatelessWidget {
  const _InputActionTooltip({required this.message, required this.child});

  static const double _gap = 8;

  final String message;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: message,
      positionDelegate: _positionBesideAction,
      child: child,
    );
  }

  static Offset _positionBesideAction(TooltipPositionContext context) {
    final targetRight = context.target.dx + context.targetSize.width / 2;
    final maxDy = (context.overlaySize.height - context.tooltipSize.height)
        .clamp(0.0, double.infinity)
        .toDouble();

    return Offset(
      targetRight + _gap,
      (context.target.dy - context.tooltipSize.height / 2)
          .clamp(0.0, maxDy)
          .toDouble(),
    );
  }
}

class MessageStrip extends StatelessWidget {
  const MessageStrip({
    super.key,
    required this.containerColor,
    required this.foregroundColor,
    required this.icon,
    required this.text,
  });

  final Color containerColor;
  final Color foregroundColor;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: containerColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 18, color: foregroundColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: foregroundColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
