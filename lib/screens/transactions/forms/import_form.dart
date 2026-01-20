import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../../notification_service.dart';
import '../../text_scanner_screen.dart';
import '../../../helpers/cache_helper.dart';

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

class ThousandsFormatterLocal extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    String newText = newValue.text.replaceAll('.', '').replaceAll(',', '');
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

String generateTicketId() {
  final now = DateTime.now();
  final dateFormat = DateFormat('yyyyMMdd-HHmmss');
  final randomNum = (100 + (now.millisecondsSinceEpoch % 900)).toString();
  return 'IMP-${dateFormat.format(now)}-$randomNum';
}

String formatNumberLocal(num value) {
  return NumberFormat('#,###', 'vi_VN').format(value).replaceAll(',', '.');
}

class ImportForm extends StatefulWidget {
  final SupabaseClient tenantClient;

  const ImportForm({super.key, required this.tenantClient});

  @override
  State<ImportForm> createState() => _ImportFormState();
}

class _ImportFormState extends State<ImportForm> {
  int? categoryId;
  String? categoryName;
  String? supplier;
  String? supplierId;
  String? productId;
  String? productName;
  String? imei = '';
  String? price;
  String? currency;
  String? account;
  String? note;
  String? warehouseId;
  String? warehouseName;
  bool isAccessory = false;
  String? imeiError;
  bool isProcessing = false;
  final Set<String> confirmedImeis = {};
  Map<String, num>? supplierDebt; // Lưu công nợ: {'debt_vnd': ..., 'debt_cny': ..., 'debt_usd': ...}

  List<Map<String, dynamic>> categories = [];
  List<Map<String, dynamic>> suppliers = [];
  Map<String, String> supplierIdMap = {};
  List<Map<String, dynamic>> products = [];
  List<String> currencies = [];
  List<Map<String, dynamic>> accounts = [];
  List<String> accountNames = [];
  List<Map<String, dynamic>> warehouses = [];
  bool isLoading = true;
  String? errorMessage;

  final TextEditingController imeiController = TextEditingController();
  final TextEditingController priceController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _fetchInitialData();
    imeiController.text = imei ?? '';
    priceController.text = price ?? '';
    confirmedImeis.clear();
  }

  @override
  void dispose() {
    imeiController.dispose();
    priceController.dispose();
    super.dispose();
  }

  Future<void> _fetchInitialData() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      final supabase = widget.tenantClient;

      final categoryResponse = await retry(
            () => supabase.from('categories').select('id, name'),
        operation: 'Fetch categories',
      );
      final categoryList = categoryResponse
          .map((e) => {'id': e['id'] as int, 'name': e['name'] as String})
          .toList()
        ..sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));

      final supplierResponse = await retry(
            () => supabase.from('suppliers').select('id, name, phone'),
        operation: 'Fetch suppliers',
      );
      final supplierList = supplierResponse
          .map((e) {
        final id = e['id']?.toString();
        final name = e['name'] as String?;
        final phone = e['phone'] as String? ?? '';
        if (id != null && name != null) {
          return {'id': id, 'name': name, 'phone': phone};
        }
        return null;
      })
          .whereType<Map<String, dynamic>>()
          .toList()
        ..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));

      final productResponse = await retry(
            () => supabase.from('products_name').select('id, products'),
        operation: 'Fetch products',
      );
      final productList = productResponse
          .map((e) {
        final id = e['id']?.toString();
        final products = e['products'] as String?;
        if (id != null && products != null) {
          CacheUtil.cacheProductName(id, products);
          return <String, dynamic>{'id': id, 'name': products};
        }
        return null;
      })
          .whereType<Map<String, dynamic>>()
          .toList()
        ..sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));

      final warehouseResponse = await retry(
            () => supabase.from('warehouses').select('id, name, type'),
        operation: 'Fetch warehouses',
      );
      final warehouseList = warehouseResponse
          .map((e) {
        final id = e['id']?.toString();
        final name = e['name'] as String?;
        final type = e['type'] as String?;
        if (id != null && name != null && type != null) {
          CacheUtil.cacheWarehouseName(id, name);
          return {'id': id, 'name': name, 'type': type};
        }
        return null;
      })
          .whereType<Map<String, dynamic>>()
          .toList()
        ..sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));

      final currencyResponse = await retry(
            () => supabase.from('financial_accounts').select('currency').neq('currency', ''),
        operation: 'Fetch currencies',
      );
      final uniqueCurrencies = currencyResponse
          .map((e) => e['currency'] as String?)
          .whereType<String>()
          .toSet()
          .toList();

      final accountResponse = await retry(
            () => supabase.from('financial_accounts').select('id, name, currency, balance'),
        operation: 'Fetch accounts',
      );
      final accountList = accountResponse
          .map((e) => {
        'id': e['id'].toString(),
        'name': e['name'] as String?,
        'currency': e['currency'] as String?,
        'balance': e['balance'] as num?,
      })
          .where((e) => e['name'] != null && e['currency'] != null)
          .toList();

      if (mounted) {
        setState(() {
          categories = categoryList;
          suppliers = supplierList;
          supplierIdMap = {};
          for (var s in supplierList) {
            final name = s['name'] as String;
            final id = s['id'] as String;
            supplierIdMap[name] = id;
          }
          products = productList;
          warehouses = warehouseList;
          currencies = uniqueCurrencies;
          accounts = accountList;
          currency = null;
          accountNames = [];
          _updateAccountNames(null);
          isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          errorMessage = 'Không thể tải dữ liệu từ Supabase: $e';
          isLoading = false;
        });
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text('Lỗi khi tải dữ liệu: $e'),
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

  Future<void> _fetchSupplierDebt() async {
    if (supplierId == null) {
      setState(() {
        supplierDebt = null;
      });
      return;
    }

    try {
      final supabase = widget.tenantClient;
      final response = await retry(
            () => supabase
            .from('suppliers')
            .select('debt_vnd, debt_cny, debt_usd')
            .eq('id', supplierId!)
            .single(),
        operation: 'Fetch supplier debt',
      );

      setState(() {
        supplierDebt = {
          'debt_vnd': (response['debt_vnd'] as num?) ?? 0,
          'debt_cny': (response['debt_cny'] as num?) ?? 0,
          'debt_usd': (response['debt_usd'] as num?) ?? 0,
        };
      });
    } catch (e) {
      setState(() {
        supplierDebt = null;
      });
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
      if (mounted) {
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text('Lỗi khi lấy tỷ giá: $e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
      }
      return 1;
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

  String? _checkDuplicateImeis(String input) {
    // ✅ Trim IMEI để loại bỏ khoảng trắng thừa
    final lines = input.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    final seen = <String>{};
    for (var line in lines) {
      if (seen.contains(line)) {
        return 'Line "$line" đã được nhập!';
      }
      seen.add(line);
    }
    return null;
  }

  Future<String?> _checkProductStatus(String input) async {
    // ✅ Trim IMEI để loại bỏ khoảng trắng thừa
    final lines = input.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (lines.isEmpty) return null;
    final supabase = widget.tenantClient;

    try {
      for (int i = 0; i < lines.length; i += batchSize) {
        final batchImeis = lines.sublist(i, math.min(i + batchSize, lines.length));
        // ✅ Trim IMEI khi check với confirmedImeis
        final imeisToCheck = batchImeis.map((imei) => imei.trim()).where((imei) => !confirmedImeis.contains(imei)).toList();
        if (imeisToCheck.isEmpty) continue;

        final response = await retry(
              () => supabase
              .from('products')
              .select('imei, name, warehouse_id, status, return_date')
              .inFilter('imei', imeisToCheck),
          operation: 'Check product status batch ${i ~/ batchSize + 1}',
        );

        for (final product in response) {
          final imei = product['imei'] as String;
          final productName = product['name'] as String;
          final warehouseIdFromDb = product['warehouse_id']?.toString();
          final status = product['status'] as String;
          final returnDate = product['return_date'] as String?;
          final warehouseIds = warehouses.map((w) => w['id'] as String).toList();

          if (status == 'Đã trả ncc') {
            if (mounted) {
              final shouldImport = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Xác nhận nhập lại'),
                  content: Text('Sản phẩm $productName với mã "$imei" đã từng trả ncc ngày ${returnDate != null ? DateFormat('dd/MM/yyyy').format(DateTime.parse(returnDate)) : "không xác định"}. Bạn có đồng ý nhập tiếp không?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Hủy'),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Đồng ý'),
                    ),
                  ],
                ),
              );
              if (shouldImport == false) {
                return 'Đã hủy nhập lại sản phẩm với mã "$imei"';
              }
              confirmedImeis.add(imei);
            }
            continue;
          }

          if (warehouseIdFromDb != null && warehouseIds.contains(warehouseIdFromDb) ||
              productName == 'Đang sửa' || productName == 'Đang chuyển Nhật') {
            return 'Sản phẩm $productName với mã "$imei" đã tồn tại!';
          }
        }
      }
      return null;
    } catch (e) {
      return 'Lỗi khi kiểm tra mã: $e';
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
        // Phát âm âm thanh beep khi quét thành công
        _playBeepSound();
        
        // ✅ Trim IMEI để loại bỏ khoảng trắng thừa
        final trimmedScannedData = scannedData.trim();
        
        final currentImei = imei != null && imei!.isNotEmpty 
            ? '$imei\n$trimmedScannedData' 
            : trimmedScannedData;
        
        final duplicateError = _checkDuplicateImeis(currentImei);
        if (duplicateError != null) {
          setState(() {
            imei = currentImei;
            imeiController.text = currentImei;
            imeiError = duplicateError;
          });
          await _showImeiErrorDialog(duplicateError);
          return;
        }

        final productError = await _checkProductStatus(currentImei);
        if (productError != null) {
          setState(() {
            imei = currentImei;
            imeiController.text = currentImei;
            imeiError = productError;
          });
          await _showImeiErrorDialog(productError);
          return;
        }

        setState(() {
          imei = currentImei;
          imeiController.text = currentImei;
          imeiError = null;
        });
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
        
        // ✅ Trim IMEI để loại bỏ khoảng trắng thừa
        final trimmedScannedData = scannedData.trim();
        
        final currentImei = imei != null && imei!.isNotEmpty 
            ? '$imei\n$trimmedScannedData' 
            : trimmedScannedData;
        
        final duplicateError = _checkDuplicateImeis(currentImei);
        if (duplicateError != null) {
          setState(() {
            imei = currentImei;
            imeiController.text = currentImei;
            imeiError = duplicateError;
          });
          await _showImeiErrorDialog(duplicateError);
          return;
        }

        final productError = await _checkProductStatus(currentImei);
        if (productError != null) {
          setState(() {
            imei = currentImei;
            imeiController.text = currentImei;
            imeiError = productError;
          });
          await _showImeiErrorDialog(productError);
          return;
        }

        setState(() {
          imei = currentImei;
          imeiController.text = currentImei;
          imeiError = null;
        });
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
    if (productId == null || warehouseId == null) {
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Thông báo'),
          content: const Text('Vui lòng chọn sản phẩm và kho hàng trước!'),
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

    int quantity = 1;
    String? imeiPrefix;

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tự động sinh IMEI'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Số lượng'),
              onChanged: (val) => quantity = int.tryParse(val) ?? 1,
            ),
            const SizedBox(height: 8),
            TextField(
              decoration: const InputDecoration(labelText: 'Đầu mã bắt đầu'),
              onChanged: (val) => imeiPrefix = val.isNotEmpty ? val : null,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Hủy'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _generateAutoImeis(quantity, imeiPrefix);
            },
            child: const Text('Xác nhận'),
          ),
        ],
      ),
    );
  }

  void _generateAutoImeis(int quantity, String? prefix) {
    if (quantity <= 0) return;
    
    final List<String> newImeis = [];
    final effectivePrefix = prefix?.isNotEmpty == true ? prefix! : (isAccessory ? 'PK' : 'AUTO');
    
    for (int i = 0; i < quantity; i++) {
      final randomNumbers = math.Random().nextInt(10000000).toString().padLeft(7, '0');
      newImeis.add('$effectivePrefix$randomNumbers');
    }
    
    setState(() {
      if (imei != null && imei!.isNotEmpty) {
        imei = '$imei\n${newImeis.join('\n')}';
      } else {
        imei = newImeis.join('\n');
      }
      imeiController.text = imei ?? '';
    });
  }

  Future<Map<String, dynamic>> _createSnapshot(String ticketId, List<String> imeiList) async {
    final supabase = widget.tenantClient;
    final snapshotData = <String, dynamic>{};

    try {
      if (supplierId != null) {
        final supplierData = await retry(
              () => supabase.from('suppliers').select().eq('id', supplierId!).single(),
          operation: 'Fetch supplier data',
        );
        snapshotData['suppliers'] = supplierData;
      }

      if (account != null && account != 'Công nợ' && currency != null) {
        final accountData = await retry(
              () => supabase
              .from('financial_accounts')
              .select()
              .eq('name', account!)
              .eq('currency', currency!)
              .single(),
          operation: 'Fetch account data',
        );
        snapshotData['financial_accounts'] = accountData;
      }

      if (imeiList.isNotEmpty) {
        final productsData = await retry(
              () => supabase.from('products').select().inFilter('imei', imeiList),
          operation: 'Fetch products data',
        );
        snapshotData['products'] = productsData;
      }

      snapshotData['import_orders'] = [
        {
          'id': ticketId,
          'supplier_id': supplierId,
          'warehouse_id': warehouseId,
          'warehouse_name': CacheUtil.getWarehouseName(warehouseId),
          'product_id': productId,
          'product_name': CacheUtil.getProductName(productId),
          'imei': imeiList.join(','),
          'quantity': imeiList.length,
          'price': double.tryParse(priceController.text.replaceAll('.', '')) ?? 0,
          'currency': currency,
          'account': account,
          'note': note,
          'total_amount': (double.tryParse(priceController.text.replaceAll('.', '')) ?? 0) * imeiList.length,
        }
      ];

      return snapshotData;
    } catch (e) {
      throw Exception('Failed to create snapshot: $e');
    }
  }

  void addCategoryDialog() async {
    String name = '';
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Thêm chủng loại sản phẩm'),
        content: TextField(
          decoration: const InputDecoration(labelText: 'Tên chủng loại'),
          onChanged: (val) => name = val,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Hủy')),
          ElevatedButton(
            onPressed: () async {
              if (name.isEmpty) {
                await showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Thông báo'),
                    content: const Text('Tên chủng loại không được để trống!'),
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
              try {
                final response = await retry(
                      () => widget.tenantClient
                      .from('categories')
                      .insert({'name': name})
                      .select('id, name')
                      .single(),
                  operation: 'Add category',
                );

                final newCategory = {
                  'id': response['id'] as int,
                  'name': response['name'] as String,
                };
                
                // Note: Categories không cần GlobalCache vì không có autocomplete ở form khác
                // Chỉ cache local trong form này là đủ

                setState(() {
                  categories.add(newCategory);
                  categories.sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));
                  categoryId = newCategory['id'] as int;
                  categoryName = newCategory['name'] as String;
                  isAccessory = categoryName == 'Linh phụ kiện';
                });
                Navigator.pop(context);
              } catch (e) {
                await showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Thông báo'),
                    content: Text('Lỗi khi thêm chủng loại: $e'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Đóng'),
                      ),
                    ],
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

  void addSupplierDialog() async {
    String name = '';
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Thêm nhà cung cấp'),
        content: TextField(
          decoration: const InputDecoration(labelText: 'Tên nhà cung cấp'),
          onChanged: (val) => name = val,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Hủy')),
          ElevatedButton(
            onPressed: () async {
              if (name.isEmpty) {
                await showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Thông báo'),
                    content: const Text('Tên nhà cung cấp không được để trống!'),
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
              try {
                final response = await retry(
                      () => widget.tenantClient.from('suppliers').insert({
                    'name': name,
                    'debt_vnd': 0,
                    'debt_cny': 0,
                    'debt_usd': 0,
                  }).select('id, name').single(),
                  operation: 'Add supplier',
                );
                final newSupplierId = response['id']?.toString();
                final newSupplierName = response['name'] as String;
                
                // ✅ Cache supplier ngay sau khi tạo
                if (newSupplierId != null) {
                  CacheHelper.cacheSupplier(newSupplierId, newSupplierName);
                  
                  setState(() {
                    suppliers.add({'id': newSupplierId, 'name': name});
                    suppliers.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
                    supplier = name;
                    supplierId = newSupplierId;
                    supplierIdMap[name] = newSupplierId;
                  });
                }
                Navigator.pop(context);
              } catch (e) {
                await showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Thông báo'),
                    content: Text('Lỗi khi thêm nhà cung cấp: $e'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Đóng'),
                      ),
                    ],
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

  void addProductDialog() async {
    String name = '';
    int? selectedCategoryId = categoryId;
    String? selectedCategoryName = categoryName;
    
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Thêm sản phẩm'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int>(
                  value: selectedCategoryId,
                  decoration: const InputDecoration(
                    labelText: 'Chủng loại sản phẩm *',
                    border: OutlineInputBorder(),
                  ),
                  items: categories.map((e) => DropdownMenuItem<int>(
                    value: e['id'] as int,
                    child: Text(e['name'] as String),
                  )).toList(),
                  onChanged: (val) {
                    setDialogState(() {
                      selectedCategoryId = val;
                      if (val != null) {
                        final selectedCategory = categories.firstWhere((e) => e['id'] == val);
                        selectedCategoryName = selectedCategory['name'] as String;
                      }
                    });
                  },
                ),
                const SizedBox(height: 16),
                TextField(
                  decoration: const InputDecoration(
                    labelText: 'Tên sản phẩm *',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (val) => name = val,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Hủy')),
            ElevatedButton(
              onPressed: () async {
                if (name.isEmpty) {
                  await showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Thông báo'),
                      content: const Text('Tên sản phẩm không được để trống!'),
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
                if (selectedCategoryId == null) {
                  await showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Thông báo'),
                      content: const Text('Vui lòng chọn chủng loại sản phẩm!'),
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
                try {
                  final response = await retry(
                        () => widget.tenantClient
                        .from('products_name')
                        .insert({
                          'products': name,
                          'category_id': selectedCategoryId,
                        })
                        .select('id, products')
                        .single(),
                    operation: 'Add product',
                  );
                  final newProductId = response['id']?.toString();
                  if (newProductId != null) {
                    // ✅ Cache product vào cả local và global cache
                    CacheUtil.cacheProductName(newProductId, name);
                    CacheHelper.cacheProduct(newProductId, name);
                    
                    setState(() {
                      products.add(<String, dynamic>{
                        'id': newProductId,
                        'name': name,
                      });
                      products.sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));
                      productId = newProductId;
                      productName = name;
                      // Cập nhật categoryId và categoryName nếu chưa có
                      if (categoryId == null) {
                        categoryId = selectedCategoryId;
                        categoryName = selectedCategoryName;
                        isAccessory = categoryName == 'Linh phụ kiện';
                      }
                    });
                    Navigator.pop(context);
                    await showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Thông báo'),
                        content: const Text('Đã thêm sản phẩm thành công'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Đóng'),
                          ),
                        ],
                      ),
                    );
                  }
                } catch (e) {
                  await showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Thông báo'),
                      content: Text('Lỗi khi thêm sản phẩm: $e'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Đóng'),
                        ),
                      ],
                    ),
                  );
                }
              },
              child: const Text('Lưu'),
            ),
          ],
        ),
      ),
    );
  }

  void addWarehouseDialog() async {
    String name = '';
    String type = 'nội địa';
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Thêm kho hàng'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              decoration: const InputDecoration(labelText: 'Tên kho hàng'),
              onChanged: (val) => name = val,
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: type,
              items: const [
                DropdownMenuItem(value: 'nội địa', child: Text('Nội địa')),
                DropdownMenuItem(value: 'quốc tế', child: Text('Quốc tế')),
              ],
              onChanged: (val) => type = val!,
              decoration: const InputDecoration(
                labelText: 'Loại kho',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Hủy')),
          ElevatedButton(
            onPressed: () async {
              if (name.isEmpty) {
                await showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Thông báo'),
                    content: const Text('Tên kho hàng không được để trống!'),
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
              try {
                final response = await retry(
                      () => widget.tenantClient
                      .from('warehouses')
                      .insert({'name': name, 'type': type})
                      .select('id, name')
                      .single(),
                  operation: 'Add warehouse',
                );
                final newWarehouseId = response['id']?.toString();
                if (newWarehouseId != null) {
                  // ✅ Cache warehouse vào cả local và global cache
                  CacheUtil.cacheWarehouseName(newWarehouseId, name);
                  CacheHelper.cacheWarehouse(newWarehouseId, name);
                  
                  setState(() {
                    warehouses.add({'id': newWarehouseId, 'name': response['name'], 'type': type});
                    warehouses.sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));
                    warehouseId = newWarehouseId;
                    warehouseName = name;
                  });
                  Navigator.pop(context);
                }
              } catch (e) {
                await showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Thông báo'),
                    content: Text('Lỗi khi thêm kho hàng: $e'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Đóng'),
                      ),
                    ],
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

  Future<void> showConfirmDialog(BuildContext scaffoldContext) async {
    if (categoryId == null ||
        supplier == null ||
        productId == null ||
        warehouseId == null ||
        priceController.text.isEmpty ||
        account == null ||
        currency == null ||
        (imei == null || imei!.isEmpty)) {
      if (mounted) {
        await showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Vui lòng điền đầy đủ thông tin!'),
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

    if (imeiError != null && mounted) {
      await showDialog(
        context: scaffoldContext,
        builder: (context) => AlertDialog(
          title: const Text('Thông báo'),
          content: Text(imeiError!),
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

    final now = DateTime.now();
    final amount = double.tryParse(priceController.text.replaceAll('.', '')) ?? 0;

    List<String> imeiList = [];
    if (imei != null && imei!.isNotEmpty) {
      // ✅ Trim từng IMEI để loại bỏ khoảng trắng thừa
      imeiList = imei!.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    }

    if (imeiList.isEmpty) {
      if (mounted) {
        await showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Vui lòng nhập ít nhất một mã hoặc sinh mã tự động!'),
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

    if (imeiList.length > maxImeiQuantity) {
      if (mounted) {
        await showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text('Số lượng mã (${formatNumberLocal(imeiList.length)}) vượt quá giới hạn ${formatNumberLocal(maxImeiQuantity)}. Vui lòng chia thành nhiều phiếu.'),
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

    if (imeiList.length >= warnImeiQuantity && mounted) {
      await showDialog(
        context: scaffoldContext,
        builder: (context) => AlertDialog(
          title: const Text('Cảnh báo'),
          content: Text('Danh sách mã đã vượt quá ${formatNumberLocal(warnImeiQuantity)} số. Nên chia thành nhiều phiếu nhỏ hơn để tối ưu hiệu suất.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Đã hiểu'),
            ),
          ],
        ),
      );
    }

    final totalAmount = amount * imeiList.length;

    if (mounted) {
      await showDialog(
        context: scaffoldContext,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Xác nhận phiếu nhập'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Chủng loại: ${categoryName ?? 'Không xác định'}'),
                Text('Nhà cung cấp: ${supplier ?? 'Không xác định'}'),
                Text('Kho: ${CacheUtil.getWarehouseName(warehouseId)}'),
                Text('Sản phẩm: ${CacheUtil.getProductName(productId)}'),
                const Text('Danh sách mã:'),
                ...imeiList.take(displayImeiLimit).map((imei) => Text('- $imei')),
                if (imeiList.length > displayImeiLimit)
                  Text('... và ${formatNumberLocal(imeiList.length - displayImeiLimit)} mã khác'),
                Text('Số lượng: ${formatNumberLocal(imeiList.length)}'),
                Text('Số tiền: ${formatNumberLocal(amount)} ${currency ?? ''}'),
                Text('Tổng tiền: ${formatNumberLocal(totalAmount)} ${currency ?? ''}'),
                Text('Tài khoản: ${account ?? 'Không xác định'}'),
                Text('Ghi chú: ${note ?? 'Không có'}'),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Sửa lại')),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(dialogContext);
                setState(() {
                  isProcessing = true;
                });

                try {
                  if (account != 'Công nợ') {
                    final selectedAccount = accounts.firstWhere((acc) => acc['name'] == account);
                    final currentBalance = selectedAccount['balance'] as num? ?? 0;
                    if (currentBalance < totalAmount) {
                      setState(() {
                        isProcessing = false;
                      });
                      if (mounted) {
                        await showDialog(
                          context: scaffoldContext,
                          builder: (context) => AlertDialog(
                            title: const Text('Thông báo'),
                            content: const Text('Tài khoản không đủ số dư để thanh toán!'),
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
                  }

                  final supabase = widget.tenantClient;

                  for (int i = 0; i < imeiList.length; i += batchSize) {
                    // ✅ Đảm bảo IMEI đã được trim trước khi check với database
                    final batchImeis = imeiList.sublist(i, math.min(i + batchSize, imeiList.length)).map((e) => e.trim()).toList();
                    final existingProducts = await retry(
                          () => supabase
                          .from('products')
                          .select('imei, status, return_date')
                          .inFilter('imei', batchImeis),
                      operation: 'Check existing products batch ${i ~/ batchSize + 1}',
                    );

                    for (final product in existingProducts) {
                      final status = product['status'] as String;
                      if (status != 'Đã trả ncc') {
                        final duplicateImei = product['imei'] as String;
                        setState(() {
                          isProcessing = false;
                        });
                        if (mounted) {
                          await showDialog(
                            context: scaffoldContext,
                            builder: (context) => AlertDialog(
                              title: const Text('Thông báo'),
                              content: Text('Sản phẩm với mã "$duplicateImei" đã tồn tại!'),
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
                    }
                  }

                  final exchangeRate = await _getExchangeRate(currency!);
                  if (exchangeRate == 1 && currency != 'VND') {
                    throw Exception('Vui lòng tạo phiếu đổi tiền để cập nhật tỷ giá cho $currency.');
                  }

                  num costPrice = amount;
                  if (currency == 'CNY') {
                    costPrice *= exchangeRate;
                  } else if (currency == 'USD') {
                    costPrice *= exchangeRate;
                  }

                  // Generate ticket ID
                  final ticketId = generateTicketId();

                  // Create snapshot
                  final snapshotData = await retry(
                    () => _createSnapshot(ticketId, imeiList),
                    operation: 'Create snapshot',
                  );

                  // Prepare supplier debt change
                  Map<String, dynamic>? supplierDebtChange;
                  if (account == 'Công nợ') {
                    supplierDebtChange = {
                      'debt_vnd': currency == 'VND' ? totalAmount : 0,
                      'debt_cny': currency == 'CNY' ? totalAmount : 0,
                      'debt_usd': currency == 'USD' ? totalAmount : 0,
                    };
                  }

                  // Prepare account balance change
                  double? accountBalanceChange;
                  if (account != null && account != 'Công nợ') {
                    accountBalanceChange = -totalAmount; // Negative because money goes out
                  }

                  // Debug logging
                  print('🔍 DEBUG: Calling import RPC with data:');
                  print('  ticket_id: $ticketId');
                  print('  supplier_id: $supplierId');
                  print('  product_id: $productId');
                  print('  warehouse_id: $warehouseId');
                  print('  category_id: $categoryId');
                  print('  imei_list count: ${imeiList.length}');
                  print('  supplier_debt_change: $supplierDebtChange');
                  print('  account_balance_change: $accountBalanceChange');

                  // ✅ CALL RPC FUNCTION - All operations in ONE atomic transaction
                  final result = await retry(
                    () => supabase.rpc('create_import_transaction', params: {
                      'p_ticket_id': ticketId,
                      'p_supplier_id': supplierId,
                      'p_warehouse_id': warehouseId,
                      'p_product_id': productId,
                      'p_product_name': CacheUtil.getProductName(productId),
                      'p_category_id': categoryId,
                      'p_imei_list': imeiList,
                      'p_price': amount,
                      'p_currency': currency,
                      'p_account': account ?? '',
                      'p_note': note ?? '',
                      'p_cost_price': costPrice,
                      'p_supplier_debt_change': supplierDebtChange,
                      'p_account_balance_change': accountBalanceChange,
                      'p_snapshot_data': snapshotData,
                      'p_created_at': now.toIso8601String(),
                    }),
                    operation: 'Create import transaction (RPC)',
                  );

                  // Check result
                  if (result == null || result['success'] != true) {
                    throw Exception('RPC function returned error: ${result?['message'] ?? 'Unknown error'}');
                  }

                  print('✅ Import transaction created successfully via RPC!');

                  final currentProductId = productId;
                  final currentImeiListLength = imeiList.length;
                  
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

                  await NotificationService.showNotification(
                    132,
                    'Phiếu Nhập Hàng Đã Tạo',
                    'Đã nhập hàng "${CacheUtil.getProductName(currentProductId)}" số lượng ${formatNumberLocal(currentImeiListLength)} chiếc',
                    'import_created',
                  );
                  
                  // ✅ Gửi thông báo push đến tất cả thiết bị
                  await NotificationService.sendNotificationToAll(
                    'Phiếu Nhập Hàng Đã Tạo',
                    'Đã nhập hàng "${CacheUtil.getProductName(currentProductId)}" số lượng ${formatNumberLocal(currentImeiListLength)} chiếc',
                    data: {'type': 'import_created'},
                  );
                  
                  // ✅ Gửi thông báo Telegram với thông tin chi tiết
                  await NotificationService.sendTransactionToTelegram(
                    transactionType: 'import',
                    type: 'Phiếu Nhập Hàng',
                    ticketId: ticketId,
                    productName: CacheUtil.getProductName(currentProductId),
                    quantity: currentImeiListLength,
                    imeiList: imeiList.join(', '),
                    price: formatNumberLocal(amount),
                    totalAmount: formatNumberLocal(totalAmount),
                    currency: currency ?? 'VND',
                    paymentMethod: account ?? 'Công nợ',
                    account: account != 'Công nợ' ? account : null,
                    finalBalance: finalBalanceStr,
                    note: note,
                  );

                  if (mounted) {
                    // Reset all fields
                    setState(() {
                      categoryId = null;
                      categoryName = null;
                      supplier = null;
                      supplierId = null;
                      productId = null;
                      productName = null;
                      imei = '';
                      price = null;
                      currency = null;
                      account = null;
                      note = null;
                      warehouseId = null;
                      warehouseName = null;
                      isAccessory = false;
                      imeiError = null;
                      isProcessing = false;
                      accountNames = [];
                    });
                    
                    // Clear controllers
                    imeiController.clear();
                    priceController.clear();
                    confirmedImeis.clear();
                    
                    // Show success message
                    ScaffoldMessenger.of(scaffoldContext).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Đã nhập hàng "${CacheUtil.getProductName(currentProductId)}" số lượng ${formatNumberLocal(currentImeiListLength)} chiếc',
                          style: const TextStyle(color: Colors.white),
                        ),
                        backgroundColor: Colors.green,
                        behavior: SnackBarBehavior.floating,
                        margin: const EdgeInsets.all(8),
                        duration: const Duration(seconds: 2),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    );
                  }
                } catch (e) {
                  print('❌ ERROR: $e');
                  print('❌ ERROR TYPE: ${e.runtimeType}');
                  
                  setState(() {
                    isProcessing = false;
                  });
                  
                  if (mounted) {
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
                        title: const Text('Lỗi tạo phiếu nhập hàng'),
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
              },
              child: const Text('Tạo phiếu'),
            ),
          ],
        ),
      );
    }
  }

  Widget wrapField(Widget child, {bool isImeiField = false, bool isSupplierField = false, bool isImeiList = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      margin: const EdgeInsets.symmetric(vertical: 4),
      height: isImeiField ? 144 : isImeiList ? 120 : isSupplierField ? 56 : 48, // Tăng chiều cao IMEI field từ 96 lên 144 (50%)
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: imeiError != null && isImeiField ? Colors.red : Colors.grey.shade300),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Phiếu nhập hàng', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: wrapField(
                        DropdownButtonFormField<int>(
                          value: categoryId,
                          items: categories.map((e) => DropdownMenuItem<int>(
                            value: e['id'] as int,
                            child: Text(e['name'] as String),
                          )).toList(),
                          decoration: const InputDecoration(
                            labelText: 'Chủng loại sản phẩm',
                            border: InputBorder.none,
                            isDense: true,
                          ),
                          onChanged: (val) {
                            if (val != null) {
                              final selectedCategory = categories.firstWhere((e) => e['id'] == val);
                              setState(() {
                                categoryId = val;
                                categoryName = selectedCategory['name'] as String;
                                isAccessory = categoryName == 'Linh phụ kiện';
                              });
                            }
                          },
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: addCategoryDialog,
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ],
                ),
                  Row(
                  children: [
                    Expanded(
                      child: wrapField(
                        Autocomplete<Map<String, dynamic>>(
                          optionsBuilder: (textEditingValue) {
                            final query = textEditingValue.text.toLowerCase();
                            final filtered = suppliers
                                .where((e) {
                                  final name = (e['name'] as String).toLowerCase();
                                  final phone = (e['phone'] as String? ?? '').toLowerCase();
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
                                return aName.compareTo(bName);
                              });
                            return filtered.isNotEmpty ? filtered.take(10).toList() : [{'id': '', 'name': 'Không tìm thấy nhà cung cấp', 'phone': ''}];
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
                            if (val['id'].isNotEmpty) {
                              setState(() {
                                supplier = val['name'] as String;
                                supplierId = val['id'] as String;
                              });
                              await _fetchSupplierDebt();
                            }
                          },
                          fieldViewBuilder: (context, controller, focusNode, onSubmit) {
                            controller.text = supplier ?? '';
                            return TextField(
                              controller: controller,
                              focusNode: focusNode,
                              onChanged: (val) => setState(() {
                                supplier = val.isNotEmpty ? val : null;
                                if (val.isEmpty) {
                                  supplierId = null;
                                  supplierDebt = null;
                                }
                              }),
                              decoration: const InputDecoration(
                                labelText: 'Nhà cung cấp',
                                border: InputBorder.none,
                                isDense: true,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: addSupplierDialog,
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ],
                ),
                if (supplierDebt != null) ...[
                  Builder(
                    builder: (context) {
                      final debtVnd = supplierDebt!['debt_vnd'] ?? 0;
                      final debtCny = supplierDebt!['debt_cny'] ?? 0;
                      final debtUsd = supplierDebt!['debt_usd'] ?? 0;
                      
                      final debtDetails = <String>[];
                      if (debtVnd != 0) debtDetails.add('${formatNumberLocal(debtVnd.abs())} VND');
                      if (debtCny != 0) debtDetails.add('${formatNumberLocal(debtCny.abs())} CNY');
                      if (debtUsd != 0) debtDetails.add('${formatNumberLocal(debtUsd.abs())} USD');
                      
                      if (debtDetails.isEmpty) {
                        return const SizedBox.shrink();
                      }
                      
                      final debtText = debtDetails.join(', ');
                      final isPositive = debtVnd > 0 || debtCny > 0 || debtUsd > 0;
                      final message = isPositive ? 'Mình còn nợ $debtText' : 'Ncc nợ mình $debtText';
                      
                      return Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          message,
                          style: TextStyle(color: isPositive ? Colors.red : Colors.blue),
                        ),
                      );
                    },
                  ),
                ],
                Row(
                  children: [
                    Expanded(
                      child: wrapField(
                        Autocomplete<Map<String, dynamic>>(
                          optionsBuilder: (textEditingValue) {
                            final query = textEditingValue.text.toLowerCase();
                            final filtered = products
                                .where((e) => (e['name'] as String).toLowerCase().contains(query))
                                .toList()
                              ..sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));
                            return filtered.isNotEmpty ? filtered.take(10).toList() : [{'id': '', 'name': 'Không tìm thấy sản phẩm'}];
                          },
                          displayStringForOption: (option) => option['name'] as String,
                          onSelected: (val) {
                            if (val['id'].isNotEmpty) {
                              setState(() {
                                productId = val['id'] as String;
                                productName = val['name'] as String;
                              });
                            }
                          },
                          fieldViewBuilder: (context, controller, focusNode, onSubmit) {
                            controller.text = productName ?? '';
                            return TextField(
                              controller: controller,
                              focusNode: focusNode,
                              onChanged: (val) => setState(() {
                                productId = null;
                                productName = val.isNotEmpty ? val : null;
                              }),
                              decoration: const InputDecoration(
                                labelText: 'Sản phẩm',
                                border: InputBorder.none,
                                isDense: true,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: addProductDialog,
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: wrapField(
                        Autocomplete<Map<String, dynamic>>(
                          optionsBuilder: (textEditingValue) {
                            final query = textEditingValue.text.toLowerCase();
                            final filtered = warehouses
                                .where((e) => (e['name'] as String).toLowerCase().contains(query))
                                .toList()
                              ..sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));
                            return filtered.isNotEmpty ? filtered.take(10).toList() : [{'id': '', 'name': 'Không tìm thấy kho'}];
                          },
                          displayStringForOption: (option) => option['name'] as String,
                          onSelected: (val) {
                            if (val['id'].isNotEmpty) {
                              setState(() {
                                warehouseId = val['id'] as String;
                                warehouseName = val['name'] as String;
                              });
                            }
                          },
                          fieldViewBuilder: (context, controller, focusNode, onSubmit) {
                            controller.text = warehouseName ?? '';
                            return TextField(
                              controller: controller,
                              focusNode: focusNode,
                              onChanged: (val) => setState(() {
                                warehouseId = null;
                                warehouseName = val.isNotEmpty ? val : null;
                              }),
                              decoration: const InputDecoration(
                                labelText: 'Kho hàng',
                                border: InputBorder.none,
                                isDense: true,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: addWarehouseDialog,
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ],
                ),
            if (!isAccessory)
              wrapField(
                Column(
                  children: [
                    // ✅ FIX: Hiển thị số lượng IMEI đã nhập
                    if (imei != null && imei!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Đã nhập ${imei!.split('\n').where((e) => e.trim().isNotEmpty).length} IMEI',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                                color: Colors.blue,
                              ),
                            ),
                            TextButton.icon(
                              onPressed: () {
                                setState(() {
                                  imei = '';
                                  imeiController.clear();
                                  imeiError = null;
                                });
                              },
                              icon: const Icon(Icons.clear_all, size: 16),
                              label: const Text('Xóa tất cả', style: TextStyle(fontSize: 12)),
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.red,
                                padding: EdgeInsets.zero,
                                minimumSize: const Size(0, 0),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                          ],
                        ),
                      ),
                    // Phần nhập IMEI
                    Expanded(
                      child: TextFormField(
                        controller: imeiController,
                        maxLines: null,
                        onChanged: (val) {
                          setState(() {
                            imei = val;
                            imeiError = _checkDuplicateImeis(val);
                          });

                          if (imeiError == null) {
                            _checkProductStatus(val).then((error) async {
                              if (mounted && error != null) {
                                setState(() => imeiError = error);
                                await _showImeiErrorDialog(error);
                              }
                            });
                          } else if (imeiError != null) {
                            _showImeiErrorDialog(imeiError!);
                          }
                        },
                        onEditingComplete: () {
                          // ✅ Normalize IMEI khi user hoàn thành nhập (trim từng dòng)
                          final currentText = imeiController.text;
                          final normalizedLines = currentText.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
                          final normalizedText = normalizedLines.join('\n');
                          if (normalizedText != currentText) {
                            imeiController.text = normalizedText;
                            setState(() {
                              imei = normalizedText;
                              imeiError = _checkDuplicateImeis(normalizedText);
                            });
                          }
                        },
                        decoration: InputDecoration(
                          labelText: 'Nhập IMEI hoặc quét QR (mỗi dòng 1)',
                          border: InputBorder.none,
                          isDense: true,
                          floatingLabelBehavior: FloatingLabelBehavior.never, // ✅ Label biến mất khi focus
                        ),
                      ),
                    ),
                    // 3 nút quét
                    Row(
                      children: [
                        // Nút quét QR (màu vàng)
                        Expanded(
                          child: Container(
                            height: 24,
                            margin: const EdgeInsets.only(right: 2),
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
                            height: 24,
                            margin: const EdgeInsets.symmetric(horizontal: 2),
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
                        // Nút Auto IMEI (màu xanh dương)
                        Expanded(
                          child: Container(
                            height: 24,
                            margin: const EdgeInsets.only(left: 2),
                            child: ElevatedButton.icon(
                              onPressed: _showAutoImeiDialog,
                              icon: const Icon(Icons.auto_awesome, size: 16),
                              label: const Text('Auto', style: TextStyle(fontSize: 12)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.blue,
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
                  TextFormField(
                    controller: priceController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [ThousandsFormatterLocal()],
                    onChanged: (val) => setState(() {
                      price = val.replaceAll('.', '');
                    }),
                    decoration: const InputDecoration(
                      labelText: 'Số tiền',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: wrapField(
                        DropdownButtonFormField<String>(
                          value: currency,
                          hint: const Text('Loại tiền'),
                          items: currencies.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                          decoration: const InputDecoration(
                            labelText: 'Đơn vị tiền',
                            border: InputBorder.none,
                            isDense: true,
                          ),
                          onChanged: (val) => setState(() {
                            currency = val;
                            _updateAccountNames(val);
                          }),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: wrapField(
                        DropdownButtonFormField<String>(
                          value: account,
                          items: accountNames.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                          decoration: const InputDecoration(
                            labelText: 'Tài khoản',
                            border: InputBorder.none,
                            isDense: true,
                          ),
                          onChanged: (val) => setState(() => account = val),
                        ),
                      ),
                    ),
                  ],
                ),
                wrapField(
                  TextFormField(
                    decoration: const InputDecoration(
                      labelText: 'Ghi chú ý',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    onChanged: (val) => setState(() => note = val),
                  ),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 20),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: isProcessing ? null : () => showConfirmDialog(context),
                  child: const Text('Xác nhận'),
                ),
              ],
            ),
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

class QRCodeScannerScreen extends StatefulWidget {
  const QRCodeScannerScreen({super.key});

  @override
  State<QRCodeScannerScreen> createState() => _QRCodeScannerScreenState();
}

class _QRCodeScannerScreenState extends State<QRCodeScannerScreen> {
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
        title: const Text('Quét mã QR', style: TextStyle(color: Colors.white)),
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
              child: const Text(
                'Quét mã QR để lấy mã số',
                style: TextStyle(fontSize: 18, color: Colors.black),
              ),
            ),
          ),
        ],
      ),
    );
  }
}