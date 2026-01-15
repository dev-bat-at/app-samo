import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../../notification_service.dart';
import 'dart:async';
import 'dart:math' as math;
import '../../text_scanner_screen.dart';

// Cache utility class
class CacheUtil {
  static final Map<String, String> productNameCache = {};
  static final Map<String, String> warehouseNameCache = {};

  static void cacheProductName(String id, String name) => productNameCache[id] = name;
  static void cacheWarehouseName(String id, String name) => warehouseNameCache[id] = name;
  static String getProductName(String? id) => id != null ? productNameCache[id] ?? 'Không xác định' : 'Không xác định';
  static String getWarehouseName(String? id) => id != null ? warehouseNameCache[id] ?? 'Không xác định' : 'Không xác định';
}

// Constants for IMEI handling
const int maxImeiQuantity = 100000;
const int warnImeiQuantity = 10000;
const int batchSize = 1000;
const int displayImeiLimit = 100;
const int maxRetries = 3;
const Duration retryDelay = Duration(seconds: 1);
const int queryLimit = 50;

// Retries a function with exponential backoff
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

class ThousandsFormatterLocal extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    String newText = newValue.text.replaceAll('.', '');
    if (newText.isEmpty) return newValue;
    final doubleValue = double.tryParse(newText);
    if (doubleValue == null) return oldValue;
    final formatted = NumberFormat('#,###', 'vi_VN').format(doubleValue).replaceAll(',', '.');
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

String formatNumberLocal(num value) {
  return NumberFormat('#,###', 'vi_VN').format(value).replaceAll(',', '.');
}

class ReimportForm extends StatefulWidget {
  final SupabaseClient tenantClient;

  const ReimportForm({super.key, required this.tenantClient});

  @override
  State<ReimportForm> createState() => _ReimportFormState();
}

class _ReimportFormState extends State<ReimportForm> {
  // ✅ Luôn là 'Khách Hàng' - không cần dropdown
  final String selectedTarget = 'Khách Hàng';
  String? productId;
  String? imei = '';
  String? price;
  String? currency;
  String? account;
  String? note;
  String? warehouseId;
  List<Map<String, dynamic>> addedItems = [];
  List<String> imeiSuggestions = [];

  List<String> fixers = [];
  List<Map<String, dynamic>> products = [];
  List<String> currencies = [];
  List<Map<String, dynamic>> accounts = [];
  List<String> accountNames = [];
  List<Map<String, dynamic>> warehouses = [];
  List<String> customers = [];
  Map<String, String> customerIdMap = {}; // Map customer name to id
  List<String> usedImeis = [];
  bool isLoading = true;
  bool isProcessing = false;
  String? errorMessage;
  String? imeiError;
  bool isImeiManual = true;

  final TextEditingController imeiController = TextEditingController();
  final TextEditingController priceController = TextEditingController();
  final TextEditingController productController = TextEditingController();
  late final FocusNode imeiFocusNode;
  Timer? _debounce;

  final NumberFormat numberFormat = NumberFormat.decimalPattern('vi_VN');

  @override
  void initState() {
    super.initState();
    imeiFocusNode = FocusNode();
    _fetchInitialData();
    imeiController.text = imei ?? '';
    priceController.text = price ?? '';
  }

  @override
  void dispose() {
    imeiController.dispose();
    priceController.dispose();
    productController.dispose();
    imeiFocusNode.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _fetchInitialData() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      final supabase = widget.tenantClient;

      // Fetch warehouses
      final warehouseResponse = await retry(
        () => supabase.from('warehouses').select('id, name'),
        operation: 'Fetch initial warehouses',
      );
      final warehouseList = warehouseResponse
          .map((e) {
            final id = e['id'] as String?;
            final name = e['name'] as String?;
            if (id != null && name != null) {
              CacheUtil.cacheWarehouseName(id, name);
              return {'id': id, 'name': name};
            }
            return null;
          })
          .whereType<Map<String, dynamic>>()
          .toList()
        ..sort((a, b) => (a['name'] ?? '').toLowerCase().compareTo((b['name'] ?? '')));

      // Fetch currencies
      final currencyResponse = await retry(
        () => supabase.from('financial_accounts').select('currency').neq('currency', ''),
        operation: 'Fetch currencies',
      );
      final uniqueCurrencies = currencyResponse
          .map((e) => e['currency'] as String?)
          .whereType<String>()
          .toSet()
          .toList()
        ..sort();

      // Fetch accounts
      final accountResponse = await retry(
        () => supabase.from('financial_accounts').select('name, currency, balance'),
        operation: 'Fetch accounts',
      );
      final accountList = accountResponse
          .map((e) => {
                'name': e['name'] as String?,
                'currency': e['currency'] as String?,
                'balance': (e['balance'] as num?)?.toDouble() ?? 0.0,
              })
          .where((e) => e['name'] != null && e['currency'] != null)
          .cast<Map<String, dynamic>>()
          .toList();

      // Fetch products
      final productResponse = await retry(
        () => supabase.from('products_name').select('id, products'),
        operation: 'Fetch products',
      );
      final productList = productResponse
          .map((e) => {'id': e['id'].toString(), 'name': e['products'] as String})
          .toList()
        ..sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));

      // Fetch customers
      final customerResponse = await retry(
        () => supabase.from('customers').select('id, name'),
        operation: 'Fetch customers',
      );
      final customerList = customerResponse
          .map((e) => e['name'] as String?)
          .whereType<String>()
          .toList()
        ..sort();
      // Build customer id map
      final customerIdMapTemp = <String, String>{};
      for (var e in customerResponse) {
        final name = e['name'] as String?;
        final id = e['id']?.toString();
        if (name != null && id != null) {
          customerIdMapTemp[name] = id;
        }
      }

      if (mounted) {
        setState(() {
          warehouses = warehouseList;
          usedImeis = [];
          currencies = uniqueCurrencies;
          accounts = accountList;
          products = productList;
          customers = customerList;
          customerIdMap = customerIdMapTemp;
          currency = uniqueCurrencies.contains('VND') ? 'VND' : uniqueCurrencies.isNotEmpty ? uniqueCurrencies.first : null;
          _updateAccountNames(currency);
          isLoading = false;
          for (var product in productList) {
            CacheUtil.cacheProductName(product['id'] as String, product['name'] as String);
          }
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

  void _updateAccountNames(String? selectedCurrency) {
    if (selectedCurrency == null) {
      setState(() {
        accountNames = [];
        account = null;
      });
      return;
    }

    final filteredAccounts = accounts
        .where((acc) => acc['currency'] == selectedCurrency)
        .map((acc) => acc['name'] as String)
        .toList();
    filteredAccounts.add('Công nợ');

    setState(() {
      accountNames = filteredAccounts;
      account = null;
    });
  }

  Future<void> _fetchAvailableImeis(String query) async {
    if (productId == null) {
      setState(() {
        imeiSuggestions = [];
      });
      return;
    }

    try {
      final supabase = widget.tenantClient;
      // ✅ Query tất cả sale_orders (không filter account) để tìm IMEI
      final response = await supabase
          .from('sale_orders')
          .select('imei')
          .eq('product_id', productId!)
          .eq('iscancelled', false)
          .ilike('imei', '%$query%')
          .order('created_at', ascending: false)
          .limit(100); // Lấy nhiều hơn để có đủ IMEI sau khi split và filter

      // Extract individual IMEIs từ danh sách IMEI (có thể có nhiều IMEI trong 1 sale_order)
      final Set<String> imeiSet = {};
      for (var order in response) {
        final imeiString = order['imei']?.toString() ?? '';
        final imeiList = imeiString.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
        for (var imei in imeiList) {
          if (imei.toLowerCase().contains(query.toLowerCase()) && 
              !addedItems.any((item) => item['imei'] == imei) &&
              !imeiSet.contains(imei)) {
            imeiSet.add(imei);
          }
        }
      }

      // ✅ Filter: chỉ giữ lại IMEI có trạng thái hiện tại là "Đã bán" (chưa nhập lại)
      final List<String> validImeis = [];
      for (var imei in imeiSet) {
        // ✅ Kiểm tra trạng thái hiện tại của sản phẩm phải là "Đã bán" (chưa nhập lại)
        try {
          final productStatusCheck = await supabase
              .from('products')
              .select('status')
              .eq('imei', imei)
              .eq('product_id', productId!)
              .maybeSingle();
          
          if (productStatusCheck != null) {
            final currentStatus = productStatusCheck['status']?.toString();
            if (currentStatus == 'Đã bán') {
              // Trạng thái hiện tại là "Đã bán" → hợp lệ cho phiếu nhập lại hàng
              validImeis.add(imei);
            }
          }
        } catch (e) {
          debugPrint('Lỗi khi kiểm tra trạng thái sản phẩm cho IMEI $imei: $e');
          // Bỏ qua IMEI này nếu có lỗi
        }
      }

      final imeiListFromDb = validImeis..sort();

      if (mounted) {
        setState(() {
          imeiSuggestions = imeiListFromDb.take(10).toList();
        });
      }
    } catch (e) {
      debugPrint('Lỗi khi tải gợi ý IMEI: $e');
      if (mounted) {
        setState(() {
          imeiSuggestions = [];
        });
      }
    }
  }

  // ✅ Helper method để hiển thị lỗi IMEI dạng popup
  Future<void> _showImeiErrorDialog(String error) async {
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Lỗi IMEI'),
        content: SingleChildScrollView(
          child: Text(error),
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

  Future<String?> _checkDuplicateImeis(String input) async {
    if (addedItems.any((item) => item['imei'] == input)) {
      return 'IMEI "$input" đã được nhập!';
    }
    return null;
  }


  Future<void> _addImeiToList(String input) async {
    if (input.trim().isEmpty || productId == null) {
      final error = 'Vui lòng chọn sản phẩm và nhập IMEI!';
      setState(() {
        imeiError = error;
      });
      await _showImeiErrorDialog(error);
      return;
    }

    final duplicateError = await _checkDuplicateImeis(input);
    if (duplicateError != null) {
      setState(() {
        imeiError = duplicateError;
      });
      await _showImeiErrorDialog(duplicateError);
      return;
    }

    try {
      final supabase = widget.tenantClient;
      // ✅ Query sale_order gần nhất (bao gồm cả Ship COD) để lấy thông tin
      final saleOrdersResponse = await retry(
        () => supabase
            .from('sale_orders')
            .select('customer, customer_id, price, currency, account, imei')
            .eq('product_id', productId!)
            .eq('iscancelled', false)
            .like('imei', '%$input%')
            .order('created_at', ascending: false)
            .limit(10), // Lấy nhiều hơn để filter chính xác IMEI
        operation: 'Fetch sale order',
      );

      // ✅ Filter để tìm sale_order chứa IMEI chính xác
      Map<String, dynamic>? matchedOrder;
      for (var order in saleOrdersResponse) {
        final imeiString = order['imei']?.toString() ?? '';
        final imeiList = imeiString.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
        if (imeiList.contains(input)) {
          matchedOrder = order;
          break; // Tìm thấy IMEI chính xác, dừng lại
        }
      }

      if (matchedOrder == null) {
        final error = 'Không tìm thấy giao dịch bán cho IMEI "$input"!';
        setState(() {
          imeiError = error;
        });
        await _showImeiErrorDialog(error);
        return;
      }

      // ✅ Kiểm tra trạng thái hiện tại của sản phẩm phải là "Đã bán" (chưa nhập lại)
      final productStatusCheck = await retry(
        () => supabase
            .from('products')
            .select('status')
            .eq('imei', input)
            .eq('product_id', productId!)
            .maybeSingle(),
        operation: 'Check product status for IMEI $input',
      );
      
      if (productStatusCheck == null) {
        final error = 'Không tìm thấy sản phẩm cho IMEI "$input"!';
        setState(() {
          imeiError = error;
        });
        await _showImeiErrorDialog(error);
        return;
      }
      
      final currentStatus = productStatusCheck['status']?.toString();
      if (currentStatus != 'Đã bán') {
        final error = 'IMEI "$input" có trạng thái hiện tại là "$currentStatus", không phải "Đã bán". Sản phẩm có thể đã được nhập lại trước đó.';
        setState(() {
          imeiError = error;
        });
        await _showImeiErrorDialog(error);
        return;
      }
      
      // Lấy thông tin tiền cọc và tiền COD từ bảng products
      final productResponse = await retry(
        () => supabase
            .from('products')
            .select('customer_price, transporter_price, transporter, sale_date')
            .eq('imei', input)
            .eq('product_id', productId!)
            .eq('status', 'Đã bán')
            .maybeSingle(),
        operation: 'Fetch product data',
      );

      if (productResponse == null) {
        final error = 'Không tìm thấy thông tin sản phẩm cho IMEI "$input"!';
        setState(() {
          imeiError = error;
        });
        await _showImeiErrorDialog(error);
        return;
      }

      print('Product data for IMEI $input: $productResponse');

      // ✅ matchedOrder không thể null ở đây vì đã kiểm tra ở trên
      final order = matchedOrder;
      final price = order['price'] != null
          ? (order['price'] is num
              ? (order['price'] as num).toDouble()
              : double.tryParse(order['price'].toString()) ?? 0.0)
          : 0.0;

      final customerPrice = productResponse['customer_price'] != null
          ? (productResponse['customer_price'] is num
              ? (productResponse['customer_price'] as num).toDouble()
              : double.tryParse(productResponse['customer_price'].toString()) ?? 0.0)
          : 0.0;

      final transporterPrice = productResponse['transporter_price'] != null
          ? (productResponse['transporter_price'] is num
              ? (productResponse['transporter_price'] as num).toDouble()
              : double.tryParse(productResponse['transporter_price'].toString()) ?? 0.0)
          : 0.0;

      final saleDate = productResponse['sale_date'] != null
          ? DateFormat('dd/MM/yyyy HH:mm').format(DateTime.parse(productResponse['sale_date'] as String))
          : 'Không xác định';

      print('Parsed prices for IMEI $input:');
      print('- Customer price: $customerPrice');
      print('- Transporter price: $transporterPrice');
      print('- Sale date: $saleDate');

      final currency = order['currency'] as String? ?? 'VND';

      if (price == 0) {
        final error = 'Giá bán của IMEI "$input" không hợp lệ!';
        setState(() {
          imeiError = error;
        });
        await _showImeiErrorDialog(error);
        return;
      }

      // Lấy customer_id từ order hoặc tra cứu từ customerIdMap
      String? customerId;
      final customerIdFromOrder = order['customer_id'];
      if (customerIdFromOrder != null) {
        customerId = customerIdFromOrder.toString();
      } else {
        // Fallback: tra cứu từ customerIdMap dựa trên tên (cho backward compatibility)
        final customerName = order['customer'] as String?;
        if (customerName != null) {
          customerId = customerIdMap[customerName];
        }
      }

      // ✅ Xác định có phải Ship COD không dựa trên account của sale_order
      final accountValue = order['account'] as String?;
      final isCod = accountValue == 'Ship COD';

      if (mounted) {
        setState(() {
          addedItems.add({
            'imei': input,
            'product_id': productId,
            'product_name': CacheUtil.getProductName(productId),
            'isCod': isCod, // ✅ Xác định dựa trên account của sale_order
            'customer': order['customer'] as String? ?? 'Không xác định',
            'customer_id': customerId, // ✅ Lưu customer_id thay vì chỉ lưu tên
            'customer_price': customerPrice,
            'transporter_price': transporterPrice,
            'transporter': productResponse['transporter'] as String? ?? 'Không xác định',
            'sale_price': price,
            'sale_currency': currency,
            'reimport_price': null,
            'sale_date': saleDate,
          });
          imei = '';
          imeiController.text = '';
          imeiError = null;
        });
      }
    } catch (e) {
      final error = 'Lỗi khi lấy thông tin giao dịch: $e';
      setState(() {
        imeiError = error;
      });
      await _showImeiErrorDialog(error);
    }
  }

  // Hàm phát âm thanh beep
  void _playBeepSound() {
    SystemSound.play(SystemSoundType.click);
  }

  Future<void> _scanQRCode() async {
    try {
      final scannedData = await Navigator.push<String?>(
        context,
        MaterialPageRoute(builder: (context) => const QRCodeScannerScreen()),
      );

      if (scannedData != null && mounted) {
        // Phát âm thanh beep khi quét thành công
        _playBeepSound();
        
        setState(() {
          imei = scannedData;
          imeiController.text = scannedData;
        });

        await _addImeiToList(scannedData);
      }
    } catch (e) {
      if (mounted) {
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text('Lỗi khi quét QR code: $e'),
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

  Future<void> _scanText() async {
    try {
      final scannedData = await Navigator.push<String?>(
        context,
        MaterialPageRoute(builder: (context) => const TextScannerScreen()),
      );

      if (scannedData != null && mounted) {
        // Phát âm thanh beep khi quét thành công
        _playBeepSound();
        
        setState(() {
          imei = scannedData;
          imeiController.text = scannedData;
        });

        await _addImeiToList(scannedData);
      }
    } catch (e) {
      if (mounted) {
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text('Lỗi khi quét text: $e'),
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

  Future<void> _showAutoImeiDialog() async {
    int? localQuantity;
    String? localCustomer;
    final TextEditingController localQuantityController = TextEditingController();
    final TextEditingController localCustomerController = TextEditingController();

    await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Auto IMEI'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: localQuantityController,
                keyboardType: TextInputType.number,
                onChanged: (val) {
                  localQuantity = int.tryParse(val);
                },
                decoration: const InputDecoration(
                  labelText: 'Số lượng',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Autocomplete<String>(
                  optionsBuilder: (TextEditingValue textEditingValue) {
                    final query = textEditingValue.text.toLowerCase();
                    if (query.isEmpty) return customers.take(10).toList();
                    final filtered = customers.where((option) => option.toLowerCase().contains(query)).toList()
                      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
                    return filtered.isNotEmpty ? filtered.take(10).toList() : ['Không tìm thấy khách hàng'];
                  },
                  onSelected: (String selection) {
                    if (selection != 'Không tìm thấy khách hàng') {
                      localCustomer = selection;
                      localCustomerController.text = selection;
                    }
                  },
                  fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                    controller.text = localCustomerController.text;
                    return TextFormField(
                      controller: controller,
                      focusNode: focusNode,
                      onChanged: (value) {
                        localCustomer = value;
                      },
                      decoration: const InputDecoration(
                        labelText: 'Tên khách hàng',
                        border: OutlineInputBorder(),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Hủy'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (localQuantity == null || localQuantity! <= 0) {
                showDialog(
                  context: dialogContext,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Thông báo'),
                    content: const Text('Vui lòng nhập số lượng hợp lệ!'),
                    actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Đóng'))],
                  ),
                );
                return;
              }
              if (localCustomer == null || localCustomer!.trim().isEmpty) {
                showDialog(
                  context: dialogContext,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Thông báo'),
                    content: const Text('Vui lòng nhập tên khách hàng!'),
                    actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Đóng'))],
                  ),
                );
                return;
              }
              Navigator.pop(dialogContext);
              await _autoFetchImeis(localQuantity!, localCustomer);
            },
            child: const Text('Tìm'),
          ),
        ],
      ),
    );
  }

  Future<void> _autoFetchImeis(int qty, String? cust) async {
    setState(() {
      isLoading = true;
    });

    try {
      final supabase = widget.tenantClient;
      var query = supabase
          .from('sale_orders')
          .select('imei, customer, customer_id, transporter, price, currency, account, quantity')
          .eq('product_id', productId!); // ✅ Lấy tất cả đơn bán (bao gồm cả Ship COD)

      final customerId = customerIdMap[cust];
      if (customerId != null) {
        query = query.eq('customer_id', customerId);
      } else {
        // Fallback to customer name if id not found
        query = query.eq('customer', cust!);
      }

      // ✅ Loại bỏ phiếu đã hủy
      query = query.eq('iscancelled', false);

      // Fetch more rows to ensure we have enough individual IMEIs
      final response = await query.order('created_at', ascending: false).limit(qty * 2);

      // Process all rows to collect individual IMEIs
      final List<Map<String, dynamic>> allItems = [];
      
      for (var item in response) {
        final imeiString = item['imei'] as String;
        
        // Split IMEI string by comma and trim spaces
        final individualImeis = imeiString.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
        
        for (var individualImei in individualImeis) {
          if (allItems.length >= qty) break;
          
          // Check for duplicates in both addedItems and allItems
          if (await _checkDuplicateImeis(individualImei) != null) continue;
          if (allItems.any((item) => item['imei'] == individualImei)) continue;
          
          // ✅ Kiểm tra trạng thái hiện tại của sản phẩm phải là "Đã bán" (chưa nhập lại)
          try {
            final productStatusCheck = await retry(
              () => supabase
                  .from('products')
                  .select('status')
                  .eq('imei', individualImei)
                  .eq('product_id', productId!)
                  .maybeSingle(),
              operation: 'Check product status for IMEI $individualImei',
            );
            
            if (productStatusCheck == null) {
              print('Skipping IMEI $individualImei: Product not found');
              continue;
            }
            
            final currentStatus = productStatusCheck['status']?.toString();
            if (currentStatus != 'Đã bán') {
              print('Skipping IMEI $individualImei: Current status is "$currentStatus", not "Đã bán"');
              continue;
            }
          } catch (e) {
            print('Skipping IMEI $individualImei: Error checking product status: $e');
            continue;
          }
          
          try {
            final productResponse = await retry(
              () => supabase
                  .from('products')
                  .select('customer_price, transporter_price, transporter, sale_date')
                  .eq('imei', individualImei)
                  .eq('product_id', productId!)
                  .eq('status', 'Đã bán')
                  .maybeSingle(),
              operation: 'Fetch product data for IMEI $individualImei',
            );

            if (productResponse == null) {
              print('Skipping IMEI $individualImei: Product data not found');
              continue;
            }

            final price = item['price'] != null
                ? (item['price'] is num
                    ? (item['price'] as num).toDouble()
                    : double.tryParse(item['price'].toString()) ?? 0.0)
                : 0.0;

            // Price is already per-item, no need to divide by quantity
            final perItemPrice = price;

            final customerPrice = productResponse['customer_price'] != null
                ? (productResponse['customer_price'] is num
                    ? (productResponse['customer_price'] as num).toDouble()
                    : double.tryParse(productResponse['customer_price'].toString()) ?? 0.0)
                : 0.0;

            final transporterPrice = productResponse['transporter_price'] != null
                ? (productResponse['transporter_price'] is num
                    ? (productResponse['transporter_price'] as num).toDouble()
                    : double.tryParse(productResponse['transporter_price'].toString()) ?? 0.0)
                : 0.0;

            final saleDate = productResponse['sale_date'] != null
                ? DateFormat('dd/MM/yyyy HH:mm').format(DateTime.parse(productResponse['sale_date'] as String))
                : 'Không xác định';

            // Lấy customer_id từ item hoặc tra cứu từ customerIdMap
            String? customerIdForItem;
            final customerIdFromItem = item['customer_id'];
            if (customerIdFromItem != null) {
              customerIdForItem = customerIdFromItem.toString();
            } else {
              // Fallback: tra cứu từ customerIdMap dựa trên tên (cho backward compatibility)
              final customerName = item['customer'] as String?;
              if (customerName != null) {
                customerIdForItem = customerIdMap[customerName];
              }
            }

            // ✅ Xác định có phải Ship COD không dựa trên account của sale_order
            final accountValue = item['account'] as String?;
            final isCod = accountValue == 'Ship COD';

            allItems.add({
              'imei': individualImei,
              'product_id': productId,
              'product_name': CacheUtil.getProductName(productId),
              'customer': item['customer'] as String? ?? 'Không xác định',
              'customer_id': customerIdForItem, // ✅ Lưu customer_id thay vì chỉ lưu tên
              'customer_price': customerPrice,
              'transporter_price': transporterPrice,
              'transporter': productResponse['transporter'] as String? ?? 'Không xác định',
              'sale_price': perItemPrice,
              'sale_currency': item['currency'] as String? ?? 'VND',
              'reimport_price': null,
              'isCod': isCod, // ✅ Xác định dựa trên account của sale_order
              'sale_date': saleDate,
            });
          } catch (e) {
            // Skip this IMEI if product data not found
            print('Skipping IMEI $individualImei: $e');
            continue;
          }
        }
        
        if (allItems.length >= qty) break;
      }

      if (allItems.length < qty) {
        final msg = 'Khách hàng $cust mua chưa đủ số lượng. Chỉ có ${allItems.length} IMEI.';
        if (mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Thông báo'),
              content: Text(msg),
              actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Đóng'))],
            ),
          );
        }
        setState(() {
          isLoading = false;
        });
        return;
      }

      setState(() {
        addedItems = allItems;
        isImeiManual = false;
        isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Lỗi'),
            content: Text('$e'),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Đóng'))],
          ),
        );
      }
      setState(() {
        isLoading = false;
      });
    }
  }

  Future<void> showConfirmDialog() async {
    // Không khóa ở bước xác nhận; chỉ khóa khi bấm "Tạo phiếu"

    if (productId == null || warehouseId == null) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Vui lòng chọn sản phẩm và kho nhập lại!'),
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

    if (currency == null || account == null) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Vui lòng điền đầy đủ thông tin tài chính!'),
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

    List<Map<String, dynamic>> itemsToProcess = [];

    try {
      if (addedItems.isEmpty) {
        throw Exception('Vui lòng nhập IMEI hoặc sử dụng Auto IMEI!');
      }
      for (var item in addedItems) {
        if (item['reimport_price'] != null && (item['reimport_price'] < 0)) {
          throw Exception('Giá nhập lại cho IMEI ${item['imei']} không hợp lệ!');
        }
      }
      itemsToProcess = addedItems;

      if (itemsToProcess.length > maxImeiQuantity) {
        throw Exception(
            'Số lượng IMEI (${formatNumberLocal(itemsToProcess.length)}) vượt quá giới hạn ${formatNumberLocal(maxImeiQuantity)}. Vui lòng chia thành nhiều phiếu.');
      }

      if (mounted) {
        showDialog(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Xác nhận phiếu nhập lại hàng'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ...itemsToProcess.map((item) => Text('Khách hàng: ${item['customer']} (Sản phẩm: ${item['product_name']})')),
                  Text('Sản phẩm: ${CacheUtil.getProductName(productId)}'),
                  Text('Danh sách IMEI:'),
                  ...itemsToProcess.map((item) => Text('- ${item['imei']}')),
                  Text('Số lượng: ${itemsToProcess.length}'),
                  Text('Kho nhập lại: ${CacheUtil.getWarehouseName(warehouseId)}'),
                  ...itemsToProcess
                      .map((item) => Text('- IMEI ${item['imei']}: ${formatNumberLocal(item['reimport_price'] ?? item['sale_price'])} ${item['sale_currency']}')),
                  Text('Tài khoản: ${account ?? 'Không xác định'}'),
                  Text('Ghi chú: ${note ?? 'Không có'}'),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Sửa lại'),
              ),
              ElevatedButton(
                onPressed: () async {
                  if (isProcessing) return; // khóa nhấn nhanh
                  if (mounted) {
                    setState(() { isProcessing = true; });
                  }
                  Navigator.pop(dialogContext);
                  try {
                    await _processReimportOrder(itemsToProcess);
                  } finally {
                    if (mounted) {
                      setState(() { isProcessing = false; });
                    }
                  }
                },
                child: const Text('Tạo phiếu'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      setState(() {
        isProcessing = false;
      });
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text(e.toString()),
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

  Future<void> _processReimportOrder(List<Map<String, dynamic>> items) async {
    if (items.isEmpty) {
      throw Exception('Danh sách IMEI trống, không thể tạo phiếu!');
    }

    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Vui lòng chờ xử lý dữ liệu.'),
            ],
          ),
        ),
      );
    }

    Map<String, dynamic>? snapshotData;
    try {
      final supabase = widget.tenantClient;
      final ticketId = generateTicketId();
      final now = DateTime.now();

      print('Processing ${items.length} IMEIs for reimport order $ticketId');

      // Create snapshot before making any changes
      snapshotData = await retry(
        () => _createSnapshot(ticketId, items),
        operation: 'Create snapshot',
      );

      final customerGroups = <String, List<Map<String, dynamic>>>{};
      for (var item in items) {
        final customer = item['customer'] as String;
        customerGroups.putIfAbsent(customer, () => []).add(item);
      }

      try {
        // Prepare data for RPC function
        final reimportOrdersList = <Map<String, dynamic>>[];
        final productsUpdatesList = <Map<String, dynamic>>[];
        final customersDebtChangesList = <Map<String, dynamic>>[];
        double? accountBalanceChange;
        
        for (var item in items) {
          final reimportPrice = item['reimport_price'] != null
              ? (item['reimport_price'] is num ? (item['reimport_price'] as num).toDouble() : 0.0)
              : (item['sale_price'] is num ? (item['sale_price'] as num).toDouble() : 0.0);

          // ✅ Sử dụng customer_id trực tiếp từ item (đã lưu từ sale_orders)
          final customerId = item['customer_id'] as String?;
          int finalCustomerId;
          if (customerId != null && customerId.isNotEmpty) {
            finalCustomerId = int.parse(customerId);
          } else {
            final fallbackId = customerIdMap[item['customer']];
            if (fallbackId == null) {
            throw Exception('Không tìm thấy ID của khách hàng "${item['customer']}"!');
          }
            finalCustomerId = int.parse(fallbackId);
          }

          // Prepare reimport order
          reimportOrdersList.add({
              'ticket_id': ticketId,
            'customer_id': finalCustomerId,
              'product_id': item['product_id'],
              'warehouse_id': warehouseId,
              'imei': item['imei'],
              'quantity': 1,
              'price': reimportPrice,
              'currency': item['sale_currency'],
            'account': account,
              'customer_price': null,
              'transporter_price': null,
              'note': note,
              'created_at': now.toIso8601String(),
          });

          // Prepare product update
          productsUpdatesList.add({
            'imei': item['imei'],
              'status': 'Tồn kho',
              'warehouse_id': warehouseId,
              'customer_price': null,
              'transporter_price': null,
              'cost_price': reimportPrice,
          });
        }

        // Prepare customer debt changes (if account == 'Công nợ')
        if (account == 'Công nợ') {
            for (var customer in customerGroups.keys) {
              final customerItems = customerGroups[customer]!;
              final currencyGroups = <String, List<Map<String, dynamic>>>{};
              for (var item in customerItems) {
                final saleCurrency = item['sale_currency'] as String;
                currencyGroups.putIfAbsent(saleCurrency, () => []).add(item);
              }

              for (var saleCurrency in currencyGroups.keys) {
                final itemsByCurrency = currencyGroups[saleCurrency]!;
                final customerAmount = itemsByCurrency.fold<double>(
                    0.0,
                    (sum, item) => sum +
                        (item['reimport_price'] != null
                            ? (item['reimport_price'] is num ? (item['reimport_price'] as num).toDouble() : 0.0)
                            : (item['sale_price'] is num ? (item['sale_price'] as num).toDouble() : 0.0)));

                final customerId = itemsByCurrency.first['customer_id'] as String?;
              int finalCustomerId;
              if (customerId != null && customerId.isNotEmpty) {
                finalCustomerId = int.parse(customerId);
              } else {
                final fallbackId = customerIdMap[customer];
                if (fallbackId == null) {
                  throw Exception('Không tìm thấy ID của khách hàng "$customer"!');
                  }
                finalCustomerId = int.parse(fallbackId);
              }

              // Determine debt columns based on currency
              if (saleCurrency != 'VND' && saleCurrency != 'CNY' && saleCurrency != 'USD') {
                throw Exception('Loại tiền tệ không được hỗ trợ: $saleCurrency cho IMEI ${itemsByCurrency.first['imei']}');
              }

              customersDebtChangesList.add({
                'customer_id': finalCustomerId,
                'debt_vnd': saleCurrency == 'VND' ? -customerAmount : 0,
                'debt_cny': saleCurrency == 'CNY' ? -customerAmount : 0,
                'debt_usd': saleCurrency == 'USD' ? -customerAmount : 0,
              });
              }
            }
          } else {
          // Calculate account balance change
          accountBalanceChange = -items.fold<double>(
                    0.0,
                    (sum, item) => sum +
                        (item['reimport_price'] != null
                            ? (item['reimport_price'] is num ? (item['reimport_price'] as num).toDouble() : 0.0)
                            : (item['sale_price'] is num ? (item['sale_price'] as num).toDouble() : 0.0)));
        }

        // ✅ CALL RPC FUNCTION - All operations in ONE atomic transaction
        print('Calling create_reimport_transaction RPC with ${reimportOrdersList.length} orders');
        final result = await retry(
          () => supabase.rpc('create_reimport_transaction', params: {
            'p_ticket_id': ticketId,
            'p_reimport_orders': reimportOrdersList,
            'p_products_updates': productsUpdatesList,
            'p_customers_debt_changes': customersDebtChangesList,
            'p_transporters_debt_changes': <Map<String, dynamic>>[], // Empty for regular reimport
            'p_account_balance_change': accountBalanceChange,
            'p_account': account ?? 'Công nợ', // Default to 'Công nợ' if null to avoid empty string
            'p_currency': currency ?? 'VND',
            'p_snapshot_data': snapshotData,
            'p_created_at': now.toIso8601String(),
          }),
          operation: 'Create reimport transaction (RPC)',
        );

        // Check result
        if (result == null || result['success'] != true) {
          throw Exception('RPC function returned error: ${result?['message'] ?? 'Unknown error'}');
          }

        print('✅ Reimport transaction created successfully via RPC!');

        // Calculate total amount by currency
        final amountsByCurrency = <String, double>{};
        for (var item in items) {
          final saleCurrency = item['sale_currency'] as String;
          final price = item['reimport_price'] != null
              ? (item['reimport_price'] is num ? (item['reimport_price'] as num).toDouble() : 0.0)
              : (item['sale_price'] is num ? (item['sale_price'] as num).toDouble() : 0.0);
          amountsByCurrency[saleCurrency] = (amountsByCurrency[saleCurrency] ?? 0.0) + price;
        }

        // Trừ doanh số từ sub_accounts khi nhập lại hàng
        try {
          // Map để lưu doanh số cần trừ theo từng nhân viên
          final Map<String, double> doanhsoToDeduct = {};
          
          for (var item in items) {
            final imei = item['imei'] as String;
            
            // ✅ Tìm phiếu bán gần nhất cho IMEI này (tìm chính xác IMEI trong danh sách)
            // Fetch nhiều records để đảm bảo tìm được IMEI chính xác
            final saleOrders = await retry(
              () => supabase
                  .from('sale_orders')
                  .select('doanhso, quantity, saleman, imei, created_at')
                  .like('imei', '%$imei%')
                  .eq('iscancelled', false)
                  .order('created_at', ascending: false)
                  .limit(10), // Fetch nhiều hơn để filter chính xác
              operation: 'Fetch sale orders for IMEI $imei',
            );
            
            // ✅ Filter để tìm sale_order chứa IMEI chính xác
            Map<String, dynamic>? saleOrder;
            for (var order in saleOrders) {
              final imeiString = order['imei']?.toString() ?? '';
              final imeiList = imeiString.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
              // Kiểm tra IMEI có tồn tại chính xác trong danh sách
              if (imeiList.contains(imei)) {
                saleOrder = order;
                break; // Tìm thấy IMEI chính xác, dừng lại
              }
            }
            
            if (saleOrder != null && saleOrder['saleman'] != null && saleOrder['saleman'].toString().isNotEmpty) {
              final saleman = saleOrder['saleman'].toString();
              final totalDoanhso = (saleOrder['doanhso'] as num?)?.toDouble() ?? 0.0;
              
              // Đếm số lượng IMEI trong phiếu bán
              final imeiString = saleOrder['imei']?.toString() ?? '';
              final imeiList = imeiString.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
              final imeiCount = imeiList.length > 0 ? imeiList.length : 1;
              
              // Tính doanh số mỗi sản phẩm = tổng doanh số / số lượng IMEI
              final doanhsoPerItem = imeiCount > 0 ? totalDoanhso / imeiCount : 0.0;
              
              print('📊 Reimport IMEI $imei: Sale order doanhso=$totalDoanhso, quantity=$imeiCount, doanhso per item=$doanhsoPerItem, saleman=$saleman');
              
              // Cộng dồn doanh số cần trừ cho nhân viên này
              doanhsoToDeduct[saleman] = (doanhsoToDeduct[saleman] ?? 0.0) + doanhsoPerItem;
            } else {
              print('⚠️ Reimport IMEI $imei: No sale order found or no saleman');
            }
          }
          
          // Update sub_accounts cho từng nhân viên
          for (var entry in doanhsoToDeduct.entries) {
            final saleman = entry.key;
            final doanhsoToSubtract = entry.value;
            
            if (doanhsoToSubtract > 0) {
              print('📊 Deducting doanhso $doanhsoToSubtract from salesman $saleman');
              
              // Fetch current doanhso
              final currentAccount = await retry(
                () => supabase
                    .from('sub_accounts')
                    .select('id, username, doanhso')
                    .eq('username', saleman)
                    .maybeSingle(),
                operation: 'Get current doanhso for reimport',
              );
              
              if (currentAccount != null) {
                // Parse current doanhso - có thể là int hoặc double từ DB
                final currentDoanhsoRaw = currentAccount['doanhso'];
                final currentDoanhso = currentDoanhsoRaw is int 
                    ? currentDoanhsoRaw.toDouble()
                    : double.tryParse(currentDoanhsoRaw?.toString() ?? '0') ?? 0;
                
                // Tính doanh số mới = hiện tại - doanh số cần trừ
                final newDoanhsoDouble = currentDoanhso - doanhsoToSubtract;
                // Convert to int vì cột doanhso trong sub_accounts là INTEGER
                final newDoanhso = newDoanhsoDouble.round();
                
                print('💰 Reimport: Current doanhso: $currentDoanhso, Subtracting: $doanhsoToSubtract, New total: $newDoanhso');
                
                await retry(
                  () => supabase
                      .from('sub_accounts')
                      .update({'doanhso': newDoanhso}) // Gửi int thay vì double
                      .eq('username', saleman),
                  operation: 'Update sub_accounts doanhso for reimport',
                );
                
                // Verify update
                await Future.delayed(const Duration(milliseconds: 200));
                final verifyAccount = await supabase
                    .from('sub_accounts')
                    .select('doanhso')
                    .eq('username', saleman)
                    .maybeSingle();
                
                if (verifyAccount != null) {
                  final verifyDoanhso = int.tryParse(verifyAccount['doanhso']?.toString() ?? '0') ?? 0;
                  if (verifyDoanhso == newDoanhso) {
                    print('✅ Verified: Updated doanhso for salesman $saleman after reimport: $currentDoanhso - $doanhsoToSubtract = $newDoanhso');
                  } else {
                    print('❌ WARNING: Reimport doanhso verification failed. Expected: $newDoanhso, Got: $verifyDoanhso');
                  }
                }
              } else {
                print('❌ ERROR: sub_account not found for username: $saleman');
              }
            }
          }
        } catch (e, stackTrace) {
          print('❌ ERROR: Failed to deduct doanhso for reimport: $e');
          print('❌ Stack trace: $stackTrace');
          // Không throw error để không làm fail toàn bộ transaction
        }

        await NotificationService.showNotification(
          136,
          'Phiếu Nhập Lại Hàng Đã Tạo',
          'Đã tạo phiếu nhập lại hàng cho ${customerGroups.keys.join(', ')}',
          'reimport_created',
        );
        
        // ✅ Gửi thông báo push đến tất cả thiết bị
        await NotificationService.sendNotificationToAll(
          'Phiếu Nhập Lại Hàng Đã Tạo',
          'Đã tạo phiếu nhập lại hàng cho ${customerGroups.keys.join(', ')}',
          data: {'type': 'reimport_created'},
        );
        
        // Lấy số dư cuối từ tài khoản (nếu không phải Công nợ)
        String? finalBalanceStr;
        if (account != null && account != 'Công nợ' && currency != null) {
          try {
            final accountData = await supabase
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
        }
        
        // Tính tổng số tiền và lấy danh sách IMEI
        final totalAmount = items.fold<double>(
          0.0,
          (sum, item) => sum + (item['reimport_price'] != null
              ? (item['reimport_price'] is num ? (item['reimport_price'] as num).toDouble() : 0.0)
              : (item['sale_price'] is num ? (item['sale_price'] as num).toDouble() : 0.0)),
        );
        final imeiList = items.map((item) => item['imei'] as String).join(', ');
        
        // ✅ Gửi thông báo Telegram với thông tin chi tiết
        await NotificationService.sendTransactionToTelegram(
          transactionType: 'reimport', // Loại phiếu
          type: 'Phiếu Nhập Lại Hàng', // Tên hiển thị
          ticketId: ticketId,
          customer: customerGroups.keys.join(', '),
          productName: CacheUtil.getProductName(productId),
          quantity: items.length,
          imeiList: imeiList,
          totalAmount: formatNumberLocal(totalAmount),
          currency: currency ?? 'VND',
          paymentMethod: account ?? 'Công nợ',
          account: account != 'Công nợ' ? account : null,
          finalBalance: finalBalanceStr,
          note: note,
        );

        if (mounted) {
          Navigator.pop(context);
          await showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Thông báo'),
              content: const Text('Đã tạo phiếu nhập lại hàng thành công'),
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

          setState(() {
            productId = null;
            productController.text = '';
            imei = null;
            imeiController.text = '';
            price = null;
            priceController.text = '';
            currency = currencies.contains('VND') ? 'VND' : currencies.isNotEmpty ? currencies.first : null;
            account = null;
            note = null;
            warehouseId = null;
            imeiError = null;
            addedItems = [];
            isImeiManual = true;
            _updateAccountNames(currency);
          });
          await _fetchInitialData();
        }
      } catch (e) {
        // Rollback if any error occurs
        if (snapshotData != null) {
          await _rollbackSnapshot(snapshotData);
        }
        throw e;
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text(e.toString()),
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

  Future<Map<String, dynamic>> _createSnapshot(String ticketId, List<Map<String, dynamic>> items) async {
    final supabase = widget.tenantClient;
    final snapshotData = <String, dynamic>{};

    try {
      // ✅ Lấy customer_id trực tiếp từ items thay vì tra cứu từ tên
      final customerIds = <String>{};
      for (var item in items) {
        final customerId = item['customer_id'] as String?;
        if (customerId != null && customerId.isNotEmpty) {
          customerIds.add(customerId);
        } else {
          // Fallback: tra cứu từ customerIdMap dựa trên tên (cho backward compatibility)
          final customerName = item['customer'] as String?;
          if (customerName != null && customerName != 'Không xác định') {
            final fallbackCustomerId = customerIdMap[customerName];
            if (fallbackCustomerId != null) {
              customerIds.add(fallbackCustomerId);
            }
          }
        }
      }
      
      // Fetch customer data cho tất cả customer_ids
      for (var customerId in customerIds) {
            final customerData = await retry(
              () => supabase.from('customers').select().eq('id', customerId).maybeSingle(),
              operation: 'Fetch customer data',
            );
            if (customerData != null) {
              snapshotData['customers'] = snapshotData['customers'] ?? [];
              snapshotData['customers'].add(customerData);
        }
      }


      if (account != null && account != 'Công nợ' && currency != null) {
        final accountData = await retry(
          () => supabase.from('financial_accounts').select().eq('name', account!).eq('currency', currency!).maybeSingle(),
          operation: 'Fetch account data',
        );
        if (accountData != null) {
          snapshotData['financial_accounts'] = accountData;
        }
      }

      if (items.isNotEmpty) {
        final imeis = items.map((item) => item['imei'] as String).toList();
        final productsData = await retry(
          () => supabase.from('products').select('imei, product_id, warehouse_id, status, cost_price').inFilter('imei', imeis),
          operation: 'Fetch products data',
        );
        snapshotData['products'] = productsData;
      }

      snapshotData['reimport_orders'] = items.map((item) {
        final reimportPrice = item['reimport_price'] != null
            ? (item['reimport_price'] is num ? (item['reimport_price'] as num).toDouble() : 0.0)
            : (item['sale_price'] is num ? (item['sale_price'] as num).toDouble() : 0.0);
        // ✅ Sử dụng customer_id trực tiếp từ item thay vì tra cứu từ tên
        final customerId = item['customer_id'] as String?;
        int? parsedCustomerId;
        if (customerId != null && customerId.isNotEmpty) {
          parsedCustomerId = int.tryParse(customerId);
        } else {
          // Fallback: tra cứu từ customerIdMap dựa trên tên (cho backward compatibility)
          final fallbackCustomerId = customerIdMap[item['customer']];
          if (fallbackCustomerId != null) {
            parsedCustomerId = int.tryParse(fallbackCustomerId);
          }
        }
        // ✅ Luôn dùng account hiện tại (không phải COD Hoàn)
        final accountValue = account;
        return {
          'ticket_id': ticketId,
          'customer_id': parsedCustomerId,
          'product_id': item['product_id'],
          'product_name': item['product_name'],
          'warehouse_id': warehouseId,
          'warehouse_name': CacheUtil.getWarehouseName(warehouseId),
          'imei': item['imei'],
          'quantity': 1,
          'price': reimportPrice,
          'currency': item['sale_currency'],
          'account': accountValue,
          'customer_price': null,
          'transporter_price': null,
          'note': note,
        };
      }).toList();

      // ✅ Lưu snapshot của sub_accounts.doanhso TRƯỚC KHI trừ doanh số
      // Tìm tất cả các nhân viên bán từ các sale_orders liên quan đến các IMEI
      final Set<String> salesmanUsernames = {};
      for (var item in items) {
        final imei = item['imei'] as String;
        try {
          // Fetch sale_orders để tìm nhân viên bán
          final saleOrders = await retry(
            () => supabase
                .from('sale_orders')
                .select('saleman, imei, created_at')
                .like('imei', '%$imei%')
                .eq('iscancelled', false)
                .order('created_at', ascending: false)
                .limit(10),
            operation: 'Fetch sale orders for snapshot (IMEI $imei)',
          );
          
          // Filter để tìm sale_order chứa IMEI chính xác
          for (var order in saleOrders) {
            final imeiString = order['imei']?.toString() ?? '';
            final imeiList = imeiString.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
            if (imeiList.contains(imei)) {
              final saleman = order['saleman']?.toString();
              if (saleman != null && saleman.isNotEmpty) {
                salesmanUsernames.add(saleman);
              }
              break; // Tìm thấy IMEI chính xác, dừng lại
            }
          }
        } catch (e) {
          print('⚠️ WARNING: Failed to fetch sale order for snapshot (IMEI $imei): $e');
          // Tiếp tục với các IMEI khác
        }
      }
      
      // Fetch và lưu doanhso hiện tại của các nhân viên TRƯỚC KHI trừ
      if (salesmanUsernames.isNotEmpty) {
        try {
          final subAccounts = await retry(
            () => supabase
                .from('sub_accounts')
                .select('id, username, doanhso')
                .inFilter('username', salesmanUsernames.toList()),
            operation: 'Fetch sub_accounts for snapshot',
          );
          
          // Lưu snapshot cho từng nhân viên (có thể có nhiều nhân viên nếu có nhiều IMEI từ các nhân viên khác nhau)
          if (subAccounts.isNotEmpty) {
            // Nếu chỉ có 1 nhân viên, lưu dạng Map (giống sale_orders)
            // Nếu có nhiều nhân viên, lưu dạng List
            if (subAccounts.length == 1) {
              final account = subAccounts.first;
              snapshotData['sub_accounts'] = {
                'id': account['id'],
                'username': account['username'],
                'doanhso': account['doanhso'] ?? 0,
              };
              print('📸 Snapshot: Saved sub_account doanhso: ${account['doanhso']} for salesman: ${account['username']}');
            } else {
              // Nhiều nhân viên, lưu dạng List
              snapshotData['sub_accounts'] = subAccounts.map((account) => <String, dynamic>{
                'id': account['id'],
                'username': account['username'],
                'doanhso': account['doanhso'] ?? 0,
              }).toList();
              print('📸 Snapshot: Saved ${subAccounts.length} sub_accounts doanhso');
            }
          }
        } catch (e) {
          print('⚠️ WARNING: Failed to fetch sub_accounts for snapshot: $e');
          // Không throw error, tiếp tục tạo snapshot
        }
      }

      return snapshotData;
    } catch (e) {
      throw Exception('Failed to create snapshot: $e');
    }
  }

  String generateTicketId() {
    final now = DateTime.now();
    final dateFormat = DateFormat('yyyyMMdd-HHmmss');
    final randomNum = (100 + (now.millisecondsSinceEpoch % 900)).toString();
    return 'REIMPORT-${dateFormat.format(now)}-$randomNum';
  }

  Widget wrapField(Widget child, {bool isImeiField = false, bool isImeiList = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      margin: const EdgeInsets.symmetric(vertical: 4),
      height: isImeiField ? 72 : isImeiList ? 240 : 48, // Tăng chiều cao IMEI field từ 48 lên 72 (50%)
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: imeiError != null && isImeiField ? Colors.red : Colors.grey.shade300),
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

    final selectedProductIds = addedItems.map((item) => item['product_id'] as String).toSet().toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Phiếu nhập lại hàng', style: TextStyle(color: Colors.white)),
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
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Stack(
              children: [
                // Ô sản phẩm chiếm toàn bộ chiều ngang
                wrapField(
                  Autocomplete<Map<String, dynamic>>(
                    optionsBuilder: (TextEditingValue textEditingValue) {
                      final query = textEditingValue.text.toLowerCase();
                      if (query.isEmpty) return products.take(3).toList();
                      final filtered = products.where((option) => (option['name'] as String).toLowerCase().contains(query)).toList()
                        ..sort((a, b) {
                          final aName = (a['name'] as String).toLowerCase();
                          final bName = (b['name'] as String).toLowerCase();
                          final aIndex = aName.indexOf(query);
                          final bIndex = bName.indexOf(query);
                          if (aIndex != bIndex) {
                            return aIndex - bIndex;
                          }
                          return aName.compareTo(bName);
                        });
                      return filtered.isNotEmpty ? filtered : [{'id': '', 'name': 'Không tìm thấy sản phẩm'}];
                    },
                    displayStringForOption: (option) => option['name'] as String,
                    onSelected: (val) {
                      if (val['id'].isNotEmpty) {
                        setState(() {
                          productId = val['id'] as String;
                          productController.text = val['name'] as String;
                          imei = '';
                          imeiController.text = '';
                          imeiError = null;
                          addedItems = [];
                        });
                      }
                    },
                    fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                      controller.text = productController.text;
                      return TextField(
                        controller: controller,
                        focusNode: focusNode,
                        onChanged: (value) {
                          setState(() {
                            productId = null;
                            productController.text = value;
                            imei = '';
                            imeiController.text = '';
                            imeiError = null;
                            addedItems = [];
                          });
                        },
                        onEditingComplete: onFieldSubmitted,
                        decoration: const InputDecoration(
                          labelText: 'Sản phẩm',
                          border: InputBorder.none,
                          isDense: true,
                        ),
                      );
                    },
                  ),
                ),
                // Nút Auto IMEI nằm đè lên góc phải
                Positioned(
                  right: 8,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: ElevatedButton(
                      onPressed: productId != null ? _showAutoImeiDialog : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      child: const Text('Auto IMEI', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                ),
              ],
            ),
            if (selectedProductIds.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: selectedProductIds
                    .map((productId) => Chip(
                          label: Text(CacheUtil.getProductName(productId)),
                          onDeleted: () {
                            setState(() {
                              addedItems.removeWhere((item) => item['product_id'] == productId);
                            });
                          },
                        ))
                    .toList(),
              ),
            ],
            wrapField(
              Autocomplete<Map<String, dynamic>>(
                optionsBuilder: (TextEditingValue textEditingValue) {
                  final query = textEditingValue.text.toLowerCase();
                  if (query.isEmpty) return warehouses.take(10).toList();
                  final filtered = warehouses.where((option) => (option['name'] as String).toLowerCase().contains(query)).toList()
                    ..sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));
                  return filtered.isNotEmpty ? filtered.take(10).toList() : [{'id': '', 'name': 'Không tìm thấy kho'}];
                },
                displayStringForOption: (option) => option['name'] as String,
                onSelected: (val) {
                  if (val['id'].isEmpty) return;
                  setState(() {
                    warehouseId = val['id'] as String;
                    if (!warehouses.any((w) => w['id'] == val['id'])) {
                      warehouses = [...warehouses, val];
                    }
                  });
                },
                fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                  controller.text = warehouseId != null ? CacheUtil.getWarehouseName(warehouseId) : '';
                  return TextField(
                    controller: controller,
                    focusNode: focusNode,
                    onChanged: (value) {
                      if (_debounce?.isActive ?? false) _debounce?.cancel();
                      _debounce = Timer(const Duration(milliseconds: 300), () {
                        setState(() {
                          warehouseId = null;
                        });
                      });
                    },
                    decoration: const InputDecoration(
                      labelText: 'Kho nhập lại',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  );
                },
              ),
            ),
            wrapField(
              Column(
                children: [
                  // Phần nhập IMEI
                  Expanded(
                    child: Autocomplete<String>(
                      optionsBuilder: (TextEditingValue textEditingValue) {
                        final query = textEditingValue.text.toLowerCase();
                        if (productId == null) return ['Vui lòng chọn sản phẩm trước'];
                        if (query.isEmpty) return imeiSuggestions.take(10).toList();
                        final filtered = imeiSuggestions.where((option) => option.toLowerCase().contains(query)).toList()
                          ..sort((a, b) {
                            final aLower = a.toLowerCase();
                            final bLower = b.toLowerCase();
                            final aStartsWith = aLower.startsWith(query);
                            final bStartsWith = bLower.startsWith(query);
                            if (aStartsWith != bStartsWith) {
                              return aStartsWith ? -1 : 1;
                            }
                            return aLower.compareTo(bLower);
                          });
                        return filtered.isNotEmpty ? filtered.take(10).toList() : ['Không tìm thấy IMEI'];
                      },
                      onSelected: (String selection) async {
                        if (selection == 'Vui lòng chọn sản phẩm trước' || selection == 'Không tìm thấy IMEI') {
                          return;
                        }
                        final error = await _checkDuplicateImeis(selection);
                        if (error != null) {
                          setState(() {
                            imeiError = error;
                          });
                          await _showImeiErrorDialog(error);
                        } else {
                          await _addImeiToList(selection);
                          await _fetchAvailableImeis('');
                        }
                      },
                      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                        controller.text = imeiController.text;
                        return TextField(
                          controller: controller,
                          focusNode: focusNode,
                          enabled: productId != null,
                          onChanged: (value) {
                            setState(() {
                              imei = value;
                              imeiController.text = value;
                              imeiError = null;
                            });
                            if (_debounce?.isActive ?? false) _debounce!.cancel();
                            _debounce = Timer(const Duration(milliseconds: 300), () {
                              _fetchAvailableImeis(value);
                            });
                          },
                          onSubmitted: (value) async {
                            if (value.isEmpty) return;
                            final error = await _checkDuplicateImeis(value);
                            if (error != null) {
                              setState(() {
                                imeiError = error;
                              });
                              await _showImeiErrorDialog(error);
                              return;
                            }
                            await _addImeiToList(value);
                            await _fetchAvailableImeis('');
                          },
                          decoration: InputDecoration(
                            labelText: 'IMEI',
                            border: InputBorder.none,
                            isDense: true,
                            hintText: productId == null ? 'Chọn sản phẩm trước' : null,
                          ),
                        );
                      },
                    ),
                  ),
                  // 2 nút quét
                  Row(
                    children: [
                      // Nút quét QR (màu vàng)
                      Expanded(
                        child: Container(
                          height: 24, // Chiều cao bằng 1/2 của phần còn lại
                          margin: const EdgeInsets.only(right: 4),
                          child: ElevatedButton.icon(
                            onPressed: _scanQRCode,
                            icon: const Icon(Icons.qr_code_scanner, size: 16),
                            label: const Text('QR', style: TextStyle(fontSize: 12)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.amber,
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                        ),
                      ),
                      // Nút quét Text (màu xanh lá cây)
                      Expanded(
                        child: Container(
                          height: 24, // Chiều cao bằng 1/2 của phần còn lại
                          margin: const EdgeInsets.only(left: 4),
                          child: ElevatedButton.icon(
                            onPressed: _scanText,
                            icon: const Icon(Icons.text_fields, size: 16),
                            label: const Text('IMEI', style: TextStyle(fontSize: 12)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              isImeiField: true,
            ),
            wrapField(
              SizedBox(
                height: 240,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Danh sách IMEI đã thêm (${addedItems.length})',
                      style: const TextStyle(fontSize: 14, color: Colors.black54),
                    ),
                    const SizedBox(height: 4),
                    Expanded(
                      child: addedItems.isEmpty
                          ? const Center(
                              child: Text(
                                'Chưa có IMEI nào',
                                style: TextStyle(fontSize: 14, color: Colors.grey),
                              ),
                            )
                          : ListView.builder(
                              itemCount: addedItems.length < displayImeiLimit ? addedItems.length : displayImeiLimit,
                              itemBuilder: (context, index) {
                                final item = addedItems[index];
                                return Card(
                                  margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
                                  child: Padding(
                                    padding: const EdgeInsets.all(8.0),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text('Sản phẩm: ${item['product_name']}', style: const TextStyle(fontSize: 12)),
                                              Text('IMEI: ${item['imei']}', style: const TextStyle(fontSize: 12)),
                                              Text(
                                                'Khách: ${item['customer']}',
                                                style: const TextStyle(fontSize: 12),
                                              ),
                                              ...[
                                                Text(
                                                  'Giá bán: ${formatNumberLocal(item['sale_price'])} ${item['sale_currency']}',
                                                  style: const TextStyle(fontSize: 12),
                                                ),
                                                Row(
                                                  children: [
                                                    Expanded(
                                                      child: TextFormField(
                                                        initialValue: item['reimport_price'] != null ? formatNumberLocal(item['reimport_price']) : '',
                                                        keyboardType: TextInputType.number,
                                                        inputFormatters: [ThousandsFormatterLocal()],
                                                        style: const TextStyle(fontSize: 12),
                                                        decoration: const InputDecoration(
                                                          labelText: 'Giá nhập lại',
                                                          isDense: true,
                                                          contentPadding: EdgeInsets.symmetric(vertical: 4),
                                                        ),
                                                        onChanged: (value) {
                                                          final cleanedValue = value.replaceAll('.', '');
                                                          if (cleanedValue.isNotEmpty) {
                                                            final parsedValue = double.tryParse(cleanedValue);
                                                            if (parsedValue != null) {
                                                              setState(() {
                                                                addedItems[index]['reimport_price'] = parsedValue;
                                                              });
                                                              print('reimport_price for IMEI ${item['imei']}: $parsedValue');
                                                            }
                                                          } else {
                                                            setState(() {
                                                              addedItems[index]['reimport_price'] = null;
                                                            });
                                                          }
                                                        },
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                              Text('Ngày bán: ${item['sale_date']}', style: const TextStyle(fontSize: 12)),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.delete, color: Colors.red, size: 20),
                                          onPressed: () {
                                            setState(() {
                                              addedItems.removeAt(index);
                                            });
                                          },
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                    if (addedItems.length > displayImeiLimit)
                      Text(
                        '... và ${formatNumberLocal(addedItems.length - displayImeiLimit)} IMEI khác',
                        style: const TextStyle(fontSize: 14, color: Colors.grey),
                      ),
                  ],
                ),
              ),
              isImeiList: true,
            ),
            Row(
                children: [
                  Expanded(
                    child: wrapField(
                      DropdownButtonFormField<String>(
                        value: currency,
                        items: currencies.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                        hint: const Text('Đơn vị tiền'),
                        onChanged: (val) {
                          setState(() {
                            currency = val;
                            _updateAccountNames(val);
                          });
                        },
                        decoration: const InputDecoration(border: InputBorder.none, isDense: true),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: wrapField(
                      DropdownButtonFormField<String>(
                        value: account,
                        items: accountNames.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                        hint: const Text('Tài khoản'),
                        onChanged: (val) {
                          setState(() {
                            account = val;
                          });
                        },
                        decoration: const InputDecoration(border: InputBorder.none, isDense: true),
                      ),
                    ),
                  ),
                ],
              ),
            wrapField(
              TextFormField(
                onChanged: (val) {
                  setState(() {
                    note = val;
                  });
                },
                decoration: const InputDecoration(
                  labelText: 'Ghi chú',
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: showConfirmDialog,
              child: const Text('Xác nhận'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _rollbackSnapshot(Map<String, dynamic> snapshotData) async {
    final supabase = widget.tenantClient;

    try {
      if (snapshotData['customers'] != null) {
        for (var customer in snapshotData['customers']) {
          final customerId = customer['id']?.toString();
          if (customerId != null) {
            await retry(
              () => supabase.from('customers').update({
                'debt_vnd': customer['debt_vnd'],
                'debt_cny': customer['debt_cny'],
                'debt_usd': customer['debt_usd'],
              }).eq('id', customerId),
              operation: 'Rollback customer ${customer['name']} (id: $customerId)',
            );
          }
        }
      }

      if (snapshotData['transporters'] != null) {
        await retry(
          () => supabase.from('transporters').update({
            'debt': snapshotData['transporters']['debt'],
          }).eq('name', snapshotData['transporters']['name']),
          operation: 'Rollback transporter ${snapshotData['transporters']['name']}',
        );
      }

      if (snapshotData['financial_accounts'] != null) {
        await retry(
          () => supabase.from('financial_accounts').update({
            'balance': snapshotData['financial_accounts']['balance'],
          }).eq('name', snapshotData['financial_accounts']['name']).eq('currency', snapshotData['financial_accounts']['currency']),
          operation: 'Rollback financial account ${snapshotData['financial_accounts']['name']}',
        );
      }

      if (snapshotData['products'] != null) {
        for (var product in snapshotData['products']) {
          await retry(
            () => supabase.from('products').update({
              'status': product['status'],
              'warehouse_id': product['warehouse_id'],
              'cost_price': product['cost_price'],
            }).eq('imei', product['imei']),
            operation: 'Rollback product ${product['imei']}',
          );
        }
      }
    } catch (e) {
      print('Error during rollback: $e');
      throw Exception('Lỗi khi rollback dữ liệu: $e');
    }
  }
}

class QRCodeScannerScreen extends StatefulWidget {
  const QRCodeScannerScreen({super.key});

  @override
  QRCodeScannerScreenState createState() => QRCodeScannerScreenState();
}

class QRCodeScannerScreenState extends State<QRCodeScannerScreen> {
  final MobileScannerController controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
    torchEnabled: false,
  );
  bool scanned = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Quét QR Code', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on),
            onPressed: () {
              controller.toggleTorch();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            flex: 5,
            child: MobileScanner(
              controller: controller,
              onDetect: (BarcodeCapture capture) {
                if (!scanned) {
                  final String? code = capture.barcodes.first.rawValue;
                  if (code != null) {
                    setState(() {
                      scanned = true;
                    });
                    Navigator.pop(context, code);
                  }
                }
              },
            ),
          ),
          Expanded(
            flex: 1,
            child: Center(
              child: Text(
                'Quét QR code để lấy IMEI',
                style: const TextStyle(fontSize: 18, color: Colors.black),
              ),
            ),
          ),
        ],
      ),
    );
  }
}