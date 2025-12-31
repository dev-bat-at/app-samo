import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'dart:math' as math;
import 'dart:developer' as developer;
import '../../notification_service.dart';
import 'package:flutter/services.dart';
import '../../text_scanner_screen.dart';

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
        // On final attempt, throw with detailed error info
        if (e is PostgrestException) {
          throw Exception('${operation ?? 'Operation'} failed after $maxRetries attempts: PostgrestException(message: ${e.message}, code: ${e.code}, details: ${e.details}, hint: ${e.hint})');
        }
        throw Exception('${operation ?? 'Operation'} failed after $maxRetries attempts: $e');
      }
      // Exponential backoff
      await Future.delayed(retryDelay * math.pow(2, attempt).toInt());
    }
  }
  throw Exception('${operation ?? 'Operation'} failed: Unexpected error');
}

// Utility class for caching product names
class CacheUtil {
  static final Map<String, String> productNameCache = {};
  static final Map<String, String> warehouseNameCache = {};

  static void cacheProductName(String id, String name) => productNameCache[id] = name;
  static String getProductName(String? id) => id != null ? productNameCache[id] ?? 'Không xác định' : 'Không xác định';
  static void cacheWarehouseName(String id, String name) => warehouseNameCache[id] = name;
  static String getWarehouseName(String? id) => id != null ? warehouseNameCache[id] ?? 'Không xác định' : 'Không xác định';
}

// Constants for IMEI handling
const int maxImeiQuantity = 100000;
const int displayImeiLimit = 100;

// Main widget for global transfer form
class TransferGlobalForm extends StatefulWidget {
  final SupabaseClient tenantClient;

  const TransferGlobalForm({super.key, required this.tenantClient});

  @override
  State<TransferGlobalForm> createState() => _TransferGlobalFormState();
}

// State class for TransferGlobalForm
class _TransferGlobalFormState extends State<TransferGlobalForm> {
  String? transporter;
  String? productId;
  String? imei = '';
  List<String> imeiList = [];
  List<String> transporters = [];
  List<Map<String, dynamic>> products = [];
  List<String> availableImeis = [];
  List<Map<String, dynamic>> warehouses = [];
  bool isLoading = true;
  bool isSubmitting = false;
  String? errorMessage;
  String? imeiError;

  final TextEditingController productController = TextEditingController();
  final TextEditingController imeiController = TextEditingController();
  final FocusNode imeiFocusNode = FocusNode();
  final uuid = const Uuid();

  @override
  void initState() {
    super.initState();
    _fetchInitialData();
  }

  @override
  void dispose() {
    productController.dispose();
    imeiController.dispose();
    imeiFocusNode.dispose();
    super.dispose();
  }

  // Fetch initial data from Supabase
  Future<void> _fetchInitialData() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      final supabase = widget.tenantClient;

      // Fetch transporters
      final transporterResponse = await supabase
          .from('transporters')
          .select('name')
          .eq('type', 'vận chuyển quốc tế');
      final transporterList = transporterResponse
          .map((e) => e['name'] as String?)
          .whereType<String>()
          .toList()
        ..sort();

      // Fetch products from products_name
      final productResponse = await supabase
          .from('products_name')
          .select('id, products');
      final productList = productResponse
          .map((e) => {
                'id': e['id'].toString(),
                'name': e['products'] as String,
              })
          .toList()
        ..sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));

      // Fetch warehouses
      final warehouseResponse = await supabase
          .from('warehouses')
          .select('id, name');
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

      if (mounted) {
        setState(() {
          transporters = transporterList;
          products = productList;
          warehouses = warehouseList;
          isLoading = false;
          for (var product in productList) {
            CacheUtil.cacheProductName(product['id'] as String, product['name'] as String);
          }
        });
      }
    } catch (e) {
      print('Error fetching data from Supabase: $e');
      if (mounted) {
        setState(() {
          errorMessage = 'Không thể tải dữ liệu từ Supabase: $e';
          isLoading = false;
        });
      }
    }
  }

  // Fetch IMEI suggestions
  Future<void> _fetchAvailableImeis(String query) async {
    if (productId == null) {
      setState(() {
        availableImeis = [];
      });
      return;
    }

    try {
      final supabase = widget.tenantClient;
      developer.log('🔍 _fetchAvailableImeis: productId=$productId, query="$query"');
      final response = await supabase
          .from('products')
          .select('imei')
          .eq('product_id', productId!)
          .eq('status', 'Tồn kho')
          .ilike('imei', '%$query%')
          .limit(10);

      developer.log('🔍 _fetchAvailableImeis: Found ${response.length} IMEIs from database');
      final imeiListFromDb = response
          .map((e) {
            final rawImei = e['imei'] as String?;
            final trimmedImei = rawImei?.trim();
            developer.log('🔍 _fetchAvailableImeis: Raw IMEI="$rawImei", Trimmed="$trimmedImei"');
            return trimmedImei;
          })
          .whereType<String>()
          .where((imei) => imei.isNotEmpty)
          .toList();

      final filteredImeis = imeiListFromDb
          .where((imei) => !imeiList.contains(imei))
          .toList()
        ..sort();

      developer.log('🔍 _fetchAvailableImeis: Final filtered IMEIs: $filteredImeis');
      setState(() {
        availableImeis = filteredImeis;
      });
    } catch (e) {
      developer.log('❌ Error fetching IMEI suggestions: $e');
      setState(() {
        availableImeis = [];
      });
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

  // Check for duplicate IMEIs
  String? _checkDuplicateImeis(String input) {
    final trimmedInput = input.trim();
    if (imeiList.contains(trimmedInput)) {
      return 'IMEI "$trimmedInput" đã được nhập!';
    }
    return null;
  }

  // Check inventory status of IMEI
  Future<String?> _checkInventoryStatus(String input) async {
    if (productId == null) return 'Vui lòng chọn sản phẩm!';
    final trimmedInput = input.trim();
    if (trimmedInput.isEmpty) return null;

    try {
      final supabase = widget.tenantClient;
      developer.log('🔍 _checkInventoryStatus: Input="$input", Trimmed="$trimmedInput", productId=$productId');
      
      // ✅ FIX: Query với .ilike() để match case-insensitive và có thể match IMEI có khoảng trắng
      // Sau đó filter kết quả để tìm exact match sau khi trim
      final productResponseList = await supabase
          .from('products')
          .select('status, product_id, imei')
          .eq('product_id', productId!)
          .eq('status', 'Tồn kho')
          .ilike('imei', '%$trimmedInput%') // ✅ Dùng % để match cả IMEI có khoảng trắng
          .limit(100); // Lấy nhiều để tìm exact match

      developer.log('🔍 _checkInventoryStatus: Query result count: ${productResponseList.length}');
      developer.log('🔍 _checkInventoryStatus: Query results: ${productResponseList.map((e) => 'IMEI="${e['imei']}" (trimmed="${(e['imei'] as String?)?.trim()}")').toList()}');
      
      // Tìm exact match (so sánh sau khi trim cả 2 bên)
      Map<String, dynamic>? productResponse;
      try {
        productResponse = productResponseList.firstWhere(
          (item) {
            final dbImei = (item['imei'] as String?)?.trim() ?? '';
            final match = dbImei.toLowerCase() == trimmedInput.toLowerCase();
            developer.log('🔍 _checkInventoryStatus: Comparing dbImei="$dbImei" with trimmedInput="$trimmedInput", match=$match');
            return match;
          },
        ) as Map<String, dynamic>?;
      } catch (e) {
        developer.log('❌ _checkInventoryStatus: No exact match found: $e');
        productResponse = null;
      }

      developer.log('🔍 _checkInventoryStatus: Exact match result: $productResponse');
      
      if (productResponse == null) {
        developer.log('❌ _checkInventoryStatus: ProductResponse is NULL for IMEI="$trimmedInput", productId=$productId');
        // Thử query không filter product_id để xem IMEI có tồn tại không
        final checkImeiExists = await supabase
            .from('products')
            .select('imei, product_id, status')
            .ilike('imei', trimmedInput)
            .limit(10);
        developer.log('🔍 _checkInventoryStatus: IMEI exists check (no product_id filter): $checkImeiExists');
        
        final productName = CacheUtil.getProductName(productId);
        return 'IMEI "$input" không tồn tại, không thuộc sản phẩm "$productName", hoặc không ở trạng thái Tồn kho!';
      }
      
      final status = productResponse['status']?.toString();
      final foundProductId = productResponse['product_id']?.toString();
      final foundImei = productResponse['imei']?.toString();
      developer.log('🔍 _checkInventoryStatus: Found status="$status", product_id="$foundProductId", imei="$foundImei"');
      developer.log('🔍 _checkInventoryStatus: Expected status="Tồn kho", Actual status="$status", Match: ${status == 'Tồn kho'}');
      
      if (status != 'Tồn kho') {
        final productName = CacheUtil.getProductName(productId);
        developer.log('❌ _checkInventoryStatus: Status mismatch! Expected "Tồn kho", got "$status"');
        return 'IMEI "$input" không tồn tại, không thuộc sản phẩm "$productName", hoặc không ở trạng thái Tồn kho!';
      }
      
      developer.log('✅ _checkInventoryStatus: IMEI validation passed');
      return null;
    } catch (e) {
      developer.log('❌ _checkInventoryStatus: Exception: $e');
      return 'Lỗi khi kiểm tra IMEI "$input": $e';
    }
  }

  // Create snapshot for transfer
  Future<Map<String, dynamic>> _createSnapshot(String ticketId, List<String> imeiList) async {
    final supabase = widget.tenantClient;
    final snapshotData = <String, dynamic>{};

    if (transporter != null) {
      final transporterData = await supabase
          .from('transporters')
          .select()
          .eq('name', transporter!)
          .single();
      snapshotData['transporters'] = transporterData;
    }

    if (imeiList.isNotEmpty) {
      final productsData = await supabase
          .from('products')
          .select()
          .inFilter('imei', imeiList);
      snapshotData['products'] = productsData;
    }

    snapshotData['transporter_orders'] = [
      {
        'id': ticketId,
        'imei': imeiList.join(','),
        'product_id': productId,
        'product_name': CacheUtil.getProductName(productId),
        'transporter': transporter,
        'transport_fee': 0,
        'type': 'chuyển kho quốc tế',
      }
    ];

    return snapshotData;
  }

  // Hàm phát âm thanh beep
  void _playBeepSound() {
    SystemSound.play(SystemSoundType.click);
  }

  // Scan QR code for IMEI
  Future<void> _scanQRCode() async {
    try {
      final scannedData = await Navigator.push<String?>(
        context,
        MaterialPageRoute(builder: (context) => const QRCodeScannerScreen()),
      );

      if (scannedData != null && mounted) {
        // Phát âm thanh beep khi quét thành công
        _playBeepSound();
        
        final duplicateError = _checkDuplicateImeis(scannedData);
        if (duplicateError != null) {
        setState(() {
            imeiError = duplicateError;
        });
          await _showImeiErrorDialog(duplicateError);
          return;
        }

        final inventoryError = await _checkInventoryStatus(scannedData);
        if (inventoryError != null) {
            setState(() {
            imeiError = inventoryError;
            });
          await _showImeiErrorDialog(inventoryError);
          return;
        }

        if (mounted) {
              setState(() {
                imeiList.insert(0, scannedData.trim());
                imei = '';
                imeiController.text = '';
                imeiError = null;
                imeiFocusNode.unfocus();
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

  // Scan text for IMEI
  Future<void> _scanText() async {
    try {
      final scannedData = await Navigator.push<String?>(
        context,
        MaterialPageRoute(builder: (context) => const TextScannerScreen()),
      );

      if (scannedData != null && mounted) {
        // Phát âm thanh beep khi quét thành công
        _playBeepSound();
        
        final duplicateError = _checkDuplicateImeis(scannedData);
        if (duplicateError != null) {
        setState(() {
            imeiError = duplicateError;
        });
          await _showImeiErrorDialog(duplicateError);
          return;
        }

        final inventoryError = await _checkInventoryStatus(scannedData);
        if (inventoryError != null) {
            setState(() {
            imeiError = inventoryError;
            });
          await _showImeiErrorDialog(inventoryError);
          return;
        }

        if (mounted) {
              setState(() {
                imeiList.insert(0, scannedData.trim());
                imei = '';
                imeiController.text = '';
                imeiError = null;
                imeiFocusNode.unfocus();
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

  // Show Auto IMEI dialog
  Future<void> _showAutoImeiDialog() async {
    int? localQuantity;
    String? localWarehouseId;
    String? selectedWarehouseId;
    final TextEditingController localQuantityController = TextEditingController();
    final TextEditingController localWarehouseController = TextEditingController();

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
              Autocomplete<Map<String, dynamic>>(
                optionsBuilder: (TextEditingValue textEditingValue) {
                  final query = textEditingValue.text.toLowerCase();
                  if (query.isEmpty) return warehouses.take(10).toList();
                  final filtered = warehouses
                      .where((option) => (option['name'] as String).toLowerCase().contains(query))
                      .toList()
                    ..sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));
                  return filtered.isNotEmpty ? filtered.take(10).toList() : [{'id': '', 'name': 'Không tìm thấy kho'}];
                },
                displayStringForOption: (option) => option['name'] as String,
                onSelected: (val) {
                  if (val['id'].isEmpty) return;
                  localWarehouseId = val['id'] as String;
                  selectedWarehouseId = val['id'] as String;
                  localWarehouseController.text = val['name'] as String;
                },
                fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                  controller.text = localWarehouseController.text;
                  return TextFormField(
                    controller: controller,
                    focusNode: focusNode,
                    onChanged: (value) {
                      localWarehouseController.text = value;
                    },
                    decoration: const InputDecoration(
                      labelText: 'Kho gửi đi',
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
              if (localWarehouseId == null || localWarehouseId!.trim().isEmpty) {
                showDialog(
                  context: dialogContext,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Thông báo'),
                    content: const Text('Vui lòng chọn kho gửi đi!'),
                    actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Đóng'))],
                  ),
                );
                return;
              }
              Navigator.pop(dialogContext);
              await _autoFetchImeis(localQuantity!, selectedWarehouseId!);
            },
            child: const Text('Tìm'),
          ),
        ],
      ),
    );
  }

  // Auto fetch IMEIs based on quantity and warehouse
  Future<void> _autoFetchImeis(int qty, String warehouseId) async {
    setState(() {
      isLoading = true;
    });

    try {
      final supabase = widget.tenantClient;
      
      // ✅ FIX: Lấy gấp đôi để đảm bảo đủ sau khi lọc duplicate
      final fetchQuantity = qty * 2;
      
      final response = await supabase
          .from('products')
          .select('imei, import_date')
          .eq('product_id', productId!)
          .eq('warehouse_id', warehouseId)
          .eq('status', 'Tồn kho')
          .order('import_date', ascending: true)  // FIFO - Lấy hàng cũ nhất trước
          .limit(fetchQuantity);

      final fetchedImeis = response
          .map((e) => e['imei'] as String?)
          .whereType<String>()
          .where((imei) => imei != null && imei.trim().isNotEmpty && !imeiList.contains(imei))
          .cast<String>()
          .take(qty)  // ✅ FIX: Chỉ lấy đúng số lượng sau khi lọc
          .toList();

      if (fetchedImeis.length < qty) {
        // Check tổng số lượng có trong kho
        final totalCountResponse = await supabase
            .from('products')
            .select('imei')
            .eq('product_id', productId!)
            .eq('warehouse_id', warehouseId)
            .eq('status', 'Tồn kho')
            .count(CountOption.exact);
        
        final totalCount = totalCountResponse.count;
        
        if (mounted) {
          await showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Thông báo'),
              content: Text(
                'Số lượng sản phẩm tồn kho không đủ!\n\n'
                'Cần: $qty sản phẩm\n'
                'Có trong kho: $totalCount sản phẩm\n'
                'Đã nhập: ${imeiList.length} sản phẩm\n'
                'Có thể lấy thêm: ${fetchedImeis.length} sản phẩm\n\n'
                'Sản phẩm: "${CacheUtil.getProductName(productId)}"\n'
                'Kho: "${CacheUtil.getWarehouseName(warehouseId)}"'
              ),
              actions: [
                if (fetchedImeis.isNotEmpty)
                  TextButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      setState(() {
                        imeiList.addAll(fetchedImeis);
                        isLoading = false;
                      });
                    },
                    child: Text('Lấy ${fetchedImeis.length} sản phẩm'),
                  ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    setState(() {
                      isLoading = false;
                    });
                  },
                  child: const Text('Đóng'),
                ),
              ],
            ),
          );
        }
        setState(() {
          isLoading = false;
        });
        return;
      }

      setState(() {
        imeiList.addAll(fetchedImeis);
        isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Lỗi'),
            content: Text('Không thể tải IMEI: $e'),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Đóng'))],
          ),
        );
      }
      setState(() {
        isLoading = false;
      });
    }
  }

  // Show confirmation dialog
  void showConfirmDialog() {
    if (isSubmitting) return;

    if (transporter == null || productId == null || imeiList.isEmpty) {
      showDialog(
        context: context,
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
      return;
    }

    if (imeiList.length > maxImeiQuantity) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Thông báo'),
          content: Text('Số lượng IMEI (${formatNumberLocal(imeiList.length)}) vượt quá giới hạn (${formatNumberLocal(maxImeiQuantity)}). Vui lòng chia thành nhiều phiếu.'),
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

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Xác nhận chuyển kho quốc tế'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Đơn vị vận chuyển: ${transporter ?? 'Không xác định'}'),
              Text('Sản phẩm: ${CacheUtil.getProductName(productId)}'),
              Text('Danh sách IMEI:'),
              ...imeiList.map((imei) => Text('- $imei')),
              Text('Số lượng: ${imeiList.length}'),
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
              Navigator.pop(dialogContext);
              await saveTransfer(imeiList);
            },
            child: const Text('Tạo phiếu'),
          ),
        ],
      ),
    );
  }

  // Save transfer to Supabase
  Future<void> saveTransfer(List<String> imeiList) async {
    if (isSubmitting) return;

    setState(() {
      isSubmitting = true;
    });

    try {
      final supabase = widget.tenantClient;
      final now = DateTime.now();

      // Validate input
      if (transporter == null || productId == null || imeiList.isEmpty) {
        throw Exception('Thông tin không đầy đủ: Vui lòng kiểm tra đơn vị vận chuyển, sản phẩm và IMEI.');
      }

      // Create ticketId
      final ticketId = uuid.v4();

      // Create snapshot first
      developer.log('Creating snapshot for ticket $ticketId with ${imeiList.length} IMEIs');
      final snapshotData = await _createSnapshot(ticketId, imeiList);

      // Debug logging
      developer.log('🔍 DEBUG: Calling transfer_global RPC with data:');
      developer.log('  ticket_id: $ticketId');
      developer.log('  product_id: $productId');
      developer.log('  product_name: ${CacheUtil.getProductName(productId)}');
      developer.log('  transporter: $transporter');
      developer.log('  imei_list count: ${imeiList.length}');

      // ✅ CALL RPC FUNCTION - All operations in ONE atomic transaction
      final result = await retry(
        () => supabase.rpc('create_transfer_global_transaction', params: {
          'p_ticket_id': ticketId,
          'p_product_id': productId,
          'p_product_name': CacheUtil.getProductName(productId),
          'p_transporter': transporter,
          'p_imei_list': imeiList,
          'p_snapshot_data': snapshotData,
          'p_created_at': now.toIso8601String(),
        }),
        operation: 'Create transfer global transaction (RPC)',
      );

      // Check result
      if (result == null || result['success'] != true) {
        throw Exception('RPC function returned error: ${result?['message'] ?? 'Unknown error'}');
      }

      developer.log('✅ Transfer global transaction created successfully via RPC!');

      // Send push notification
      await NotificationService.showNotification(
        140,
        "Đã tạo phiếu vận chuyển quốc tế",
        "Đã tạo phiếu vận chuyển quốc tế sản phẩm ${CacheUtil.getProductName(productId)} số lượng ${formatNumberLocal(imeiList.length)}",
        'transfer_global_created',
      );
      
      // ✅ Gửi thông báo push đến tất cả thiết bị
      await NotificationService.sendNotificationToAll(
        "Đã tạo phiếu vận chuyển quốc tế",
        "Đã tạo phiếu vận chuyển quốc tế sản phẩm ${CacheUtil.getProductName(productId)} số lượng ${formatNumberLocal(imeiList.length)}",
        data: {'type': 'transfer_global_created'},
      );
      
      // ✅ Gửi thông báo Telegram với thông tin chi tiết
      await NotificationService.sendTransactionToTelegram(
        transactionType: 'transfer_global',
        type: 'Phiếu Chuyển Kho Quốc Tế',
        ticketId: ticketId,
        partnerType: 'transporters',
        partnerName: transporter,
        productName: CacheUtil.getProductName(productId),
        quantity: imeiList.length,
        imeiList: imeiList.join(', '),
      );

      if (mounted) {
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Đã tạo phiếu chuyển kho quốc tế và cập nhật trạng thái'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );

        // Reset sau khi đóng dialog
        if (mounted) {
          setState(() {
            transporter = null;
            productId = null;
            imei = '';
            imeiList.clear(); // Use clear() instead of = []
            imeiError = null;
            isSubmitting = false;
          });
          
          // Clear controllers
          productController.clear();
          imeiController.clear();
        }
      }
    } catch (e) {
      print('Error saving transfer: $e');
      if (mounted) {
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text('Lỗi khi tạo phiếu: $e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
        setState(() {
          isSubmitting = false;
        });
      }
    }
  }

  // Format number for display
  String formatNumberLocal(num value) {
    return NumberFormat('#,###', 'vi_VN').format(value).replaceAll(',', '.');
  }

  // Wrap field with styled container
  Widget wrapField(Widget child, {bool isImeiField = false, bool isImeiList = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      margin: const EdgeInsets.symmetric(vertical: 4),
      height: isImeiField ? 72 : isImeiList ? 120 : 48, // Tăng chiều cao IMEI field từ 48 lên 72 (50%)
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: imeiError != null ? Colors.red : Colors.grey.shade300),
      ),
      child: child,
    );
  }

  // Build the UI
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
        title: const Text('Phiếu chuyển kho quốc tế', style: TextStyle(color: Colors.white)),
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
            wrapField(
              Autocomplete<String>(
                optionsBuilder: (TextEditingValue textEditingValue) {
                  final query = textEditingValue.text.toLowerCase();
                  if (query.isEmpty) return transporters.take(10).toList();
                  final filtered = transporters
                      .where((option) => option.toLowerCase().contains(query))
                      .toList()
                    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
                  return filtered.isNotEmpty ? filtered.take(10).toList() : ['Không tìm thấy đơn vị vận chuyển'];
                },
                onSelected: (String selection) {
                  if (selection != 'Không tìm thấy đơn vị vận chuyển') {
                    setState(() {
                      transporter = selection;
                    });
                  }
                },
                fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                  controller.text = transporter ?? '';
                  return TextField(
                    controller: controller,
                    focusNode: focusNode,
                    onChanged: (value) {
                      setState(() {
                        transporter = value.isNotEmpty ? value : null;
                      });
                    },
                    decoration: const InputDecoration(
                      labelText: 'Đơn vị vận chuyển',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  );
                },
              ),
            ),
            Stack(
              children: [
                // Ô sản phẩm chiếm toàn bộ chiều ngang
                wrapField(
                  Autocomplete<Map<String, dynamic>>(
                    optionsBuilder: (TextEditingValue textEditingValue) {
                      final query = textEditingValue.text.toLowerCase();
                      if (query.isEmpty) return products.take(10).toList();
                      final filtered = products
                          .where((option) => (option['name'] as String).toLowerCase().contains(query))
                          .toList()
                        ..sort((a, b) {
                          final aName = (a['name'] as String).toLowerCase();
                          final bName = (b['name'] as String).toLowerCase();
                          final aStartsWith = aName.startsWith(query);
                          final bStartsWith = bName.startsWith(query);
                          if (aStartsWith != bStartsWith) {
                            return aStartsWith ? -1 : 1;
                          }
                          final aIndex = aName.indexOf(query);
                          final bIndex = bName.indexOf(query);
                          if (aIndex != bIndex) {
                            return aIndex - bIndex;
                          }
                          return aName.compareTo(bName);
                        });
                      return filtered.isNotEmpty ? filtered.take(10).toList() : [{'id': '', 'name': 'Không tìm thấy sản phẩm'}];
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
            wrapField(
              Column(
                children: [
                  // Phần nhập IMEI
                  Expanded(
                    child: Autocomplete<String>(
                      optionsBuilder: (TextEditingValue textEditingValue) {
                        final query = textEditingValue.text.toLowerCase();
                        if (productId == null) return ['Vui lòng chọn sản phẩm'];
                        final availableSuggestions = availableImeis
                            .where((option) => !imeiList.contains(option))
                            .toList();
                        if (query.isEmpty) return availableSuggestions.take(10).toList();
                        final filtered = availableSuggestions
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
                        if (selection == 'Vui lòng chọn sản phẩm' || selection == 'Không tìm thấy IMEI') return;

                        developer.log('🔍 onSelected: Selection="$selection", Length=${selection.length}, Bytes=${selection.codeUnits}');
                        final trimmedSelection = selection.trim();
                        developer.log('🔍 onSelected: Trimmed="$trimmedSelection", Length=${trimmedSelection.length}, Bytes=${trimmedSelection.codeUnits}');
                        developer.log('🔍 onSelected: Available IMEIs: $availableImeis');
                        developer.log('🔍 onSelected: Selection in availableImeis: ${availableImeis.contains(trimmedSelection)}');
                        
                        final error = _checkDuplicateImeis(trimmedSelection);
                        if (error != null) {
                          developer.log('❌ onSelected: Duplicate error: $error');
                          setState(() {
                            imeiError = error;
                          });
                          await _showImeiErrorDialog(error);
                          return;
                        }

                        developer.log('🔍 onSelected: Calling _checkInventoryStatus with "$trimmedSelection"');
                        final inventoryError = await _checkInventoryStatus(trimmedSelection);
                        if (inventoryError != null) {
                          developer.log('❌ onSelected: Inventory error: $inventoryError');
                          setState(() {
                            imeiError = inventoryError;
                          });
                          await _showImeiErrorDialog(inventoryError);
                          return;
                        }

                        developer.log('✅ onSelected: Successfully added IMEI "$trimmedSelection"');
                        setState(() {
                          imeiList.add(trimmedSelection);
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

                            final trimmedValue = value.trim();
                            final error = _checkDuplicateImeis(trimmedValue);
                            if (error != null) {
                              setState(() {
                                imeiError = error;
                              });
                              await _showImeiErrorDialog(error);
                              return;
                            }

                            final inventoryError = await _checkInventoryStatus(trimmedValue);
                            if (inventoryError != null) {
                              setState(() {
                                imeiError = inventoryError;
                              });
                              await _showImeiErrorDialog(inventoryError);
                              return;
                            }

                            setState(() {
                              imeiList.add(trimmedValue);
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
                height: 120,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Danh sách IMEI đã thêm (${imeiList.length})',
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
                              itemExtent: 24,
                              itemBuilder: (context, index) {
                                return Row(
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

  Future<void> _rollbackChanges(Map<String, dynamic> snapshot, String ticketId) async {
    final supabase = widget.tenantClient;
    
    try {
      // Rollback transporters
      if (snapshot['transporters'] != null) {
        await supabase
          .from('transporters')
          .update(snapshot['transporters'])
          .eq('name', snapshot['transporters']['name']);
      }

      // Rollback products
      if (snapshot['products'] != null) {
        for (var product in snapshot['products']) {
          await supabase
            .from('products')
            .update(product)
            .eq('imei', product['imei']);
        }
      }

      // Delete created transporter orders
      await supabase
        .from('transporter_orders')
        .delete()
        .eq('id', ticketId);

    } catch (e) {
      print('Error during rollback: $e');
      throw Exception('Lỗi khi rollback dữ liệu: $e');
    }
  }

  Future<bool> _verifyData(String ticketId, List<String> imeiList) async {
    final supabase = widget.tenantClient;
    
    try {
      // Verify products data
      final productsData = await supabase
          .from('products')
          .select('status, transporter')
          .inFilter('imei', imeiList);
      
      // Verify transporter orders
      final transporterOrders = await supabase
          .from('transporter_orders')
          .select()
          .eq('id', ticketId);

      // Verify all IMEIs are marked as being transported and assigned to correct transporter
      for (var product in productsData) {
        if (product['status'] != 'Đang vận chuyển' || 
            product['transporter'] != transporter) {
          return false;
        }
      }

      // Verify transporter order is created
      if (transporterOrders.isEmpty) {
        return false;
      }

      // Verify transporter data
      if (transporter != null) {
        final transporterData = await supabase
            .from('transporters')
            .select()
            .eq('name', transporter!)
            .single();
        if (transporterData == null) return false;
      }

      return true;
    } catch (e) {
      print('Error during data verification: $e');
      return false;
    }
  }

  Future<void> _submitTransfer() async {
    if (isSubmitting) return;

    if (transporter == null) {
      setState(() {
        errorMessage = 'Vui lòng chọn đơn vị vận chuyển!';
      });
      return;
    }

    if (imeiList.isEmpty) {
      setState(() {
        errorMessage = 'Vui lòng thêm ít nhất một IMEI!';
      });
      return;
    }

    if (imeiList.length > maxImeiQuantity) {
      setState(() {
        errorMessage = 'Số lượng IMEI (${imeiList.length}) vượt quá $maxImeiQuantity. Vui lòng chia thành nhiều phiếu nhỏ hơn.';
      });
      return;
    }

    setState(() {
      isSubmitting = true;
      errorMessage = null;
    });

    try {
      final supabase = widget.tenantClient;
      final now = DateTime.now();
      final ticketId = uuid.v4();

      // Create snapshot before any changes
      Map<String, dynamic> snapshot;
      try {
        snapshot = await _createSnapshot(ticketId, imeiList);
      } catch (e) {
        setState(() {
          isSubmitting = false;
          errorMessage = 'Lỗi khi tạo snapshot: $e';
        });
        return;
      }

      try {
        // Execute transaction
        await supabase.rpc('execute_transaction', params: {
          'operations': [
            {
              'type': 'insert',
              'table': 'snapshots',
              'data': {
                'ticket_id': ticketId,
                'ticket_table': 'transporter_orders',
                'snapshot_data': snapshot,
                'created_at': now.toIso8601String(),
              },
            },
            {
              'type': 'insert',
              'table': 'transporter_orders',
              'data': {
                'id': ticketId,
                'imei': imeiList.join(','),
                'product_id': productId,
                'product_name': CacheUtil.getProductName(productId),
                'transporter': transporter,
                'transport_fee': 0,
                'type': 'chuyển kho quốc tế',
                'created_at': now.toIso8601String(),
                'iscancelled': false,
              },
            },
            {
              'type': 'update',
              'table': 'products',
              'condition': {'imei': imeiList},
              'data': {
                'status': 'Đang vận chuyển',
                'transporter': transporter,
                'transport_date': now.toIso8601String(),
              },
            },
          ],
        });

        // After all updates, verify the data
        final isDataValid = await _verifyData(ticketId, imeiList);
        if (!isDataValid) {
          // If data verification fails, rollback changes
          await _rollbackChanges(snapshot, ticketId);
          throw Exception('Dữ liệu không khớp sau khi cập nhật. Đã rollback thay đổi.');
        }

        // Success notification
        await NotificationService.showNotification(
          137,
          'Phiếu Chuyển Kho Quốc Tế Đã Tạo',
          'Đã chuyển ${imeiList.length} sản phẩm ${CacheUtil.getProductName(productId)} cho ${transporter}',
          'transfer_global_created',
        );
        
        // ✅ Gửi thông báo push đến tất cả thiết bị
        await NotificationService.sendNotificationToAll(
          'Phiếu Chuyển Kho Quốc Tế Đã Tạo',
          'Đã chuyển ${imeiList.length} sản phẩm ${CacheUtil.getProductName(productId)} cho ${transporter}',
          data: {'type': 'transfer_global_created'},
        );

        if (mounted) {
          Navigator.pop(context);
          Navigator.pop(context);
        }

      } catch (e) {
        // If any error occurs, rollback changes
        try {
          await _rollbackChanges(snapshot, ticketId);
        } catch (rollbackError) {
          print('Rollback failed: $rollbackError');
        }

        if (mounted) {
          setState(() {
            isSubmitting = false;
            errorMessage = e.toString();
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          isSubmitting = false;
          errorMessage = e.toString();
        });
      }
    }
  }
}

// QR code scanner screen
class QRCodeScannerScreen extends StatefulWidget {
  const QRCodeScannerScreen({super.key});

  @override
  QRCodeScannerScreenState createState() => QRCodeScannerScreenState();
}

// State class for QRCodeScannerScreen
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