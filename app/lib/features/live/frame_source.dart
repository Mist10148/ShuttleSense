import 'dart:async';
import 'dart:io' show File;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One camera frame as a JPEG, with its size in pixels.
typedef CapturedFrame = ({Uint8List jpeg, int width, int height});

/// The camera could not be opened; [permissionDenied] when the user said no.
class CameraUnavailable implements Exception {
  const CameraUnavailable(this.message, {this.permissionDenied = false});

  final String message;
  final bool permissionDenied;

  @override
  String toString() => message;
}

/// Where live frames come from: the device camera, or a fake in tests.
abstract class FrameSource {
  Future<void> start();

  Future<CapturedFrame> capture();

  Widget preview();

  /// A short name for the UI ("Back camera", "Webcam").
  String get label;

  Future<void> dispose();
}

/// The phone camera (Android/iOS), the browser camera (web) or a webcam (Windows).
///
/// Frames are still captures, so the rate depends on the device: phones and browsers give
/// roughly 5 to 15 per second. The session reports what actually arrives.
class CameraFrameSource implements FrameSource {
  CameraController? _controller;
  ({int width, int height})? _size;
  DeviceOrientation? _sizeOrientation;
  String _label = 'Camera';

  /// Orientation of the last captured still, including 180-degree turns.
  DeviceOrientation? get captureOrientation => _sizeOrientation;

  @override
  String get label => _label;

  @override
  Future<void> start() async {
    final List<CameraDescription> cameras;
    try {
      cameras = await availableCameras();
    } on CameraException catch (e) {
      throw _unavailable(e);
    }
    if (cameras.isEmpty) throw const CameraUnavailable('No camera found on this device');
    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    _label = switch (camera.lensDirection) {
      CameraLensDirection.back => 'Back camera',
      CameraLensDirection.front => 'Front camera',
      CameraLensDirection.external => 'Webcam',
    };
    final controller = CameraController(camera, ResolutionPreset.high, enableAudio: false);
    try {
      await controller.initialize();
    } on CameraException catch (e) {
      await controller.dispose();
      throw _unavailable(e);
    }
    // Phones default to auto flash, which would fire on every still in a dim hall and slow
    // each capture down. Webcams and browsers have no flash control.
    try {
      await controller.setFlashMode(FlashMode.off);
    } on Object {
      // not supported here
    }
    _controller = controller;
  }

  CameraUnavailable _unavailable(CameraException e) {
    final denied = e.code.startsWith('CameraAccessDenied') || e.code == 'cameraPermission';
    return CameraUnavailable(
      denied
          ? 'Camera access was denied. Allow it in the system or browser settings, then retry.'
          : 'Could not open the camera: ${e.description ?? e.code}',
      permissionDenied: denied,
    );
  }

  @override
  Future<CapturedFrame> capture() async {
    final controller = _controller;
    if (controller == null) throw StateError('camera not started');
    final orientation = controller.value.deviceOrientation;
    final file = await controller.takePicture();
    final jpeg = await file.readAsBytes();
    // takePicture writes each still to a temp file; a long session would leave thousands.
    if (!kIsWeb) unawaited(File(file.path).delete().then((_) {}, onError: (_) {}));
    // Decoding every still for its size is costly; measure again only when the device
    // turned, which swaps width and height.
    if (controller.value.deviceOrientation != orientation) {
      throw const CameraUnavailable('Camera orientation changed during capture. Recalibrate.');
    }
    if (_size == null || orientation != _sizeOrientation) {
      _size = await _decodeSize(jpeg);
      _sizeOrientation = orientation;
    }
    final size = _size!;
    return (jpeg: jpeg, width: size.width, height: size.height);
  }

  static Future<({int width, int height})> _decodeSize(Uint8List jpeg) async {
    final codec = await ui.instantiateImageCodec(jpeg);
    final frame = await codec.getNextFrame();
    final size = (width: frame.image.width, height: frame.image.height);
    frame.image.dispose();
    codec.dispose();
    return size;
  }

  @override
  Widget preview() {
    final controller = _controller;
    if (controller == null) return const ColoredBox(color: Colors.black);
    return CameraPreview(controller);
  }

  @override
  Future<void> dispose() async {
    await _controller?.dispose();
    _controller = null;
  }
}

/// Makes the frame source for a live session; tests replace it.
final frameSourceFactoryProvider = Provider<FrameSource Function()>((ref) => CameraFrameSource.new);
