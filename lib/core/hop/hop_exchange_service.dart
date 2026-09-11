import 'package:cake_wallet/entities/exchange_api_mode.dart';
import 'package:cake_wallet/exchange/provider/exchange_provider.dart';
import 'package:cake_wallet/exchange/provider/exolix_exchange_provider.dart';
import 'package:cake_wallet/exchange/provider/letsexchange_exchange_provider.dart';
import 'package:cake_wallet/exchange/provider/stealth_ex_exchange_provider.dart';
import 'package:cake_wallet/exchange/provider/swaptrade_exchange_provider.dart';
import 'package:cake_wallet/exchange/provider/xoswap_exchange_provider.dart';
import 'package:cake_wallet/exchange/trade.dart';
import 'package:cake_wallet/exchange/trade_request.dart';
import 'package:cake_wallet/store/settings_store.dart';
import 'package:cake_wallet/exchange/provider/trocador_exchange_provider.dart';
import 'package:cw_core/crypto_currency.dart';
import 'package:cw_core/utils/print_verbose.dart';

/// Minimal provider pool for programmatic swaps.
///
/// Mirrors the shape used by `ExchangeViewModel`, minus the pieces that need a
/// live UI (limits polling, rate sorting). Providers are tried in order until
/// one returns a trade; failures fall through to the next.
class HopExchangeService {
  HopExchangeService(this._settingsStore);

  final SettingsStore _settingsStore;

  List<ExchangeProvider> _providers() => [
        ExolixExchangeProvider(),
        SwapTradeExchangeProvider(),
        LetsExchangeExchangeProvider(),
        StealthExExchangeProvider(),
        XOSwapExchangeProvider(),
        TrocadorExchangeProvider(
          useTorOnly: _settingsStore.exchangeStatus == ExchangeApiMode.torOnly,
          providerStates: _settingsStore.trocadorProviderStates,
        ),
      ];

  /// Create a swap and return the deposit address the source wallet must pay.
  ///
  /// Returns a record: the provider deposit address plus the raw [Trade] so the
  /// caller can persist/track it.
  Future<({String depositAddress, Trade trade, ExchangeProvider provider})?>
      createSwap({
    required CryptoCurrency from,
    required CryptoCurrency to,
    required String fromAmount,
    required String toAddress,
    required String refundAddress,
  }) async {
    final request = TradeRequest(
      fromCurrency: from,
      toCurrency: to,
      toAddress: toAddress,
      refundAddress: refundAddress,
      fromAmount: fromAmount,
    );

    for (final provider in _providers()) {
      try {
        if (!provider.isEnabled) continue;

        final trade = await provider.createTrade(
          request: request,
          isFixedRateMode: false,
          isSendAll: false,
        );

        final deposit = trade.inputAddress;
        if (deposit == null || deposit.isEmpty) continue;

        return (depositAddress: deposit, trade: trade, provider: provider);
      } catch (e) {
        printV('HopExchangeService: ${provider.title} failed: $e');
        continue;
      }
    }

    return null;
  }
}
