import 'dart:async';

import 'package:cake_wallet/entities/new_ui_entities/list_item/list_item_regular_row.dart';
import 'package:cake_wallet/entities/new_ui_entities/list_item/list_item_selector.dart';
import 'package:cake_wallet/entities/new_ui_entities/list_item/list_item_text_field.dart';
import 'package:cake_wallet/entities/new_ui_entities/list_item/list_item_toggle.dart';
import 'package:cake_wallet/new-ui/widgets/modal_page_wrapper.dart';
import 'package:cake_wallet/new-ui/widgets/receive_page/receive_top_bar.dart';
import 'package:cake_wallet/src/screens/base_page.dart';
import 'package:cake_wallet/src/widgets/new_list_row/new_list_section.dart';
import 'package:cake_wallet/src/widgets/primary_button.dart';
import 'package:cw_core/wallet_info.dart';
import 'package:flutter/material.dart';
import 'package:cake_wallet/view_model/hop/hop_view_model.dart';

/// "懂的都懂" — randomized chain-hopping across fresh addresses.
///
/// Pick a source wallet + final destination, a total amount, and a time
/// window. The app splits the total into random slices and schedules them at
/// random intervals, each landing on a fresh address before moving on.
class HopPage extends BasePage {
  HopPage(this._viewModel) {
    unawaited(_viewModel.refresh());
  }

  final HopViewModel _viewModel;

  final _destinationController = TextEditingController();
  final _amountController = TextEditingController();
  final _hopsController = TextEditingController(text: '6');

  @override
  bool get hideAppBar => true;

  @override
  Widget body(BuildContext context) {
    return ListenableBuilder(
      listenable: _viewModel,
      builder: (context, _) {
        return ModalPageWrapper(
          topBar: ModalTopBar(
            title: '懂的都懂',
            leadingIcon: const Icon(Icons.arrow_back_ios_new),
            leadingSemanticLabel: 'Back',
            onLeadingPressed: () => Navigator.of(context).pop(),
          ),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              NewListSections(
                showHeader: true,
                controllers: {
                  'hop_destination': _destinationController,
                  'hop_amount': _amountController,
                  'hop_count': _hopsController,
                },
                tapHandlers: {
                  'hop_wallet': () => _pickWallet(context),
                  'hop_start': () => _pickDateTime(context, isStart: true),
                  'hop_end': () => _pickDateTime(context, isStart: false),
                },
                sections: {
                  'source': [
                    ListItemSelector(
                      keyValue: 'hop_wallet',
                      label: 'Source wallet',
                      options: [
                        _viewModel.selectedWallet == null
                            ? 'Select a wallet'
                            : '${_viewModel.selectedWallet!.name} (${_viewModel.selectedWallet!.type})'
                      ],
                      onTap: () => _pickWallet(context),
                    ),
                  ],
                  'destination': [
                    ListItemTextField(
                      keyValue: 'hop_destination',
                      label: 'Final destination address',
                      onChanged: _viewModel.setDestination,
                    ),
                  ],
                  'plan': [
                    ListItemTextField(
                      keyValue: 'hop_amount',
                      label: 'Total amount',
                      onChanged: _viewModel.setTotalAmount,
                    ),
                    ListItemTextField(
                      keyValue: 'hop_count',
                      label: 'Number of hops',
                      onChanged: (v) {
                        final n = int.tryParse(v);
                        if (n != null) _viewModel.setHopCount(n);
                      },
                    ),
                    ListItemToggle(
                      keyValue: 'hop_relay',
                      label: 'Relay across wallets',
                      value: _viewModel.relayAcrossWallets,
                      onChanged: _viewModel.setRelayAcrossWallets,
                    ),
                    ListItemToggle(
                      keyValue: 'hop_rotate',
                      label: 'Rotate currencies (swap between hops)',
                      value: _viewModel.rotateCurrencies,
                      onChanged: (v) {
                        _viewModel.setRotateCurrencies(v);
                        if (v) _viewModel.setRelayAcrossWallets(true);
                      },
                    ),
                  ],
                  'window': [
                    ListItemRegularRow(
                      keyValue: 'hop_start',
                      label: 'Start time',
                      trailingText: _fmt(_viewModel.startAt),
                      onTap: () => _pickDateTime(context, isStart: true),
                    ),
                    ListItemRegularRow(
                      keyValue: 'hop_end',
                      label: 'End time',
                      trailingText: _fmt(_viewModel.endAt),
                      onTap: () => _pickDateTime(context, isStart: false),
                    ),
                  ],
                  if (_viewModel.error != null)
                    'error': [
                      ListItemRegularRow(
                        keyValue: 'hop_error',
                        label: _viewModel.error!,
                        showArrow: false,
                      ),
                    ],
                  'tasks': [
                    for (final task in _viewModel.tasks)
                      ListItemRegularRow(
                        keyValue: 'task_${task.id}',
                        label: '${task.startCurrency} x${task.hopCount}',
                        subtitle: '${task.status}  ${_fmtRange(task.startAt, task.endAt)}',
                        trailingText: task.isActive ? 'CANCEL' : '',
                        onTap: task.isActive
                            ? () => _viewModel.cancelTask(task.id)
                            : null,
                      ),
                  ],
                },
              ),
              const SizedBox(height: 24),
              PrimaryButton(
                text: _viewModel.isBuilding ? 'Building…' : '懂的都懂 · 开始',
                color: Theme.of(context).colorScheme.primary,
                textColor: Theme.of(context).colorScheme.onPrimary,
                isDisabled: !_viewModel.canBuild,
                onPressed: _viewModel.canBuild ? () => _onStart(context) : null,
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _onStart(BuildContext context) async {
    final id = await _viewModel.createPlan();
    if (id != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Task $id scheduled')),
      );
    }
  }

  Future<void> _pickWallet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _WalletPicker(
        wallets: _viewModel.wallets,
        onSelected: (w) {
          _viewModel.setWallet(w);
          Navigator.of(context).pop();
        },
      ),
    );
  }

  Future<void> _pickDateTime(BuildContext context, {required bool isStart}) async {
    final initial = isStart ? _viewModel.startAt : _viewModel.endAt;
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !context.mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) return;
    final picked = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (isStart) {
      _viewModel.setStart(picked);
    } else {
      _viewModel.setEnd(picked);
    }
  }

  static String _fmt(DateTime d) =>
      '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';

  static String _fmtRange(DateTime a, DateTime b) => '${_fmt(a)} → ${_fmt(b)}';

  static String _two(int n) => n.toString().padLeft(2, '0');
}

class _WalletPicker extends StatelessWidget {
  const _WalletPicker({required this.wallets, required this.onSelected});

  final List<WalletInfo> wallets;
  final ValueChanged<WalletInfo> onSelected;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: wallets.length,
        itemBuilder: (context, i) {
          final w = wallets[i];
          return ListTile(
            title: Text(w.name),
            subtitle: Text(w.type.toString()),
            onTap: () => onSelected(w),
          );
        },
      ),
    );
  }
}
