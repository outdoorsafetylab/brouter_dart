// The IOException messages BRouter v1.7.10 throws for a bad rd5 file.
import 'dart:io';

/// An rd5 file that cannot be read: wrong version, too short, or a
/// checksum that does not match.
class DataFileException implements IOException {
  final String message;
  DataFileException(this.message);

  @override
  String toString() => 'DataFileException: $message';
}
