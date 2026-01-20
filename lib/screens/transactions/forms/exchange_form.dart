import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'dart:math' as math;
import '../../notification_service.dart';
import '../../../helpers/error_handler.dart';

class ThousandsFormatterLocal extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    String newText = newValue.text.replaceAll('.', '').replaceAll(',', '');
    if (newText.isEmpty) return newValue;
    final intValue = int.tryParse(newText);
    if (intValue == null) return newValue;
    final formatted = NumberFormat(
      '#,###',
      'vi_VN',
    ).format(intValue).replaceAll(',', '.');
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

String formatNumberLocal(num value) {
  return NumberFormat('#,###', 'vi_VN').format(value).replaceAll(',', '.');
}

class ExchangeForm extends StatefulWidget {
  final SupabaseClient tenantClient;

  const ExchangeForm({super.key, required this.tenantClient});

  @override
  State<ExchangeForm> createState() => _ExchangeFormState();
}

class _ExchangeFormState extends State<ExchangeForm> {
  double amount = 0;
  String? fromAccountName;
  String? toAccountName;
  double rate = 1;
  double receiveAmount = 0;
  String? note;
  bool isProcessing = false;
  List<Map<String, dynamic>> accounts = [];

  final TextEditingController amountController = TextEditingController();
  final uuid = const Uuid();

  // Retry helper function
  Future<T> _retry<T>(Future<T> Function() fn, {String? operation}) async {
    const maxRetries = 3;
    const retryDelay = Duration(seconds: 1);
    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        return await fn();
      } catch (e) {
        if (attempt == maxRetries - 1) {
          if (e is PostgrestException) {
            throw Exception('${operation ?? 'Operation'} failed after $maxRetries attempts: PostgrestException(message: ${e.message}, code: ${e.code}, details: ${e.details}, hint: ${e.hint})');
          }
          throw Exception('${operation ?? 'Operation'} failed after $maxRetries attempts: $e');
        }
        await Future.delayed(retryDelay * math.pow(2, attempt).toInt());
      }
    }
    throw Exception('${operation ?? 'Operation'} failed: Unexpected error');
  }

  @override
  void initState() {
    super.initState();
    _fetchAccounts();
    amountController.text = ''; // Để trống ô nhập số tiền đổi
  }

  @override
  void dispose() {
    amountController.dispose();
    super.dispose();
  }

  Future<void> _fetchAccounts() async {
    try {
      final response =
          await widget.tenantClient.from('financial_accounts').select();
      setState(() {
        accounts = response.map((e) => Map<String, dynamic>.from(e)).toList();
      });
    } catch (e) {
      _showErrorDialog('Lỗi khi tải danh sách tài khoản: $e');
    }
  }

  Map<String, dynamic>? _getAccount(String name) {
    return accounts.firstWhere((acc) => acc['name'] == name, orElse: () => {});
  }

  void calculateReceiveAmount() {
    setState(() {
      receiveAmount = rate > 0 ? amount / rate : 0;
    });
  }

  Future<void> checkBalance() async {
    if (fromAccountName == null || amount <= 0) return;

    final fromAcc = _getAccount(fromAccountName!);
    if (fromAcc == null || fromAcc.isEmpty) {
      _showErrorDialog('Tài khoản thanh toán không tồn tại');
      return;
    }

    final balance = fromAcc['balance'] ?? 0;
    if (balance < amount) {
      _showErrorDialog('Tài khoản không đủ tiền');
    }
  }

  Future<Map<String, dynamic>> _createSnapshot(String ticketId) async {
    final snapshotData = <String, dynamic>{};
    final financialAccounts = <String, dynamic>{};

    if (fromAccountName != null) {
      final fromAccountData =
          await widget.tenantClient
              .from('financial_accounts')
              .select()
              .eq('name', fromAccountName!)
              .single();
      financialAccounts['from_account'] = fromAccountData;
    }

    if (toAccountName != null) {
      final toAccountData =
          await widget.tenantClient
              .from('financial_accounts')
              .select()
              .eq('name', toAccountName!)
              .single();
      financialAccounts['to_account'] = toAccountData;
    }

    snapshotData['financial_accounts'] = financialAccounts;
    return snapshotData;
  }

  void showConfirm() {
    if (isProcessing) return;
    
    if (fromAccountName == null || toAccountName == null) {
      _showErrorDialog('Tài khoản không hợp lệ');
      return;
    }

    final fromAcc = _getAccount(fromAccountName!);
    final toAcc = _getAccount(toAccountName!);

    if (fromAcc == null || fromAcc.isEmpty || toAcc == null || toAcc.isEmpty) {
      _showErrorDialog('Tài khoản không hợp lệ');
      return;
    }

    final fromCurrency = fromAcc['currency'] ?? '';
    final toCurrency = toAcc['currency'] ?? '';
    final fromBalance = fromAcc['balance'] ?? 0;

    if (fromBalance < amount) {
      _showErrorDialog('Tài khoản không đủ tiền');
      return;
    }

    if (fromCurrency != 'VND' || (toCurrency != 'CNY' && toCurrency != 'USD')) {
      _showErrorDialog('Chỉ hỗ trợ đổi từ VND sang CNY hoặc USD');
      return;
    }

    showDialog(
      context: context,
      builder:
          (_) => AlertDialog(
            title: const Text('Xác nhận đổi tiền'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Số tiền đổi: ${formatNumberLocal(amount)}'),
                Text(
                  'Từ tài khoản: ${fromAcc['name']} (${fromAcc['currency']})',
                ),
                Text('Sang tài khoản: ${toAcc['name']} (${toAcc['currency']})'),
                Text('Tỉ giá: ${rate.toStringAsFixed(2)}'),
                Text('Nhận được: ${formatNumberLocal(receiveAmount)}'),
                Text('Ghi chú: ${note ?? "Không có"}'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Sửa'),
              ),
              ElevatedButton(
                onPressed: isProcessing ? null : () async {
                  Navigator.pop(context);
                  setState(() {
                    isProcessing = true;
                  });
                  await _createExchangeTicket(
                    fromAcc,
                    toAcc,
                    fromBalance,
                  );
                },
                child: const Text('Tạo phiếu'),
              ),
            ],
          ),
    );
  }

  Future<void> _createExchangeTicket(
    Map<String, dynamic> fromAcc,
    Map<String, dynamic> toAcc,
    num fromBalance,
  ) async {
    try {
      if (fromAccountName == null || toAccountName == null) {
        _showErrorDialog('Tài khoản không hợp lệ');
        return;
      }

      final now = DateTime.now();
      final ticketId = uuid.v4();

      final snapshotData = await _createSnapshot(ticketId);

      // Calculate balance changes
      final fromBalanceChange = -amount; // Trừ từ tài khoản nguồn
      final toBalanceChange = receiveAmount; // Cộng vào tài khoản đích
      final fromCurrency = fromAcc['currency'] ?? '';
      final toCurrency = toAcc['currency'] ?? '';

      // ✅ Tính tỉ giá để lưu vào database
      // Tỉ giá = số VND cần để đổi 1 đơn vị ngoại tệ (CNY hoặc USD)
      // Ví dụ: 1 CNY = 3500 VND → rate = 3500
      num? rateVndCny;
      num? rateVndUsd;
      if (fromCurrency == 'VND' && toCurrency == 'CNY') {
        // Tỉ giá VND -> CNY: số VND cần để đổi 1 CNY
        // rate = amount / receiveAmount (ví dụ: 3500000 VND / 1000 CNY = 3500)
        if (rate > 0) {
          rateVndCny = rate;
        } else if (receiveAmount > 0) {
          rateVndCny = amount / receiveAmount;
        } else {
          rateVndCny = null;
        }
        print('💰 Exchange: Setting rate_vnd_cny = $rateVndCny (rate input: $rate, from $amount VND to $receiveAmount CNY)');
      } else if (fromCurrency == 'VND' && toCurrency == 'USD') {
        // Tỉ giá VND -> USD: số VND cần để đổi 1 USD
        // rate = amount / receiveAmount (ví dụ: 25000000 VND / 1000 USD = 25000)
        if (rate > 0) {
          rateVndUsd = rate;
        } else if (receiveAmount > 0) {
          rateVndUsd = amount / receiveAmount;
        } else {
          rateVndUsd = null;
        }
        print('💰 Exchange: Setting rate_vnd_usd = $rateVndUsd (rate input: $rate, from $amount VND to $receiveAmount USD)');
      }

      // ✅ Debug: Log tỉ giá trước khi gọi RPC
      print('🔍 DEBUG: Exchange transaction params:');
      print('  from_currency: $fromCurrency, to_currency: $toCurrency');
      print('  rate (input): $rate');
      print('  rate_vnd_cny: $rateVndCny');
      print('  rate_vnd_usd: $rateVndUsd');
      print('  from_amount: $amount, to_amount: $receiveAmount');

      // ✅ Chuẩn bị params cho RPC - đảm bảo null được truyền đúng
      final rpcParams = <String, dynamic>{
        'p_ticket_id': ticketId,
        'p_from_account': fromAccountName!,
        'p_to_account': toAccountName!,
        'p_from_amount': amount,
        'p_to_amount': receiveAmount,
        'p_from_currency': fromCurrency,
        'p_to_currency': toCurrency,
        'p_note': note ?? '',
        'p_from_balance_change': fromBalanceChange,
        'p_to_balance_change': toBalanceChange,
        'p_snapshot_data': snapshotData,
        'p_created_at': now.toIso8601String(),
      };
      
      // ✅ Chỉ thêm rate parameters (có thể null)
      if (rateVndCny != null) {
        rpcParams['p_rate_vnd_cny'] = rateVndCny;
      } else {
        rpcParams['p_rate_vnd_cny'] = null;
      }
      
      if (rateVndUsd != null) {
        rpcParams['p_rate_vnd_usd'] = rateVndUsd;
      } else {
        rpcParams['p_rate_vnd_usd'] = null;
      }

      print('🔍 DEBUG: RPC params with rates: rate_vnd_cny=${rpcParams['p_rate_vnd_cny']}, rate_vnd_usd=${rpcParams['p_rate_vnd_usd']}');

      // ✅ CALL RPC FUNCTION - All operations in ONE atomic transaction
      final result = await _retry(
        () => widget.tenantClient.rpc('create_exchange_transaction', params: rpcParams),
        operation: 'Create exchange transaction (RPC)',
      );

      // Check result
      if (result == null || result['success'] != true) {
        throw Exception('RPC function returned error: ${result?['message'] ?? 'Unknown error'}');
      }

      print('✅ Exchange transaction created successfully via RPC!');

      // Lấy số dư cuối từ cả 2 tài khoản
      String? fromBalanceStr;
      String? toBalanceStr;
      try {
        final fromAccountData = await widget.tenantClient
            .from('financial_accounts')
            .select('balance')
            .eq('name', fromAccountName!)
            .eq('currency', fromCurrency)
            .maybeSingle();
        if (fromAccountData != null) {
          final balance = (fromAccountData['balance'] as num?)?.toDouble() ?? 0.0;
          fromBalanceStr = formatNumberLocal(balance);
        }
        
        final toAccountData = await widget.tenantClient
            .from('financial_accounts')
            .select('balance')
            .eq('name', toAccountName!)
            .eq('currency', toCurrency)
            .maybeSingle();
        if (toAccountData != null) {
          final balance = (toAccountData['balance'] as num?)?.toDouble() ?? 0.0;
          toBalanceStr = formatNumberLocal(balance);
        }
      } catch (e) {
        print('⚠️ Không thể lấy số dư cuối: $e');
      }

      await NotificationService.showNotification(
        129, // Unique ID for this type of notification
        "Phiếu Đổi Tiền Đã Tạo",
        "Đã tạo phiếu đổi tiền với số tiền ${formatNumberLocal(amount)} $fromCurrency",
        'exchange_created',
      );
      
      // ✅ Gửi thông báo push đến tất cả thiết bị
      await NotificationService.sendNotificationToAll(
        "Phiếu Đổi Tiền Đã Tạo",
        "Đã tạo phiếu đổi tiền với số tiền ${formatNumberLocal(amount)} $fromCurrency",
        data: {'type': 'exchange_created'},
      );

      // ✅ Gửi thông báo Telegram với thông tin chi tiết
      await NotificationService.sendTransactionToTelegram(
        transactionType: 'exchange',
        type: 'Phiếu Đổi Tiền',
        ticketId: ticketId,
        totalAmount: '${formatNumberLocal(amount)} $fromCurrency → ${formatNumberLocal(receiveAmount)} $toCurrency',
        currency: '$fromCurrency/$toCurrency',
        account: '$fromAccountName → $toAccountName',
        finalBalance: fromBalanceStr != null && toBalanceStr != null 
            ? '$fromAccountName ($fromCurrency): $fromBalanceStr $fromCurrency\n$toAccountName ($toCurrency): $toBalanceStr $toCurrency'
            : null,
        note: note,
      );

      await showDialog(
        context: context,
        builder:
            (context) => AlertDialog(
              title: const Text('Thành công'),
              content: const Text('Tạo phiếu thành công'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Đóng'),
                ),
              ],
            ),
      );

      setState(() {
        amount = 0;
        amountController.text = '';
        fromAccountName = null;
        toAccountName = null;
        rate = 1;
        receiveAmount = 0;
        note = null;
        isProcessing = false;
        _fetchAccounts();
      });
    } catch (e) {
      setState(() {
        isProcessing = false;
      });
      _showErrorDialog('Lỗi khi tạo phiếu đổi tiền: $e');
    }
  }

  Future<void> _showErrorDialog(String message) async {
    await ErrorHandler.showErrorDialog(
      context: context,
      title: 'Lỗi',
      error: message,
      showRetry: false,
    );
  }

  Widget wrapField(Widget child) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    String? fromCurrency;
    if (fromAccountName != null) {
      final account = _getAccount(fromAccountName!);
      fromCurrency = account != null ? account['currency'] as String? : null;
    }

    final filteredToAccounts =
        accounts.where((acc) {
          final accCurrency = acc['currency'];
          return fromCurrency == null || accCurrency != fromCurrency;
        }).toList();

    return GestureDetector(
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity != null && details.primaryVelocity! > 0) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Đổi tiền', style: TextStyle(color: Colors.white)),
          backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body:
            accounts.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      wrapField(
                        DropdownButtonFormField<String>(
                          value: fromAccountName,
                          decoration: const InputDecoration(
                            labelText: 'Tài khoản thanh toán',
                            border: InputBorder.none,
                            isDense: true,
                          ),
                          items:
                              accounts
                                  .map(
                                    (e) => DropdownMenuItem<String>(
                                      value: e['name'] as String,
                                      child: Text(
                                        '${e['name']} (${e['currency']})',
                                      ),
                                    ),
                                  )
                                  .toList(),
                          onChanged:
                              (String? val) => setState(() {
                                fromAccountName = val;
                                toAccountName = null;
                                calculateReceiveAmount();
                                checkBalance();
                              }),
                        ),
                      ),
                      wrapField(
                        DropdownButtonFormField<String>(
                          value: toAccountName,
                          decoration: const InputDecoration(
                            labelText: 'Tài khoản nhận',
                            border: InputBorder.none,
                            isDense: true,
                          ),
                          items:
                              filteredToAccounts
                                  .map(
                                    (e) => DropdownMenuItem<String>(
                                      value: e['name'] as String,
                                      child: Text(
                                        '${e['name']} (${e['currency']})',
                                      ),
                                    ),
                                  )
                                  .toList(),
                          onChanged:
                              (String? val) =>
                                  setState(() => toAccountName = val),
                        ),
                      ),
                      wrapField(
                        TextFormField(
                          controller: amountController,
                          keyboardType: TextInputType.number,
                          inputFormatters: [ThousandsFormatterLocal()],
                          decoration: const InputDecoration(
                            labelText: 'Số tiền đổi',
                            border: InputBorder.none,
                            isDense: true,
                          ),
                          onChanged: (val) {
                            final raw = val.replaceAll('.', '');
                            amount = double.tryParse(raw) ?? 0;
                            calculateReceiveAmount();
                            checkBalance();
                          },
                        ),
                      ),
                      wrapField(
                        TextFormField(
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Tỉ giá',
                            border: InputBorder.none,
                            isDense: true,
                          ),
                          onChanged: (val) {
                            rate = double.tryParse(val) ?? 1;
                            calculateReceiveAmount();
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'Số tiền nhận được: ${formatNumberLocal(receiveAmount)}',
                        ),
                      ),
                      wrapField(
                        TextFormField(
                          decoration: const InputDecoration(
                            labelText: 'Ghi chú',
                            border: InputBorder.none,
                            isDense: true,
                          ),
                          onChanged: (val) => setState(() => note = val),
                        ),
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton(
                        onPressed: isProcessing ? null : showConfirm,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            vertical: 14,
                            horizontal: 24,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('Xác nhận'),
                      ),
                    ],
                  ),
                ),
      ),
    );
  }
}