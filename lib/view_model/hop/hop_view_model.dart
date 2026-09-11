import 'dart:math';

import 'package:cake_wallet/core/hop/hop_engine.dart';
import 'package:cake_wallet/core/hop/hop_executor_impl.dart';
import 'package:cake_wallet/core/hop/hop_planner.dart';
import 'package:cake_wallet/entities/hop_step.dart';
import 'package:cake_wallet/entities/hop_task.dart';
import 'package:cake_wallet/view_model/wallet_address_list/wallet_address_util.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/currency_for_wallet_type.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:cw_core/utils/print_verbose.dart';
import 'package:flutter/foundation.dart';

/// UI-facing model for the "懂的都懂" (chain-hop) feature.
///
/// It owns plan *construction* only — scheduling and execution live in
/// [HopEngine], which is driven independently (foreground timer + background).
class HopViewModel extends ChangeNotifier {
  HopViewModel({
    required this.engine,
    required Future<WalletBase> Function(WalletType, String) loadWallet,
  }) : _loadWallet = loadWallet {
    loadWallets();
  }

  final HopEngine engine;
  final Future<WalletBase> Function(WalletType, String) _loadWallet;

  // ---- observable state (ChangeNotifier) ----
  List<WalletInfo> wallets = [];
  WalletInfo? selectedWallet;
  String destinationAddress = '';
  String totalAmount = '';
  int hopCount = 6;
  DateTime startAt = DateTime.now();
  DateTime endAt = DateTime.now().add(const Duration(days: 1));
  bool isBuilding = false;
  String? error;
  List<HopTask> tasks = [];

  /// When true, hops relay through other wallets of *any* type, swapping
  /// currency along the way (cross-asset hops go through exchange providers).
  bool rotateCurrencies = false;

  void setRotateCurrencies(bool value) {
    rotateCurrencies = value;
    notifyListeners();
  }

  /// When true, hops relay through the app's other wallets instead of fanning
  /// out from a single wallet. Each hop sends from the wallet that received the
  /// previous hop, producing a real cross-wallet chain.
  bool relayAcrossWallets = false;

  void setRelayAcrossWallets(bool value) {
    relayAcrossWallets = value;
    notifyListeners();
  }

  bool get canBuild =>
      selectedWallet != null &&
      destinationAddress.trim().isNotEmpty &&
      totalAmount.trim().isNotEmpty &&
      hopCount >= 2 &&
      endAt.isAfter(startAt) &&
      !isBuilding;

  Duration get window => endAt.difference(startAt);

  List<HopTask> get activeTasks =>
      tasks.where((t) => t.isActive).toList(growable: false);

  List<HopTask> get finishedTasks =>
      tasks.where((t) => t.isFinished).toList(growable: false);

  Future<void> loadWallets() async {
    try {
      wallets = await WalletInfo.getAll();
      notifyListeners();
    } catch (e) {
      printV('HopViewModel.loadWallets error: $e');
    }
  }

  void setWallet(WalletInfo? wallet) {
    selectedWallet = wallet;
    notifyListeners();
  }

  void setDestination(String value) {
    destinationAddress = value;
    notifyListeners();
  }

  void setTotalAmount(String value) {
    totalAmount = value;
    notifyListeners();
  }

  void setHopCount(int value) {
    hopCount = value.clamp(2, 50);
    notifyListeners();
  }

  void setStart(DateTime value) {
    startAt = value;
    if (!endAt.isAfter(startAt)) {
      endAt = startAt.add(const Duration(days: 1));
    }
    notifyListeners();
  }

  void setEnd(DateTime value) {
    endAt = value;
    notifyListeners();
  }

  Future<void> refresh() async {
    tasks = await HopTask.selectAll();
    notifyListeners();
  }

  /// Build a plan and persist it. Returns the created task id, or null on error.
  Future<String?> createPlan() async {
    error = null;
    if (!canBuild) {
      error = 'Fill all fields (hops >= 2, end after start)';
      notifyListeners();
      return null;
    }

    isBuilding = true;
    notifyListeners();
    try {
      final walletInfo = selectedWallet!;
      final wallet = await _loadWallet(walletInfo.type, walletInfo.name);
      final startCurrency = wallet.currency;

      final amount = _parseAmount(totalAmount, startCurrency);
      if (amount == null || amount <= BigInt.zero) {
        error = 'Invalid amount';
        return null;
      }

      final taskId = 'hop_${DateTime.now().millisecondsSinceEpoch}';
      final rng = Random(seedFromString(taskId));

      final windowSeconds = window.inSeconds.clamp(60, 60 * 60 * 24 * 30).toInt();
      final delays = randomDelays(windowSeconds, hopCount, rng);
      final slices = splitAmount(amount, hopCount, rng);

      final steps = <HopStep>[];

      // Relay mode: bounce through a rotation of wallets. The chain is
      // [source, relay0, relay1, ...] and hop i sends from chain[i] into
      // chain[i+1] (the last hop sends into the final destination instead).
      // With [rotateCurrencies] the rotation may mix wallet types, in which
      // case the hop between two different types is an exchange hop.
      final relayWallets = _buildRelayRotation(walletInfo);
      final useRelay = relayAcrossWallets && relayWallets.isNotEmpty;
      final relayChain = [walletInfo, ...relayWallets];

      for (var i = 0; i < hopCount; i++) {
        final isLast = i == hopCount - 1;

        String target;
        String? sourceWalletName;
        var stepCurrency = startCurrency;
        var kind = HopTransferKind.send;

        if (useRelay) {
          final sender = relayChain[i % relayChain.length];
          sourceWalletName = sender.name;
          stepCurrency = walletTypeToCryptoCurrency(sender.type);

          if (isLast) {
            target = destinationAddress.trim();
          } else {
            final receiver = relayChain[(i + 1) % relayChain.length];
            target = await _addressForWallet(receiver, i);
            if (receiver.type != sender.type) {
              kind = HopTransferKind.exchange;
            }
          }
        } else {
          target = isLast
              ? destinationAddress.trim()
              : await _mintAddress(wallet, walletInfo.type, i);
        }

        final receiverCurrency = useRelay && !isLast
            ? walletTypeToCryptoCurrency(
                relayChain[(i + 1) % relayChain.length].type)
            : stepCurrency;

        steps.add(HopStep(
          id: '${taskId}_$i',
          taskId: taskId,
          stepIndex: i,
          sourceCurrency: stepCurrency.title,
          targetCurrency: receiverCurrency.title,
          amount: _formatAmount(slices[i], stepCurrency),
          targetAddress: target,
          delaySeconds: delays[i],
          status: HopStepStatus.pending,
          transferKind: kind,
          sourceWalletName: sourceWalletName,
          createdAt: DateTime.now(),
        ));
      }

      final task = HopTask(
        id: taskId,
        walletName: walletInfo.name,
        walletType: walletInfo.type.index,
        startCurrency: startCurrency.title,
        destinationAddress: destinationAddress.trim(),
        totalAmount: _formatAmount(amount, startCurrency),
        startAt: startAt,
        endAt: endAt,
        hopCount: hopCount,
        status: HopTaskStatus.pending,
        createdAt: DateTime.now(),
      );

      await HopTask.insert(task);
      await HopStep.insertAll(steps);
      await refresh();
      return taskId;
    } catch (e, st) {
      printV('HopViewModel.createPlan error: $e\n$st');
      error = e.toString();
      return null;
    } finally {
      isBuilding = false;
      notifyListeners();
    }
  }

  Future<void> cancelTask(String taskId) async {
    await engine.cancel(taskId);
    await refresh();
  }

  Future<String> _mintAddress(WalletBase wallet, WalletType type, int index) async {
    if (!supportsAddressMinting(type)) {
      return wallet.walletAddresses.address;
    }
    try {
      await createNewAddress(wallet, 'hop $index');
      return wallet.walletAddresses.latestAddress;
    } catch (e) {
      printV('mintAddress failed, falling back to primary: $e');
      return wallet.walletAddresses.address;
    }
  }

  /// Wallets (other than the source) that can participate in a relay. Same-type
  /// wallets only, unless [rotateCurrencies] is on — then any type is allowed
  /// and cross-type hops become exchange hops.
  List<WalletInfo> _buildRelayRotation(WalletInfo source) {
    final others = wallets
        .where((w) =>
            w.name != source.name &&
            w.hardwareWalletType == null &&
            (rotateCurrencies || w.type == source.type))
        .toList();
    return others;
  }

  /// Fresh receiving address for a relay wallet. Mints a new one when the type
  /// supports it, otherwise falls back to its primary address.
  Future<String> _addressForWallet(WalletInfo info, int index) async {
    try {
      final wallet = await _loadWallet(info.type, info.name);
      return await _mintAddress(wallet, info.type, index);
    } catch (e) {
      printV('relay address failed for ${info.name}, using stored address: $e');
      return info.address;
    }
  }

  BigInt? _parseAmount(String raw, CryptoCurrency currency) {
    final cleaned = raw.replaceAll(',', '.').trim();
    final value = double.tryParse(cleaned);
    if (value == null || value <= 0) return null;
    final scale = BigInt.from(10).pow(currency.decimals);
    return (BigInt.from((value * 1e8).round()) * scale) ~/ BigInt.from(100000000);
  }

  String _formatAmount(BigInt minorUnits, CryptoCurrency currency) {
    final scale = BigInt.from(10).pow(currency.decimals);
    final whole = minorUnits ~/ scale;
    final frac = (minorUnits % scale).toString().padLeft(currency.decimals, '0');
    final trimmed = frac.replaceAll(RegExp(r'0+$'), '');
    return trimmed.isEmpty ? whole.toString() : '$whole.$trimmed';
  }
}
