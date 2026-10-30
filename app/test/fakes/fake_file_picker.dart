import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// A picked file of [size] bytes; [size] null means the platform could not tell.
final class FakePickedFile extends PlatformFile {
  FakePickedFile(this.name, this.size);

  @override
  final String name;
  final int? size;

  @override
  Uri get uri => Uri.file('/videos/$name');

  @override
  get xFile => throw UnimplementedError();

  @override
  int? lengthSync() => size;

  @override
  Future<int?> length() async => size;

  @override
  Future<Uint8List> readAsBytes() async => Uint8List(size ?? 0);

  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(Uint8List(size ?? 0));
}

/// Answers every pick with [files]. Install with `FilePickerPlatform.instance = ...`.
class FakeFilePicker extends FilePickerPlatform {
  FakeFilePicker(this.files);

  final List<PlatformFile> files;

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => files;
}
