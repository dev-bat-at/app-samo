import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'dart:developer' as developer;
import '../../notification_service.dart';
import 'sale_form.dart';
import 'dart:math' as math;

// Constants for batch processing
const int maxBatchSize = 1000;
const int maxRetries = 3;
const Duration retryDelay = Duration(seconds: 1);

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

class SaleSummary extends StatefulWidget {
  final SupabaseClient tenantClient;
  final String customerId;
  final String customerName;
  final List<Map<String, dynamic>> ticketItems;
  final String salesman;
  final String currency;

  const SaleSummary({
    super.key,
    required this.tenantClient,
    required this.customerId,
    required this.customerName,
    required this.ticketItems,
    required this.salesman,
    required this.currency,
  });

  @override
  State<SaleSummary> createState() => _SaleSummaryState();
}

class _SaleSummaryState extends State<SaleSummary> {
  List<Map<String, Object?>> accounts = [];
  List<String> accountNames = [];
  List<String> localTransporters = [];
  String? account;
  String? transporter;
  String? deposit;
  double codAmount = 0;
  double customerDebt = 0;
  bool isLoading = true;
  bool isProcessing = false;
  String? errorMessage;
  String? depositError;

  final TextEditingController depositController = TextEditingController();
  final NumberFormat numberFormat = NumberFormat.decimalPattern('vi_VN');

  @override
  void initState() {
    super.initState();
    _fetchInitialData();
  }

  @override
  void dispose() {
    depositController.dispose();
    super.dispose();
  }

  Future<void> _fetchInitialData() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      final supabase = widget.tenantClient;

      final accountResponse = await retry(
        () => supabase.from('financial_accounts').select('id, name, currency, balance').eq('currency', widget.currency),
        operation: 'Fetch financial accounts',
      );
      final accountList = (accountResponse as List<dynamic>)
          .map((e) => {
                'id': e['id'] as int,
                'name': e['name'] as String?,
                'currency': e['currency'] as String?,
                'balance': e['balance'] as num?,
              })
          .where((e) => e['name'] != null && e['currency'] != null)
          .cast<Map<String, Object?>>()
          .toList();

      final transporterResponse = await retry(
        () => supabase.from('transporters').select('name').eq('type', 'vận chuyển nội địa'),
        operation: 'Fetch transporters',
      );
      final transporterList = (transporterResponse as List<dynamic>).map((e) => e['name'] as String?).whereType<String>().toList();

      final customerResponse = await retry(
        () => supabase.from('customers').select('debt_vnd').eq('id', widget.customerId).single(),
        operation: 'Fetch customer debt',
      );
      final debt = double.tryParse(customerResponse['debt_vnd'].toString()) ?? 0;

      if (mounted) {
        setState(() {
          accounts = accountList;
          localTransporters = transporterList;
          customerDebt = debt < 0 ? -debt : 0;
          accountNames = accountList.map((acc) => acc['name'] as String).toList();
          accountNames.add('Công nợ');
          accountNames.add('Ship COD');
          isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          errorMessage = 'Không thể tải dữ liệu: $e';
          isLoading = false;
        });
      }
    }
  }

  double _calculateTotalAmount() {
    return widget.ticketItems.fold(0, (sum, item) {
      final imeiCount = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).length;
      return sum + (item['price'] as double) * imeiCount;
    });
  }

  int _calculateTotalImeiCount() {
    return widget.ticketItems.fold(0, (sum, item) {
      return sum + (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).length;
    });
  }

  String _getFirstProductName() {
    return widget.ticketItems.isNotEmpty ? widget.ticketItems.first['product_name'] as String : 'Không xác định';
  }

  Future<Map<String, dynamic>> _createSnapshot(String ticketId, List<String> imeiList) async {
    final supabase = widget.tenantClient;
    final snapshotData = <String, dynamic>{};

    try {
      final customerData = await retry(
        () => supabase.from('customers').select().eq('id', widget.customerId).single(),
        operation: 'Fetch customer for snapshot',
      );
      snapshotData['customers'] = customerData;

      if (account == 'Ship COD' && transporter != null) {
        final transporterData = await retry(
          () => supabase.from('transporters').select().eq('name', transporter!).single(),
          operation: 'Fetch transporter for snapshot',
        );
        snapshotData['transporters'] = transporterData;
      }

      if (account != null && account != 'Công nợ' && account != 'Ship COD') {
        final accountData = await retry(
          () => supabase.from('financial_accounts').select().eq('name', account!).eq('currency', widget.currency).single(),
          operation: 'Fetch financial account for snapshot',
        );
        snapshotData['financial_accounts'] = accountData;
      }

      if (imeiList.isNotEmpty) {
        final response = await retry(
          () => supabase.from('products').select('*, saleman').inFilter('imei', imeiList),
          operation: 'Fetch products for snapshot',
        );
        snapshotData['products'] = response as List<dynamic>;
      }

      snapshotData['sale_orders'] = widget.ticketItems.map((item) {
        final imeiList = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).toList();
        return {
          'ticket_id': ticketId,
          'customer_id': widget.customerId,
          'customer': widget.customerName,
          'product_id': item['product_id'],
          'product_name': item['product_name'],
          'imei': item['imei'],
          'quantity': imeiList.length,
          'price': item['price'],
          'currency': item['currency'],
          'account': account,
          'note': item['note'],
          'doanhso': item['doanhso'] ?? 0,
        };
      }).toList();

      // ✅ Lưu snapshot của sub_accounts.doanhso TRƯỚC KHI cộng thêm doanhso mới
      if (widget.salesman.isNotEmpty) {
        try {
          final salesmanAccount = await retry(
            () => supabase
                .from('sub_accounts')
                .select('id, username, doanhso')
                .eq('username', widget.salesman)
                .maybeSingle(),
            operation: 'Fetch sub_account for snapshot',
          );
          
          if (salesmanAccount != null) {
            snapshotData['sub_accounts'] = {
              'id': salesmanAccount['id'],
              'username': salesmanAccount['username'],
              'doanhso': salesmanAccount['doanhso'] ?? 0,
            };
            developer.log('📸 Snapshot: Saved sub_account doanhso: ${salesmanAccount['doanhso']} for salesman: ${widget.salesman}');
          }
        } catch (e) {
          developer.log('⚠️ WARNING: Failed to fetch sub_account for snapshot: $e');
          // Không throw error, tiếp tục tạo snapshot
        }
      }

      return snapshotData;
    } catch (e) {
      throw Exception('Failed to create snapshot: $e');
    }
  }

  Future<double> _getExchangeRate(String currency) async {
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
        operation: 'Get exchange rate',
      );

      if (response == null) return 1;

      if (currency == 'CNY' && response['rate_vnd_cny'] != null) {
        final rate = double.tryParse(response['rate_vnd_cny'].toString()) ?? 0;
        return rate != 0 ? rate : 1;
      } else if (currency == 'USD' && response['rate_vnd_usd'] != null) {
        final rate = double.tryParse(response['rate_vnd_usd'].toString()) ?? 0;
        return rate != 0 ? rate : 1;
      }
      return 1;
    } catch (e) {
      print('Error getting exchange rate: $e');
      return 1;
    }
  }

  String generateTicketId() {
    final now = DateTime.now();
    final dateFormat = DateFormat('yyyyMMdd-HHmmss');
    final randomNum = (100 + (now.millisecondsSinceEpoch % 900)).toString();
    return 'SALE-${dateFormat.format(now)}-$randomNum';
  }

  String formatNumberLocal(num value) {
    return NumberFormat('#,###', 'vi_VN').format(value).replaceAll(',', '.');
  }

  // ⚠️ OLD CODE - Kept for reference (now handled by RPC auto-rollback)
  // ignore: unused_element
  Future<void> _rollbackChanges(Map<String, dynamic> snapshot, String ticketId) async {
    final supabase = widget.tenantClient;

    try {
      if (snapshot.containsKey('customers') && snapshot['customers'] != null) {
        try {
          await retry(
            () => supabase.from('customers').update(snapshot['customers']).eq('id', widget.customerId),
            operation: 'Rollback customers',
          );
        } catch (e) {
          print('Rollback customers failed: $e');
        }
      }

      if (snapshot.containsKey('transporters') && snapshot['transporters'] != null && transporter != null) {
        try {
          await retry(
            () => supabase.from('transporters').update(snapshot['transporters']).eq('name', transporter!),
            operation: 'Rollback transporters',
          );
        } catch (e) {
          print('Rollback transporters failed: $e');
        }
      }

      if (snapshot.containsKey('financial_accounts') && snapshot['financial_accounts'] != null && account != null) {
        try {
          await retry(
            () => supabase
                .from('financial_accounts')
                .update(snapshot['financial_accounts'])
                .eq('name', account!)
                .eq('currency', widget.currency),
            operation: 'Rollback financial accounts',
          );
        } catch (e) {
          print('Rollback financial accounts failed: $e');
        }
      }

      if (snapshot.containsKey('products') && snapshot['products'] != null) {
        for (var product in snapshot['products'] as List<dynamic>) {
          try {
            await retry(
              () => supabase.from('products').update(product).eq('imei', product['imei']),
              operation: 'Rollback product ${product['imei']}',
            );
          } catch (e) {
            print('Rollback product ${product['imei']} failed: $e');
          }
        }
      }

      try {
        await retry(
          () => supabase.from('sale_orders').delete().eq('ticket_id', ticketId),
          operation: 'Delete sale orders',
        );
      } catch (e) {
        print('Delete sale orders failed: $e');
      }

      try {
        await retry(
          () => supabase.from('snapshots').delete().eq('ticket_id', ticketId),
          operation: 'Delete snapshot',
        );
      } catch (e) {
        print('Delete snapshot failed: $e');
      }
    } catch (e) {
      print('Error during rollback: $e');
      throw Exception('Lỗi khi rollback dữ liệu: $e');
    }
  }

  // ⚠️ OLD CODE - Kept for reference (now handled by RPC)
  // ignore: unused_element
  Future<bool> _verifyData(
    String ticketId,
    List<String> allImeis,
    double totalAmount,
    double depositValue,
    double codAmount,
    Map<String, dynamic> snapshotData,
    double customerPricePerImei,
    Map<String, double> transporterPricePerImei,
  ) async {
    try {
      final supabase = widget.tenantClient;

      final saleOrders = await retry(
        () => supabase.from('sale_orders').select().eq('ticket_id', ticketId),
        operation: 'Verify sale orders',
      );

      if ((saleOrders as List<dynamic>).isEmpty) {
        print('No sale orders found for ticket $ticketId');
        return false;
      }

      final productsData = await retry(
        () => supabase
            .from('products')
            .select('imei, status, saleman, sale_price, customer_price, transporter_price, profit, customer')
            .inFilter('imei', allImeis),
        operation: 'Verify products',
      );

      for (var product in productsData as List<dynamic>) {
        if (product['status'] != 'Đã bán' || 
            product['saleman'] != widget.salesman ||
            product['customer'] != widget.customerName) {
          print('Product ${product['imei']} not properly updated: status=${product['status']}, saleman=${product['saleman']}, customer=${product['customer']}');
          return false;
        }

        if (account == 'Ship COD') {
          final customerPrice = double.tryParse(product['customer_price'].toString()) ?? 0;
          final transporterPrice = double.tryParse(product['transporter_price'].toString()) ?? 0;
          final expectedTransporterPrice = transporterPricePerImei[product['imei']] ?? 0;

          if ((customerPrice - customerPricePerImei).abs() > 0.01 || (transporterPrice - expectedTransporterPrice).abs() > 0.01) {
            print(
                'Product ${product['imei']} COD prices mismatch: customer_price=$customerPrice (expected $customerPricePerImei), transporter_price=$transporterPrice (expected $expectedTransporterPrice)');
            return false;
          }
        }
      }

      if (account == 'Công nợ') {
        final customerData = await retry(
          () => supabase.from('customers').select('debt_vnd, debt_cny, debt_usd').eq('id', widget.customerId).single(),
          operation: 'Verify customer debt',
        );

        final debtColumn = 'debt_${widget.currency.toLowerCase()}';
        final snapshotDebt = double.tryParse(snapshotData['customers'][debtColumn].toString()) ?? 0;
        final currentDebt = double.tryParse(customerData[debtColumn].toString()) ?? 0;

        if ((currentDebt - (snapshotDebt + totalAmount)).abs() > 0.01) {
          print('Customer debt mismatch for $debtColumn: current=$currentDebt, snapshot=$snapshotDebt, total=$totalAmount');
          return false;
        }
      } else if (account == 'Ship COD') {
        final customerData = await retry(
          () => supabase.from('customers').select('debt_vnd').eq('id', widget.customerId).single(),
          operation: 'Verify customer COD debt',
        );

        final snapshotDebtVnd = double.tryParse(snapshotData['customers']['debt_vnd'].toString()) ?? 0;
        final currentDebtVnd = double.tryParse(customerData['debt_vnd'].toString()) ?? 0;

        if ((currentDebtVnd - (snapshotDebtVnd + depositValue)).abs() > 0.01) {
          print('Customer VND debt mismatch for COD: current=$currentDebtVnd, snapshot=$snapshotDebtVnd, deposit=$depositValue');
          return false;
        }

        final transporterData = await retry(
          () => supabase.from('transporters').select('debt').eq('name', transporter!).single(),
          operation: 'Verify transporter debt',
        );

        final snapshotTransporterDebt = double.tryParse(snapshotData['transporters']['debt'].toString()) ?? 0;
        final currentTransporterDebt = double.tryParse(transporterData['debt'].toString()) ?? 0;

        if ((currentTransporterDebt - (snapshotTransporterDebt - codAmount)).abs() > 0.01) {
          print('Transporter debt mismatch: current=$currentTransporterDebt, snapshot=$snapshotTransporterDebt, cod=$codAmount');
          return false;
        }
      } else if (account != null) {
        final accountData = await retry(
          () => supabase.from('financial_accounts').select('balance').eq('name', account!).eq('currency', widget.currency).single(),
          operation: 'Verify account balance',
        );

        final snapshotBalance = double.tryParse(snapshotData['financial_accounts']['balance'].toString()) ?? 0;
        final currentBalance = double.tryParse(accountData['balance'].toString()) ?? 0;

        if ((currentBalance - (snapshotBalance + totalAmount)).abs() > 0.01) {
          print('Account balance mismatch: current=$currentBalance, snapshot=$snapshotBalance, total=$totalAmount');
          return false;
        }
      }

      return true;
    } catch (e) {
      print('Error during data verification: $e');
      return false;
    }
  }

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
      return;
    }

    if (account == 'Ship COD' && transporter == null) {
      setState(() {
        isProcessing = false;
      });
      await showDialog(
        context: scaffoldContext,
        builder: (context) => AlertDialog(
          title: const Text('Thông báo'),
          content: const Text('Vui lòng chọn đơn vị vận chuyển nội địa khi chọn Ship COD!'),
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

    final imeiMap = <String, String>{};
    List<String> allImeis = [];
    for (var item in widget.ticketItems) {
      final imeiList = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).toList();
      for (var imei in imeiList) {
        if (imeiMap.containsKey(imei)) {
          setState(() {
            isProcessing = false;
          });
          await showDialog(
            context: scaffoldContext,
            builder: (context) => AlertDialog(
              title: const Text('Thông báo'),
              content: Text('IMEI "$imei" xuất hiện trong nhiều sản phẩm (ID: ${imeiMap[imei]} và ${item['product_id']}). Mỗi IMEI chỉ được phép thuộc một sản phẩm!'),
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
        imeiMap[imei] = item['product_id'] as String;
      }
      allImeis.addAll(imeiList);
    }

    if (allImeis.any((imei) => imei.trim().isEmpty)) {
      setState(() {
        isProcessing = false;
      });
      await showDialog(
        context: scaffoldContext,
        builder: (context) => AlertDialog(
          title: const Text('Thông báo'),
          content: const Text('Danh sách IMEI chứa giá trị không hợp lệ (rỗng hoặc khoảng trắng)!'),
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

    final totalAmount = _calculateTotalAmount();
    final totalImeiCount = _calculateTotalImeiCount();
    final firstProductName = _getFirstProductName();
    final depositValue = double.tryParse(deposit?.replaceAll('.', '') ?? '0') ?? 0;
    final codAmount = totalAmount - depositValue;

    if (account == 'Ship COD') {
      if (depositValue > customerDebt) {
        setState(() {
          isProcessing = false;
        });
        await showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Tiền cọc không được lớn hơn số tiền khách dư!'),
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
    }

    final supabase = widget.tenantClient;

    if (allImeis.isNotEmpty) {
      try {
        final response = await retry(
          () => supabase.from('products').select('imei, product_id, status').inFilter('imei', allImeis).eq('status', 'Tồn kho'),
          operation: 'Validate IMEIs',
        );

        final validImeis =
            (response as List<dynamic>).where((p) => widget.ticketItems.any((item) => item['product_id'] == p['product_id'])).map((p) => p['imei'] as String).toList();

        final invalidImeis = allImeis.where((imei) => !validImeis.contains(imei)).toList();
        if (invalidImeis.isNotEmpty) {
          setState(() {
            isProcessing = false;
          });
          await showDialog(
            context: scaffoldContext,
            builder: (context) => AlertDialog(
              title: const Text('Thông báo'),
              content: Text(
                  'Các IMEI sau không tồn tại, không thuộc sản phẩm đã chọn, hoặc không ở trạng thái Tồn kho: ${invalidImeis.take(10).join(', ')}${invalidImeis.length > 10 ? '...' : ''}'),
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
      } catch (e) {
        setState(() {
          isProcessing = false;
        });
        await showDialog(
          context: scaffoldContext,
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
        return;
      }
    }

    try {
      final now = DateTime.now();
      final ticketId = generateTicketId();

      final exchangeRate = await _getExchangeRate(widget.currency);
      if (exchangeRate == 1 && widget.currency != 'VND') {
        throw Exception('Vui lòng tạo phiếu đổi tiền để cập nhật tỉ giá');
      }

      // Fetch products data for cost price calculation
      List<Map<String, dynamic>> productsDataBeforeUpdate = [];
      if (allImeis.isNotEmpty) {
        final response = await retry(
          () => supabase.from('products').select('imei, product_id, cost_price, warehouse_id, warehouse_name').inFilter('imei', allImeis),
          operation: 'Fetch products data',
        );
        productsDataBeforeUpdate = List<Map<String, dynamic>>.from(response);
      }

      // Create snapshot for rollback reference
      final snapshotData = await retry(
        () => _createSnapshot(ticketId, allImeis),
        operation: 'Create snapshot',
      );

      // Calculate prices for Ship COD
      double customerPricePerImei = 0;
      final Map<String, double> transporterPricePerImei = {};
      if (account == 'Ship COD') {
        customerPricePerImei = totalImeiCount > 0 ? depositValue / totalImeiCount : 0;
        for (var item in widget.ticketItems) {
          final imeiList = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).toList();
          final itemPrice = item['price'] as double;
          for (var imei in imeiList) {
            transporterPricePerImei[imei] = itemPrice - customerPricePerImei;
          }
        }
      }

      // Prepare sale orders data with profit calculation
      final List<Map<String, dynamic>> saleOrdersList = [];
      for (var item in widget.ticketItems) {
        final imeiList = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).toList();
        final imeiCount = imeiList.length;
        final productData = productsDataBeforeUpdate.where((data) => imeiList.contains(data['imei'])).toList();
        final warehouseId = productData.isNotEmpty ? productData.first['warehouse_id'] as String? ?? '' : '';
        
        // Calculate profit for this item
        final salePriceInVND = item['currency'] == 'CNY'
            ? (item['price'] as double) * exchangeRate
            : item['currency'] == 'USD'
                ? (item['price'] as double) * exchangeRate
                : item['price'] as double;
        
        double totalProfit = 0;
        for (var imei in imeiList) {
          final productInfo = productsDataBeforeUpdate.firstWhere(
            (data) => data['imei'] == imei,
            orElse: () => {'cost_price': 0},
          );
          final costPrice = double.tryParse(productInfo['cost_price'].toString()) ?? 0;
          totalProfit += (salePriceInVND - costPrice);
        }
        
        // Tính doanh số: nhân doanh số mỗi sản phẩm với số lượng
        final doanhsoPerProduct = (item['doanhso'] as num?)?.toDouble() ?? 0;
        final totalDoanhsoForItem = doanhsoPerProduct * imeiCount;
        
        // Tính tiền cọc và tiền COD cho item này (chia đều cho tổng số sản phẩm)
        double? itemCustomerPrice;
        double? itemTransporterPrice;
        if (account == 'Ship COD') {
          // Tiền cọc mỗi sản phẩm = tổng tiền cọc / tổng số sản phẩm
          // Tiền COD mỗi sản phẩm = giá sản phẩm - tiền cọc mỗi sản phẩm
          // Trong sale_orders, mỗi loại sản phẩm lưu 1 hàng với quantity, nên phải nhân với số lượng
          final itemPrice = item['price'] as double;
          final customerPricePerProduct = customerPricePerImei; // Tiền cọc mỗi sản phẩm
          final transporterPricePerProduct = itemPrice - customerPricePerImei; // Tiền COD mỗi sản phẩm
          itemCustomerPrice = customerPricePerProduct * imeiCount; // Tổng tiền cọc cho số lượng sản phẩm trong item
          itemTransporterPrice = transporterPricePerProduct * imeiCount; // Tổng tiền COD cho số lượng sản phẩm trong item
        }
        
        saleOrdersList.add({
          'customer_id': widget.customerId,
          'customer': widget.customerName,
          'product_id': item['product_id'],
          'product_name': item['product_name'],
          'warehouse_id': warehouseId,
          'imei': item['imei'],
          'quantity': imeiCount,
          'price': item['price'],
          'currency': item['currency'],
          'account': account,
          'note': item['note'],
          'saleman': widget.salesman,
          'profit': totalProfit,
          'created_at': now.toIso8601String(),
          'iscancelled': false,
          'customer_price': itemCustomerPrice, // Tổng tiền cọc cho số lượng sản phẩm trong item
          'transporter_price': itemTransporterPrice, // Tổng tiền COD cho số lượng sản phẩm trong item
          'transporter': account == 'Ship COD' ? transporter : null,
          'doanhso': totalDoanhsoForItem, // Lưu tổng doanh số (đã nhân với số lượng)
        });
      }

      // Prepare products updates
      final List<Map<String, dynamic>> productsUpdatesList = [];
      for (var item in widget.ticketItems) {
        final imeiList = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).toList();
        final salePriceInVND = item['currency'] == 'CNY'
            ? (item['price'] as double) * exchangeRate
            : item['currency'] == 'USD'
                ? (item['price'] as double) * exchangeRate
                : item['price'] as double;

        for (var imei in imeiList) {
          final productInfo = productsDataBeforeUpdate.firstWhere(
            (data) => data['imei'] == imei,
            orElse: () => {'cost_price': 0},
          );
          final costPrice = double.tryParse(productInfo['cost_price'].toString()) ?? 0;
          
          productsUpdatesList.add({
            'imei': imei,
            'status': 'Đã bán',
            'sale_date': now.toIso8601String(),
            'saleman': widget.salesman,
            'sale_price': salePriceInVND,
            'profit': salePriceInVND - costPrice,
            'customer': widget.customerName,
            'customer_id': int.parse(widget.customerId), // ✅ Lưu customer_id vào products
            'customer_price': account == 'Ship COD' ? customerPricePerImei : null,
            'transporter_price': account == 'Ship COD' ? (transporterPricePerImei[imei] ?? 0) : null,
            'transporter': account == 'Ship COD' ? transporter : null,
          });
        }
      }

      // Calculate total amount (needed for debt changes and account balance)
      final totalAmount = widget.ticketItems.fold<double>(
        0.0,
        (sum, item) {
          final imeiCount = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).length;
          return sum + ((item['price'] as num?)?.toDouble() ?? 0.0) * imeiCount;
        },
      );

      // Prepare customer debt change
      Map<String, dynamic>? customerDebtChange;
      if (account == 'Công nợ') {
        customerDebtChange = {
          'debt_vnd': widget.currency == 'VND' ? totalAmount : 0,
          'debt_cny': widget.currency == 'CNY' ? totalAmount : 0,
          'debt_usd': widget.currency == 'USD' ? totalAmount : 0,
        };
      } else if (account == 'Ship COD') {
        customerDebtChange = {
          'debt_vnd': depositValue,
          'debt_cny': 0,
          'debt_usd': 0,
        };
      }

      // Prepare transporter debt change
      double? transporterDebtChange;
      if (account == 'Ship COD') {
        transporterDebtChange = -codAmount; // Negative because transporter owes us
      }

      // Prepare account balance change
      double? accountBalanceChange;
      if (account != null && account != 'Công nợ' && account != 'Ship COD') {
        accountBalanceChange = totalAmount; // Positive because money comes in
      }

      // Debug: Print data before RPC call
      print('🔍 DEBUG: Calling RPC with data:');
      print('  ticket_id: $ticketId');
      print('  customer_id: ${widget.customerId}');
      print('  sale_orders count: ${saleOrdersList.length}');
      print('  products_updates count: ${productsUpdatesList.length}');
      print('  customer_debt_change: $customerDebtChange');
      print('  transporter_debt_change: $transporterDebtChange');
      print('  account_balance_change: $accountBalanceChange');
      // ✅ Debug: Kiểm tra customer_id, customer_price, transporter_price trong products_updates
      if (productsUpdatesList.isNotEmpty) {
        final firstUpdate = productsUpdatesList.first;
        print('  First product update IMEI: ${firstUpdate['imei']}');
        print('  First product update customer_id: ${firstUpdate['customer_id']}');
        print('  First product update customer_price: ${firstUpdate['customer_price']}');
        print('  First product update transporter_price: ${firstUpdate['transporter_price']}');
        print('  Account: $account');
      }

      // ✅ CALL RPC FUNCTION - All operations in ONE atomic transaction
      final result = await retry(
        () => supabase.rpc('create_sale_transaction', params: {
          'p_ticket_id': ticketId,
          'p_customer_id': widget.customerId,
          'p_customer_name': widget.customerName,
          'p_salesman': widget.salesman,
          'p_account': account ?? '',
          'p_currency': widget.currency,
          'p_transporter': transporter,
          'p_sale_orders': saleOrdersList,
          'p_products_updates': productsUpdatesList,
          'p_customer_debt_change': customerDebtChange,
          'p_transporter_debt_change': transporterDebtChange,
          'p_account_balance_change': accountBalanceChange,
          'p_snapshot_data': snapshotData,
          'p_created_at': now.toIso8601String(),
        }),
        operation: 'Create sale transaction (RPC)',
      );

      // Check result
      if (result == null || result['success'] != true) {
        throw Exception('RPC function returned error: ${result?['message'] ?? 'Unknown error'}');
      }

      print('✅ Sale transaction completed successfully: ${result['ticket_id']}');

      // Wait a bit to ensure RPC transaction is fully committed
      await Future.delayed(const Duration(milliseconds: 500));

      // Update sub_accounts doanhso
      if (widget.salesman.isNotEmpty) {
        try {
          // Calculate total doanhso from all items (nhân với số lượng mỗi item)
          double totalDoanhso = 0;
          for (var item in widget.ticketItems) {
            final doanhsoPerProduct = (item['doanhso'] as num?)?.toDouble() ?? 0;
            // Đếm số lượng IMEI trong item này
            final imeiList = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).toList();
            final quantity = imeiList.length;
            // Nhân doanh số mỗi sản phẩm với số lượng
            final itemDoanhso = doanhsoPerProduct * quantity;
            totalDoanhso += itemDoanhso;
            developer.log('📊 Item doanhso: $doanhsoPerProduct × $quantity = $itemDoanhso');
          }
          
          developer.log('📊 Total doanhso for salesman ${widget.salesman}: $totalDoanhso');
          
          // Update sub_accounts doanhso
          if (totalDoanhso > 0) {
            try {
              developer.log('🔍 Fetching current doanhso for username: ${widget.salesman}');
              final currentAccount = await retry(
                () => supabase
                    .from('sub_accounts')
                    .select('id, username, doanhso')
                    .eq('username', widget.salesman)
                    .maybeSingle(),
                operation: 'Get current doanhso',
              );
              
              if (currentAccount == null) {
                developer.log('❌ ERROR: sub_account not found for username: ${widget.salesman}');
                print('❌ ERROR: sub_account not found for username: ${widget.salesman}');
              } else {
                // Parse current doanhso - có thể là int hoặc double từ DB
                final currentDoanhsoRaw = currentAccount['doanhso'];
                final currentDoanhso = currentDoanhsoRaw is int 
                    ? currentDoanhsoRaw.toDouble()
                    : double.tryParse(currentDoanhsoRaw?.toString() ?? '0') ?? 0;
                
                final newDoanhsoDouble = currentDoanhso + totalDoanhso;
                // Convert to int vì cột doanhso trong sub_accounts là INTEGER
                final newDoanhso = newDoanhsoDouble.round();
                
                developer.log('💰 Current doanhso: $currentDoanhso, Adding: $totalDoanhso, New total: $newDoanhso (int: $newDoanhso)');
                
                await retry(
                  () => supabase
                      .from('sub_accounts')
                      .update({'doanhso': newDoanhso}) // Gửi int thay vì double
                      .eq('username', widget.salesman),
                  operation: 'Update sub_accounts doanhso',
                );
                
                // Verify update succeeded
                await Future.delayed(const Duration(milliseconds: 200)); // Đợi một chút để đảm bảo update commit
                final verifyAccount = await supabase
                    .from('sub_accounts')
                    .select('doanhso')
                    .eq('username', widget.salesman)
                    .maybeSingle();
                
                if (verifyAccount != null) {
                  final verifyDoanhso = int.tryParse(verifyAccount['doanhso']?.toString() ?? '0') ?? 0;
                  if (verifyDoanhso == newDoanhso) {
                    developer.log('✅ Verified: Updated doanhso for salesman ${widget.salesman}: $currentDoanhso + $totalDoanhso = $newDoanhso');
                    print('✅ Verified: Updated doanhso for salesman ${widget.salesman}: $currentDoanhso + $totalDoanhso = $newDoanhso');
                  } else {
                    developer.log('❌ WARNING: Update verification failed. Expected: $newDoanhso, Got: $verifyDoanhso');
                    print('❌ WARNING: Update verification failed. Expected: $newDoanhso, Got: $verifyDoanhso');
                  }
                } else {
                  developer.log('❌ ERROR: Could not verify update - account not found after update');
                  print('❌ ERROR: Could not verify update - account not found after update');
                }
              }
            } catch (e, stackTrace) {
              developer.log('❌ ERROR: Failed to fetch/update sub_accounts doanhso: $e');
              developer.log('❌ Stack trace: $stackTrace');
              print('❌ ERROR: Failed to fetch/update sub_accounts doanhso: $e');
              print('❌ Stack trace: $stackTrace');
            }
          } else {
            developer.log('ℹ️ Skipping doanhso update: totalDoanhso = 0');
          }
        } catch (e, stackTrace) {
          developer.log('❌ ERROR: Failed to calculate/update doanhso: $e');
          developer.log('❌ Stack trace: $stackTrace');
          print('❌ ERROR: Failed to calculate/update doanhso: $e');
          print('❌ Stack trace: $stackTrace');
          // Don't fail the transaction if doanhso update fails
        }
      } else {
        developer.log('⚠️ Skipping doanhso update: salesman is empty');
      }

      // Lấy số dư cuối từ tài khoản (nếu không phải Công nợ hoặc Ship COD)
      String? finalBalanceStr;
      if (account != null && account != 'Công nợ' && account != 'Ship COD') {
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
      
      // Lấy danh sách IMEI (totalAmount đã được tính ở trên)
      final imeiList = widget.ticketItems
          .map((item) => item['imei'] as String)
          .join(', ');

      await NotificationService.showNotification(
        138,
        "Phiếu Bán Hàng Đã Tạo",
        "Đã bán hàng \"$firstProductName\" số lượng ${formatNumberLocal(totalImeiCount)} chiếc",
        'sale_created',
      );
      
      // ✅ Gửi thông báo push đến tất cả thiết bị
      await NotificationService.sendNotificationToAll(
        "Phiếu Bán Hàng Đã Tạo",
        "Đã bán hàng \"$firstProductName\" số lượng ${formatNumberLocal(totalImeiCount)} chiếc",
        data: {'type': 'sale_created'},
      );
      
      // ✅ Gửi thông báo Telegram với thông tin chi tiết
      await NotificationService.sendTransactionToTelegram(
        transactionType: 'sale',
        type: 'Phiếu Bán Hàng',
        ticketId: ticketId,
        customer: widget.customerName,
        productName: firstProductName,
        quantity: totalImeiCount,
        imeiList: imeiList,
        totalAmount: formatNumberLocal(totalAmount),
        currency: widget.currency,
        paymentMethod: account ?? 'Công nợ',
        account: account != 'Công nợ' && account != 'Ship COD' ? account : null,
        finalBalance: finalBalanceStr,
        note: widget.ticketItems.isNotEmpty ? (widget.ticketItems.first['note'] as String?) : null,
      );

      if (mounted) {
        setState(() {
          isProcessing = false;
        });
        ScaffoldMessenger.of(scaffoldContext).showSnackBar(
          SnackBar(
            content: Text(
              'Đã bán hàng "$firstProductName" số lượng ${formatNumberLocal(totalImeiCount)} chiếc',
              style: const TextStyle(color: Colors.white),
            ),
            backgroundColor: Colors.black,
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.all(8),
            duration: const Duration(seconds: 3),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        );
        Navigator.pop(context);
        Navigator.pop(context);
      }
    } catch (e) {
      print('❌ ERROR: $e');
      print('❌ ERROR TYPE: ${e.runtimeType}');
      
      if (mounted) {
        setState(() {
          isProcessing = false;
        });
        
        // Show detailed error for debugging
        String errorMessage = e.toString();
        if (e is PostgrestException) {
          errorMessage = 'PostgrestException:\n'
              'Message: ${e.message}\n'
              'Code: ${e.code}\n'
              'Details: ${e.details}\n'
              'Hint: ${e.hint}';
        }
        
        await showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Lỗi tạo phiếu bán hàng'),
            content: SingleChildScrollView(
              child: SelectableText(
                errorMessage,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
      }
    }
  }

  Widget wrapField(Widget child, {bool isImeiField = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      margin: const EdgeInsets.symmetric(vertical: 4),
      height: isImeiField ? 80 : 40,
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
    final depositValue = double.tryParse(deposit?.replaceAll('.', '') ?? '0') ?? 0;
    codAmount = totalAmount - depositValue;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Danh sách sản phẩm', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Stack(
        children: [
          Column(
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
                          itemCount: widget.ticketItems.length,
                          itemBuilder: (context, index) {
                            final item = widget.ticketItems[index];
                            final imeiCount = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).length;
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
                                          Text('Sản phẩm: ${item['product_name']}'),
                                          Text('Số IMEI: $imeiCount'),
                                          Text('Số tiền: ${formatNumberLocal(item['price'])} ${item['currency']}'),
                                          Text('Ghi chú: ${item['note'] ?? ''}'),
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
                                                builder: (context) => SaleForm(
                                                  tenantClient: widget.tenantClient,
                                                  initialCustomer: widget.customerName,
                                                  initialProductId: item['product_id'] as String,
                                                  initialProductName: item['product_name'] as String,
                                                  initialPrice: (item['price'] as double).toString(),
                                                  initialImei: item['imei'] as String,
                                                  initialNote: item['note'] as String?,
                                                  initialSalesman: widget.salesman,
                                                  initialDoanhso: (item['doanhso'] ?? 0).toString(),
                                                  ticketItems: widget.ticketItems,
                                                  editIndex: index,
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.delete, color: Colors.red, size: 20),
                                          onPressed: () {
                                            setState(() {
                                              widget.ticketItems.removeAt(index);
                                            });
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
                      Text('Nhân viên bán: ${widget.salesman}'),
                      const SizedBox(height: 8),
                      Text('Khách hàng: ${widget.customerName}'),
                      const SizedBox(height: 8),
                      wrapField(
                        DropdownButtonFormField<String>(
                          value: account,
                          items: accountNames.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                          hint: const Text('Tài khoản'),
                          onChanged: (val) {
                            setState(() {
                              account = val;
                              transporter = null;
                              deposit = null;
                              depositController.text = '';
                              codAmount = totalAmount;
                              depositError = null;
                            });
                          },
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            isDense: true,
                          ),
                        ),
                      ),
                      if (account == 'Ship COD') ...[
                        Row(
                          children: [
                            Expanded(
                              child: wrapField(
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text(
                                      'Khách dư',
                                      style: TextStyle(fontSize: 14, color: Colors.black54),
                                    ),
                                    Text(
                                      formatNumberLocal(customerDebt),
                                      style: const TextStyle(fontSize: 14, color: Colors.black),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: wrapField(
                                TextFormField(
                                  controller: depositController,
                                  keyboardType: TextInputType.number,
                                  onChanged: (val) {
                                    final cleanedValue = val.replaceAll(RegExp(r'[^0-9]'), '');
                                    if (cleanedValue.isNotEmpty) {
                                      final parsedValue = double.tryParse(cleanedValue);
                                      if (parsedValue != null) {
                                        final formattedValue = numberFormat.format(parsedValue);
                                        depositController.value = TextEditingValue(
                                          text: formattedValue,
                                          selection: TextSelection.collapsed(offset: formattedValue.length),
                                        );
                                        setState(() {
                                          deposit = cleanedValue;
                                          final depositValue = double.tryParse(deposit!) ?? 0;
                                          if (depositValue > customerDebt) {
                                            depositError = 'Tiền cọc không được lớn hơn khách dư!';
                                          } else if (depositValue < 0) {
                                            depositError = 'Tiền cọc không được nhỏ hơn 0!';
                                          } else {
                                            depositError = null;
                                          }
                                          codAmount = totalAmount - depositValue;
                                        });
                                      }
                                    } else {
                                      setState(() {
                                        deposit = null;
                                        depositError = null;
                                        codAmount = totalAmount;
                                      });
                                    }
                                  },
                                  decoration: InputDecoration(
                                    labelText: 'Tiền cọc',
                                    border: InputBorder.none,
                                    isDense: true,
                                    errorText: depositError,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: wrapField(
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text(
                                      'Tiền COD',
                                      style: TextStyle(fontSize: 14, color: Colors.black54),
                                    ),
                                    Text(
                                      formatNumberLocal(codAmount),
                                      style: const TextStyle(fontSize: 14, color: Colors.black),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: wrapField(
                                DropdownButtonFormField<String>(
                                  value: transporter,
                                  items: localTransporters.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                                  hint: const Text('Đơn vị vận chuyển'),
                                  onChanged: (val) => setState(() => transporter = val),
                                  decoration: const InputDecoration(
                                    border: InputBorder.none,
                                    isDense: true,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
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
                              builder: (context) => SaleForm(
                                tenantClient: widget.tenantClient,
                                initialCustomerId: widget.customerId,
                                initialCustomer: widget.customerName,
                                initialSalesman: widget.salesman,
                                ticketItems: widget.ticketItems,
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
          if (isProcessing)
            Container(
              color: Colors.black.withOpacity(0.5),
              child: const Center(
                child: CircularProgressIndicator(
                  color: Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }
}