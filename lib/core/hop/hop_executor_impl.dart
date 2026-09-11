import 'package:cake_wallet/bitcoin/bitcoin.dart';
import 'package:cake_wallet/core/hop/hop_engine.dart';
import 'package:cake_wallet/core/hop/hop_exchange_service.dart';
import 'package:cake_wallet/decred/decred.dart';
import 'package:cake_wallet/entities/hop_step.dart';
import 'package:cake_wallet/entities/hop_task.dart';
import 'package:cake_wallet/evm/evm.dart';
import 'package:cake_wallet/monero/monero.dart';
import 'package:cake_wallet/nano/nano.dart';
import 'package:cake_wallet/reactions/wallet_connect.dart';
import 'package:cake_wallet/solana/solana.dart';
import 'package:cake_wallet/store/app_store.dart';
import 'package:cake_wallet/store/dashboard/fiat_conversion_store.dart';
import 'package:cake_wallet/store/settings_store.dart';
import 'package:cake_wallet/tron/tron.dart';
import 'package:cake_wallet/view_model/send/output.dart';
import 'package:cake_wallet/wownero/wownero.dart';
import 'package:cake_wallet/zano/zano.dart';
import 'package:cake_wallet/zcash/zcash.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/currency_for_wallet_type.dart';
import 'package:cw_core/erc20_token.dart';
import 'package:cw_core/pending_transaction.dart';
import 'package:cw_core/wallet_base.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:cw_core/wallet_type.dart';
import 'package:cw_core/utils/print_verbose.dart';

/// Loads a wallet by (type, name) on demand.
typedef HopWalletLoader = Future<WalletBase> Function(WalletType type, String name);

/// Executes hop steps against real wallets.
///
/// Supported transfer kinds:
///  - [HopTransferKind.send]: same-chain send, built exactly like SendViewModel
///  - [HopTransferKind.bridge]: EVM cross-chain via USDT0 / LayerZero
///  - [HopTransferKind.exchange]: cross-asset via an exchange provider
///
/// A step may carry its own `sourceWalletName` (relay mode); otherwise the task
/// wallet is used. Failures are returned, never thrown, so the engine can retry.
class HopExecutorImpl implements HopExecutor {
  HopExecutorImpl({
    required this.appStore,
    required this.settingsStore,
    required this.fiatConversionStore,
    required this.loadWallet,
    required this.exchangeService,
  });

  final AppStore appStore;
  final SettingsStore settingsStore;
  final FiatConversionStore fiatConversionStore;
  final HopWalletLoader loadWallet;
  final HopExchangeService exchangeService;

  @override
  Future<HopExecutionResult> execute(HopTask task, HopStep step) async {
    final wallet = await _resolveSourceWallet(task, step);
    if (wallet == null) {
      return HopExecutionResult.failed('source wallet not found');
    }

    switch (step.transferKind) {
      case HopTransferKind.send:
        return _sendFromWallet(wallet.wallet, wallet.type, step);
      case HopTransferKind.bridge:
        return _executeBridge(wallet.wallet, wallet.type, step);
      case HopTransferKind.exchange:
        return _executeExchange(wallet.wallet, wallet.type, step);
      default:
        return HopExecutionResult.failed('unknown transfer kind ${step.transferKind}');
    }
  }

  /// Resolve which wallet sends this hop. A step may name its own source wallet
  /// (relay mode); otherwise the task wallet is used.
  Future<({WalletBase wallet, WalletType type})?> _resolveSourceWallet(
    HopTask task,
    HopStep step,
  ) async {
    final name = step.sourceWalletName ?? task.walletName;
    try {
      final infos = await WalletInfo.getAll();
      final info = infos.firstWhere(
        (w) => w.name == name,
        orElse: () => throw StateError('wallet $name not found'),
      );
      final wallet = await loadWallet(info.type, info.name);
      return (wallet: wallet, type: info.type);
    } catch (e) {
      printV('Hop: could not resolve source wallet $name: $e');
      return null;
    }
  }

  /// Cross-chain EVM hop via the built-in USDT0 / LayerZero bridge.
  ///
  /// The step's source currency must be a USDT0 token on an EVM chain and the
  /// source wallet must be that EVM chain wallet. The destination chain is
  /// resolved from the step's target currency when it maps to a supported EVM
  /// chain, otherwise the first supported destination is used.
  Future<HopExecutionResult> _executeBridge(
    WalletBase wallet,
    WalletType walletType,
    HopStep step,
  ) async {
    if (!isEVMCompatibleChain(walletType)) {
      return HopExecutionResult.failed('bridge requires an EVM wallet, got $walletType');
    }
    final sourceChainId = evm!.getSelectedChainId(wallet);
    if (sourceChainId == null) {
      return HopExecutionResult.failed('cannot resolve source chain id');
    }

    final source = CryptoCurrency.fromString(step.sourceCurrency);
    if (source is! Erc20Token || !evm!.isUSDT0Token(wallet, source)) {
      return HopExecutionResult.failed('${step.sourceCurrency} is not a bridgeable USDT0 token');
    }
    final token = source;

    final destinations = evm!.getUSDT0DestinationChains(wallet);
    if (destinations.isEmpty) {
      return HopExecutionResult.failed('no USDT0 destination chains available');
    }
    final targetChainId = _resolveDestinationChainId(step.targetCurrency, destinations) ??
        destinations.first.chainId;

    final amount = _parseMinor(step.amount, token);
    if (amount == null || amount <= BigInt.zero) {
      return HopExecutionResult.failed('invalid bridge amount ${step.amount}');
    }

    final address = step.targetAddress.trim();
    if (address.isEmpty) {
      return HopExecutionResult.failed('empty bridge recipient');
    }

    try {
      final quote = await evm!.quoteUSDT0Transfer(
        wallet: wallet,
        sourceChainId: sourceChainId,
        destinationChainId: targetChainId,
        amount: amount,
        recipientAddress: address,
      );

      final pending = await evm!.executeUSDT0Transfer(
        wallet: wallet,
        token: token,
        sourceChainId: sourceChainId,
        destinationChainId: targetChainId,
        amount: amount,
        recipientAddress: address,
        quote: quote,
        priority: evm!.getDefaultTransactionPriority(),
        useBlinkProtection: canSupportBlinkProtection(sourceChainId),
      );
      await pending.commit();
      return HopExecutionResult.ok(pending.evmTxHashFromRawHex ?? pending.id);
    } catch (e) {
      printV('Hop bridge failed: $e');
      return HopExecutionResult.failed(e.toString());
    }
  }

  /// Cross-asset hop via an exchange provider.
  ///
  /// Creates a swap from the step's source currency to its target currency,
  /// pays the provider's deposit address from the source wallet, and returns
  /// the provider trade id so it can be reconciled later.
  Future<HopExecutionResult> _executeExchange(
    WalletBase wallet,
    WalletType walletType,
    HopStep step,
  ) async {
    if (step.sourceCurrency == step.targetCurrency) {
      return HopExecutionResult.failed('exchange hop needs distinct currencies');
    }

    final source = CryptoCurrency.fromString(step.sourceCurrency);
    final target = CryptoCurrency.fromString(step.targetCurrency);

    try {
      final swap = await exchangeService.createSwap(
        from: source,
        to: target,
        fromAmount: step.amount,
        toAddress: step.targetAddress.trim(),
        refundAddress: wallet.walletAddresses.address,
      );

      if (swap == null) {
        return HopExecutionResult.failed('no exchange provider available for the pair');
      }

      final payment = HopStep(
        id: step.id,
        taskId: step.taskId,
        stepIndex: step.stepIndex,
        sourceCurrency: step.sourceCurrency,
        targetCurrency: step.targetCurrency,
        amount: step.amount,
        targetAddress: swap.depositAddress,
        delaySeconds: step.delaySeconds,
        status: step.status,
        transferKind: step.transferKind,
        sourceWalletName: step.sourceWalletName,
        createdAt: step.createdAt,
      );

      final result = await _sendFromWallet(wallet, walletType, payment);
      if (!result.success) return result;

      return HopExecutionResult.ok('${swap.trade.id}:${result.txHash}');
    } catch (e) {
      printV('Hop exchange failed: $e');
      return HopExecutionResult.failed(e.toString());
    }
  }

  int? _resolveDestinationChainId(String targetCurrency, List<ChainInfo> destinations) {
    try {
      final target = CryptoCurrency.fromString(targetCurrency);
      final chainId = getChainIdByCryptoCurrency(target);
      if (chainId != null && destinations.any((d) => d.chainId == chainId)) {
        return chainId;
      }
    } catch (_) {}
    return null;
  }

  /// Build a same-chain send from [wallet] to [step.targetAddress].
  Future<HopExecutionResult> _sendFromWallet(
    WalletBase wallet,
    WalletType walletType,
    HopStep step,
  ) async {
    final source = CryptoCurrency.fromString(step.sourceCurrency);

    final output = Output(
      wallet,
      appStore,
      fiatConversionStore,
      ([CryptoCurrency? c]) => c ?? source,
    );
    output
      ..address = step.targetAddress
      ..setCryptoAmount(step.amount);

    final priority = settingsStore.getPriority(walletType, chainId: wallet.chainId);
    final credentials = _credentialsFor(walletType, output, source, priority);
    if (credentials == null) {
      return HopExecutionResult.failed('no credentials builder for $walletType');
    }

    try {
      final PendingTransaction pending = await wallet.createTransaction(credentials);
      await pending.commit();
      return HopExecutionResult.ok(pending.evmTxHashFromRawHex ?? pending.id);
    } catch (e) {
      printV('Hop send failed: $e');
      return HopExecutionResult.failed(e.toString());
    }
  }

  /// Parse a display amount into minor units for [currency].
  static BigInt? _parseMinor(String amount, CryptoCurrency currency) {
    final value = double.tryParse(amount.replaceAll(',', '.').trim());
    if (value == null || value <= 0) return null;
    final scale = BigInt.from(10).pow(currency.decimals);
    return (BigInt.from((value * 1e8).round()) * scale) ~/ BigInt.from(100000000);
  }

  Object? _credentialsFor(
    WalletType walletType,
    Output output,
    CryptoCurrency source,
    dynamic priority,
  ) {
    final outputs = [output];
    switch (walletType) {
      case WalletType.bitcoin:
      case WalletType.bitcoinCash:
      case WalletType.dogecoin:
      case WalletType.litecoin:
        if (priority == null) return null;
        return bitcoin!.createBitcoinTransactionCredentials(outputs, priority: priority);
      case WalletType.monero:
        if (priority == null) return null;
        return monero!
            .createMoneroTransactionCreationCredentials(outputs: outputs, priority: priority);
      case WalletType.wownero:
        if (priority == null) return null;
        return wownero!
            .createWowneroTransactionCreationCredentials(outputs: outputs, priority: priority);
      case WalletType.ethereum:
      case WalletType.polygon:
      case WalletType.base:
      case WalletType.arbitrum:
      case WalletType.bsc:
        return evm!.createEVMTransactionCredentials(
          outputs,
          priority: priority,
          currency: source,
          useBlinkProtection: false,
        );
      case WalletType.solana:
        return solana!.createSolanaTransactionCredentials(outputs, currency: source);
      case WalletType.tron:
        return tron!.createTronTransactionCredentials(outputs, currency: source);
      case WalletType.nano:
      case WalletType.banano:
        return nano!.createNanoTransactionCredentials(outputs);
      case WalletType.zcash:
        return zcash!.createZcashTransactionCredentials(outputs, currency: source);
      case WalletType.decred:
        if (priority == null) return null;
        return decred!.createDecredTransactionCredentials(outputs, priority);
      case WalletType.zano:
        if (priority == null) return null;
        return zano!.createZanoTransactionCredentials(
            outputs: outputs, priority: priority, currency: source);
      default:
        return null;
    }
  }
}

/// Whether a wallet type can mint brand-new addresses for each hop.
bool supportsAddressMinting(WalletType type) {
  switch (type) {
    case WalletType.bitcoin:
    case WalletType.bitcoinCash:
    case WalletType.litecoin:
    case WalletType.dogecoin:
    case WalletType.monero:
    case WalletType.wownero:
    case WalletType.decred:
      return true;
    default:
      return false;
  }
}
