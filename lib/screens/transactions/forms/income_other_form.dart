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
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    String newText = newValue.text.replaceAll('.', '').replaceAll(',', '');
    if (newText.isEmpty) return newValue;
    final intValue = int.tryParse(newText);
    if (intValue == null) return newValue;
    final formatted = NumberFormat('#,###', 'vi_VN').format(intValue).replaceAll(',', '.');
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

String formatNumberLocal(num value) {
  return NumberFormat('#,###', 'vi_VN').format(value).replaceAll(',', '.');
}

class IncomeOtherForm extends StatefulWidget {
  final SupabaseClient tenantClient;

  const IncomeOtherForm({super.key, required this.tenantClient});

  @override
  State<IncomeOtherForm> createState() => _IncomeOtherFormState();
}

class _IncomeOtherFormState extends State<IncomeOtherForm> {
  double? amount;
  String? currency;
  String? account;
  String? note;
  bool isProcessing = false;

  List<String> currencies = [];
  List<String> accounts = [];

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
    loadCurrencies();
    amountController.text = amount?.toString() ?? '';
  }

  @override
  void dispose() {
    amountController.dispose();
    super.dispose();
  }

  Future<void> loadCurrencies() async {
    final response = await widget.tenantClient
        .from('financial_accounts')
        .select('currency')
        .neq('currency', '');
    final uniqueCurrencies = response
        .map((e) => e['currency'] as String?)
        .where((e) => e != null && e.isNotEmpty)
        .cast<String>()
        .toSet()
        .toList();

    setState(() {
      currencies = uniqueCurrencies;
      currency = currencies.isNotEmpty ? currencies.first : null;
      fetchAccounts();
    });
  }

  Future<void> fetchAccounts() async {
    if (currency == null) {
      setState(() {
        accounts = [];
        account = null;
      });
      return;
    }

    final res = await widget.tenantClient
        .from('financial_accounts')
        .select('name')
        .eq('currency', currency!);

    setState(() {
      accounts = res
          .map((e) => e['name'] as String?)
          .where((e) => e != null)
          .cast<String>()
          .toList();
      account = accounts.isNotEmpty ? accounts.first : null;
    });
  }

  Future<Map<String, dynamic>> _createSnapshot(String ticketId) async {
    final snapshotData = <String, dynamic>{};

    if (account != null && currency != null) {
      final accountData = await widget.tenantClient
          .from('financial_accounts')
          .select()
          .eq('name', account!)
          .eq('currency', currency!)
          .single();
      snapshotData['financial_accounts'] = accountData;
    }

    return snapshotData;
  }

  Future<void> showConfirm() async {
    if (isProcessing) return;
    
    if (amount == null || amount! <= 0 || currency == null || account == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vui lòng nhập đầy đủ thông tin hợp lệ')),
      );
      return;
    }

    final balanceRes = await widget.tenantClient
        .from('financial_accounts')
        .select('balance')
        .eq('name', account!)
        .eq('currency', currency!)
        .maybeSingle();

    if (balanceRes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tài khoản không tồn tại')),
      );
      return;
    }

    final currentBalance = balanceRes['balance'] ?? 0;

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Xác nhận thu nhập khác'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Số tiền: ${formatNumberLocal(amount!)} $currency'),
            Text('Tài khoản: $account'),
            Text('Ghi chú: ${note ?? "Không có"}'),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Sửa')),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              setState(() {
                isProcessing = true;
              });
              try {
                final now = DateTime.now();
                final ticketId = uuid.v4();
                
                // Account balance change: cộng vào (thu nhập)
                final accountBalanceChange = amount!;

                final snapshotData = await _createSnapshot(ticketId);

                // ✅ CALL RPC FUNCTION - All operations in ONE atomic transaction
                final result = await _retry(
                  () => widget.tenantClient.rpc('create_income_other_transaction', params: {
                    'p_ticket_id': ticketId,
                    'p_income_type': 'income_other',
                    'p_amount': amount!,
                    'p_currency': currency!,
                    'p_account': account!,
                    'p_note': note ?? '',
                    'p_account_balance_change': accountBalanceChange,
                    'p_snapshot_data': snapshotData,
                    'p_created_at': now.toIso8601String(),
                  }),
                  operation: 'Create income other transaction (RPC)',
                );

                // Check result
                if (result == null || result['success'] != true) {
                  throw Exception('RPC function returned error: ${result?['message'] ?? 'Unknown error'}');
                }

                print('✅ Income other transaction created successfully via RPC!');

                // Lấy số dư cuối từ tài khoản
                String? finalBalanceStr;
                try {
                  final accountData = await widget.tenantClient
                      .from('financial_accounts')
                      .select('balance')
                      .eq('name', account!)
                      .eq('currency', currency!)
                      .maybeSingle();
                  if (accountData != null) {
                    final balance = (accountData['balance'] as num?)?.toDouble() ?? 0.0;
                    finalBalanceStr = formatNumberLocal(balance);
                  }
                } catch (e) {
                  print('⚠️ Không thể lấy số dư cuối: $e');
                }

                 await NotificationService.showNotification(
                      133, // Unique ID for this type of notification
                      "Phiếu Thu Nhập Khác Đã Tạo",
                      "Đã tạo phiếu thu nhập khác cho $account với số tiền ${formatNumberLocal(amount!)} $currency",
                      'income_other_created',
                    );
                    
                    // ✅ Gửi thông báo push đến tất cả thiết bị
                    await NotificationService.sendNotificationToAll(
                      "Phiếu Thu Nhập Khác Đã Tạo",
                      "Đã tạo phiếu thu nhập khác cho $account với số tiền ${formatNumberLocal(amount!)} $currency",
                      data: {'type': 'income_other_created'},
                    );

                    // ✅ Gửi thông báo Telegram với thông tin chi tiết
                    await NotificationService.sendTransactionToTelegram(
                      transactionType: 'income_other',
                      type: 'Phiếu Thu Nhập Khác',
                      ticketId: ticketId,
                      totalAmount: formatNumberLocal(amount!),
                      currency: currency,
                      account: account,
                      finalBalance: finalBalanceStr,
                      note: note,
                    );

                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Đã tạo phiếu thu nhập khác')),
                  );

                  setState(() {
                    amount = null;
                    amountController.text = '';
                    currency = currencies.isNotEmpty ? currencies.first : null;
                    account = null;
                    note = null;
                    isProcessing = false;
                    fetchAccounts();
                  });
                }
              } catch (e) {
                if (mounted) {
                  setState(() {
                    isProcessing = false;
                  });
                  await ErrorHandler.showErrorDialog(
                    context: context,
                    title: 'Lỗi tạo phiếu thu nhập khác',
                    error: e,
                    showRetry: false,
                  );
                }
              }
            },
            child: const Text('Tạo phiếu'),
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
    return GestureDetector(
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity != null && details.primaryVelocity! > 0) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Thu nhập khác', style: TextStyle(color: Colors.white)),
          backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
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
                    amount = double.tryParse(raw);
                    setState(() {});
                  },
                  validator: (val) {
                    if (val == null || val.isEmpty || double.tryParse(val.replaceAll('.', '')) == null || double.parse(val.replaceAll('.', '')) <= 0) {
                      return 'Vui lòng nhập số tiền hợp lệ';
                    }
                    return null;
                  },
                ),
              ),
              wrapField(
                DropdownButtonFormField(
                  value: currency,
                  items: currencies.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                  onChanged: (val) {
                    setState(() {
                      currency = val!;
                      fetchAccounts();
                    });
                  },
                  decoration: const InputDecoration(
                    labelText: 'Đơn vị tiền',
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
              ),
              wrapField(
                DropdownButtonFormField(
                  value: account,
                  items: accounts.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                  onChanged: (val) => setState(() => account = val),
                  decoration: const InputDecoration(
                    labelText: 'Tài khoản',
                    border: InputBorder.none,
                    isDense: true,
                  ),
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
                  padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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