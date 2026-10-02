class RecordEntry {
  const RecordEntry({
    required this.id,
    required this.date,
    required this.value,
    required this.recordedAtUtc,
    required this.recordedLocalDate,
    required this.timezoneId,
    required this.utcOffsetMinutes,
    this.deleted = false,
    this.source = 'manual',
    this.legacyTimestamp,
    this.revision = 1,
  });
  final String id;
  final String date;
  final int value;
  final String? recordedAtUtc;
  final String recordedLocalDate;
  final String timezoneId;
  final int? utcOffsetMinutes;
  final String? legacyTimestamp;
  final int revision;
  final bool deleted;
  final String source;
  RecordEntry copyWith({int? value, bool? deleted}) => RecordEntry(
    id: id,
    date: date,
    value: value ?? this.value,
    recordedAtUtc: recordedAtUtc,
    recordedLocalDate: recordedLocalDate,
    timezoneId: timezoneId,
    utcOffsetMinutes: utcOffsetMinutes,
    deleted: deleted ?? this.deleted,
    source: source,
    legacyTimestamp: legacyTimestamp,
    revision: revision + 1,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'date': date,
    'value': value,
    'recordedAtUtc': recordedAtUtc,
    'recordedLocalDate': recordedLocalDate,
    'timezoneId': timezoneId,
    'utcOffsetMinutes': utcOffsetMinutes,
    'legacyTimestamp': legacyTimestamp,
    'revision': revision,
    'deleted': deleted,
    'source': source,
  };
  factory RecordEntry.fromJson(Map<String, Object?> value) => RecordEntry(
    id: value['id']! as String,
    date: value['date']! as String,
    value: value['value']! as int,
    recordedAtUtc: value['recordedAtUtc'] as String?,
    recordedLocalDate: value['recordedLocalDate']! as String,
    timezoneId: value['timezoneId']! as String,
    utcOffsetMinutes: value['utcOffsetMinutes'] as int?,
    legacyTimestamp: value['legacyTimestamp'] as String?,
    revision: value['revision'] as int? ?? 1,
    deleted: value['deleted'] as bool? ?? false,
    source: value['source'] as String? ?? 'manual',
  );
}

/// Decimal input is converted without floating point arithmetic.
int parseFixed(String input, {int scale = 1000}) {
  final text = input.trim();
  final digits = scale.toString().length - 1;
  if (!RegExp(r'^\d+(?:\.\d+)?$').hasMatch(text)) {
    throw const FormatException('请输入非负数');
  }
  final parts = text.split('.');
  final fraction = parts.length == 2 ? parts[1] : '';
  if (fraction.length > digits) throw FormatException('最多 $digits 位小数');
  final whole = int.tryParse(parts[0]);
  if (whole == null || whole > 1000000000) throw const FormatException('数值过大');
  return whole * scale +
      (digits == 0 ? 0 : int.parse(fraction.padRight(digits, '0')));
}

String formatFixed(int value, {int scale = 1000}) {
  if (scale == 1) return '$value';
  final digits = scale.toString().length - 1;
  final fraction = (value % scale)
      .toString()
      .padLeft(digits, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  return '${value ~/ scale}${fraction.isEmpty ? '' : '.$fraction'}';
}
