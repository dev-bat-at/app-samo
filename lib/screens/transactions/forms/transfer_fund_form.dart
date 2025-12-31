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

class TransferFundForm extends StatefulWidget {
  final SupabaseClient tenantClient;

  const TransferFundForm({super.key, required this.tenantClient});

  @override
  State<TransferFundForm> createState() => _TransferFundFormState();
}

class _TransferFundFormState extends State<TransferFundForm> {
  double amount = 0;
  String? fromAccountName;
  String? toAccountName;
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

  Map<String, dynamic>? _getAccount(String? name) {
    if (name == null) return null;
    return accounts.firstWhere((acc) => acc['name'] == name, orElse: () => {});
  }

  Future<void> checkBalance() async {
    if (fromAccountName == null || amount <= 0) return;

    final fromAcc = _getAccount(fromAccountName);
    if (fromAcc == null || fromAcc.isEmpty) {
      _showErrorDialog('Tài khoản gửi không tồn tại');
      return;
    }

    final balance = fromAcc['balance'] as num? ?? 0;
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
    
    final fromAcc = _getAccount(fromAccountName);
    final toAcc = _getAccount(toAccountName);

    if (fromAcc == null || fromAcc.isEmpty || toAcc == null || toAcc.isEmpty) {
      _showErrorDialog('Tài khoản không hợp lệ');
      return;
    }

    final fromCurrency = fromAcc['currency'] as String? ?? '';
    final toCurrency = toAcc['currency'] as String? ?? '';
    final fromBalance = fromAcc['balance'] as num? ?? 0;
    final toBalance = toAcc['balance'] as num? ?? 0;

    if (fromCurrency != toCurrency) {
      _showErrorDialog('Chỉ được chuyển giữa các tài khoản cùng loại tiền tệ');
      return;
    }

    if (fromBalance < amount) {
      _showErrorDialog('Tài khoản không đủ tiền');
      return;
    }

    showDialog(
      context: context,
      builder:
          (_) => AlertDialog(
            title: const Text('Xác nhận chuyển quỹ'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Số tiền: ${formatNumberLocal(amount)}'),
                Text(
                  'Từ tài khoản: ${fromAcc['name']} (${fromAcc['currency']})',
                ),
                Text('Tới tài khoản: ${toAcc['name']} (${toAcc['currency']})'),
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
                  await _createTransferTicket(
                    fromAcc,
                    toAcc,
                    fromBalance,
                    toBalance,
                  );
                },
                child: const Text('Tạo phiếu'),
              ),
            ],
          ),
    );
  }

  Future<void> _createTransferTicket(
    Map<String, dynamic> fromAcc,
    Map<String, dynamic> toAcc,
    num fromBalance,
    num toBalance,
  ) async {
    try {
      final fromAccountData =
          await widget.tenantClient
              .from('financial_accounts')
              .select()
              .eq('name', fromAccountName!)
              .single();

      final toAccountData =
          await widget.tenantClient
              .from('financial_accounts')
              .select()
              .eq('name', toAccountName!)
              .single();

      final now = DateTime.now();
      final ticketId = uuid.v4();
      
      // Prepare snapshot data
      final snapshotData = <String, dynamic>{};
      final financialAccounts = <String, dynamic>{};
      financialAccounts['from_account'] = fromAccountData;
      financialAccounts['to_account'] = toAccountData;
      snapshotData['financial_accounts'] = financialAccounts;

      // Calculate balance changes
      final fromBalanceChange = -amount; // Trừ từ tài khoản nguồn
      final toBalanceChange = amount; // Cộng vào tài khoản đích
      final currency = fromAcc['currency'] as String? ?? 'VND';

      // ✅ CALL RPC FUNCTION - All operations in ONE atomic transaction
      final result = await _retry(
        () => widget.tenantClient.rpc('create_transfer_fund_transaction', params: {
          'p_ticket_id': ticketId,
          'p_from_account': fromAccountName!,
          'p_to_account': toAccountName!,
          'p_amount': amount,
          'p_currency': currency,
          'p_note': note ?? '',
          'p_from_balance_change': fromBalanceChange,
          'p_to_balance_change': toBalanceChange,
          'p_snapshot_data': snapshotData,
          'p_created_at': now.toIso8601String(),
        }),
        operation: 'Create transfer fund transaction (RPC)',
      );

      // Check result
      if (result == null || result['success'] != true) {
        throw Exception('RPC function returned error: ${result?['message'] ?? 'Unknown error'}');
      }

      print('✅ Transfer fund transaction created successfully via RPC!');

      // Lấy số dư cuối từ cả 2 tài khoản
      String? fromBalanceStr;
      String? toBalanceStr;
      try {
        final fromAccountData = await widget.tenantClient
            .from('financial_accounts')
            .select('balance')
            .eq('name', fromAccountName!)
            .eq('currency', currency)
            .maybeSingle();
        if (fromAccountData != null) {
          final balance = (fromAccountData['balance'] as num?)?.toDouble() ?? 0.0;
          fromBalanceStr = formatNumberLocal(balance);
        }
        
        final toAccountData = await widget.tenantClient
            .from('financial_accounts')
            .select('balance')
            .eq('name', toAccountName!)
            .eq('currency', currency)
            .maybeSingle();
        if (toAccountData != null) {
          final balance = (toAccountData['balance'] as num?)?.toDouble() ?? 0.0;
          toBalanceStr = formatNumberLocal(balance);
        }
      } catch (e) {
        print('⚠️ Không thể lấy số dư cuối: $e');
      }

      await NotificationService.showNotification(
        139, // Unique ID for this type of notification
        "Phiếu Chuyển Quỹ Đã Tạo",
        "Đã tạo phiếu chuyển quỹ cho $fromAccountName với số tiền ${formatNumberLocal(amount)} $currency",
        'transfer_fund_created',
      );
      
      // ✅ Gửi thông báo push đến tất cả thiết bị
      await NotificationService.sendNotificationToAll(
        "Phiếu Chuyển Quỹ Đã Tạo",
        "Đã tạo phiếu chuyển quỹ cho $fromAccountName với số tiền ${formatNumberLocal(amount)} $currency",
        data: {'type': 'transfer_fund_created'},
      );

      // ✅ Gửi thông báo Telegram với thông tin chi tiết
      await NotificationService.sendTransactionToTelegram(
        transactionType: 'transfer_fund',
        type: 'Phiếu Chuyển Quỹ',
        ticketId: ticketId,
        totalAmount: formatNumberLocal(amount),
        currency: currency,
        account: '$fromAccountName → $toAccountName',
        finalBalance: fromBalanceStr != null && toBalanceStr != null 
            ? '$fromAccountName: $fromBalanceStr $currency\n$toAccountName: $toBalanceStr $currency'
            : null,
        note: note,
      );

      await showDialog(
        context: context,
        builder:
            (context) => AlertDialog(
              title: const Text('Thành công'),
              content: const Text('Tạo phiếu chuyển quỹ thành công'),
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
        note = null;
        isProcessing = false;
        _fetchAccounts();
      });
    } catch (e) {
      setState(() {
        isProcessing = false;
      });
      _showErrorDialog('Lỗi khi tạo phiếu chuyển quỹ: $e');
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

  void _showErrorDialogOld(String message) {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
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
    final fromAcc = _getAccount(fromAccountName);
    final fromCurrency = fromAcc?['currency'] as String? ?? '';

    return GestureDetector(
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity != null && details.primaryVelocity! > 0) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            'Chuyển quỹ',
            style: TextStyle(color: Colors.white),
          ),
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
                            labelText: 'Tài khoản gửi',
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
                              fromAccountName == null
                                  ? []
                                  : accounts
                                      .where(
                                        (e) =>
                                            e['currency'] == fromCurrency &&
                                            e['name'] != fromAccountName,
                                      )
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
                            labelText: 'Số tiền',
                            border: InputBorder.none,
                            isDense: true,
                          ),
                          onChanged: (val) {
                            final raw = val.replaceAll('.', '');
                            amount = double.tryParse(raw) ?? 0;
                            checkBalance();
                            setState(() {});
                          },
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