import 'package:cw_core/db/sqlite.dart';

/// Status lifecycle for a hop (chain-hopping) task.
class HopTaskStatus {
  static const pending = 'pending'; // created, waiting for start_at
  static const running = 'running'; // executing steps
  static const completed = 'completed'; // all steps done
  static const failed = 'failed'; // aborted, see error_message
  static const cancelled = 'cancelled'; // user stopped it

  static const active = {pending, running};
}

/// A single hop task: split a total amount across N random hops that bounce
/// between currencies/chains and fresh addresses, ending at `destinationAddress`.
class HopTask {
  HopTask({
    required this.id,
    required this.walletName,
    required this.walletType,
    required this.startCurrency,
    required this.destinationAddress,
    required this.totalAmount,
    required this.startAt,
    required this.endAt,
    required this.hopCount,
    required this.status,
    required this.createdAt,
    this.updatedAt,
    this.errorMessage,
  });

  static const tableName = 'HopTask';

  String id;
  String walletName;
  int walletType;
  String startCurrency; // CryptoCurrency.title of the first hop source
  String destinationAddress; // final address everything funnels into
  String totalAmount; // canonical display amount of startCurrency
  DateTime startAt;
  DateTime endAt;
  int hopCount;
  String status;
  DateTime createdAt;
  DateTime? updatedAt;
  String? errorMessage;

  bool get isActive => HopTaskStatus.active.contains(status);
  bool get isFinished => !isActive;

  Duration get window => endAt.difference(startAt);

  /// Wall-clock time since the window opened (clamped at zero).
  Duration get elapsed {
    final now = DateTime.now();
    if (now.isBefore(startAt)) return Duration.zero;
    return now.difference(startAt);
  }

  static Future<List<HopTask>> selectAll() async {
    final database = db;
    if (database == null) return [];
    final rows = await database.query(tableName, orderBy: 'created_at DESC');
    return rows.map(fromRow).toList();
  }

  static Future<HopTask?> getById(String id) async {
    final database = db;
    if (database == null) return null;
    final rows = await database.query(tableName, where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return fromRow(rows.first);
  }

  static Future<List<HopTask>> selectActive() async {
    final database = db;
    if (database == null) return [];
    final rows = await database.query(
      tableName,
      where: 'status IN (?, ?)',
      whereArgs: [HopTaskStatus.pending, HopTaskStatus.running],
      orderBy: 'created_at ASC',
    );
    return rows.map(fromRow).toList();
  }

  static Future<void> insert(HopTask task) async {
    final database = db;
    if (database == null) return;
    await database.insert(tableName, task.toRow());
  }

  static Future<void> update(HopTask task) async {
    final database = db;
    if (database == null) return;
    await database.update(tableName, task.toRow(), where: 'id = ?', whereArgs: [task.id]);
  }

  static Future<void> delete(String id) async {
    final database = db;
    if (database == null) return;
    await database.delete(tableName, where: 'id = ?', whereArgs: [id]);
  }

  Map<String, Object?> toRow() => {
        'id': id,
        'wallet_name': walletName,
        'wallet_type': walletType,
        'start_currency': startCurrency,
        'destination_address': destinationAddress,
        'total_amount': totalAmount,
        'start_at': startAt.millisecondsSinceEpoch,
        'end_at': endAt.millisecondsSinceEpoch,
        'hop_count': hopCount,
        'status': status,
        'created_at': createdAt.millisecondsSinceEpoch,
        'updated_at': updatedAt?.millisecondsSinceEpoch,
        'error_message': errorMessage,
      };

  static int _parseInt(Object? v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static DateTime _parseDate(Object? v) =>
      DateTime.fromMillisecondsSinceEpoch(_parseInt(v));

  static HopTask fromRow(Map<String, Object?> m) => HopTask(
        id: m['id'] as String,
        walletName: m['wallet_name'] as String,
        walletType: _parseInt(m['wallet_type']),
        startCurrency: m['start_currency'] as String,
        destinationAddress: m['destination_address'] as String,
        totalAmount: m['total_amount'] as String,
        startAt: _parseDate(m['start_at']),
        endAt: _parseDate(m['end_at']),
        hopCount: _parseInt(m['hop_count']),
        status: m['status'] as String,
        createdAt: _parseDate(m['created_at']),
        updatedAt: m['updated_at'] == null ? null : _parseDate(m['updated_at']),
        errorMessage: m['error_message'] as String?,
      );
}
