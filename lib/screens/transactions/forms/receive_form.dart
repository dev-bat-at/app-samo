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

class ReceiveForm extends StatefulWidget {
  final SupabaseClient tenantClient;

  const ReceiveForm({super.key, required this.tenantClient});

  @override
  State<ReceiveForm> createState() => _ReceiveFormState();
}

class _ReceiveFormState extends State<ReceiveForm> {
  String? partnerType;
  String? partnerName;
  String? partnerId;
  double? amount;
  String? currency;
  String? account;
  String? note;
  bool isProcessing = false;
  Map<String, num>? currentDebt; // Lưu công nợ hiện tại: {'debt_vnd': ..., 'debt_cny': ..., 'debt_usd': ...} hoặc {'debt': ...} cho transporters
  bool isLoadingDebt = false;

  final _formKey = GlobalKey<FormState>();

  List<String> partnerTypes = [
    'Khách hàng',
    'Nhà cung cấp',
    'Đơn vị fix lỗi',
    'Đơn vị vận chuyển',
  ];
  List<Map<String, dynamic>> partnerData = []; // Lưu cả name, phone, id
  Map<String, String> partnerIdMap = {}; // Map name to id for customers
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
    if (!mounted) return;
    try {
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

      if (mounted) {
        setState(() {
          currencies = uniqueCurrencies;
          // ✅ Ưu tiên VND nếu có trong danh sách, nếu không thì lấy currency đầu tiên
          currency = currencies.contains('VND') ? 'VND' : (currencies.isNotEmpty ? currencies.first : null);
          loadAccounts();
        });
      }
    } catch (e) {
      print('Error loading currencies: $e');
    }
  }

  Future<void> loadAccounts() async {
    if (!mounted) return;
    if (currency == null) {
      if (mounted) {
        setState(() {
          accounts = [];
          account = null;
        });
      }
      return;
    }

    try {
      final res = await widget.tenantClient
          .from('financial_accounts')
          .select('name')
          .eq('currency', currency!);
      if (mounted) {
        setState(() {
          accounts =
              res
                  .map((e) => e['name'] as String?)
                  .where((e) => e != null)
                  .cast<String>()
                  .toList();
          account = accounts.isNotEmpty ? accounts.first : null;
        });
      }
    } catch (e) {
      print('Error loading accounts: $e');
    }
  }

  Future<void> loadCurrentDebt() async {
    if (partnerName == null || partnerType == null) {
      setState(() {
        currentDebt = null;
      });
      return;
    }

    setState(() {
      isLoadingDebt = true;
    });

    try {
      final table = getTable(partnerType!);
      
      if (partnerType == 'Đơn vị vận chuyển') {
        final partnerData = await widget.tenantClient
            .from(table)
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
        final partnerData = (partnerType == 'Khách hàng' || partnerType == 'Nhà cung cấp' || partnerType == 'Đơn vị fix lỗi') && partnerId != null
            ? await widget.tenantClient
                .from(table)
                .select('debt_vnd, debt_cny, debt_usd')
                .eq('id', partnerId!)
                .single()
            : await widget.tenantClient
                .from(table)
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

  Future<void> loadPartnerNames(String type) async {
    if (!mounted) return;
    String table =
        type == 'Khách hàng'
            ? 'customers'
            : type == 'Nhà cung cấp'
            ? 'suppliers'
            : type == 'Đơn vị fix lỗi'
            ? 'fix_units'
            : 'transporters';
    try {
      // ✅ Select cả phone cho customers, suppliers, fix_units
      final selectColumns = (type == 'Khách hàng' || type == 'Nhà cung cấp' || type == 'Đơn vị fix lỗi') 
          ? 'id, name, phone' 
          : 'name';
      final res = await widget.tenantClient.from(table).select(selectColumns);
      if (mounted) {
        setState(() {
          // ✅ Lưu dạng Map với name, phone, id
          partnerData = res
              .map((e) => <String, dynamic>{
                    'id': (type == 'Khách hàng' || type == 'Nhà cung cấp' || type == 'Đơn vị fix lỗi') 
                        ? e['id']?.toString() 
                        : null,
                    'name': e['name'] as String? ?? '',
                    'phone': (type == 'Khách hàng' || type == 'Nhà cung cấp' || type == 'Đơn vị fix lỗi')
                        ? (e['phone'] as String? ?? '')
                        : '',
                  })
              .where((e) => e['name'] != null && (e['name'] as String).isNotEmpty)
              .toList()
            ..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
          
          // Build id map for customers, suppliers, and fix units
          if (type == 'Khách hàng' || type == 'Nhà cung cấp' || type == 'Đơn vị fix lỗi') {
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
      }
    } catch (e) {
      print('Error loading partner names: $e');
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
            title: Text('Thêm ${partnerType?.toLowerCase()}'),
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
                  if (partnerType == 'Đơn vị vận chuyển') ...[
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
                      final table = getTable(partnerType!);
                      final partnerData = {
                        'name': name,
                        'phone': phone.isNotEmpty ? phone : '',
                        'address': address.isNotEmpty ? address : '',
                        'note': note.isNotEmpty ? note : '',
                        'debt_vnd': 0,
                        'debt_cny': 0,
                        'debt_usd': 0,
                      };

                      if (partnerType == 'Đơn vị vận chuyển') {
                        partnerData['type'] = transporterType ?? '';
                      }

                      final insertResponse = await widget.tenantClient
                          .from(table)
                          .insert(partnerData)
                          .select('id, name')
                          .single();
                      
                      // ✅ Cache partner ngay sau khi tạo
                      final newPartnerId = insertResponse['id'].toString();
                      final newPartnerName = insertResponse['name'] as String;
                      
                      if (partnerType == 'Khách hàng') {
                        CacheHelper.cacheCustomer(newPartnerId, newPartnerName);
                      } else if (partnerType == 'Nhà cung cấp') {
                        CacheHelper.cacheSupplier(newPartnerId, newPartnerName);
                      } else if (partnerType == 'Đơn vị fix lỗi') {
                        CacheHelper.cacheFixer(newPartnerId, newPartnerName);
                      }
                      // Note: Đơn vị vận chuyển không cần cache
                      
                      await loadPartnerNames(partnerType!);
                      if (mounted) {
                        setState(() => partnerName = name);
                      }
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

    try {
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

      if (partnerType != null && partnerName != null) {
        final table = getTable(partnerType!);
        if ((partnerType == 'Khách hàng' || partnerType == 'Nhà cung cấp' || partnerType == 'Đơn vị fix lỗi') && partnerId != null) {
          final partnerData =
              await widget.tenantClient
                  .from(table)
                  .select()
                  .eq('id', partnerId!)
                  .single();
          snapshotData[table] = partnerData;
        } else {
          final partnerData =
              await widget.tenantClient
                  .from(table)
                  .select()
                  .eq('name', partnerName!)
                  .single();
          snapshotData[table] = partnerData;
        }
      }
    } catch (e) {
      print('Error creating snapshot: $e');
    }

    return snapshotData;
  }

  Future<void> submit() async {
    if (isProcessing) return;
    
    if (!_formKey.currentState!.validate()) return;
    if (partnerType == null ||
        partnerName == null ||
        currency == null ||
        account == null ||
        amount == null ||
        amount! <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vui lòng điền đầy đủ thông tin hợp lệ')),
      );
      return;
    }

    final accData =
        await widget.tenantClient
            .from('financial_accounts')
            .select('balance')
            .eq('name', account!)
            .eq('currency', currency!)
            .maybeSingle();

    final balance = accData?['balance'] as num? ?? 0;

    final table = getTable(partnerType!);
    String debtColumn;
    Map<String, dynamic> partnerData;
    
    // ✅ Transporters chỉ có cột 'debt', không có debt_vnd/debt_cny/debt_usd
    if (partnerType == 'Đơn vị vận chuyển') {
      partnerData = await widget.tenantClient
          .from(table)
          .select('debt')
          .eq('name', partnerName!)
          .single();
      debtColumn = 'debt';
    } else {
      // ✅ Các loại đối tác khác có debt_vnd, debt_cny, debt_usd
      partnerData = (partnerType == 'Khách hàng' || partnerType == 'Nhà cung cấp' || partnerType == 'Đơn vị fix lỗi') && partnerId != null
          ? await widget.tenantClient
              .from(table)
              .select('debt_vnd, debt_cny, debt_usd')
              .eq('id', partnerId!)
              .single()
          : await widget.tenantClient
              .from(table)
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Loại tiền tệ không được hỗ trợ: $currency')),
        );
        return;
      }
    }

    final currentDebt =
        double.tryParse(partnerData[debtColumn]?.toString() ?? '0') ?? 0;
    final isCustomer = partnerType == 'Khách hàng';
    final newDebt = isCustomer ? currentDebt - amount! : currentDebt + amount!;

    showDialog(
      context: context,
      builder:
          (_) => AlertDialog(
            title: const Text('Xác nhận thu tiền đối tác'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Loại đối tác: ${partnerType ?? "Không xác định"}'),
                Text('Tên đối tác: ${partnerName ?? "Không xác định"}'),
                Text(
                  'Số tiền: ${formatNumberLocal(amount!)} ${currency ?? "Không xác định"}',
                ),
                Text('Tài khoản: ${account ?? "Không xác định"}'),
                Text('Ghi chú: ${note ?? "Không có"}'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Sửa'),
              ),
              ElevatedButton(
                onPressed: () async {
                  Navigator.pop(context);
                  setState(() {
                    isProcessing = true;
                  });
                  try {
                    final now = DateTime.now();
                    final ticketId = uuid.v4();
                    
                    // Calculate debt change: với customers thì trừ công nợ, với các loại khác thì cộng
                    final debtChange = isCustomer ? -amount! : amount!;
                    
                    // Account balance change: cộng vào (thu tiền)
                    final accountBalanceChange = amount!;

                    final snapshotData = await _createSnapshot(ticketId);

                    // ✅ CALL RPC FUNCTION - All operations in ONE atomic transaction
                    final result = await _retry(
                      () => widget.tenantClient.rpc('create_receive_transaction', params: {
                        'p_ticket_id': ticketId,
                        'p_type': 'receive',
                        'p_partner_type': getPartnerTypeForDB(partnerType!),
                        'p_partner_name': partnerName!,
                        'p_partner_id': partnerId,
                        'p_amount': amount!,
                        'p_currency': currency!,
                        'p_account': account!,
                        'p_note': note ?? '',
                        'p_debt_column': debtColumn,
                        'p_debt_change': debtChange,
                        'p_account_balance_change': accountBalanceChange,
                        'p_snapshot_data': snapshotData,
                        'p_created_at': now.toIso8601String(),
                      }),
                      operation: 'Create receive transaction (RPC)',
                    );

                    // Check result
                    if (result == null || result['success'] != true) {
                      throw Exception('RPC function returned error: ${result?['message'] ?? 'Unknown error'}');
                    }

                    print('✅ Receive transaction created successfully via RPC!');

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
                      134, // Unique ID for this type of notification
                      "Phiếu Thu Tiền Đã Tạo",
                      "Đã tạo phiếu thu tiền cho $partnerName với số tiền ${formatNumberLocal(amount!)} $currency",
                      'receive_created',
                    );
                    
                    // ✅ Gửi thông báo push đến tất cả thiết bị
                    await NotificationService.sendNotificationToAll(
                      "Phiếu Thu Tiền Đã Tạo",
                      "Đã tạo phiếu thu tiền cho $partnerName với số tiền ${formatNumberLocal(amount!)} $currency",
                      data: {'type': 'receive_created'},
                    );
                    
                    // ✅ Gửi thông báo Telegram với thông tin chi tiết
                    await NotificationService.sendTransactionToTelegram(
                      transactionType: 'receive',
                      type: 'Phiếu Thu',
                      ticketId: ticketId,
                      partnerType: getPartnerTypeForDB(partnerType!),
                      partnerName: partnerName,
                      totalAmount: formatNumberLocal(amount!),
                      currency: currency,
                      account: account,
                      finalBalance: finalBalanceStr,
                      note: note,
                    );

                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Tạo phiếu thu thành công')),
                    );

                    if (mounted) {
                      setState(() {
                        partnerType = null;
                        partnerName = null;
                        amount = null;
                        amountController.text = '';
                        currency =
                            currencies.isNotEmpty ? currencies.first : null;
                        account = null;
                        note = null;
                        this.partnerData = <Map<String, dynamic>>[];
                        isProcessing = false;
                        loadAccounts();
                      });
                    }

                    Navigator.pop(context);
                  } catch (e) {
                    if (mounted) {
                      setState(() {
                        isProcessing = false;
                      });
                    }
                    await ErrorHandler.showErrorDialog(
                      context: context,
                      title: 'Lỗi tạo phiếu thu',
                      error: e,
                      showRetry: false,
                    );
                  }
                },
                child: const Text('Tạo phiếu'),
              ),
            ],
          ),
    );
  }

  String getTable(String type) {
    if (type == 'Khách hàng') return 'customers';
    if (type == 'Nhà cung cấp') return 'suppliers';
    if (type == 'Đơn vị fix lỗi') return 'fix_units';
    return 'transporters';
  }

  String getPartnerTypeForDB(String type) {
    if (type == 'Khách hàng') return 'customers';
    if (type == 'Nhà cung cấp') return 'suppliers';
    if (type == 'Đơn vị fix lỗi') return 'fix_units';
    return 'transporters';
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
        if (details.primaryVelocity! > 0) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: Colors.white),
          title: const Text(
            'Thu tiền đối tác',
            style: TextStyle(color: Colors.white),
          ),
        ),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _formKey,
            child: ListView(
              children: [
                wrapField(
                  DropdownButtonFormField(
                    value: partnerType,
                    decoration: const InputDecoration(
                      labelText: 'Loại đối tác',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    items:
                        partnerTypes
                            .map(
                              (e) => DropdownMenuItem(value: e, child: Text(e)),
                            )
                            .toList(),
                    onChanged: (val) {
                      if (mounted) {
                        setState(() {
                          partnerType = val;
                          partnerName = null;
                          partnerId = null;
                          currentDebt = null;
                          // ✅ Nếu là Đơn vị vận chuyển, mặc định currency = 'VND'
                          if (val == 'Đơn vị vận chuyển') {
                            currency = 'VND';
                          } else if (val == 'Khách hàng') {
                            // ✅ Nếu là Khách hàng, mặc định currency = 'VND' (nếu có trong danh sách)
                            if (currencies.contains('VND')) {
                              currency = 'VND';
                            }
                          }
                          loadPartnerNames(val!);
                        });
                        // ✅ Load accounts sau khi set currency
                        if (val == 'Đơn vị vận chuyển' || val == 'Khách hàng') {
                          loadAccounts();
                        }
                      }
                    },
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
                                if (mounted) {
                                  setState(() {
                                    partnerName = val['name'] as String;
                                    if (partnerType == 'Khách hàng' || partnerType == 'Nhà cung cấp' || partnerType == 'Đơn vị fix lỗi') {
                                      partnerId = val['id'] as String?;
                                    } else {
                                      partnerId = null;
                                    }
                                  });
                                  await loadCurrentDebt();
                                }
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
                            onPressed:
                                partnerType != null ? addPartnerDialog : null,
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
                                        if (partnerType == 'Đơn vị vận chuyển') {
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
                    decoration: const InputDecoration(
                      labelText: 'Số tiền',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    onChanged: (val) {
                      final raw = val.replaceAll('.', '');
                      amount = double.tryParse(raw);
                      if (mounted) {
                        setState(() {});
                      }
                    },
                    validator: (val) {
                      if (val == null ||
                          val.isEmpty ||
                          double.tryParse(val.replaceAll('.', '')) == null ||
                          double.parse(val.replaceAll('.', '')) <= 0) {
                        return 'Vui lòng nhập số tiền hợp lệ';
                      }
                      return null;
                    },
                  ),
                ),
                wrapField(
                  DropdownButtonFormField(
                    value: currency,
                    decoration: const InputDecoration(
                      labelText: 'Đơn vị tiền tệ',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    items:
                        currencies
                            .map(
                              (e) => DropdownMenuItem(value: e, child: Text(e)),
                            )
                            .toList(),
                    onChanged: partnerType == 'Đơn vị vận chuyển'
                        ? null // ✅ Disable khi là Đơn vị vận chuyển
                        : (val) {
                      if (mounted) {
                        setState(() {
                          currency = val as String?;
                          loadAccounts();
                        });
                      }
                    },
                  ),
                ),
                wrapField(
                  DropdownButtonFormField(
                    value: account,
                    decoration: const InputDecoration(
                      labelText: 'Tài khoản',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    items:
                        accounts
                            .map(
                              (e) => DropdownMenuItem(value: e, child: Text(e)),
                            )
                            .toList(),
                    onChanged: (val) {
                      if (mounted) {
                        setState(() => account = val);
                      }
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
                    onChanged: (val) {
                      if (mounted) {
                        setState(() => note = val);
                      }
                    },
                  ),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: isProcessing ? null : submit,
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
