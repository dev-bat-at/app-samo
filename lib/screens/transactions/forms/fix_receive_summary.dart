import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../notification_service.dart';
import 'fix_receive_form.dart';
import 'dart:math' as math;

// Cache utility class
class CacheUtil {
  static final Map<String, String> productNameCache = {};
  static final Map<String, String> warehouseNameCache = {};

  static void cacheProductName(String id, String name) => productNameCache[id] = name;
  static void cacheWarehouseName(String id, String name) => warehouseNameCache[id] = name;
  static String getProductName(String? id) => id != null ? productNameCache[id] ?? 'Không xác định' : 'Không xác định';
  static String getWarehouseName(String? id) => id != null ? warehouseNameCache[id] ?? 'Không xác định' : 'Không xác định';
}

// Constants for batch processing and limits
const int maxBatchSize = 1000;
const int maxRetries = 3;
const Duration retryDelay = Duration(seconds: 1);
const int maxImeiLimit = 100000;
const int maxTicketItems = 100;
const int displayImeiLimit = 100;

/// Retries a function with exponential backoff
Future<T> retry<T>(Future<T> Function() fn, {String? operation}) async {
  for (int attempt = 0; attempt < maxRetries; attempt++) {
    try {
      return await fn();
    } catch (e) {
      if (attempt == maxRetries - 1) {
        throw Exception('${operation ?? 'Operation'} failed after $maxRetries attempts: $e');
      }
      await Future.delayed(retryDelay * math.pow(2, attempt));
    }
  }
  throw Exception('Retry failed');
}

class FixReceiveSummary extends StatefulWidget {
  final SupabaseClient tenantClient;
  final List<Map<String, dynamic>> ticketItems;
  final String currency;

  const FixReceiveSummary({
    super.key,
    required this.tenantClient,
    required this.ticketItems,
    required this.currency,
  });

  @override
  State<FixReceiveSummary> createState() => _FixReceiveSummaryState();
}

class _FixReceiveSummaryState extends State<FixReceiveSummary> {
  List<Map<String, Object?>> accounts = [];
  List<String> accountNames = [];
  String? account;
  bool isLoading = true;
  bool isProcessing = false;
  String? errorMessage;
  late List<Map<String, dynamic>> ticketItems;

  final NumberFormat numberFormat = NumberFormat.decimalPattern('vi_VN');

  @override
  void initState() {
    super.initState();
    ticketItems = List.from(widget.ticketItems);
    _fetchInitialData();
  }

  Future<void> _fetchInitialData() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      final supabase = widget.tenantClient;

      final accountResponse = await retry(
        () => supabase
            .from('financial_accounts')
            .select('name, currency, balance')
            .eq('currency', widget.currency),
        operation: 'Fetch accounts',
      );
      final accountList = accountResponse
          .map((e) => {
                'name': e['name'] as String?,
                'currency': e['currency'] as String?,
                'balance': e['balance'] as num?,
              })
          .where((e) => e['name'] != null && e['currency'] != null)
          .cast<Map<String, Object?>>()
          .toList();

      if (mounted) {
        setState(() {
          accounts = accountList;
          accountNames = accountList.map((acc) => acc['name'] as String).toList();
          accountNames.add('Công nợ');
          isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          errorMessage = 'Không thể tải dữ liệu từ Supabase: $e';
          isLoading = false;
        });
      }
    }
  }

  double _calculateTotalAmount() {
    return ticketItems.fold(0, (sum, item) => sum + (item['price'] as num) * (item['quantity'] as int));
  }

  Future<Map<String, dynamic>> _createSnapshot(String ticketId, List<String> imeiList) async {
    final supabase = widget.tenantClient;
    final snapshotData = <String, dynamic>{};

    try {
      if (account != null && account != 'Công nợ') {
        final accountData = await retry(
          () => supabase
              .from('financial_accounts')
              .select()
              .eq('name', account!)
              .eq('currency', widget.currency)
              .single(),
          operation: 'Fetch account data',
        );
        snapshotData['financial_accounts'] = accountData;
      }

      if (account == 'Công nợ') {
        final fixerIds = ticketItems.map((item) => item['fixer_id']?.toString()).where((id) => id != null).toSet();
        if (fixerIds.isNotEmpty) {
          final fixerData = await retry(
            () => supabase
                .from('fix_units')
                .select()
                .inFilter('id', fixerIds.toList()),
            operation: 'Fetch fixer data',
          );
          snapshotData['fix_units'] = fixerData;
        }
      }

      if (imeiList.isNotEmpty) {
        List<Map<String, dynamic>> productsData = [];
        for (int i = 0; i < imeiList.length; i += maxBatchSize) {
          final batchImeis = imeiList.sublist(i, math.min(i + maxBatchSize, imeiList.length));
          final response = await retry(
            () => supabase.from('products').select('imei, product_id, warehouse_id, status, fix_price, cost_price, fix_unit').inFilter('imei', batchImeis),
            operation: 'Fetch products snapshot batch ${i ~/ maxBatchSize + 1}',
          );
          productsData.addAll(response.cast<Map<String, dynamic>>());
        }
        snapshotData['products'] = productsData;
      }

      snapshotData['fix_receive_orders'] = ticketItems.map((item) {
        return {
          'ticket_id': ticketId,
          'fixer': item['fixer'],
          'fix_unit_id': item['fixer_id'],
          'product_id': item['product_id'],
          'product_name': item['product_name'],
          'warehouse_id': item['warehouse_id'],
          'warehouse_name': item['warehouse_name'],
          'imei': item['imei'],
          'quantity': item['quantity'],
          'price': item['price'],
          'currency': item['currency'],
          'account': account,
        };
      }).toList();

      return snapshotData;
    } catch (e) {
      throw Exception('Failed to create snapshot: $e');
    }
  }

  Future<num> _getExchangeRate(String currency) async {
    try {
      final supabase = widget.tenantClient;
      final response = await retry(
        () => supabase
            .from('financial_orders')
            .select('rate_vnd_cny, rate_vnd_usd')
            .eq('type', 'exchange')
            .order('created_at', ascending: false)
            .limit(1)
            .maybeSingle(),
        operation: 'Fetch exchange rate',
      );

      if (response == null) return 1;

      if (currency == 'CNY' && response['rate_vnd_cny'] != null) {
        final rate = response['rate_vnd_cny'] as num;
        return rate != 0 ? rate : 1;
      } else if (currency == 'USD' && response['rate_vnd_usd'] != null) {
        final rate = response['rate_vnd_usd'] as num;
        return rate != 0 ? rate : 1;
      }
      return 1;
    } catch (e) {
      return 1;
    }
  }

  String generateTicketId() {
    final now = DateTime.now();
    final dateFormat = DateFormat('yyyyMMdd-HHmmss');
    final randomNum = (100 + (now.millisecondsSinceEpoch % 900)).toString();
    return 'FIXRECV-${dateFormat.format(now)}-$randomNum';
  }

  String formatNumberLocal(num value) {
    return NumberFormat('#,###', 'vi_VN').format(value).replaceAll(',', '.');
  }

  Future<bool> _validateImeis(List<String> allImeis) async {
    final supabase = widget.tenantClient;
    List<String> validImeis = [];

    try {
      for (int i = 0; i < allImeis.length; i += maxBatchSize) {
        final batchImeis = allImeis.sublist(i, math.min(i + maxBatchSize, allImeis.length));
        final response = await retry(
          () => supabase
              .from('products')
              .select('imei, product_id, status, fix_unit')
              .inFilter('imei', batchImeis)
              .eq('status', 'Đang sửa'),
          operation: 'Validate IMEIs batch ${i ~/ maxBatchSize + 1}',
        );

        validImeis.addAll(
          response
              .where((p) => ticketItems.any((item) => p['product_id'] == item['product_id'] && p['fix_unit'] == item['fixer']))
              .map((p) => p['imei'] as String),
        );
      }

      final invalidImeis = allImeis.where((imei) => !validImeis.contains(imei)).toList();
      if (invalidImeis.isNotEmpty && mounted) {
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text('Các IMEI sau không hợp lệ, không ở trạng thái "Đang sửa", hoặc không thuộc đơn vị sửa: ${invalidImeis.take(10).join(', ')}${invalidImeis.length > 10 ? '... (tổng cộng ${invalidImeis.length} IMEI)' : ''}'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
        return false;
      }
      return true;
    } catch (e) {
      if (mounted) {
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text('Lỗi khi kiểm tra IMEI: $e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
      }
      return false;
    }
  }

  // ✅ Không cần rollback/verify thủ công nữa khi dùng function Supabase (transaction atomic)

  Future<void> createTicket(BuildContext scaffoldContext) async {
    if (isProcessing) return;
    
    // Set isProcessing ngay để ngăn double-submit
    setState(() {
      isProcessing = true;
    });

    if (account == null) {
      setState(() {
        isProcessing = false;
      });
      if (mounted) {
        await showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Vui lòng chọn tài khoản thanh toán!'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
      }
      return;
    }

    if (ticketItems.isEmpty) {
      setState(() {
        isProcessing = false;
      });
      if (mounted) {
        showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Vui lòng thêm ít nhất một sản phẩm để tạo phiếu!'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
      }
      return;
    }

    if (ticketItems.length > maxTicketItems) {
      setState(() {
        isProcessing = false;
      });
      if (mounted) {
        showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text('Số lượng mục (${ticketItems.length}) vượt quá $maxTicketItems. Vui lòng giảm số mục để tối ưu hiệu suất.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
      }
      return;
    }

    final allImeis = ticketItems.expand((item) => (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty)).toList();
    if (allImeis.length > maxImeiLimit) {
      setState(() {
        isProcessing = false;
      });
      if (mounted) {
        showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text('Số lượng IMEI (${formatNumberLocal(allImeis.length)}) vượt quá $maxImeiLimit. Vui lòng chia thành nhiều phiếu nhỏ hơn.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
      }
      return;
    }

    if (!await _validateImeis(allImeis)) {
      setState(() {
        isProcessing = false;
      });
      return;
    }

    final ticketId = generateTicketId();

    // Create snapshot before any changes
    Map<String, dynamic> snapshot;
    try {
      snapshot = await _createSnapshot(ticketId, allImeis);
    } catch (e) {
      setState(() {
        isProcessing = false;
        errorMessage = 'Lỗi khi tạo snapshot: $e';
      });
      return;
    }

    try {
      final supabase = widget.tenantClient;
      final now = DateTime.now();
      final totalAmount = _calculateTotalAmount();

      final exchangeRate = await _getExchangeRate(widget.currency);
      if (exchangeRate == 1 && widget.currency != 'VND') {
        throw Exception('Vui lòng tạo phiếu đổi tiền để cập nhật tỷ giá cho ${widget.currency}.');
      }

      if (account != 'Công nợ') {
        final selectedAccount = accounts.firstWhere((acc) => acc['name'] == account);
        final currentBalance = selectedAccount['balance'] as num? ?? 0;
        if (currentBalance < totalAmount) {
          throw Exception('Tài khoản không đủ số dư để thanh toán!');
        }
      }

      // Hiển thị loading trong lúc tạo phiếu để tránh người dùng nghĩ app bị treo
      showDialog(
        context: scaffoldContext,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          content: Row(
            children: const [
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 16),
              Expanded(child: Text('Đang tạo phiếu...')),
            ],
          ),
        ),
      );

      // Chuẩn bị dữ liệu fix_receive_orders (như cũ)
      final fixReceiveOrders = ticketItems.map((item) {
        return {
          'ticket_id': ticketId,
          'fixer': item['fixer'],
          'fix_unit_id': item['fixer_id'],
          'product_id': item['product_id'],
          'warehouse_id': item['warehouse_id'],
          'imei': item['imei'],
          'quantity': item['quantity'],
          'price': item['price'],
          'currency': item['currency'],
          'account': account,
          'created_at': now.toIso8601String(),
          'iscancelled': false,
        };
      }).toList();

      // Gọi Supabase RPC - toàn bộ insert/update/rollback do DB xử lý atomic
      await retry(
        () => supabase.rpc(
          'create_fix_receive_transaction',
          params: {
            'p_ticket_id': ticketId,
            'p_fix_receive_orders': fixReceiveOrders,
            'p_account': account,
            'p_currency': widget.currency,
            'p_snapshot_data': snapshot,
            'p_created_at': now.toIso8601String(),
          },
        ),
        operation: 'Create fix_receive_transaction',
      );

      // Lấy số dư cuối từ tài khoản (nếu không phải Công nợ)
      String? finalBalanceStr;
      if (account != null && account != 'Công nợ') {
        try {
          final accountData = await supabase
              .from('financial_accounts')
              .select('balance')
              .eq('name', account!)
              .eq('currency', widget.currency)
              .maybeSingle();
          if (accountData != null) {
            final balance = (accountData['balance'] as num?)?.toDouble() ?? 0.0;
            finalBalanceStr = formatNumberLocal(balance);
          }
        } catch (e) {
          print('⚠️ Không thể lấy số dư cuối: $e');
        }
      }
      
      // Lấy thông tin sản phẩm, IMEI và tính tổng tiền
      final firstItem = ticketItems.isNotEmpty ? ticketItems.first : null;
      final productName = firstItem != null ? (firstItem['product_name'] as String? ?? 'Không xác định') : 'Không xác định';
      final fixerName = firstItem != null ? (firstItem['fixer'] as String? ?? 'Không xác định') : 'Không xác định';
      final imeiList = ticketItems
          .map((item) => item['imei'] as String)
          .join(', ');
      final totalQuantity = ticketItems.fold<int>(0, (sum, item) => sum + (item['quantity'] as int? ?? 1));
      final calculatedTotalAmount = _calculateTotalAmount();
      
      await NotificationService.showNotification(
        130,
        'Phiếu Nhận Hàng Đã Tạo',
        'Đã tạo phiếu nhận hàng sửa về kho',
        'fix_receive_created',
      );
      
      // ✅ Gửi thông báo push đến tất cả thiết bị
      await NotificationService.sendNotificationToAll(
        'Phiếu Nhận Hàng Đã Tạo',
        'Đã tạo phiếu nhận hàng sửa về kho',
        data: {'type': 'fix_receive_created'},
      );
      
      // ✅ Gửi thông báo Telegram với thông tin chi tiết
      await NotificationService.sendTransactionToTelegram(
        transactionType: 'fix_receive',
        type: 'Phiếu Nhận Sửa',
        ticketId: ticketId,
        partnerType: 'fix_units',
        partnerName: fixerName,
        productName: productName,
        quantity: totalQuantity,
        imeiList: imeiList,
        totalAmount: formatNumberLocal(calculatedTotalAmount),
        currency: widget.currency,
        paymentMethod: account ?? 'Công nợ',
        account: account != 'Công nợ' ? account : null,
        finalBalance: finalBalanceStr,
      );

      if (mounted) {
        // Đóng loading trước khi hiển thị thông báo thành công
        if (Navigator.of(scaffoldContext, rootNavigator: true).canPop()) {
          Navigator.of(scaffoldContext, rootNavigator: true).pop();
        }
        setState(() {
          isProcessing = false;
        });
        await showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Đã tạo phiếu nhận sửa thành công'),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.pop(context);
                },
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        // Đóng loading trước khi hiển thị lỗi
        if (Navigator.of(scaffoldContext, rootNavigator: true).canPop()) {
          Navigator.of(scaffoldContext, rootNavigator: true).pop();
        }
        setState(() {
          isProcessing = false;
          errorMessage = e.toString();
        });
      }
    }
  }

  Widget wrapField(Widget child) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      margin: const EdgeInsets.symmetric(vertical: 4),
      height: 48,
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(8),
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
                onPressed: _fetchInitialData,
                child: const Text('Thử lại'),
              ),
            ],
          ),
        ),
      );
    }

    final totalAmount = _calculateTotalAmount();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Danh sách sản phẩm nhận sửa', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        leading: IconButton(
          icon: Transform.rotate(
            angle: math.pi,
            child: const Icon(Icons.arrow_forward_ios, color: Colors.white),
          ),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Danh sách sản phẩm đã thêm:',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 300,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ListView.builder(
                      itemCount: ticketItems.length,
                      itemBuilder: (context, index) {
                        final item = ticketItems[index];
                        final imeiList = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).toList();
                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                          child: Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('Đơn vị sửa: ${item['fixer'] ?? 'Không xác định'}'),
                                      Text('Sản phẩm: ${item['product_name'] ?? 'Không xác định'}'),
                                      Text('Kho nhận: ${item['warehouse_name'] ?? 'Không xác định'}'),
                                      Text('Số lượng IMEI: ${formatNumberLocal(item['quantity'])}'),
                                      Text('Chi phí mỗi sản phẩm: ${formatNumberLocal(item['price'])} ${item['currency']}'),
                                      if (imeiList.length <= displayImeiLimit) ...[
                                        Text('IMEI:'),
                                        ...imeiList.map((imei) => Text('- $imei')),
                                      ] else
                                        Text('IMEI: ${imeiList.take(displayImeiLimit).join(', ')}... và ${formatNumberLocal(imeiList.length - displayImeiLimit)} IMEI khác'),
                                    ],
                                  ),
                                ),
                                Column(
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.edit, color: Colors.blue, size: 20),
                                      onPressed: () {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (context) => FixReceiveForm(
                                              tenantClient: widget.tenantClient,
                                              initialProductId: item['product_id'] as String?,
                                              initialPrice: (item['price'] ?? 0).toString(),
                                              initialImei: item['imei'] as String?,
                                              initialCurrency: item['currency'] as String?,
                                              initialWarehouseId: item['warehouse_id'] as String?,
                                              ticketItems: ticketItems,
                                              editIndex: index,
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete, color: Colors.red, size: 20),
                                      onPressed: () {
                                        if (mounted) {
                                          setState(() {
                                            ticketItems.removeAt(index);
                                          });
                                        }
                                      },
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Tổng tiền: ${formatNumberLocal(totalAmount)} ${widget.currency}',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  wrapField(
                    DropdownButtonFormField<String>(
                      value: account,
                      items: accountNames.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                      hint: const Text('Tài khoản'),
                      onChanged: (val) {
                        setState(() {
                          account = val;
                        });
                      },
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => FixReceiveForm(
                            tenantClient: widget.tenantClient,
                            ticketItems: ticketItems,
                            initialCurrency: widget.currency,
                            initialWarehouseId: ticketItems.isNotEmpty ? ticketItems.last['warehouse_id'] as String? : null,
                          ),
                        ),
                      );
                    },
                    child: const Text('Thêm Sản Phẩm'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: isProcessing ? null : () => createTicket(context),
                    child: const Text('Tạo Phiếu'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}