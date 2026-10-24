import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../cancel.dart';
import '../client.dart';
import '../jwt.dart';

/// A file to upload. Build it from bytes, or from a function that opens the
/// data again each time it is sent (a retry after a token refresh sends it
/// twice).
class UploadFile {
  UploadFile.fromBytes(this.filename, List<int> bytes, {this.contentType})
      : length = bytes.length,
        _open = (() => Stream.value(bytes));

  /// ```dart
  /// UploadFile.fromStream('photo.jpg', () => file.openRead(),
  ///     length: await file.length());
  /// ```
  UploadFile.fromStream(this.filename, Stream<List<int>> Function() open,
      {required this.length, this.contentType})
      : _open = open;

  final String filename;
  final int length;

  /// For example `image/jpeg`; the server detects it when null.
  final String? contentType;
  final Stream<List<int>> Function() _open;

  http.MultipartFile toMultipartFile(String field) => http.MultipartFile(
        field,
        _open(),
        length,
        filename: filename,
        contentType: contentType == null ? null : MediaType.parse(contentType!),
      );
}

/// A stored file, as the upload returns it. Set a file field to
/// [filename] to attach it to a record.
class FileMeta {
  const FileMeta(
      {required this.id,
      required this.filename,
      required this.originalName,
      required this.size,
      required this.mimeType});

  factory FileMeta.fromJson(Map<String, dynamic> json) => FileMeta(
        id: json['id'] as String? ?? '',
        filename: json['filename'] as String? ?? '',
        originalName: json['originalName'] as String? ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        mimeType: json['mimeType'] as String? ?? '',
      );

  final String id;
  final String filename;
  final String originalName;
  final int size;
  final String mimeType;
}

/// An access token for a protected file.
class FileToken {
  const FileToken(this.token, this.expiresAt, {this.oneTime = false});

  final String token;

  /// Unix seconds.
  final int expiresAt;

  /// Spent by the first download.
  final bool oneTime;
}

enum ThumbFit { contain, cover, crop }

enum ImageFormat { webp, jpeg, png, auto }

/// Upload, URLs and access tokens.
class Files {
  Files(this._vb);

  final Vaultbase _vb;
  final _tokens = <String, FileToken>{};
  String? _tokenIdentity;

  String _fieldPath(String collection, String recordId, String field) =>
      '/api/v1/files/${Uri.encodeComponent(collection)}/'
      '${Uri.encodeComponent(recordId)}/${Uri.encodeComponent(field)}';

  /// Uploads [files] to a record's file field. The upload only stores
  /// them; set the field to the returned filenames to attach them.
  /// [onProgress] gets the bytes sent and the total.
  Future<List<FileMeta>> upload(
    String collection,
    String recordId,
    String field,
    List<UploadFile> files, {
    void Function(int sent, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final data = await _vb.request(_fieldPath(collection, recordId, field),
        method: 'POST',
        cancelToken: cancelToken,
        onProgress: onProgress,
        multipart: () => (
              fields: const <String, String>{},
              files: [for (final f in files) f.toMultipartFile('file')],
            ));
    final list = data is List ? data : [data];
    return [
      for (final e in list)
        if (e is Map) FileMeta.fromJson(e.cast<String, dynamic>())
    ];
  }

  /// The URL of a stored file. [thumb] is `WxH`, or one side 0 to keep the
  /// aspect ratio (`400x0`). Protected files need [urlWithToken].
  Uri url(String filename,
      {String? thumb, ThumbFit? fit, ImageFormat? format, int? quality}) {
    String? t = thumb;
    if (t != null &&
        fit != null &&
        fit != ThumbFit.contain &&
        !t.contains('_')) {
      t = '${t}_${fit.name}';
    }
    return _vb.buildUrl('/api/v1/files/${Uri.encodeComponent(filename)}', {
      'thumb': t,
      'format': format?.name,
      'quality': quality,
    });
  }

  /// An access token for a protected file, cached until a minute before it
  /// expires (one-time tokens are never cached). The cache is dropped when
  /// the signed-in identity changes.
  Future<FileToken> token(
      String collection, String recordId, String field, String filename) async {
    final identity = _identity();
    if (identity != _tokenIdentity) {
      _tokens.clear();
      _tokenIdentity = identity;
    }
    final key = '$collection:$recordId:$field:$filename';
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final cached = _tokens[key];
    if (cached != null && cached.expiresAt - now > 60) return cached;

    final data = await _vb.request(
        '${_fieldPath(collection, recordId, field)}/${Uri.encodeComponent(filename)}/token',
        method: 'POST') as Map;
    final raw = data['token'] as String;
    final oneTime = data['one_time'] is bool
        ? data['one_time'] as bool
        : decodeJwtPayload(raw)?['uses'] == 1;
    final token =
        FileToken(raw, (data['expires_at'] as num).toInt(), oneTime: oneTime);
    if (!oneTime) _tokens[key] = token;
    return token;
  }

  /// [url] with an access token, for protected files.
  Future<Uri> urlWithToken(
      String collection, String recordId, String field, String filename,
      {String? thumb, ThumbFit? fit, ImageFormat? format, int? quality}) async {
    final t = await token(collection, recordId, field, filename);
    final u =
        url(filename, thumb: thumb, fit: fit, format: format, quality: quality);
    return u.replace(queryParameters: {...u.queryParameters, 'token': t.token});
  }

  /// Deletes one stored file of the field, or all of them when [filename]
  /// is null. The record's field still names the file; update the record to
  /// remove it.
  Future<void> delete(String collection, String recordId, String field,
      [String? filename]) async {
    final path = _fieldPath(collection, recordId, field);
    await _vb.request(
        filename == null ? path : '$path/${Uri.encodeComponent(filename)}',
        method: 'DELETE');
  }

  void clearTokenCache() => _tokens.clear();

  String? _identity() {
    final token = _vb.authStore.token;
    if (token == null || token.isEmpty) return null;
    final c = decodeJwtPayload(token);
    if (c == null) return 'token:$token';
    return '${c['aud'] ?? ''}:${c['collection'] ?? ''}:${c['id'] ?? c['sub'] ?? ''}';
  }
}
