import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'return_summary.dart';
import '../../text_scanner_screen.dart';

// Constants for IMEI handling
const int maxImeiQuantity = 100000;
const int warnImeiQuantity = 10000;
const int batchSize = 1000;
const int displayImeiLimit = 100;

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

class CacheUtil {
  static final Map<String, String> productNameCache = {};
  static final Map<String, String> warehouseNameCache = {};

  static void cacheProductName(String id, String name) => productNameCache[id] = name;
  static String getProductName(String? id) => id != null ? productNameCache[id] ?? 'Không xác định' : 'Không xác định';
  static void cacheWarehouseName(String id, String name) => warehouseNameCache[id] = name;
  static String getWarehouseName(String? id) => id != null ? warehouseNameCache[id] ?? 'Không xác định' : 'Không xác định';
}

class Debouncer {
  final Duration delay;
  Timer? _timer;

  Debouncer({required this.delay});

  void run(VoidCallback action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  void dispose() {
    _timer?.cancel();
  }
}

class ReturnForm extends StatefulWidget {
  final SupabaseClient tenantClient;
  final String? initialSupplier;
  final String? initialProductId;
  final String? initialProductName;
  final String? initialPrice;
  final String? initialImei;
  final String? initialNote;
  final String? initialCurrency;
  final String? initialSupplierId;
  final List<Map<String, dynamic>> ticketItems;
  final int? editIndex;

  const ReturnForm({
    super.key,
    required this.tenantClient,
    this.initialSupplier,
    this.initialProductId,
    this.initialProductName,
    this.initialPrice,
    this.initialImei,
    this.initialNote,
    this.initialCurrency,
    this.initialSupplierId,
    this.ticketItems = const [],
    this.editIndex,
  });

  @override
  State<ReturnForm> createState() => _ReturnFormState();
}

class _ReturnFormState extends State<ReturnForm> {
  String? supplier;
  String? supplierId;
  String? productId;
  String? imei = '';
  List<String> imeiList = [];
  Map<String, Map<String, dynamic>> imeiData = {};
  String? price;
  String? currency;
  String? note;
  bool isAccessory = false;
  String? imeiPrefix;
  List<Map<String, dynamic>> ticketItems = [];
  bool isManualEntry = false; // Biến để theo dõi xem đã nhập IMEI thủ công hay chưa

  List<String> suppliers = [];
  Map<String, String> supplierIdMap = {}; // Map supplier name to id
  Map<String, String> supplierNameMap = {}; // Map supplier id to name
  List<String> currencies = [];
  List<String> imeiSuggestions = [];
  Map<String, String> productMap = {};
  List<Map<String, dynamic>> warehouses = [];
  bool isLoading = true;
  String? errorMessage;
  String? imeiError;

  final TextEditingController imeiController = TextEditingController();
  final TextEditingController supplierController = TextEditingController();
  final TextEditingController productController = TextEditingController();
  final TextEditingController priceController = TextEditingController();
  late final Debouncer _debouncer;

  final NumberFormat numberFormat = NumberFormat.decimalPattern('vi_VN');

  @override
  void initState() {
    super.initState();
    _debouncer = Debouncer(delay: const Duration(milliseconds: 300));
    supplier = widget.initialSupplier;
    productId = widget.initialProductId;
    price = widget.initialPrice;
    imei = widget.initialImei ?? '';
    note = widget.initialNote;
    currency = widget.initialCurrency;
    ticketItems = List.from(widget.ticketItems);

    supplierController.text = supplier ?? '';
    productController.text = widget.initialProductName ?? '';
    priceController.text = price != null ? formatNumberLocal(double.parse(price!)) : '';
    imeiController.text = imei ?? '';

    if (widget.initialImei != null && widget.initialImei!.isNotEmpty) {
      imeiList = widget.initialImei!.split(',').where((e) => e.trim().isNotEmpty).toList();
      isManualEntry = true;
      
      // ✅ Tái tạo imeiData khi edit
      if (widget.initialPrice != null && widget.initialCurrency != null) {
        final priceValue = double.tryParse(widget.initialPrice!) ?? 0;
        final supplierIdValue = widget.initialSupplierId ?? '';
        for (var imei in imeiList) {
          imeiData[imei] = {
            'price': priceValue,
            'currency': widget.initialCurrency!,
            'supplier_id': supplierIdValue,
          };
        }
      }
    }

    _fetchInitialData();
  }

  @override
  void dispose() {
    _debouncer.dispose();
    imeiController.dispose();
    supplierController.dispose();
    productController.dispose();
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

      final supplierResponse = await supabase.from('suppliers').select('id, name');
      final supplierList = supplierResponse
          .map((e) => e['name'] as String?)
          .whereType<String>()
          .toList()
        ..sort();
      
      // Tạo map supplier name -> id và id -> name
      for (var s in supplierResponse) {
        if (s['name'] != null && s['id'] != null) {
          final name = s['name'] as String;
          final id = s['id'].toString();
          supplierIdMap[name] = id;
          supplierNameMap[id] = name;
        }
      }

      final productResponse = await supabase.from('products_name').select('id, products');
      final productList = productResponse
          .map((e) => {'id': e['id'].toString(), 'name': e['products'] as String})
          .toList()
        ..sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));

      final currencyResponse = await supabase
          .from('financial_accounts')
          .select('currency')
          .neq('currency', '');
      final uniqueCurrencies = currencyResponse
          .map((e) => e['currency'] as String?)
          .whereType<String>()
          .toSet()
          .toList();

      final warehouseResponse = await supabase.from('warehouses').select('id, name');
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

      if (mounted) {
        setState(() {
          suppliers = supplierList;
          currencies = uniqueCurrencies;
          warehouses = warehouseList;
          supplier = widget.initialSupplier != null && supplierList.contains(widget.initialSupplier) ? widget.initialSupplier : null;
          supplierController.text = supplier ?? '';
          isLoading = false;

          productMap = {
            for (var product in productList) product['id'] as String: product['name'] as String
          };

          for (var product in productList) {
            CacheUtil.cacheProductName(product['id'] as String, product['name'] as String);
          }
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
      final response = await supabase
          .from('products')
          .select('imei')
          .eq('product_id', productId!)
          .eq('status', 'Tồn kho')
          .ilike('imei', '%$query%')
          .limit(10);

      final filteredImeis = response
          .map((e) => e['imei'] as String?)
          .whereType<String>()
          .where((imei) => !imeiList.contains(imei))
          .toList()
        ..sort();

      if (mounted) {
        setState(() {
          imeiSuggestions = filteredImeis;
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

  Future<Map<String, dynamic>?> _fetchImeiData(String input) async {
    if (input.trim().isEmpty || productId == null) {
      return null;
    }

    try {
      final supabase = widget.tenantClient;
      final response = await supabase
          .from('products')
          .select('imei, import_price, import_currency, status, product_id, supplier_id')
          .eq('imei', input)
          .eq('product_id', productId!)
          .maybeSingle();

      if (response == null || response['status'] == null) {
        return null;
      }

      final status = response['status'] as String;
      if (status != 'Tồn kho') {
        return null;
      }

      return {
        'imei': response['imei'] as String,
        'price': response['import_price'] as num?,
        'currency': response['import_currency'] as String?,
        'supplier_id': response['supplier_id']?.toString(),
      };
    } catch (e) {
      debugPrint('Lỗi khi kiểm tra IMEI "$input": $e');
      return null;
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
    String? selectedWarehouseId;

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
                decoration: const InputDecoration(labelText: 'Số lượng sản phẩm trả'),
                onChanged: (val) => quantity = int.tryParse(val) ?? 0,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: selectedWarehouseId,
                items: warehouses.map((w) => DropdownMenuItem(
                  value: w['id'] as String,
                  child: Text(w['name'] as String),
                )).toList(),
                decoration: const InputDecoration(
                  labelText: 'Kho trả hàng',
                  border: OutlineInputBorder(),
                ),
                onChanged: (val) => setDialogState(() => selectedWarehouseId = val),
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
                if (quantity > 0 && selectedWarehouseId != null) {
                  await _fetchImeisForQuantity(quantity, selectedWarehouseId!);
                }
              },
              child: const Text('Xác nhận'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _fetchImeisForQuantity(int quantity, String warehouseId) async {
    if (productId == null || quantity <= 0) {
      return;
    }

    try {
      final supabase = widget.tenantClient;
      
      // ✅ FIX: Lấy gấp đôi để đảm bảo đủ sau khi lọc duplicate
      final fetchQuantity = quantity * 2;
      
      final response = await supabase
          .from('products')
          .select('imei, import_price, import_currency, supplier_id, import_date')
          .eq('product_id', productId!)
          .eq('status', 'Tồn kho')
          .eq('warehouse_id', warehouseId)
          .order('import_date', ascending: true)  // ✅ FIX: FIFO - Lấy hàng cũ nhất trước
          .limit(fetchQuantity);

      final imeiListFromDb = response
          .map((e) => {
                'imei': e['imei'] as String?,
                'price': e['import_price'] as num?,
                'currency': e['import_currency'] as String?,
                'supplier_id': e['supplier_id']?.toString(),
              })
          .where((e) => e['imei'] != null)
          .toList();

      // ✅ FIX: Lọc duplicate và lấy đúng số lượng
      final filteredImeis = <String>[];
      for (var item in imeiListFromDb) {
        if (filteredImeis.length >= quantity) break;  // Đủ số lượng rồi
        
        final imei = item['imei'] as String;
        if (!imeiList.contains(imei)) {
          filteredImeis.add(imei);
          imeiData[imei] = {
            'price': item['price'] ?? 0,
            'currency': item['currency'] ?? 'VND',
            'supplier_id': item['supplier_id'] ?? '',
          };
        }
      }

      // ✅ FIX: Better messaging khi không đủ số lượng
      if (filteredImeis.length < quantity) {
        // Kiểm tra tổng số lượng có trong kho
        final totalCountResponse = await supabase
            .from('products')
            .select('imei')
            .eq('product_id', productId!)
            .eq('status', 'Tồn kho')
            .eq('warehouse_id', warehouseId)
            .count(CountOption.exact);
        
        final totalCount = totalCountResponse.count;
        
        if (mounted) {
          await showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Thông báo'),
              content: Text(
                'Số lượng sản phẩm tồn kho không đủ!\n\n'
                'Cần: $quantity sản phẩm\n'
                'Có trong kho: $totalCount sản phẩm\n'
                'Đã nhập: ${imeiList.length} sản phẩm\n'
                'Có thể lấy thêm: ${filteredImeis.length} sản phẩm\n\n'
                'Sản phẩm: "${CacheUtil.getProductName(productId)}"\n'
                'Kho: "${CacheUtil.getWarehouseName(warehouseId)}"'
              ),
              actions: [
                if (filteredImeis.isNotEmpty)
                  TextButton(
                    onPressed: () {
                      Navigator.pop(context);
                      setState(() {
                        imeiList.addAll(filteredImeis);
                      });
                    },
                    child: Text('Lấy ${filteredImeis.length} sản phẩm'),
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
            imeiList.addAll(filteredImeis);
          });
        }
      }

      debugPrint('Fetched ${filteredImeis.length} IMEIs for quantity: $quantity from warehouse: $warehouseId');
    } catch (e) {
      debugPrint('Error fetching IMEIs for quantity: $e');
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
          debugPrint('Scanned QR code: $scannedData');
          isManualEntry = true; // Đánh dấu là nhập thủ công
        });

        final data = await _fetchImeiData(scannedData);
        setState(() {
          imeiError = data == null ? 'IMEI "$scannedData" không hợp lệ hoặc không tồn kho!' : null;
        });

        if (data != null) {
          if (imeiList.contains(scannedData)) {
            setState(() {
              imeiError = 'IMEI "$scannedData" đã có trong danh sách!';
              imei = '';
              imeiController.text = '';
            });
            debugPrint('Duplicate IMEI: $scannedData');
          } else {
            setState(() {
              imeiList.insert(0, scannedData);
              imeiData[scannedData] = {
                'price': data['price'] ?? 0,
                'currency': data['currency'] ?? 'VND',
                'supplier_id': data['supplier_id'] ?? '',
              };
              imei = '';
              imeiController.text = '';
              imeiError = null;
              // Không cập nhật quantity ở đây để tránh vô hiệu hóa ô nhập IMEI
            });
            debugPrint('Added IMEI: $scannedData');
          }
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
        debugPrint('Error scanning QR code: $e');
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
          debugPrint('Scanned text: $scannedData');
          isManualEntry = true; // Đánh dấu là nhập thủ công
        });

        final data = await _fetchImeiData(scannedData);
        if (data == null) {
          final error = 'IMEI "$scannedData" không hợp lệ hoặc không tồn kho!';
        setState(() {
            imeiError = error;
        });
          await _showImeiErrorDialog(error);
          return;
        }

          if (imeiList.contains(scannedData)) {
          final error = 'IMEI "$scannedData" đã có trong danh sách!';
            setState(() {
            imeiError = error;
              imei = '';
              imeiController.text = '';
            });
          await _showImeiErrorDialog(error);
            debugPrint('Duplicate IMEI: $scannedData');
          return;
        }

            setState(() {
              imeiList.insert(0, scannedData);
              imeiData[scannedData] = {
                'price': data['price'] ?? 0,
                'currency': data['currency'] ?? 'VND',
                'supplier_id': data['supplier_id'] ?? '',
              };
              imei = '';
              imeiController.text = '';
              imeiError = null;
              // Không cập nhật quantity ở đây để tránh vô hiệu hóa ô nhập IMEI
            });
            debugPrint('Added IMEI: $scannedData');
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
        debugPrint('Error scanning text: $e');
      }
    }
  }

  void addToTicket(BuildContext scaffoldContext) async {
    if (productId == null || (imeiList.isEmpty && !isAccessory)) {
      if (mounted) {
        await showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Vui lòng điền đầy đủ thông tin, bao gồm sản phẩm và IMEI!'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
        debugPrint('Invalid input: productId=$productId, imeiList=$imeiList');
      }
      return;
    }

    if (!isAccessory && imeiList.isEmpty) {
      if (mounted) {
        await showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Vui lòng nhập ít nhất một IMEI hoặc chọn số lượng lớn hơn 0!'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
        debugPrint('No IMEI or quantity for non-accessory');
      }
      return;
    }

    final List<String> finalImeiList = imeiList;

    if (mounted) {
      setState(() {
        if (isAccessory) {
          final amount = double.tryParse(price?.replaceAll('.', '') ?? '0') ?? 0;
          final item = {
            'product_id': productId!,
            'product_name': CacheUtil.getProductName(productId),
            'imei': finalImeiList.join(','),
            'price': amount,
            'currency': currency!,
            'note': note,
            'is_accessory': isAccessory,
            'imei_prefix': imeiPrefix,
          };
          if (widget.editIndex != null) {
            ticketItems[widget.editIndex!] = item;
          } else {
            ticketItems.add(item);
          }
        } else {
          // Nhóm theo supplier_id, import_price và import_currency
          final Map<String, List<String>> groupedImeis = {};
          for (var imei in finalImeiList) {
            final data = imeiData[imei] ?? {'price': 0, 'currency': 'VND', 'supplier_id': ''};
            final key = '${data['supplier_id']}_${data['price']}_${data['currency']}';
            groupedImeis[key] = groupedImeis[key] ?? [];
            groupedImeis[key]!.add(imei);
          }

          for (var entry in groupedImeis.entries) {
            final keyParts = entry.key.split('_');
            final itemSupplierId = keyParts[0];
            final amount = double.tryParse(keyParts[1]) ?? 0;
            final itemCurrency = keyParts[2];
            final item = {
              'product_id': productId!,
              'product_name': CacheUtil.getProductName(productId),
              'imei': entry.value.join(','),
              'price': amount,
              'currency': itemCurrency,
              'supplier_id': itemSupplierId,
              'supplier_name': supplierNameMap[itemSupplierId] ?? 'N/A',
              'note': note,
              'is_accessory': isAccessory,
              'imei_prefix': null,
            };
            if (widget.editIndex != null) {
              ticketItems[widget.editIndex!] = item;
            } else {
              ticketItems.add(item);
            }
          }
        }
        debugPrint('Added/Updated ticket items: $ticketItems');
      });

      // Nhóm các item theo supplier_id để hiển thị
      final supplierGroups = <String, List<Map<String, dynamic>>>{};
      for (var item in ticketItems) {
        final itemSupplierId = item['supplier_id'] as String? ?? '';
        supplierGroups.putIfAbsent(itemSupplierId, () => []).add(item);
      }
      
      // Nếu chỉ có 1 supplier_id, truyền supplier_id đó, còn không thì truyền rỗng
      final singleSupplierId = supplierGroups.length == 1 ? supplierGroups.keys.first : '';

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => ReturnSummary(
            tenantClient: widget.tenantClient,
            supplier: singleSupplierId,
            ticketItems: ticketItems,
            currency: ticketItems.isNotEmpty ? ticketItems.first['currency'] : 'VND',
          ),
        ),
      );
    }
  }

  Widget wrapField(Widget child, {bool isImeiField = false, bool isSupplierField = false, bool isImeiList = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      margin: const EdgeInsets.symmetric(vertical: 4),
      height: isImeiField ? 72 : isImeiList ? 240 : isSupplierField ? 56 : 48, // Tăng chiều cao danh sách IMEI lên 240 giống reimport_form
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
        title: const Text('Phiếu trả hàng', style: TextStyle(color: Colors.white)),
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
            onPressed: () {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(
                  builder: (context) => ReturnSummary(
                    tenantClient: widget.tenantClient,
                    supplier: supplier ?? '',
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
            Row(
              children: [
                Expanded(
                  child: wrapField(
                    _buildProductField(),
                  ),
                ),
              ],
            ),
            if (!isAccessory) ...[
              wrapField(
                _buildImeiField(),
                isImeiField: true,
              ),
              wrapField(
                SizedBox(
                  height: 240,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Danh sách IMEI đã nhập (${imeiList.length})',
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
                                  final imeiItem = imeiList[index];
                                  final itemData = imeiData[imeiItem] ?? {'price': 0, 'currency': 'VND'};
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
                                                Text('IMEI: $imeiItem', style: const TextStyle(fontSize: 12)),
                                                Text(
                                                  'Giá nhập: ${formatNumberLocal(itemData['price'])} ${itemData['currency']}',
                                                  style: const TextStyle(fontSize: 12),
                                                ),
                                                Row(
                                                  children: [
                                                    Expanded(
                                                      child: TextFormField(
                                                        initialValue: formatNumberLocal(itemData['price']),
                                                        keyboardType: TextInputType.number,
                                                        inputFormatters: [ThousandsFormatterLocal()],
                                                        style: const TextStyle(fontSize: 12),
                                                        decoration: const InputDecoration(
                                                          labelText: 'Giá trả lại',
                                                          isDense: true,
                                                          contentPadding: EdgeInsets.symmetric(vertical: 4),
                                                        ),
                                                        onChanged: (value) {
                                                          final cleanedValue = value.replaceAll('.', '');
                                                          if (cleanedValue.isNotEmpty) {
                                                            final parsedValue = double.tryParse(cleanedValue);
                                                            if (parsedValue != null) {
                                                              setState(() {
                                                                imeiData[imeiItem]!['price'] = parsedValue;
                                                              });
                                                            }
                                                          }
                                                        },
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.delete, color: Colors.red, size: 20),
                                            onPressed: () {
                                              setState(() {
                                                imeiData.remove(imeiItem);
                                                imeiList.removeAt(index);
                                                if (imeiList.isEmpty) {
                                                  isManualEntry = false;
                                                  currency = null;
                                                  price = null;
                                                  priceController.text = '';
                                                }
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
                        Text(
                          '... và ${formatNumberLocal(imeiList.length - displayImeiLimit)} IMEI khác',
                          style: const TextStyle(fontSize: 14, color: Colors.grey),
                        ),
                    ],
                  ),
                ),
                isImeiList: true,
              ),
            ],
            if (isAccessory)
              wrapField(
                TextFormField(
                  onChanged: (val) => setState(() {
                    imeiPrefix = val.isNotEmpty ? val : null;
                  }),
                  decoration: const InputDecoration(
                    labelText: 'Đầu mã IMEI',
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

  Widget _buildProductField() {
    return Autocomplete<String>(
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
            isAccessory = ['Ốp lưng', 'Tai nghe'].contains(selection);
            imei = '';
            imeiController.text = '';
            imeiError = null;
            imeiList = [];
            imeiData.clear();
            currency = null;
            price = null;
            priceController.text = '';
            isManualEntry = false; // Reset trạng thái nhập thủ công khi chọn sản phẩm mới
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
                isAccessory = false;
                imei = '';
                imeiController.text = '';
                imeiError = null;
                imeiList = [];
                imeiData.clear();
                currency = null;
                price = null;
                priceController.text = '';
                isManualEntry = false; // Reset trạng thái nhập thủ công
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
    );
  }

  Widget _buildImeiField() {
    return Column(
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

              if (imeiList.contains(selection)) {
                final error = 'IMEI "$selection" đã được nhập!';
                setState(() {
                  imeiError = error;
                });
                await _showImeiErrorDialog(error);
                return;
              }

              final data = await _fetchImeiData(selection);
              if (data == null) {
                final error = 'IMEI "$selection" không hợp lệ hoặc không tồn kho!';
              setState(() {
                  imeiError = error;
              });
                await _showImeiErrorDialog(error);
                return;
              }

              if (data != null) {
                setState(() {
                  imeiList.add(selection);
                  imeiData[selection] = {
                    'price': data['price'] ?? 0,
                    'currency': data['currency'] ?? 'VND',
                  };
                  currency = data['currency'] ?? 'VND';
                  price = data['price'].toString();
                  priceController.text = formatNumberLocal(data['price'] as num);
                  imei = '';
                  imeiController.text = '';
                  imeiError = null;
                  isManualEntry = true; // Đánh dấu là nhập thủ công
                });
                _fetchAvailableImeis('');
              }
            },
            fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
              controller.text = imeiController.text;
              return TextField(
                controller: controller,
                focusNode: focusNode,
                enabled: productId != null && !isAccessory, // Bật nếu đã chọn sản phẩm và không phải phụ kiện
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

                  if (imeiList.contains(value)) {
                    final error = 'IMEI "$value" đã được nhập!';
                    setState(() {
                      imeiError = error;
                    });
                    await _showImeiErrorDialog(error);
                    return;
                  }

                  final data = await _fetchImeiData(value);
                  if (data == null) {
                    final error = 'IMEI "$value" không hợp lệ hoặc không tồn kho!';
                  setState(() {
                      imeiError = error;
                  });
                    await _showImeiErrorDialog(error);
                    return;
                  }

                  if (data != null) {
                    setState(() {
                      imeiList.add(value);
                      imeiData[value] = {
                        'price': data['price'] ?? 0,
                        'currency': data['currency'] ?? 'VND',
                      };
                      currency = data['currency'] ?? 'VND';
                      price = data['price'].toString();
                      priceController.text = formatNumberLocal(data['price'] as num);
                      imei = '';
                      imeiController.text = '';
                      imeiError = null;
                      isManualEntry = true; // Đánh dấu là nhập thủ công
                    });
                    _fetchAvailableImeis('');
                  }
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
            child: const Center(
              child: Text(
                'Quét QR code để lấy IMEI',
                style: TextStyle(fontSize: 18, color: Colors.black),
              ),
            ),
          ),
        ],
      ),
    );
  }
}