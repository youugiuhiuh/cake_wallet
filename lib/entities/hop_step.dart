import 'package:cw_core/db/sqlite.dart';

/// How a hop moves value between two currencies/chains.
class HopTransferKind {
  /// Plain send within the same chain/currency (fresh subaddress / own wallet).
  static const send = 'send';

  /// EVM <-> EVM cross-chain via the built-in USDT0 / LayerZero bridge.
  static const bridge = 'bridge';

  /// Cross-chain / cross-asset via an exchange provider (Trocador, etc).
  static const exchange = 'exchange';
}

class HopStepStatus {
  static const pending = 'pending';
  static const running = 'running';
  static const completed = 'completed';
  static const failed = 'failed';

  static const settled = {completed, failed};
}

/// One leg of a hop task. Holds everything needed to execute it later, so the
/// engine can resume from disk after a restart / background wake.
class HopStep {
  HopStep({
    required this.id,
    required this.taskId,
    required this.stepIndex,
    required this.sourceCurrency,
    required this.targetCurrency,
    required this.amount,
    required this.targetAddress,
    required this.delaySeconds,
    required this.status,
    required this.transferKind,
    required this.createdAt,
    this.sourceWalletName,
    this.settledAt,
    this.txHash,
    this.executedAt,
    this.errorMessage,
  });

  static const tableName = 'HopStep';

  String id;
  String taskId;
  int stepIndex;
  String sourceCurrency; // CryptoCurrency.title
  String targetCurrency; // CryptoCurrency.title
  String amount; // canonical display amount of sourceCurrency
  String targetAddress;
  int delaySeconds; // wait before executing this step (relative to task start)
  String status;
  String transferKind; // HopTransferKind.*
  DateTime createdAt;

  /// Wallet to send *from*. When set, overrides the task wallet — this is what
  /// enables multi-wallet relay (each hop sends from the wallet that received
  /// the previous hop).
  String? sourceWalletName;

  /// Set once the engine has observed this hop settle; gates the next hop in a
  /// relay chain.
  DateTime? settledAt;

  String? txHash;
  DateTime? executedAt;
  String? errorMessage;

  bool get isSettled => HopStepStatus.settled.contains(status);

  static Future<List<HopStep>> forTask(String taskId) async {
    final database = db;
    if (database == null) return [];
    final rows = await database.query(
      tableName,
      where: 'task_id = ?',
      whereArgs: [taskId],
      orderBy: 'step_index ASC',
    );
    return rows.map(fromRow).toList();
  }

  static Future<List<HopStep>> selectPending() async {
    final database = db;
    if (database == null) return [];
    final rows = await database.query(
      tableName,
      where: 'status IN (?, ?)',
      whereArgs: [HopStepStatus.pending, HopStepStatus.running],
      orderBy: 'created_at ASC',
    );
    return rows.map(fromRow).toList();
  }

  static Future<void> insertAll(List<HopStep> steps) async {
    final database = db;
    if (database == null) return;
    final batch = database.batch();
    for (final step in steps) {
      batch.insert(tableName, step.toRow());
    }
    await batch.commit(noResult: true);
  }

  static Future<void> update(HopStep step) async {
    final database = db;
    if (database == null) return;
    await database.update(tableName, step.toRow(), where: 'id = ?', whereArgs: [step.id]);
  }

  static Future<void> deleteForTask(String taskId) async {
    final database = db;
    if (database == null) return;
    await database.delete(tableName, where: 'task_id = ?', whereArgs: [taskId]);
  }

  Map<String, Object?> toRow() => {
        'id': id,
        'task_id': taskId,
        'step_index': stepIndex,
        'source_currency': sourceCurrency,
        'target_currency': targetCurrency,
        'amount': amount,
        'target_address': targetAddress,
        'delay_seconds': delaySeconds,
        'status': status,
        'tx_hash': txHash,
        'transfer_kind': transferKind,
        'created_at': createdAt.millisecondsSinceEpoch,
        'executed_at': executedAt?.millisecondsSinceEpoch,
        'error_message': errorMessage,
        'source_wallet_name': sourceWalletName,
        'settled_at': settledAt?.millisecondsSinceEpoch,
      };

  static int _parseInt(Object? v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static DateTime _parseDate(Object? v) => DateTime.fromMillisecondsSinceEpoch(_parseInt(v));

  static HopStep fromRow(Map<String, Object?> m) => HopStep(
        id: m['id'] as String,
        taskId: m['task_id'] as String,
        stepIndex: _parseInt(m['step_index']),
        sourceCurrency: m['source_currency'] as String,
        targetCurrency: m['target_currency'] as String,
        amount: m['amount'] as String,
        targetAddress: m['target_address'] as String,
        delaySeconds: _parseInt(m['delay_seconds']),
        status: m['status'] as String,
        transferKind: m['transfer_kind'] as String,
        createdAt: _parseDate(m['created_at']),
        sourceWalletName: m['source_wallet_name'] as String?,
        settledAt: m['settled_at'] == null ? null : _parseDate(m['settled_at']),
        txHash: m['tx_hash'] as String?,
        executedAt: m['executed_at'] == null ? null : _parseDate(m['executed_at']),
        errorMessage: m['error_message'] as String?,
      );
}
