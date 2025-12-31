import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'dart:math' as math;
import '../../notification_service.dart';
import '../../../helpers/error_handler.dart';
import '../../../helpers/cache_helper.dart';

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

class PaymentForm extends StatefulWidget {
  final SupabaseClient tenantClient;

  const PaymentForm({super.key, required this.tenantClient});

  @override
  State<PaymentForm> createState() => _PaymentFormState();
}

class _PaymentFormState extends State<PaymentForm> {
  String partnerType = 'suppliers';
  String? partnerName;
  String? partnerId;
  double amount = 0;
  String? currency;
  String? account;
  String? note;
  bool isLoading = true;
  bool isProcessing = false;
  String? errorMessage;
  Map<String, num>? currentDebt; // Lưu công nợ hiện tại: {'debt_vnd': ..., 'debt_cny': ..., 'debt_usd': ...} hoặc {'debt': ...} cho transporters
  bool isLoadingDebt = false;

  List<String> currencies = [];
  List<String> accounts = [];
  List<Map<String, dynamic>> partnerData = []; // Lưu cả name, phone, id
  Map<String, String> partnerIdMap = {}; // Map name to id for suppliers

  final Map<String, String> partnerTypeLabels = {
    'suppliers': 'Nhà cung cấp',
    'fix_units': 'Đơn vị fix lỗi',
    'transporters': 'Đơn vị vận chuyển',
    'customers': 'Khách hàng',
  };

  final TextEditingController amountController = TextEditingController();
  final uuid = const Uuid();

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

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
  void dispose() {
    amountController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      await Future.wait([loadCurrencies(), loadPartners()]);
    } catch (e) {
      setState(() {
        errorMessage = 'Không thể tải dữ liệu: $e';
      });
    } finally {
      setState(() {
        isLoading = false;
      });
    }
  }

  Future<void> loadCurrencies() async {
    final response = await widget.tenantClient
        .from('financial_accounts')
        .select('currency')
        .neq('currency', '');
    final uniqueCurrencies =
        response
            .map((e) => e['currency'] as String?)
            .where((e) => e != null && e.isNotEmpty)
            .cast<String>()
            .toSet()
            .toList();

    setState(() {
      currencies = uniqueCurrencies;
      // ✅ Set currency mặc định theo loại đối tác
      if (partnerType == 'suppliers' || partnerType == 'fix_units') {
        // Nhà cung cấp và đơn vị fix lỗi: mặc định CNY
        currency = currencies.contains('CNY') ? 'CNY' : (currencies.isNotEmpty ? currencies.first : null);
      } else if (partnerType == 'customers') {
        // Khách hàng: mặc định VND
        currency = currencies.contains('VND') ? 'VND' : (currencies.isNotEmpty ? currencies.first : null);
      } else if (partnerType == 'transporters') {
        // Đơn vị vận chuyển: mặc định VND
        currency = currencies.contains('VND') ? 'VND' : (currencies.isNotEmpty ? currencies.first : null);
      } else {
        currency = currencies.isNotEmpty ? currencies.first : null;
      }
      loadAccounts();
    });
  }

  Future<void> loadAccounts() async {
    if (currency == null) {
      setState(() {
        accounts = [];
        account = null;
      });
      return;
    }

    final response = await widget.tenantClient
        .from('financial_accounts')
        .select('name')
        .eq('currency', currency!);
    setState(() {
      accounts =
          response
              .map((e) => e['name'] as String?)
              .where((e) => e != null)
              .cast<String>()
              .toList();
      account = accounts.isNotEmpty ? accounts.first : null;
    });
  }

  Future<void> loadCurrentDebt() async {
    if (partnerName == null || partnerType.isEmpty) {
      setState(() {
        currentDebt = null;
      });
      return;
    }

    setState(() {
      isLoadingDebt = true;
    });

    try {
      if (partnerType == 'transporters') {
        final partnerData = await widget.tenantClient
            .from(partnerType)
            .select('debt')
            .eq('name', partnerName!)
            .single();
        
        setState(() {
          currentDebt = {
            'debt': (partnerData['debt'] as num?) ?? 0,
          };
          isLoadingDebt = false;
        });
      } else {
        final partnerData = (partnerType == 'suppliers' || partnerType == 'fix_units' || partnerType == 'customers') && partnerId != null
            ? await widget.tenantClient
                .from(partnerType)
                .select('debt_vnd, debt_cny, debt_usd')
                .eq('id', partnerId!)
                .single()
            : await widget.tenantClient
                .from(partnerType)
                .select('debt_vnd, debt_cny, debt_usd')
                .eq('name', partnerName!)
                .single();

        setState(() {
          currentDebt = {
            'debt_vnd': (partnerData['debt_vnd'] as num?) ?? 0,
            'debt_cny': (partnerData['debt_cny'] as num?) ?? 0,
            'debt_usd': (partnerData['debt_usd'] as num?) ?? 0,
          };
          isLoadingDebt = false;
        });
      }
    } catch (e) {
      setState(() {
        currentDebt = null;
        isLoadingDebt = false;
      });
    }
  }

  Future<void> loadPartners() async {
    try {
      // ✅ Select cả phone cho suppliers, fix_units và customers
      final selectColumns = (partnerType == 'suppliers' || partnerType == 'fix_units' || partnerType == 'customers') 
          ? 'id, name, phone' 
          : 'name';
      final response = await widget.tenantClient
          .from(partnerType)
          .select(selectColumns);
      setState(() {
        // ✅ Lưu dạng Map với name, phone, id
        partnerData = response
            .map((e) => <String, dynamic>{
                  'id': (partnerType == 'suppliers' || partnerType == 'fix_units' || partnerType == 'customers') 
                      ? e['id']?.toString() 
                      : null,
                  'name': e['name'] as String? ?? '',
                  'phone': (partnerType == 'suppliers' || partnerType == 'fix_units' || partnerType == 'customers')
                      ? (e['phone'] as String? ?? '')
                      : '',
                })
            .where((e) => e['name'] != null && (e['name'] as String).isNotEmpty)
            .toList()
          ..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
        
        // Build id map for suppliers, fix units and customers
        if (partnerType == 'suppliers' || partnerType == 'fix_units' || partnerType == 'customers') {
          partnerIdMap = {};
          for (var e in partnerData) {
            final name = e['name'] as String;
            final id = e['id'] as String?;
            if (name.isNotEmpty && id != null) {
              partnerIdMap[name] = id;
            }
          }
        } else {
          partnerIdMap = {};
        }
        partnerName = null;
        partnerId = null;
      });
    } catch (e) {
      setState(() {
        partnerData = [];
        errorMessage = 'Không thể tải danh sách đối tác: $e';
      });
    }
  }

  Future<void> addPartnerDialog() async {
    String name = '';
    String phone = '';
    String address = '';
    String note = '';
    String? transporterType;

    await showDialog(
      context: context,
      builder:
          (_) => AlertDialog(
            title: Text(
              'Thêm ${partnerTypeLabels[partnerType]?.toLowerCase()}',
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    decoration: const InputDecoration(labelText: 'Tên'),
                    onChanged: (val) => name = val,
                  ),
                  TextField(
                    decoration: const InputDecoration(
                      labelText: 'Số điện thoại',
                    ),
                    keyboardType: TextInputType.phone,
                    onChanged: (val) => phone = val,
                  ),
                  TextField(
                    decoration: const InputDecoration(labelText: 'Địa chỉ'),
                    onChanged: (val) => address = val,
                  ),
                  TextField(
                    decoration: const InputDecoration(labelText: 'Ghi chú'),
                    onChanged: (val) => note = val,
                  ),
                  if (partnerType == 'transporters') ...[
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      value: transporterType,
                      decoration: const InputDecoration(
                        labelText: 'Chủng loại',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'vận chuyển nội địa',
                          child: Text('Vận chuyển nội địa'),
                        ),
                        DropdownMenuItem(
                          value: 'vận chuyển quốc tế',
                          child: Text('Vận chuyển quốc tế'),
                        ),
                      ],
                      onChanged: (val) => transporterType = val,
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Hủy'),
              ),
              ElevatedButton(
                onPressed: () async {
                  if (name.isNotEmpty) {
                    try {
                      final partnerData = {
                        'name': name,
                        'phone': phone.isNotEmpty ? phone : null,
                        'address': address.isNotEmpty ? address : null,
                        'note': note.isNotEmpty ? note : null,
                        'debt_vnd': 0,
                        'debt_cny': 0,
                        'debt_usd': 0,
                      };

                      if (partnerType == 'transporters') {
                        partnerData['type'] = transporterType;
                      }

                      final insertResponse = await widget.tenantClient
                          .from(partnerType)
                          .insert(partnerData)
                          .select('id, name')
                          .single();
                      
                      // ✅ Cache partner ngay sau khi tạo
                      final newPartnerId = insertResponse['id'].toString();
                      final newPartnerName = insertResponse['name'] as String;
                      
                      if (partnerType == 'customers') {
                        CacheHelper.cacheCustomer(newPartnerId, newPartnerName);
                      } else if (partnerType == 'suppliers') {
                        CacheHelper.cacheSupplier(newPartnerId, newPartnerName);
                      } else if (partnerType == 'fix_units') {
                        CacheHelper.cacheFixer(newPartnerId, newPartnerName);
                      }
                      // Note: Transporter không cần cache
                      
                      await loadPartners();
                      setState(() => partnerName = name);
                      Navigator.pop(context);
                    } catch (e) {
                      await ErrorHandler.showErrorDialog(
                        context: context,
                        title: 'Lỗi thêm đối tác',
                        error: e,
                        showRetry: false,
                      );
                    }
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Tên đối tác không được để trống'),
                      ),
                    );
                  }
                },
                child: const Text('Lưu'),
              ),
            ],
          ),
    );
  }

  Future<Map<String, dynamic>> _createSnapshot(String ticketId) async {
    final snapshotData = <String, dynamic>{};

    if (account != null && currency != null) {
      final accountData =
          await widget.tenantClient
              .from('financial_accounts')
              .select()
              .eq('name', account!)
              .eq('currency', currency!)
              .single();
      snapshotData['financial_accounts'] = accountData;
    }

    if (partnerName != null) {
      if ((partnerType == 'suppliers' || partnerType == 'fix_units' || partnerType == 'customers') && partnerId != null) {
        final partnerData =
            await widget.tenantClient
                .from(partnerType)
                .select()
                .eq('id', partnerId!)
                .single();
        snapshotData[partnerType] = partnerData;
      } else {
        final partnerData =
            await widget.tenantClient
                .from(partnerType)
                .select()
                .eq('name', partnerName!)
                .single();
        snapshotData[partnerType] = partnerData;
      }
    }

    return snapshotData;
  }

  Future<void> showConfirm() async {
    if (isProcessing) return;
    
    if (partnerName == null ||
        currency == null ||
        account == null ||
        amount <= 0) {
      await showDialog(
        context: context,
        builder:
            (context) => AlertDialog(
              title: const Text('Thông báo'),
              content: const Text('Vui lòng điền đầy đủ thông tin hợp lệ'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Đóng'),
                ),
              ],
            ),
      );
      return;
    }

    final balanceData =
        await widget.tenantClient
            .from('financial_accounts')
            .select('balance')
            .eq('name', account!)
            .eq('currency', currency!)
            .single();

    final currentBalance = double.tryParse(balanceData['balance']?.toString() ?? '0') ?? 0.0;

    if (currentBalance < amount) {
      await showDialog(
        context: context,
        builder:
            (context) => AlertDialog(
              title: const Text('Thông báo'),
              content: const Text('Tiền trong tài khoản không đủ'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Đóng'),
                ),
              ],
            ),
      );
      return;
    }

    String debtColumn;
    double currentDebt;
    if (partnerType == 'transporters') {
      final partnerData =
          await widget.tenantClient
              .from(partnerType)
              .select('debt')
              .eq('name', partnerName!)
              .single();

      debtColumn = 'debt';
      currentDebt = double.tryParse(partnerData[debtColumn].toString()) ?? 0;
    } else {
      final partnerData = (partnerType == 'suppliers' || partnerType == 'fix_units' || partnerType == 'customers') && partnerId != null
          ? await widget.tenantClient
              .from(partnerType)
              .select('debt_vnd, debt_cny, debt_usd')
              .eq('id', partnerId!)
              .single()
          : await widget.tenantClient
              .from(partnerType)
              .select('debt_vnd, debt_cny, debt_usd')
              .eq('name', partnerName!)
              .single();

      if (currency == 'VND') {
        debtColumn = 'debt_vnd';
      } else if (currency == 'CNY') {
        debtColumn = 'debt_cny';
      } else if (currency == 'USD') {
        debtColumn = 'debt_usd';
      } else {
        throw Exception('Loại tiền tệ không được hỗ trợ: $currency');
      }

      currentDebt = double.tryParse(partnerData[debtColumn].toString()) ?? 0;
    }

    showDialog(
      context: context,
      builder:
          (_) => AlertDialog(
            title: const Text('Xác nhận phiếu chi'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Loại đối tác: ${partnerTypeLabels[partnerType]}'),
                Text('Tên đối tác: $partnerName'),
                Text('Số tiền: ${formatNumberLocal(amount)} $currency'),
                Text('Tài khoản: $account'),
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
                  setState(() {
                    isProcessing = true;
                  });
                  try {
                    final now = DateTime.now();
                    final ticketId = uuid.v4();
                    
                    // Calculate debt change: với customers thì cộng vào công nợ, với các loại khác thì trừ
                    final debtChange = partnerType == 'customers' 
                        ? amount 
                        : -amount;
                    
                    // Account balance change: trừ đi (chi tiền)
                    final accountBalanceChange = -amount;

                    final snapshotData = await _createSnapshot(ticketId);

                    // ✅ CALL RPC FUNCTION - All operations in ONE atomic transaction
                    final result = await _retry(
                      () => widget.tenantClient.rpc('create_payment_transaction', params: {
                        'p_ticket_id': ticketId,
                        'p_type': 'payment',
                        'p_partner_type': partnerType,
                        'p_partner_name': partnerName!,
                        'p_partner_id': partnerId,
                        'p_amount': amount,
                        'p_currency': currency!,
                        'p_account': account!,
                        'p_note': note ?? '',
                        'p_debt_column': debtColumn,
                        'p_debt_change': debtChange,
                        'p_account_balance_change': accountBalanceChange,
                        'p_snapshot_data': snapshotData,
                        'p_created_at': now.toIso8601String(),
                      }),
                      operation: 'Create payment transaction (RPC)',
                    );

                    // Check result
                    if (result == null || result['success'] != true) {
                      throw Exception('RPC function returned error: ${result?['message'] ?? 'Unknown error'}');
                    }

                    print('✅ Payment transaction created successfully via RPC!');

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

                    print('Attempting to show payment notification');
                    // Show notification for successful transaction
                    try {
                      await NotificationService.showNotification(
                        134, // Unique ID for this type of notification
                        "Phiếu Chi Đã Tạo",
                        "Đã tạo phiếu chi với số tiền ${formatNumberLocal(amount)} $currency",
                        'payment_created',
                      );
        
                      // ✅ Gửi thông báo push đến tất cả thiết bị
                      await NotificationService.sendNotificationToAll(
                        "Phiếu Chi Đã Tạo",
                        "Đã tạo phiếu chi với số tiền ${formatNumberLocal(amount)} $currency",
                        data: {'type': 'payment_created'},
                      );
                      
                      // ✅ Gửi thông báo Telegram với thông tin chi tiết
                      await NotificationService.sendTransactionToTelegram(
                        transactionType: 'payment',
                        type: 'Phiếu Chi',
                        ticketId: ticketId,
                        partnerType: partnerType,
                        partnerName: partnerName,
                        totalAmount: formatNumberLocal(amount),
                        currency: currency,
                        account: account,
                        finalBalance: finalBalanceStr,
                        note: note,
                      );
        
                    } catch (e) {
                      print('Error showing payment notification: $e');
                    }

                    if (mounted) {
                      Navigator.pop(context);
                      await showDialog(
                        context: context,
                        builder:
                            (context) => AlertDialog(
                              title: const Text('Thông báo'),
                              content: const Text(
                                'Đã tạo phiếu chi thành công',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('Đóng'),
                                ),
                              ],
                            ),
                      );

                      setState(() {
                        partnerType = 'suppliers';
                        partnerName = null;
                        amount = 0;
                        amountController.text = '';
                        currency =
                            currencies.isNotEmpty ? currencies.first : null;
                        account = null;
                        note = null;
                        isProcessing = false;
                        loadPartners();
                        loadAccounts();
                      });
                    }
                  } catch (e) {
                    if (mounted) {
                      setState(() {
                        isProcessing = false;
                      });
                      Navigator.pop(context);
                      await ErrorHandler.showErrorDialog(
                        context: context,
                        title: 'Lỗi tạo phiếu chi',
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
    if (isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (errorMessage != null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(errorMessage!),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadInitialData,
                child: const Text('Thử lại'),
              ),
            ],
          ),
        ),
      );
    }

    return GestureDetector(
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity! > 0) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            'Chi thanh toán đối tác',
            style: TextStyle(color: Colors.white),
          ),
          backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: Column(
              children: [
                wrapField(
                  DropdownButtonFormField(
                    value: partnerType,
                    items:
                        partnerTypeLabels.entries
                            .map(
                              (e) => DropdownMenuItem(
                                value: e.key,
                                child: Text(e.value),
                              ),
                            )
                            .toList(),
                    onChanged: (val) async {
                      setState(() {
                        partnerType = val!;
                        partnerName = null;
                        partnerId = null;
                        currentDebt = null;
                        // ✅ Set currency mặc định theo loại đối tác
                        if (val == 'transporters') {
                          currency = 'VND';
                        } else if (val == 'customers') {
                          // Khách hàng: mặc định VND
                          if (currencies.contains('VND')) {
                            currency = 'VND';
                          }
                        } else if (val == 'suppliers' || val == 'fix_units') {
                          // Nhà cung cấp và đơn vị fix lỗi: mặc định CNY
                          if (currencies.contains('CNY')) {
                            currency = 'CNY';
                          }
                        }
                      });
                      await loadPartners();
                      // ✅ Load accounts sau khi set currency
                      loadAccounts();
                    },
                    decoration: const InputDecoration(
                      labelText: 'Loại đối tác',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
                wrapField(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Autocomplete<Map<String, dynamic>>(
                              optionsBuilder: (textEditingValue) {
                                final query = textEditingValue.text.toLowerCase();
                                if (query.isEmpty) return partnerData.take(10).toList();
                                final filtered = partnerData
                                    .where((option) {
                                      final name = (option['name'] as String).toLowerCase();
                                      final phone = (option['phone'] as String? ?? '').toLowerCase();
                                      return name.contains(query) || phone.contains(query);
                                    })
                                    .toList()
                                  ..sort((a, b) {
                                    final aName = (a['name'] as String).toLowerCase();
                                    final bName = (b['name'] as String).toLowerCase();
                                    // Ưu tiên khớp theo tên trước
                                    final aNameMatch = aName.contains(query);
                                    final bNameMatch = bName.contains(query);
                                    if (aNameMatch != bNameMatch) {
                                      return aNameMatch ? -1 : 1;
                                    }
                                    // Nếu đều khớp theo phone, ưu tiên tên
                                    if (!aNameMatch && !bNameMatch) {
                                      return aName.compareTo(bName);
                                    }
                                    final aStartsWith = aName.startsWith(query);
                                    final bStartsWith = bName.startsWith(query);
                                    if (aStartsWith != bStartsWith) {
                                      return aStartsWith ? -1 : 1;
                                    }
                                    return aName.compareTo(bName);
                                  });
                                return filtered.isNotEmpty 
                                    ? filtered.take(10).toList() 
                                    : [{'id': null, 'name': 'Không tìm thấy đối tác', 'phone': ''}];
                              },
                              displayStringForOption: (option) {
                                final name = option['name'] as String;
                                final phone = option['phone'] as String? ?? '';
                                if (phone.isNotEmpty) {
                                  return '$name - $phone';
                                }
                                return name;
                              },
                              onSelected: (val) async {
                                if (val['id'] == null && val['name'] == 'Không tìm thấy đối tác') return;
                                setState(() {
                                  partnerName = val['name'] as String;
                                  if (partnerType == 'suppliers' || partnerType == 'fix_units' || partnerType == 'customers') {
                                    partnerId = val['id'] as String?;
                                  }
                                });
                                await loadCurrentDebt();
                              },
                              fieldViewBuilder: (
                                context,
                                controller,
                                focusNode,
                                onFieldSubmitted,
                              ) {
                                return TextFormField(
                                  controller: controller,
                                  focusNode: focusNode,
                                  decoration: const InputDecoration(
                                    labelText: 'Tên đối tác',
                                    border: InputBorder.none,
                                    isDense: true,
                                  ),
                                );
                              },
                            ),
                          ),
                          IconButton(
                            onPressed: addPartnerDialog,
                            icon: const Icon(Icons.add_circle_outline),
                          ),
                        ],
                      ),
                      if (partnerName != null) ...[
                        const SizedBox(height: 8),
                        isLoadingDebt
                            ? const Padding(
                                padding: EdgeInsets.only(left: 12),
                                child: SizedBox(
                                  height: 16,
                                  width: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              )
                            : currentDebt != null
                                ? Padding(
                                    padding: const EdgeInsets.only(left: 12),
                                    child: Builder(
                                      builder: (context) {
                                        if (partnerType == 'transporters') {
                                          final debt = currentDebt!['debt'] ?? 0;
                                          return Text(
                                            'Công nợ hiện tại: ${formatNumberLocal(debt)} VND',
                                            style: TextStyle(
                                              color: debt > 0 ? Colors.red : Colors.green,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          );
                                        } else {
                                          final debtVnd = currentDebt!['debt_vnd'] ?? 0;
                                          final debtCny = currentDebt!['debt_cny'] ?? 0;
                                          final debtUsd = currentDebt!['debt_usd'] ?? 0;
                                          final debtDetails = <String>[];
                                          if (debtVnd != 0) debtDetails.add('${formatNumberLocal(debtVnd)} VND');
                                          if (debtCny != 0) debtDetails.add('${formatNumberLocal(debtCny)} CNY');
                                          if (debtUsd != 0) debtDetails.add('${formatNumberLocal(debtUsd)} USD');
                                          final debtText = debtDetails.isNotEmpty ? debtDetails.join(', ') : '0 VND';
                                          final totalDebt = debtVnd + debtCny + debtUsd;
                                          return Text(
                                            'Công nợ hiện tại: $debtText',
                                            style: TextStyle(
                                              color: totalDebt > 0 ? Colors.red : Colors.green,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          );
                                        }
                                      },
                                    ),
                                  )
                                : const SizedBox.shrink(),
                      ],
                    ],
                  ),
                ),
                wrapField(
                  TextFormField(
                    controller: amountController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [ThousandsFormatterLocal()],
                    onChanged: (val) {
                      final raw = val.replaceAll('.', '');
                      amount = double.tryParse(raw) ?? 0;
                    },
                    decoration: const InputDecoration(
                      labelText: 'Số tiền',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
                wrapField(
                  DropdownButtonFormField(
                    value: currency,
                    items:
                        currencies
                            .map(
                              (e) => DropdownMenuItem(value: e, child: Text(e)),
                            )
                            .toList(),
                    onChanged:
                        partnerType == 'transporters' 
                            ? null // ✅ Disable khi là transporters
                            : (val) => setState(() {
                              currency = val as String?;
                              loadAccounts();
                            }),
                    decoration: const InputDecoration(
                      labelText: 'Đơn vị tiền tệ',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
                wrapField(
                  DropdownButtonFormField(
                    value: account,
                    items:
                        accounts
                            .map(
                              (e) => DropdownMenuItem(value: e, child: Text(e)),
                            )
                            .toList(),
                    onChanged: (val) => setState(() => account = val!),
                    decoration: const InputDecoration(
                      labelText: 'Tài khoản',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
                wrapField(
                  TextFormField(
                    onChanged: (val) => setState(() => note = val),
                    decoration: const InputDecoration(
                      labelText: 'Ghi chú',
                      border: InputBorder.none,
                      isDense: true,
                    ),
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
      ),
    );
  }
}