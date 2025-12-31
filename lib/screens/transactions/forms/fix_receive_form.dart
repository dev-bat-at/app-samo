import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'fix_receive_summary.dart';
import 'dart:math' as math;
import '../../text_scanner_screen.dart';
import '../../../helpers/error_handler.dart';

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

String formatNumberLocal(num value) {
  return NumberFormat('#,###', 'vi_VN').format(value).replaceAll(',', '.');
}

class FixReceiveForm extends StatefulWidget {
  final SupabaseClient tenantClient;
  final String? initialProductId;
  final String? initialPrice;
  final String? initialImei;
  final String? initialCurrency;
  final String? initialWarehouseId;
  final List<Map<String, dynamic>> ticketItems;
  final int? editIndex;

  const FixReceiveForm({
    super.key,
    required this.tenantClient,
    this.initialProductId,
    this.initialPrice,
    this.initialImei,
    this.initialCurrency,
    this.initialWarehouseId,
    this.ticketItems = const [],
    this.editIndex,
  });

  @override
  State<FixReceiveForm> createState() => _FixReceiveFormState();
}

class _FixReceiveFormState extends State<FixReceiveForm> {
  String? productId;
  String? imei = '';
  List<String> imeiList = [];
  String? price;
  String? currency;
  String? warehouseId;
  List<Map<String, dynamic>> ticketItems = [];

  Map<String, String> productMap = {};
  List<String> currencies = [];
  List<Map<String, dynamic>> warehouses = [];
  List<Map<String, dynamic>> fixers = [];
  List<String> imeiSuggestions = [];
  bool isLoading = true;
  String? errorMessage;
  String? imeiError;

  final TextEditingController imeiController = TextEditingController();
  final TextEditingController productController = TextEditingController();
  final TextEditingController priceController = TextEditingController();
  final FocusNode imeiFocusNode = FocusNode();

  final NumberFormat numberFormat = NumberFormat.decimalPattern('vi_VN');

  @override
  void initState() {
    super.initState();
    productId = widget.initialProductId;
    price = widget.initialPrice;
    imei = widget.initialImei ?? '';
    currency = widget.initialCurrency; // Không gán mặc định là 'VND'
    warehouseId = widget.initialWarehouseId;
    ticketItems = List.from(widget.ticketItems);

    productController.text = productId != null ? CacheUtil.getProductName(productId) : '';
    priceController.text = price != null ? formatNumberLocal(double.parse(price!)) : '';
    imeiController.text = imei ?? '';

    if (widget.initialImei != null && widget.initialImei!.isNotEmpty) {
      imeiList = widget.initialImei!.split(',').where((e) => e.trim().isNotEmpty).toList();
    }

    _fetchInitialData();
  }

  @override
  void dispose() {
    imeiController.dispose();
    productController.dispose();
    priceController.dispose();
    imeiFocusNode.dispose();
    super.dispose();
  }

  Future<void> _fetchInitialData() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      final supabase = widget.tenantClient;

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
              return {'id': id, 'name': products};
            }
            return null;
          })
          .whereType<Map<String, String>>()
          .toList();

      productMap = {
        for (var product in productList)
          product['id']!: product['name']!
      };

      final warehouseResponse = await retry(
        () => supabase.from('warehouses').select('id, name'),
        operation: 'Fetch warehouses',
      );
      final warehouseList = warehouseResponse
          .map((e) {
            final id = e['id']?.toString();
            final name = e['name'] as String?;
            if (id != null && name != null) {
              CacheUtil.cacheWarehouseName(id, name);
              return {'id': id, 'name': name};
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
          .toList()
        ..sort();

      final fixerResponse = await retry(
        () => supabase.from('fix_units').select('id, name'),
        operation: 'Fetch fixers',
      );
      final fixerList = fixerResponse
          .map((e) {
            final id = e['id']?.toString();
            final name = e['name'] as String?;
            if (id != null && name != null) {
              return {'id': id, 'name': name};
            }
            return null;
          })
          .whereType<Map<String, dynamic>>()
          .toList()
        ..sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));

      if (mounted) {
        setState(() {
          warehouses = warehouseList;
          currencies = uniqueCurrencies;
          fixers = fixerList;
          currency = currency ?? (uniqueCurrencies.length == 1 ? uniqueCurrencies.first : null); // Chỉ gán currency nếu có đúng 1 loại tiền tệ
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

  Future<void> _fetchAvailableImeis(String query) async {
    if (productId == null || query.isEmpty) {
      setState(() {
        imeiSuggestions = [];
      });
      return;
    }

    try {
      final supabase = widget.tenantClient;
      final response = await retry(
        () => supabase
            .from('products')
            .select('imei')
            .eq('product_id', productId!)
            .eq('status', 'Đang sửa')
            .ilike('imei', '%$query%')
            .limit(10),
        operation: 'Fetch IMEI suggestions',
      );

      final imeiListFromDb = response
          .map((e) => e['imei'] as String?)
          .whereType<String>()
          .where((imei) => !imeiList.contains(imei))
          .toList()
        ..sort((a, b) {
          final aLower = a.toLowerCase();
          final bLower = b.toLowerCase();
          final aStartsWith = aLower.startsWith(query.toLowerCase());
          final bStartsWith = bLower.startsWith(query.toLowerCase());
          if (aStartsWith != bStartsWith) {
            return aStartsWith ? -1 : 1;
          }
          return aLower.compareTo(bLower);
        });

      if (mounted) {
        setState(() {
          imeiSuggestions = imeiListFromDb;
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

  String? _checkDuplicateImeis(String input) {
    if (imeiList.contains(input.trim())) {
      return 'IMEI "$input" đã được nhập!';
    }
    return null;
  }

  Future<String?> _checkFixStatus(List<String> imeis) async {
    if (productId == null) return 'Vui lòng chọn sản phẩm!';
    if (imeis.isEmpty) return null;

    try {
      final supabase = widget.tenantClient;
      final response = await retry(
        () => supabase
            .from('products')
            .select('imei, fix_unit')
            .inFilter('imei', imeis)
            .eq('product_id', productId!)
            .eq('status', 'Đang sửa'),
        operation: 'Check fix status',
      );

      final validImeis = response.map((p) => p['imei'] as String).toList();
      final invalidImeis = imeis.where((imei) => !validImeis.contains(imei)).toList();

      if (invalidImeis.isNotEmpty) {
        final product = CacheUtil.getProductName(productId);
        final displayImeis = invalidImeis.take(10).join(', ');
        final suffix = invalidImeis.length > 10 ? '... (tổng cộng ${invalidImeis.length} IMEI)' : '';
        return 'Các IMEI sau không tồn tại, không thuộc sản phẩm "$product", hoặc không ở trạng thái "Đang sửa": $displayImeis$suffix';
      }
      return null;
    } catch (e) {
      return 'Lỗi khi kiểm tra IMEI: $e';
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

        final duplicateError = _checkDuplicateImeis(scannedData);
        if (duplicateError != null) {
          setState(() {
            imeiError = duplicateError;
          });
          return;
        }

        final inventoryError = await _checkFixStatus([scannedData]);
        setState(() {
          imeiError = inventoryError;
        });
        if (inventoryError == null) {
          setState(() {
            imeiList.insert(0, scannedData);
            imei = '';
            imeiController.text = '';
            imeiError = null;
          });
        }
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

        final duplicateError = _checkDuplicateImeis(scannedData);
        if (duplicateError != null) {
          setState(() {
            imeiError = duplicateError;
          });
          return;
        }

        final inventoryError = await _checkFixStatus([scannedData]);
        setState(() {
          imeiError = inventoryError;
        });
        if (inventoryError == null) {
          setState(() {
            imeiList.insert(0, scannedData);
            imei = '';
            imeiController.text = '';
            imeiError = null;
          });
        }
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
    if (productId == null) {
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Thông báo'),
          content: const Text('Vui lòng chọn sản phẩm trước!'),
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

    int quantity = 0;
    String? selectedFixerId;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Tự động lấy IMEI'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Số lượng máy nhận về'),
                onChanged: (val) => quantity = int.tryParse(val) ?? 0,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: selectedFixerId,
                items: fixers.map((f) => DropdownMenuItem(
                  value: f['id'] as String,
                  child: Text(f['name'] as String),
                )).toList(),
                decoration: const InputDecoration(
                  labelText: 'Đơn vị fix lỗi',
                  border: OutlineInputBorder(),
                ),
                onChanged: (val) => setDialogState(() => selectedFixerId = val),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Hủy'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(context);
                if (quantity > 0 && selectedFixerId != null) {
                  await _fetchImeisForQuantity(quantity, selectedFixerId!);
                }
              },
              child: const Text('Xác nhận'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _fetchImeisForQuantity(int quantity, String fixerId) async {
    if (productId == null || quantity <= 0) return;

    try {
      final supabase = widget.tenantClient;
      
      // Fetch fixer name from fixerId
      final fixerData = await retry(
        () => supabase
            .from('fix_units')
            .select('name')
            .eq('id', fixerId)
            .maybeSingle(),
        operation: 'Fetch fixer name',
      );
      
      if (fixerData == null) {
        if (mounted) {
          await showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Thông báo'),
              content: const Text('Không tìm thấy đơn vị fix lỗi!'),
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
      
      final fixerName = fixerData['name'] as String;
      
      // ✅ FIX: Lấy gấp đôi để đảm bảo đủ sau khi lọc duplicate
      final fetchQuantity = quantity * 2;
      
      final response = await retry(
        () => supabase
            .from('products')
            .select('imei, import_date')
            .eq('product_id', productId!)
            .eq('status', 'Đang sửa')
            .eq('fix_unit', fixerName)
            .order('import_date', ascending: true)  // ✅ FIX: FIFO - Lấy hàng cũ nhất trước
            .limit(fetchQuantity),
        operation: 'Fetch IMEIs for auto',
      );

      final imeiListFromDb = response
          .map((e) => e['imei'] as String?)
          .whereType<String>()
          .where((imei) => imei != null && imei.trim().isNotEmpty && !imeiList.contains(imei))
          .cast<String>()
          .take(quantity)  // ✅ FIX: Chỉ lấy đúng số lượng sau khi lọc
          .toList();

      if (imeiListFromDb.length < quantity) {
        // Check tổng số lượng có đang sửa
        final totalCountResponse = await supabase
            .from('products')
            .select('imei')
            .eq('product_id', productId!)
            .eq('status', 'Đang sửa')
            .eq('fix_unit', fixerName)
            .count(CountOption.exact);
        
        final totalCount = totalCountResponse.count;
        
        if (mounted) {
          await showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Thông báo'),
              content: Text(
                'Số lượng sản phẩm không đủ!\n\n'
                'Cần: $quantity sản phẩm\n'
                'Đang sửa tại "$fixerName": $totalCount sản phẩm\n'
                'Đã nhập: ${imeiList.length} sản phẩm\n'
                'Có thể lấy thêm: ${imeiListFromDb.length} sản phẩm\n\n'
                'Sản phẩm: "${CacheUtil.getProductName(productId)}"'
              ),
              actions: [
                if (imeiListFromDb.isNotEmpty)
                  TextButton(
                    onPressed: () {
                      Navigator.pop(context);
                      setState(() {
                        imeiList.addAll(imeiListFromDb);
                      });
                    },
                    child: Text('Lấy ${imeiListFromDb.length} sản phẩm'),
                  ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Đóng'),
                ),
              ],
            ),
          );
        }
      } else {
        // Đủ số lượng, thêm vào list
        if (mounted) {
          setState(() {
            imeiList.addAll(imeiListFromDb);
          });
        }
      }
    } catch (e) {
      debugPrint('Error fetching IMEIs: $e');
      if (mounted) {
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Lỗi'),
            content: Text('Không thể tải IMEI: $e'),
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

  void addToTicket(BuildContext scaffoldContext) async {
    if (productId == null || price == null || currency == null || warehouseId == null || imeiList.isEmpty) {
      if (mounted) {
        showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Vui lòng điền đầy đủ thông tin và nhập ít nhất một IMEI!'),
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

    final amount = double.tryParse(price!);
    if (amount == null || amount < 0) {
      if (mounted) {
        showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Số tiền không hợp lệ!'),
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
        showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text('Số lượng IMEI (${formatNumberLocal(imeiList.length)}) vượt quá giới hạn ${formatNumberLocal(maxImeiQuantity)}. Vui lòng chia thành nhiều phiếu.'),
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

    String? inventoryError;
    for (int i = 0; i < imeiList.length; i += batchSize) {
      final batchImeis = imeiList.sublist(i, math.min(i + batchSize, imeiList.length));
      inventoryError = await _checkFixStatus(batchImeis);
      if (inventoryError != null) break;
    }

    if (inventoryError != null) {
      if (mounted) {
        showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text(inventoryError.toString()),
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

    final supabase = widget.tenantClient;
    String? fixer;
    String? fixerId;
    try {
      final response = await retry(
        () => supabase
            .from('products')
            .select('imei, fix_unit')
            .inFilter('imei', imeiList)
            .eq('status', 'Đang sửa'),
        operation: 'Fetch fixer from products',
      );

      // Kiểm tra số lượng bản ghi trả về
      if (response.isEmpty) {
        throw Exception('Không tìm thấy sản phẩm nào trong trạng thái "Đang sửa" cho các IMEI này!');
      }

      // Kiểm tra xem tất cả IMEI có thuộc cùng một fix_unit không
      final fixUnits = response.map((p) => p['fix_unit'] as String?).toSet();
      if (fixUnits.length > 1) {
        throw Exception('Các IMEI thuộc nhiều đơn vị sửa khác nhau: ${fixUnits.join(", ")}');
      }
      if (fixUnits.length == 1 && fixUnits.first != null) {
        fixer = fixUnits.first;
        
        // Fetch fix_unit_id from fix_units table
        final fixerData = await retry(
          () => supabase
              .from('fix_units')
              .select('id, name')
              .eq('name', fixer!)
              .maybeSingle(),
          operation: 'Fetch fixer id',
        );
        if (fixerData != null) {
          fixerId = fixerData['id']?.toString();
        }
      } else {
        throw Exception('Không tìm thấy đơn vị sửa cho các IMEI này!');
      }
    } catch (e) {
      if (mounted) {
        showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text('Lỗi khi lấy đơn vị sửa: $e'),
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

    final item = {
      'fixer': fixer,
      'fixer_id': fixerId,
      'product_id': productId!,
      'product_name': CacheUtil.getProductName(productId),
      'imei': imeiList.join(','),
      'price': amount,
      'currency': currency!,
      'warehouse_id': warehouseId!,
      'warehouse_name': CacheUtil.getWarehouseName(warehouseId),
      'quantity': imeiList.length,
    };

    setState(() {
      if (widget.editIndex != null) {
        ticketItems[widget.editIndex!] = item;
      } else {
        ticketItems.add(item);
      }
    });

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => FixReceiveSummary(
          tenantClient: widget.tenantClient,
          ticketItems: ticketItems,
          currency: currency ?? 'VND',
        ),
      ),
    );
  }

  Widget wrapField(Widget child, {bool isImeiField = false, bool isFixerField = false, bool isImeiList = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      margin: const EdgeInsets.symmetric(vertical: 4),
      height: isImeiField ? 72 : isImeiList ? 120 : isFixerField ? 56 : 48, // Tăng chiều cao IMEI field từ 48 lên 72 (50%)
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
        title: const Text('Phiếu nhận hàng sửa xong', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        leading: IconButton(
          icon: Transform.rotate(
            angle: math.pi,
            child: const Icon(Icons.arrow_forward_ios, color: Colors.white),
          ),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.arrow_forward_ios, color: Colors.white),
            onPressed: ticketItems.isEmpty
                ? null
                : () {
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                        builder: (context) => FixReceiveSummary(
                          tenantClient: widget.tenantClient,
                          ticketItems: ticketItems,
                          currency: currency ?? 'VND',
                        ),
                      ),
                    );
                  },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            wrapField(
              Autocomplete<String>(
                optionsBuilder: (TextEditingValue textEditingValue) {
                  final query = textEditingValue.text.toLowerCase();
                  if (query.isEmpty) {
                    return productMap.values.take(10).toList();
                  }
                  final filtered = productMap.entries
                      .where((entry) => entry.value.toLowerCase().contains(query))
                      .map((entry) => entry.value)
                      .toList()
                    ..sort((a, b) {
                      final aLower = a.toLowerCase();
                      final bLower = b.toLowerCase();
                      final aStartsWith = aLower.startsWith(query);
                      final bStartsWith = bLower.startsWith(query);
                      if (aStartsWith != bStartsWith) {
                        return aStartsWith ? -1 : 1;
                      }
                      final aIndex = aLower.indexOf(query);
                      final bIndex = bLower.indexOf(query);
                      if (aIndex != bIndex) {
                        return aIndex - bIndex;
                      }
                      return aLower.compareTo(bLower);
                    });
                  return filtered.isNotEmpty ? filtered.take(10).toList() : ['Không tìm thấy sản phẩm'];
                },
                onSelected: (String selection) {
                  if (selection == 'Không tìm thấy sản phẩm') return;
                  
                  final selectedEntry = productMap.entries.firstWhere(
                    (entry) => entry.value == selection,
                    orElse: () => MapEntry('', ''),
                  );
                  
                  if (selectedEntry.key.isNotEmpty) {
                    setState(() {
                      productId = selectedEntry.key;
                      productController.text = selection;
                      imei = '';
                      imeiController.text = '';
                      imeiError = null;
                      imeiList = [];
                    });
                    _fetchAvailableImeis('');
                  }
                },
                fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                  controller.text = productController.text;
                  return TextField(
                    controller: controller,
                    focusNode: focusNode,
                    onChanged: (value) {
                      setState(() {
                        productController.text = value;
                        if (value.isEmpty) {
                          productId = null;
                          imei = '';
                          imeiController.text = '';
                          imeiError = null;
                          imeiList = [];
                        }
                      });
                    },
                    decoration: const InputDecoration(
                      labelText: 'Sản phẩm',
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 8, horizontal: 0),
                      floatingLabelBehavior: FloatingLabelBehavior.auto,
                      labelStyle: TextStyle(fontSize: 14),
                    ),
                  );
                },
              ),
            ),
            wrapField(
              Autocomplete<Map<String, dynamic>>(
                optionsBuilder: (TextEditingValue textEditingValue) {
                  final query = textEditingValue.text.toLowerCase();
                  if (query.isEmpty) return warehouses;
                  final filtered = warehouses
                      .where((option) => (option['name'] as String).toLowerCase().contains(query))
                      .toList()
                    ..sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));
                  return filtered.isNotEmpty ? filtered : [{'id': '', 'name': 'Không tìm thấy kho'}];
                },
                displayStringForOption: (option) => option['name'] as String,
                onSelected: (val) {
                  if (val['id'].isEmpty) return;
                  setState(() {
                    warehouseId = val['id'] as String;
                  });
                },
                fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                  controller.text = warehouseId != null ? CacheUtil.getWarehouseName(warehouseId) : '';
                  return TextField(
                    controller: controller,
                    focusNode: focusNode,
                    onChanged: (value) {
                      setState(() {
                        warehouseId = null;
                      });
                    },
                    decoration: const InputDecoration(
                      labelText: 'Kho nhận',
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 8, horizontal: 0),
                      floatingLabelBehavior: FloatingLabelBehavior.auto,
                      labelStyle: TextStyle(fontSize: 14),
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
                        if (productId == null) return ['Vui lòng chọn sản phẩm'];
                        if (query.isEmpty) return imeiSuggestions.take(10).toList();
                        final filtered = imeiSuggestions
                            .where((option) => option.toLowerCase().contains(query))
                            .toList()
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
                        if (selection == 'Vui lòng chọn sản phẩm' || selection == 'Không tìm thấy IMEI') {
                          return;
                        }
                        
                        final error = _checkDuplicateImeis(selection);
                        if (error != null) {
                          setState(() {
                            imeiError = error;
                          });
                          await _showImeiErrorDialog(error);
                          return;
                        }

                        final inventoryError = await _checkFixStatus([selection]);
                        if (inventoryError != null) {
                          setState(() {
                            imeiError = inventoryError;
                          });
                          await _showImeiErrorDialog(inventoryError);
                          return;
                        }

                        setState(() {
                          imeiList.add(selection);
                          imei = '';
                          imeiController.text = '';
                          imeiError = null;
                        });
                        _fetchAvailableImeis('');
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
                            _fetchAvailableImeis(value);
                          },
                          onSubmitted: (value) async {
                            if (value.isEmpty) return;

                            final error = _checkDuplicateImeis(value);
                            if (error != null) {
                              setState(() {
                                imeiError = error;
                              });
                              await _showImeiErrorDialog(error);
                              return;
                            }

                            final inventoryError = await _checkFixStatus([value]);
                            if (inventoryError != null) {
                              setState(() {
                                imeiError = inventoryError;
                              });
                              await _showImeiErrorDialog(inventoryError);
                              return;
                            }

                            setState(() {
                              imeiList.add(value);
                              imei = '';
                              imeiController.text = '';
                              imeiError = null;
                            });
                            _fetchAvailableImeis('');
                          },
                          decoration: InputDecoration(
                            labelText: 'IMEI',
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 0),
                            floatingLabelBehavior: FloatingLabelBehavior.auto,
                            labelStyle: const TextStyle(fontSize: 14),
                            hintText: productId == null ? 'Chọn sản phẩm trước' : null,
                          ),
                        );
                      },
                    ),
                  ),
                  // 3 nút quét
                  Row(
                    children: [
                      // Nút quét QR (màu vàng)
                      Expanded(
                        child: Container(
                          height: 24,
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
                          height: 24,
                          margin: const EdgeInsets.symmetric(horizontal: 4),
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
                          margin: const EdgeInsets.only(left: 4),
                          child: ElevatedButton.icon(
                            onPressed: _showAutoImeiDialog,
                            icon: const Icon(Icons.flash_on, size: 16),
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
              SizedBox(
                height: 120,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Danh sách IMEI. Đã nhập ${formatNumberLocal(imeiList.length)} chiếc.',
                      style: const TextStyle(fontSize: 14, color: Colors.black54),
                    ),
                    const SizedBox(height: 4),
                    Expanded(
                      child: imeiList.isEmpty
                          ? const Center(
                              child: Text(
                                'Chưa có IMEI nào',
                                style: TextStyle(fontSize: 14, color: Colors.grey),
                              ),
                            )
                          : ListView.builder(
                              itemCount: math.min(imeiList.length, displayImeiLimit),
                              itemBuilder: (context, index) {
                                return Card(
                                  margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
                                  elevation: 0,
                                  color: Colors.grey.shade300,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Container(
                                    height: 36,
                                    padding: const EdgeInsets.symmetric(vertical: 1, horizontal: 8),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Expanded(
                                          child: Text(
                                            imeiList[index],
                                            style: const TextStyle(fontSize: 14),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.delete, color: Colors.red, size: 18),
                                          onPressed: () {
                                            setState(() {
                                              imeiList.removeAt(index);
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
                    if (imeiList.length > displayImeiLimit)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '... và ${formatNumberLocal(imeiList.length - displayImeiLimit)} IMEI khác',
                          style: const TextStyle(fontSize: 14, color: Colors.grey),
                        ),
                      ),
                  ],
                ),
              ),
              isImeiList: true,
            ),
            wrapField(
              TextFormField(
                controller: priceController,
                keyboardType: TextInputType.number,
                inputFormatters: [ThousandsFormatterLocal()],
                onChanged: (val) {
                  final cleanedValue = val.replaceAll('.', '');
                  if (cleanedValue.isNotEmpty) {
                    final parsedValue = double.tryParse(cleanedValue);
                    if (parsedValue != null) {
                      setState(() {
                        price = cleanedValue;
                      });
                    }
                  } else {
                    setState(() {
                      price = null;
                    });
                  }
                },
                decoration: const InputDecoration(
                  labelText: 'Chi phí sửa mỗi sản phẩm',
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 8, horizontal: 0),
                  floatingLabelBehavior: FloatingLabelBehavior.auto,
                  labelStyle: TextStyle(fontSize: 14),
                ),
              ),
            ),
            wrapField(
              DropdownButtonFormField<String>(
                value: currency,
                items: currencies.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                hint: const Text('Chọn loại tiền'), // Sửa hint thành "Chọn loại tiền"
                onChanged: (val) => setState(() {
                  currency = val;
                }),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 8, horizontal: 0),
                  floatingLabelBehavior: FloatingLabelBehavior.auto,
                  labelStyle: TextStyle(fontSize: 14),
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
              onPressed: () => addToTicket(context),
              child: Text(widget.editIndex != null ? 'Cập Nhật Sản Phẩm' : 'Thêm Vào Phiếu'),
            ),
          ],
        ),
      ),
    );
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