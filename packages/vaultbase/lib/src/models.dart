import 'dart:convert';

/// A record as the server returns it, with typed getters over the JSON map.
class RecordModel {
  RecordModel(Map<String, dynamic> data) : data = Map.unmodifiable(data);

  factory RecordModel.fromJson(Map<String, dynamic> json) => RecordModel(json);

  final Map<String, dynamic> data;

  String get id => data['id'] as String? ?? '';

  /// Unix seconds.
  int get created => (data['created'] as num?)?.toInt() ?? 0;

  /// Unix seconds.
  int get updated => (data['updated'] as num?)?.toInt() ?? 0;

  DateTime get createdAt => _fromSeconds(created);

  DateTime get updatedAt => _fromSeconds(updated);

  dynamic operator [](String field) => data[field];

  String getString(String field, [String fallback = '']) {
    final v = data[field];
    return v == null ? fallback : v.toString();
  }

  int getInt(String field, [int fallback = 0]) => switch (data[field]) {
        num v => v.toInt(),
        bool v => v ? 1 : 0,
        String v => int.tryParse(v) ?? fallback,
        _ => fallback,
      };

  double getDouble(String field, [double fallback = 0]) =>
      switch (data[field]) {
        num v => v.toDouble(),
        String v => double.tryParse(v) ?? fallback,
        _ => fallback,
      };

  /// Booleans, and the 0 / 1 integers auth fields use.
  bool getBool(String field, [bool fallback = false]) => switch (data[field]) {
        bool v => v,
        num v => v != 0,
        String v => v == 'true' || v == '1',
        _ => fallback,
      };

  List<T> getList<T>(String field) {
    final v = data[field];
    return v is List ? v.whereType<T>().toList() : <T>[];
  }

  /// A date field (Unix seconds) as a UTC [DateTime], or null when unset.
  DateTime? getDate(String field) {
    final v = data[field];
    return v is num ? _fromSeconds(v.toInt()) : null;
  }

  /// A single relation expanded with `expand`.
  RecordModel? expandOne(String field) {
    final v = _expand()[field];
    if (v is Map) return RecordModel(v.cast<String, dynamic>());
    if (v is List && v.isNotEmpty && v.first is Map) {
      return RecordModel((v.first as Map).cast<String, dynamic>());
    }
    return null;
  }

  /// A multiple relation expanded with `expand`.
  List<RecordModel> expandMany(String field) {
    final v = _expand()[field];
    if (v is List) {
      return [
        for (final e in v)
          if (e is Map) RecordModel(e.cast<String, dynamic>())
      ];
    }
    if (v is Map) return [RecordModel(v.cast<String, dynamic>())];
    return const [];
  }

  Map<String, dynamic> _expand() =>
      (data['expand'] as Map?)?.cast<String, dynamic>() ?? const {};

  Map<String, dynamic> toJson() => data;

  @override
  String toString() => 'RecordModel(${jsonEncode(data)})';

  static DateTime _fromSeconds(int s) =>
      DateTime.fromMillisecondsSinceEpoch(s * 1000, isUtc: true);
}

/// One page of a list.
class ListResult<T> {
  const ListResult({
    required this.items,
    required this.page,
    required this.perPage,
    required this.totalItems,
    required this.totalPages,
  });

  factory ListResult.fromJson(
      Map<String, dynamic> json, T Function(Map<String, dynamic>) decode) {
    final raw = json['data'] as List? ?? const [];
    return ListResult(
      items: [for (final e in raw) decode((e as Map).cast<String, dynamic>())],
      page: (json['page'] as num?)?.toInt() ?? 1,
      perPage: (json['perPage'] as num?)?.toInt() ?? raw.length,
      totalItems: (json['totalItems'] as num?)?.toInt() ?? -1,
      totalPages: (json['totalPages'] as num?)?.toInt() ?? -1,
    );
  }

  final List<T> items;
  final int page;

  /// The page size the server used (it caps the requested one at 500).
  final int perPage;

  /// -1 when the list was asked for with `skipTotal`.
  final int totalItems;

  /// -1 when the list was asked for with `skipTotal`.
  final int totalPages;
}

/// The result of one operation in a batch.
class BatchResult {
  const BatchResult(this.status, this.body);

  factory BatchResult.fromJson(Map<String, dynamic> json) =>
      BatchResult((json['status'] as num).toInt(), json['body']);

  final int status;
  final Object? body;

  bool get ok => status >= 200 && status < 300;

  /// The body as a record, for create, update and get operations.
  RecordModel? get record {
    final b = body;
    if (b is! Map) return null;
    final inner = b['data'];
    return RecordModel((inner is Map ? inner : b).cast<String, dynamic>());
  }
}
