import 'package:flutter/material.dart' hide Border, BorderStyle;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:excel/excel.dart';
import 'package:open_file/open_file.dart';
import 'dart:io';
import '../helpers/export_progress_dialog.dart';
import 'dart:developer' as developer;
import '../helpers/error_handler.dart';
import '../helpers/storage_helper.dart';
import '../helpers/excel_style_helper.dart';

// Cache utility class
class CacheUtil {
  static final Map<String, String> productNameCache = {};

  static void cacheProductName(String id, String name) => productNameCache[id] = name;
  static String getProductName(String? id) => id != null ? productNameCache[id] ?? 'Không xác định' : 'Không xác định';
}

/// Hàm định dạng số với dấu phân cách hàng nghìn (ví dụ: 1000000000 → 1.000.000.000)
String formatNumber(num? amount) {
  if (amount == null) return '0';
  return NumberFormat.decimalPattern('vi_VN').format(amount);
}

/// Hàm định dạng ngày từ ISO 8601 sang dd-MM-yyyy
String formatDate(String? dateStr) {
  if (dateStr == null) return '';
  try {
    final parsedDate = DateTime.parse(dateStr);
    return DateFormat('dd-MM-yyyy').format(parsedDate);
  } catch (e) {
    return dateStr;
  }
}

class TransportersScreen extends StatefulWidget {
  final List<String> permissions;
  final SupabaseClient tenantClient;

  const TransportersScreen({
    super.key,
    required this.permissions,
    required this.tenantClient,
  });

  @override
  _TransportersScreenState createState() => _TransportersScreenState();
}

class _TransportersScreenState extends State<TransportersScreen> {
  String searchText = '';
  String sortOption = 'name-asc';
  List<Map<String, dynamic>> transporters = [];
  bool isLoading = true;
  String? errorMessage;

  @override
  void initState() {
    super.initState();
    _initProductCache().then((_) => _fetchTransporters());
  }

  Future<void> _initProductCache() async {
    try {
      final productResponse = await widget.tenantClient.from('products_name').select('id, products');
      for (var product in productResponse) {
        CacheUtil.cacheProductName(product['id'].toString(), product['products'] as String);
      }
    } catch (e) {
      print('Error initializing product cache: $e');
    }
  }

  Future<void> _fetchTransporters() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      final response = await widget.tenantClient.from('transporters').select();
      setState(() {
        transporters = (response as List<dynamic>).cast<Map<String, dynamic>>();
        isLoading = false;
      });
    } catch (e) {
      setState(() {
        errorMessage = 'Không thể tải dữ liệu từ Supabase: $e';
        isLoading = false;
      });
    }
  }

  List<Map<String, dynamic>> get filteredTransporters {
    var filtered = transporters.where((transporter) {
      final name = transporter['name']?.toString().toLowerCase() ?? '';
      final phone = transporter['phone']?.toString().toLowerCase() ?? '';
      return name.contains(searchText.toLowerCase()) || phone.contains(searchText.toLowerCase());
    }).toList();

    if (sortOption == 'name-asc') {
      filtered.sort((a, b) => (a['name']?.toString() ?? '').compareTo(b['name']?.toString() ?? ''));
    } else if (sortOption == 'name-desc') {
      filtered.sort((a, b) => (b['name']?.toString() ?? '').compareTo(a['name']?.toString() ?? ''));
    } else if (sortOption == 'debt-desc') {
      filtered.sort((a, b) {
        final debtA = (a['debt'] as num? ?? 0);
        final debtB = (b['debt'] as num? ?? 0);
        return debtB.compareTo(debtA);
      });
    } else if (sortOption == 'debt-asc') {
      filtered.sort((a, b) {
        final debtA = (a['debt'] as num? ?? 0);
        final debtB = (b['debt'] as num? ?? 0);
        return debtA.compareTo(debtB);
      });
    }

    return filtered;
  }

  void _showTransporterDetails(Map<String, dynamic> transporter) {
    showDialog(
      context: context,
      builder: (context) => TransporterDetailsDialog(
        transporter: transporter,
        tenantClient: widget.tenantClient,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
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
                onPressed: _fetchTransporters,
                child: const Text('Thử lại'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('Đơn Vị Vận Chuyển', style: TextStyle(color: Colors.white, fontSize: 20)),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      labelText: 'Tìm kiếm đơn vị vận chuyển',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                    onChanged: (value) {
                      setState(() {
                        searchText = value;
                      });
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    decoration: InputDecoration(
                      labelText: 'Sắp xếp',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                    icon: Container(),
                    value: sortOption,
                    items: const [
                      DropdownMenuItem(value: 'name-asc', child: Text('Tên (A-Z)')),
                      DropdownMenuItem(value: 'name-desc', child: Text('Tên (Z-A)')),
                      DropdownMenuItem(value: 'debt-asc', child: Text('Công nợ thấp đến cao')),
                      DropdownMenuItem(value: 'debt-desc', child: Text('Công nợ cao đến thấp')),
                    ],
                    onChanged: (value) {
                      setState(() {
                        sortOption = value ?? 'name-asc';
                      });
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView.builder(
                itemCount: filteredTransporters.length,
                itemBuilder: (context, index) {
                  final transporter = filteredTransporters[index];
                  final debt = transporter['debt'] as num? ?? 0;
                  final debtText = debt != 0 ? '${formatNumber(debt)} VND' : '0 VND';

                  return Card(
                    elevation: 2,
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    child: ListTile(
                      title: Text(transporter['name']?.toString() ?? ''),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Điện thoại: ${transporter['phone']?.toString() ?? ''}'),
                          Text('Công nợ: $debtText'),
                        ],
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.visibility, color: Colors.blue),
                        onPressed: () => _showTransporterDetails(transporter),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class TransporterDetailsDialog extends StatefulWidget {
  final Map<String, dynamic> transporter;
  final SupabaseClient tenantClient;

  const TransporterDetailsDialog({
    super.key,
    required this.transporter,
    required this.tenantClient,
  });

  @override
  _TransporterDetailsDialogState createState() => _TransporterDetailsDialogState();
}

class _TransporterDetailsDialogState extends State<TransporterDetailsDialog> {
  DateTime? startDate;
  DateTime? endDate;
  List<Map<String, dynamic>> transactions = [];
  bool isLoadingTransactions = true;
  String? transactionError;
  int pageSize = 20;
  int currentPage = 0;
  bool hasMoreData = true;
  bool isLoadingMore = false;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _fetchTransactions();

    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
              _scrollController.position.maxScrollExtent - 200 &&
          !isLoadingMore &&
          hasMoreData &&
          startDate == null &&
          endDate == null) {
        _loadMoreTransactions();
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _fetchTransactions() async {
    setState(() {
      isLoadingTransactions = true;
      transactionError = null;
      transactions = [];
      currentPage = 0;
      hasMoreData = true;
    });

    try {
      await _loadMoreTransactions();
    } catch (e) {
      setState(() {
        transactionError = 'Không thể tải giao dịch: $e';
        isLoadingTransactions = false;
      });
    }
  }

  Future<void> _loadMoreTransactions() async {
    if (!hasMoreData || isLoadingMore) return;

    setState(() {
      isLoadingMore = true;
    });

    try {
      final transporterName = widget.transporter['name']?.toString() ?? '';
      developer.log('Fetching transactions for transporter: "$transporterName"');
      final start = currentPage * pageSize;
      final end = start + pageSize - 1;

      dynamic transporterOrdersQuery = widget.tenantClient
          .from('transporter_orders')
          .select('*, product_id')
          .eq('transporter', transporterName)
          .eq('iscancelled', false);

      dynamic financialOrdersQuery = widget.tenantClient
          .from('financial_orders')
          .select()
          .eq('partner_type', 'transporters')
          .eq('partner_name', transporterName)
          .eq('iscancelled', false);

      dynamic saleOrdersQuery = widget.tenantClient
          .from('sale_orders')
          .select('*, product_id')
          .eq('transporter', transporterName)
          .eq('iscancelled', false);

      // ✅ Query reimport_orders COD hoàn (sẽ filter theo transporter sau)
      dynamic reimportOrdersQuery = widget.tenantClient
          .from('reimport_orders')
          .select('*, product_id, customer_price, transporter_price')
          .eq('account', 'Cod hoàn') // ✅ Sử dụng 'Cod hoàn' (chữ thường) như trong database
          .eq('iscancelled', false);

      // Add date filters if dates are selected
      if (startDate != null) {
        transporterOrdersQuery = transporterOrdersQuery.gte('created_at', startDate!.toIso8601String());
        financialOrdersQuery = financialOrdersQuery.gte('created_at', startDate!.toIso8601String());
        saleOrdersQuery = saleOrdersQuery.gte('created_at', startDate!.toIso8601String());
        reimportOrdersQuery = reimportOrdersQuery.gte('created_at', startDate!.toIso8601String());
      }
      if (endDate != null) {
        final endDateTime = endDate!.add(const Duration(days: 1));
        transporterOrdersQuery = transporterOrdersQuery.lt('created_at', endDateTime.toIso8601String());
        financialOrdersQuery = financialOrdersQuery.lt('created_at', endDateTime.toIso8601String());
        saleOrdersQuery = saleOrdersQuery.lt('created_at', endDateTime.toIso8601String());
        reimportOrdersQuery = reimportOrdersQuery.lt('created_at', endDateTime.toIso8601String());
      }

      // Add order and range after all filters
      transporterOrdersQuery = transporterOrdersQuery.order('created_at', ascending: false).range(start, end);
      financialOrdersQuery = financialOrdersQuery.order('created_at', ascending: false).range(start, end);
      saleOrdersQuery = saleOrdersQuery.order('created_at', ascending: false).range(start, end);
      reimportOrdersQuery = reimportOrdersQuery.order('created_at', ascending: false).range(start, end);

      developer.log('Executing queries for transporter: "$transporterName"');
      final results = await Future.wait<dynamic>([
        transporterOrdersQuery,
        financialOrdersQuery,
        saleOrdersQuery,
        reimportOrdersQuery,
      ]);
      developer.log('Queries completed');

      final transporterOrders = (results[0] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map((order) => {
                ...order,
                'type': order['type'] == 'chuyển kho quốc tế'
                    ? 'Phiếu Chuyển Kho Quốc Tế'
                    : order['type'] == 'chuyển kho nội địa'
                        ? 'Phiếu Chuyển Kho Nội Địa'
                        : order['type'] == 'nhập kho vận chuyển'
                            ? 'Phiếu Nhập Kho Vận Chuyển'
                            : 'Vận Chuyển',
                'product_name': CacheUtil.getProductName(order['product_id']?.toString()),
              })
          .toList();
      developer.log('Transporter Orders: ${transporterOrders.length}, First order: ${transporterOrders.isNotEmpty ? transporterOrders.first : "none"}');

      final financialOrders = (results[1] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map((order) {
            // ✅ Phân biệt giữa payment (chi) và receive (thu)
            final orderType = order['type']?.toString() ?? '';
            final displayType = orderType == 'payment' 
                ? 'Chi Thanh Toán Đối Tác' 
                : orderType == 'receive'
                    ? 'Phiếu Thu Tiền Đối Tác'
                    : 'Chi Thanh Toán Đối Tác'; // Fallback
            return {...order, 'type': displayType};
          })
          .toList();
      developer.log('Financial Orders: ${financialOrders.length}, First order: ${financialOrders.isNotEmpty ? financialOrders.first : "none"}');

      final saleOrders = (results[2] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map((order) => {
                ...order,
                'type': 'Phiếu Bán Hàng',
                'product_name': CacheUtil.getProductName(order['product_id']?.toString()),
              })
          .toList();
      developer.log('Sale Orders: ${saleOrders.length}, First order: ${saleOrders.isNotEmpty ? saleOrders.first : "none"}');

      // ✅ Filter reimport_orders COD hoàn theo transporter từ products
      final reimportOrdersRaw = (results[3] as List<dynamic>).cast<Map<String, dynamic>>();
      final List<Map<String, dynamic>> reimportOrders = [];
      
      // ✅ Tối ưu: Lấy tất cả IMEI trước, sau đó query products một lần
      final allImeis = reimportOrdersRaw
          .map((order) => order['imei']?.toString())
          .whereType<String>()
          .where((imei) => imei.isNotEmpty)
          .toList();
      
      // Query products với tất cả IMEI để lấy transporter
      Map<String, String?> imeiToTransporter = {};
      if (allImeis.isNotEmpty) {
        try {
          // Chia thành batch để tránh query quá lớn
          for (int i = 0; i < allImeis.length; i += 100) {
            final batchImeis = allImeis.skip(i).take(100).toList();
            final productsResponse = await widget.tenantClient
                .from('products')
                .select('imei, transporter')
                .inFilter('imei', batchImeis);
            
            for (var product in productsResponse) {
              final imei = product['imei']?.toString();
              final transporter = product['transporter']?.toString();
              if (imei != null) {
                imeiToTransporter[imei] = transporter;
              }
            }
          }
        } catch (e) {
          developer.log('Error fetching transporters for IMEIs: $e');
        }
      }
      
      // Filter reimport_orders theo transporter
      for (var order in reimportOrdersRaw) {
        final imei = order['imei']?.toString() ?? '';
        final productTransporter = imeiToTransporter[imei];
        // ✅ Chỉ thêm vào danh sách nếu transporter trùng với transporter đang xem
        if (productTransporter == transporterName) {
          reimportOrders.add({
            ...order,
            'type': 'Phiếu Nhập Lại Hàng (COD Hoàn)',
            'product_name': CacheUtil.getProductName(order['product_id']?.toString()),
          });
        }
      }
      developer.log('Reimport Orders (COD Hoàn) for transporter "$transporterName": ${reimportOrders.length}');

      final newTransactions = [...transporterOrders, ...financialOrders, ...saleOrders, ...reimportOrders];

      newTransactions.sort((a, b) {
        final dateA = DateTime.tryParse(a['created_at']?.toString() ?? '1900-01-01') ?? DateTime(1900);
        final dateB = DateTime.tryParse(b['created_at']?.toString() ?? '1900-01-01') ?? DateTime(1900);
        return dateB.compareTo(dateA);
      });

      setState(() {
        transactions.addAll(newTransactions);
        // ✅ Logic hasMoreData: nếu fetch được ít hơn pageSize thì không còn dữ liệu
        if (newTransactions.length < pageSize) {
          hasMoreData = false;
        }
        currentPage++;
        isLoadingTransactions = false;
        isLoadingMore = false;
      });
    } catch (e) {
      setState(() {
        transactionError = 'Không thể tải thêm giao dịch: $e';
        isLoadingMore = false;
      });
    }
  }

  List<Map<String, dynamic>> get filteredTransactions {
    // Không cần lọc lại ở đây vì đã lọc trong query database
    return transactions;
  }

  Future<void> _selectDate(BuildContext context, bool isStart) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() {
        if (isStart) {
          startDate = picked;
        } else {
          endDate = picked;
        }
      });
      // ✅ Gọi lại fetch để áp dụng filter vào query
      await _fetchTransactions();
    }
  }

  Future<void> _exportToExcel() async {
    if (filteredTransactions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Không có giao dịch để xuất!')),
      );
      return;
    }

    // Hiển thị progress dialog
    if (!mounted) return;
    ExportProgressDialog.show(context);

    try {
      List<Map<String, dynamic>> exportTransactions = filteredTransactions;
      if (hasMoreData && startDate == null && endDate == null) {
        final transporterName = widget.transporter['name']?.toString() ?? '';

        final transporterOrdersFuture = widget.tenantClient
            .from('transporter_orders')
            .select('*, product_id')
            .eq('transporter', transporterName)
            .eq('iscancelled', false)
            .order('created_at', ascending: false);

        final financialOrdersFuture = widget.tenantClient
            .from('financial_orders')
            .select()
            .eq('partner_type', 'transporters')
            .eq('partner_name', transporterName)
            .eq('iscancelled', false)
            .order('created_at', ascending: false);

        final saleOrdersFuture = widget.tenantClient
            .from('sale_orders')
            .select('*, product_id')
            .eq('transporter', transporterName)
            .eq('iscancelled', false)
            .order('created_at', ascending: false);

        // ✅ Query reimport_orders COD hoàn (sẽ filter theo transporter sau)
        final reimportOrdersFuture = widget.tenantClient
            .from('reimport_orders')
            .select('*, product_id, customer_price, transporter_price')
            .eq('account', 'Cod hoàn') // ✅ Sử dụng 'Cod hoàn' (chữ thường) như trong database
            .eq('iscancelled', false)
            .order('created_at', ascending: false);

        final results = await Future.wait([
          transporterOrdersFuture,
          financialOrdersFuture,
          saleOrdersFuture,
          reimportOrdersFuture,
        ]);

        final transporterOrders = (results[0] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .map((order) => {
                  ...order,
                  'type': order['type'] == 'chuyển kho quốc tế'
                      ? 'Phiếu Chuyển Kho Quốc Tế'
                      : order['type'] == 'chuyển kho nội địa'
                          ? 'Phiếu Chuyển Kho Nội Địa'
                          : order['type'] == 'nhập kho vận chuyển'
                              ? 'Phiếu Nhập Kho Vận Chuyển'
                              : 'Vận Chuyển',
                  'product_name': CacheUtil.getProductName(order['product_id']?.toString()),
                })
            .toList();

        final financialOrders = (results[1] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .map((order) {
              // ✅ Phân biệt giữa payment (chi) và receive (thu)
              final orderType = order['type']?.toString() ?? '';
              final displayType = orderType == 'payment' 
                  ? 'Chi Thanh Toán Đối Tác' 
                  : orderType == 'receive'
                      ? 'Phiếu Thu Tiền Đối Tác'
                      : 'Chi Thanh Toán Đối Tác'; // Fallback
              return {...order, 'type': displayType};
            })
            .toList();

        final saleOrders = (results[2] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .map((order) => {
                  ...order,
                  'type': 'Phiếu Bán Hàng',
                  'product_name': CacheUtil.getProductName(order['product_id']?.toString()),
                })
            .toList();

        // ✅ Filter reimport_orders COD hoàn theo transporter từ products
        final reimportOrdersRaw = (results[3] as List<dynamic>).cast<Map<String, dynamic>>();
        final List<Map<String, dynamic>> reimportOrders = [];
        
        // ✅ Tối ưu: Lấy tất cả IMEI trước, sau đó query products một lần
        final allImeis = reimportOrdersRaw
            .map((order) => order['imei']?.toString())
            .whereType<String>()
            .where((imei) => imei.isNotEmpty)
            .toList();
        
        // Query products với tất cả IMEI để lấy transporter
        Map<String, String?> imeiToTransporter = {};
        if (allImeis.isNotEmpty) {
          try {
            // Chia thành batch để tránh query quá lớn
            for (int i = 0; i < allImeis.length; i += 100) {
              final batchImeis = allImeis.skip(i).take(100).toList();
              final productsResponse = await widget.tenantClient
                  .from('products')
                  .select('imei, transporter')
                  .inFilter('imei', batchImeis);
              
              for (var product in productsResponse) {
                final imei = product['imei']?.toString();
                final transporter = product['transporter']?.toString();
                if (imei != null) {
                  imeiToTransporter[imei] = transporter;
                }
              }
            }
          } catch (e) {
            developer.log('Error fetching transporters for IMEIs: $e');
          }
        }
        
        // Filter reimport_orders theo transporter
        for (var order in reimportOrdersRaw) {
          final imei = order['imei']?.toString() ?? '';
          final productTransporter = imeiToTransporter[imei];
          // ✅ Chỉ thêm vào danh sách nếu transporter trùng với transporter đang xem
          if (productTransporter == transporterName) {
            reimportOrders.add({
              ...order,
              'type': 'Phiếu Nhập Lại Hàng (COD Hoàn)',
              'product_name': CacheUtil.getProductName(order['product_id']?.toString()),
            });
          }
        }

        exportTransactions = [...transporterOrders, ...financialOrders, ...saleOrders, ...reimportOrders];
        exportTransactions.sort((a, b) {
          final dateA = DateTime.tryParse(a['created_at']?.toString() ?? '1900-01-01') ?? DateTime(1900);
          final dateB = DateTime.tryParse(b['created_at']?.toString() ?? '1900-01-01') ?? DateTime(1900);
          return dateB.compareTo(dateA);
        });
      }

      var excel = Excel.createExcel();
      excel.delete('Sheet1');

      Sheet sheet = excel['GiaoDichDonViVanChuyen'];

      // Thêm thông tin đối tác
      final transporterName = widget.transporter['name']?.toString() ?? '';
      final transporterPhone = widget.transporter['phone']?.toString() ?? '';
      final transporterAddress = widget.transporter['address']?.toString() ?? '';
      final debt = widget.transporter['debt'] as num? ?? 0;
      final debtText = debt != 0 ? '${formatNumber(debt)} VND' : '0 VND';

      sheet.cell(CellIndex.indexByString("A1")).value = TextCellValue('Tên đơn vị vận chuyển: $transporterName');
      sheet.cell(CellIndex.indexByString("A2")).value = TextCellValue('Số điện thoại: $transporterPhone');
      sheet.cell(CellIndex.indexByString("A3")).value = TextCellValue('Địa chỉ: $transporterAddress');
      sheet.cell(CellIndex.indexByString("A4")).value = TextCellValue('Công nợ: $debtText');
      
      int currentRow = 5;
      
      // Thêm thông tin bộ lọc thời gian nếu có
      if (startDate != null && endDate != null) {
        final startDateStr = formatDate(startDate!.toIso8601String());
        final endDateStr = formatDate(endDate!.toIso8601String());
        sheet.cell(CellIndex.indexByString("A$currentRow")).value = TextCellValue('Thời gian: Từ $startDateStr đến $endDateStr');
        currentRow++;
      }

      final headers = ['Loại giao dịch', 'Ngày', 'Sản phẩm', 'IMEI', 'Số tiền', 'Đơn vị tiền', 'Tiền cọc', 'Tiền COD'];
      final columnCount = headers.length;
      final sizingTracker = ExcelSizingTracker(columnCount);
      final styles = ExcelCellStyles.build();

      for (int columnIndex = 0; columnIndex < columnCount; columnIndex++) {
        final cell = sheet.cell(
          CellIndex.indexByColumnRow(
            columnIndex: columnIndex,
            rowIndex: currentRow - 1,
          ),
        );
        cell.value = TextCellValue(headers[columnIndex]);
        cell.cellStyle = styles.header;
        sizingTracker.update(currentRow - 1, columnIndex, headers[columnIndex]);
      }
      currentRow++;

      for (int i = 0; i < exportTransactions.length; i++) {
        final transaction = exportTransactions[i];
        final type = transaction['type'] as String;
        final createdAt = formatDate(transaction['created_at']?.toString());
        final currency = transaction['currency']?.toString() ?? 'VND';
        final productName = transaction['product_name']?.toString() ?? 'Không xác định';

        final imeiStr = transaction['imei']?.toString() ?? '';
        final imeiList = imeiStr.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
        
        // ✅ Kiểm tra nếu là sale_orders với account == 'Ship COD' hoặc reimport_orders COD hoàn
        final isShipCod = type == 'Phiếu Bán Hàng' && 
            transaction['account']?.toString() == 'Ship COD';
        final isCodHoan = type == 'Phiếu Nhập Lại Hàng (COD Hoàn)' || 
            (type == 'Phiếu Nhập Lại Hàng' && transaction['account']?.toString() == 'Cod hoàn');
        final customerPriceTotal = (isShipCod || isCodHoan) ? (transaction['customer_price'] as num?) : null;
        final transporterPriceTotal = (isShipCod || isCodHoan) ? (transaction['transporter_price'] as num?) : null;
        
        // ✅ Kiểm tra xem transaction có IMEI không (các phiếu vận chuyển, bán hàng, nhập lại)
        final hasImei = imeiList.isNotEmpty && 
            (type == 'Phiếu Chuyển Kho Quốc Tế' || 
             type == 'Phiếu Chuyển Kho Nội Địa' || 
             type == 'Phiếu Nhập Kho Vận Chuyển' || 
             type == 'Phiếu Bán Hàng' || 
             type == 'Phiếu Nhập Lại Hàng' ||
             type == 'Phiếu Nhập Lại Hàng (COD Hoàn)');

        // Tính số tiền cho mỗi IMEI
        num totalAmount = transaction['transport_fee'] ?? transaction['amount'] ?? transaction['price'] ?? 0;
        num amountPerImei;
        if (type == 'Phiếu Bán Hàng' || type == 'Phiếu Nhập Lại Hàng' || type == 'Phiếu Nhập Lại Hàng (COD Hoàn)') {
          // Với phiếu có price, mỗi IMEI = price (đơn giá)
          amountPerImei = transaction['price'] as num? ?? 0;
        } else if (type == 'Phiếu Chuyển Kho Quốc Tế' || type == 'Phiếu Chuyển Kho Nội Địa' || type == 'Phiếu Nhập Kho Vận Chuyển') {
          // Với transporter_orders, chia transport_fee cho số lượng IMEI
          final imeiCount = imeiList.isNotEmpty ? imeiList.length : 1;
          amountPerImei = imeiCount > 0 ? (totalAmount / imeiCount) : totalAmount;
        } else {
          // Với financial_orders (không có IMEI), dùng totalAmount
          amountPerImei = totalAmount;
        }
        // Tính tiền cọc và tiền COD cho mỗi IMEI (chia đều như số tiền)
        num customerPricePerImei = 0;
        num transporterPricePerImei = 0;
        num customerPriceTotalValue = 0;
        num transporterPriceTotalValue = 0;
        if ((isShipCod || isCodHoan) && customerPriceTotal != null && transporterPriceTotal != null) {
          customerPriceTotalValue = customerPriceTotal;
          transporterPriceTotalValue = transporterPriceTotal;
          if (hasImei && imeiList.isNotEmpty) {
            // Chia đều cho số lượng IMEI
            final imeiCount = imeiList.length;
            customerPricePerImei = customerPriceTotal / imeiCount;
            transporterPricePerImei = transporterPriceTotal / imeiCount;
          }
        }

        if (hasImei && imeiList.isNotEmpty) {
          // ✅ Mỗi IMEI là 1 dòng riêng - tách sản phẩm và IMEI thành 2 cột
          for (final singleImei in imeiList) {
            for (int columnIndex = 0; columnIndex < columnCount; columnIndex++) {
              final cell = sheet.cell(
                CellIndex.indexByColumnRow(
                  columnIndex: columnIndex,
                  rowIndex: currentRow - 1,
                ),
              );
              final header = headers[columnIndex];
              final isMultiline = columnIndex == 3;
              
              // Xác định loại cell value dựa trên header
              if (header == 'Loại giao dịch') {
                cell.value = TextCellValue(type);
              } else if (header == 'Ngày') {
                cell.value = TextCellValue(createdAt);
              } else if (header == 'Sản phẩm') {
                cell.value = TextCellValue(productName);
              } else if (header == 'IMEI') {
                cell.value = TextCellValue(singleImei);
              } else if (header == 'Số tiền') {
                // ✅ Dùng trực tiếp giá trị num thay vì toString() để tránh format sai
                final amountValue = amountPerImei.toDouble();
                cell.value = DoubleCellValue(amountValue);
              } else if (header == 'Đơn vị tiền') {
                cell.value = TextCellValue(currency);
              } else if (header == 'Tiền cọc') {
                if (customerPricePerImei > 0) {
                  final customerPriceValue = customerPricePerImei.toDouble();
                  cell.value = DoubleCellValue(customerPriceValue);
                } else {
                  cell.value = TextCellValue('');
                }
              } else if (header == 'Tiền COD') {
                if (transporterPricePerImei > 0) {
                  final transporterPriceValue = transporterPricePerImei.toDouble();
                  cell.value = DoubleCellValue(transporterPriceValue);
                } else {
                  cell.value = TextCellValue('');
                }
              } else {
                cell.value = TextCellValue('');
              }
              
              cell.cellStyle = isMultiline ? styles.multiline : styles.centered;
              if (header == 'Số tiền' || header == 'Tiền cọc' || header == 'Tiền COD') {
                sizingTracker.update(currentRow - 1, columnIndex, cell.value.toString());
              } else {
                sizingTracker.update(currentRow - 1, columnIndex, cell.value?.toString() ?? '');
              }
            }

            currentRow++;
          }
        } else {
          for (int columnIndex = 0; columnIndex < columnCount; columnIndex++) {
            final cell = sheet.cell(
              CellIndex.indexByColumnRow(
                columnIndex: columnIndex,
                rowIndex: currentRow - 1,
              ),
            );
            final header = headers[columnIndex];
            final isMultiline = columnIndex == 3;
            
            // Xác định loại cell value dựa trên header
            if (header == 'Loại giao dịch') {
              cell.value = TextCellValue(type);
            } else if (header == 'Ngày') {
              cell.value = TextCellValue(createdAt);
            } else if (header == 'Sản phẩm') {
              cell.value = TextCellValue(productName != 'Không xác định' ? productName : '');
            } else if (header == 'IMEI') {
              cell.value = TextCellValue('');
            } else if (header == 'Số tiền') {
              // ✅ Dùng trực tiếp giá trị num thay vì toString() để tránh format sai
              final totalAmountValue = totalAmount.toDouble();
              cell.value = DoubleCellValue(totalAmountValue);
            } else if (header == 'Đơn vị tiền') {
              cell.value = TextCellValue(currency);
            } else if (header == 'Tiền cọc') {
              if (customerPriceTotalValue > 0) {
                final customerPriceValue = customerPriceTotalValue.toDouble();
                cell.value = DoubleCellValue(customerPriceValue);
              } else {
                cell.value = TextCellValue('');
              }
            } else if (header == 'Tiền COD') {
              if (transporterPriceTotalValue > 0) {
                final transporterPriceValue = transporterPriceTotalValue.toDouble();
                cell.value = DoubleCellValue(transporterPriceValue);
              } else {
                cell.value = TextCellValue('');
              }
            } else {
              cell.value = TextCellValue('');
            }
            
            cell.cellStyle = isMultiline ? styles.multiline : styles.centered;
            if (header == 'Số tiền' || header == 'Tiền cọc' || header == 'Tiền COD') {
              sizingTracker.update(currentRow - 1, columnIndex, cell.value.toString());
            } else {
              sizingTracker.update(currentRow - 1, columnIndex, cell.value?.toString() ?? '');
            }
          }

          currentRow++;
        }
      }

      sizingTracker.applyToSheet(sheet);

      if (excel.sheets.containsKey('Sheet1')) {
        excel.delete('Sheet1');
        print('Sheet1 đã được xóa trước khi xuất file.');
      } else {
        print('Không tìm thấy Sheet1 sau khi tạo các sheet.');
      }

      // Sử dụng StorageHelper để lấy thư mục Downloads (hỗ trợ Android 13+)
      final downloadsDir = await StorageHelper.getDownloadDirectory();
      if (downloadsDir == null) {
        if (mounted) ExportProgressDialog.hide(context);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Không thể truy cập thư mục Downloads')),
          );
        }
        return;
      }

      final now = DateTime.now();
      final transporterNameForFile = widget.transporter['name']?.toString() ?? 'Unknown';
      final fileName = 'Báo Cáo Giao Dịch Đơn Vị Vận Chuyển $transporterNameForFile ${now.day}_${now.month}_${now.year} ${now.hour}_${now.minute}_${now.second}.xlsx';
      final filePath = '${downloadsDir.path}/$fileName';
      final file = File(filePath);

      final excelBytes = excel.encode();
      if (excelBytes == null) {
        throw Exception('Không thể tạo file Excel');
      }
      await file.writeAsBytes(excelBytes);

      // Đóng progress dialog
      if (mounted) ExportProgressDialog.hide(context);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Đã xuất file Excel: $filePath')),
        );
      }

      final openResult = await OpenFile.open(filePath);
      if (openResult.type != ResultType.done && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Không thể mở file. File đã được lưu tại: $filePath'),
          ),
        );
      }
    } catch (e) {
      // Đóng progress dialog nếu có lỗi
      if (mounted) ExportProgressDialog.hide(context);
      
      if (mounted) {
        final shouldRetry = await ErrorHandler.showErrorDialog(
          context: context,
          title: 'Lỗi xuất Excel',
          error: e,
          showRetry: true,
        );
        
        if (shouldRetry) {
          await _exportToExcel();
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final transporter = widget.transporter;
    final debt = transporter['debt'] as num? ?? 0;
    final debtText = debt != 0 ? '${formatNumber(debt)} VND' : '0 VND';

    return AlertDialog(
      title: const Text('Chi tiết đơn vị vận chuyển'),
      content: Container(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Tên: ${transporter['name']?.toString() ?? ''}'),
            const SizedBox(height: 8),
            Text('Số điện thoại: ${transporter['phone']?.toString() ?? ''}'),
            const SizedBox(height: 8),
            Text('Địa chỉ: ${transporter['address']?.toString() ?? ''}'),
            const SizedBox(height: 8),
            Text('Công nợ: $debtText'),
            const SizedBox(height: 16),
            const Text('Lịch sử giao dịch', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => _selectDate(context, true),
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Từ ngày',
                        border: OutlineInputBorder(),
                      ),
                      child: Text(startDate != null ? formatDate(startDate!.toIso8601String()) : 'Chọn ngày'),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: InkWell(
                    onTap: () => _selectDate(context, false),
                    child: InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Đến ngày',
                        border: OutlineInputBorder(),
                      ),
                      child: Text(endDate != null ? formatDate(endDate!.toIso8601String()) : 'Chọn ngày'),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: isLoadingTransactions
                  ? const Center(child: CircularProgressIndicator())
                  : transactionError != null
                      ? Text(transactionError!)
                      : filteredTransactions.isEmpty
                          ? const Text('Không có giao dịch trong khoảng thời gian này.')
                          : ListView.builder(
                              controller: _scrollController,
                              itemCount: filteredTransactions.length + (isLoadingMore ? 1 : 0),
                              itemBuilder: (context, index) {
                                if (index == filteredTransactions.length && isLoadingMore) {
                                  return const Center(child: CircularProgressIndicator());
                                }
                                final transaction = filteredTransactions[index];
                                final type = transaction['type'] as String;
                                final createdAt = formatDate(transaction['created_at']?.toString());
                                final amount = transaction['transport_fee'] ?? transaction['amount'] ?? transaction['price'] ?? 0;
                                final currency = transaction['currency']?.toString() ?? 'VND';
                                final formattedAmount = formatNumber(amount);
                                final productName = transaction['product_name'] ?? 'Không xác định';
                                
                                // Kiểm tra nếu là sale_orders với account == 'Ship COD' hoặc reimport_orders COD hoàn
                                final isShipCod = type == 'Phiếu Bán Hàng' && 
                                    transaction['account']?.toString() == 'Ship COD';
                                final isCodHoan = type == 'Phiếu Nhập Lại Hàng (COD Hoàn)' || 
                                    (type == 'Phiếu Nhập Lại Hàng' && transaction['account']?.toString() == 'Cod hoàn');
                                final customerPrice = (isShipCod || isCodHoan) ? (transaction['customer_price'] as num?) : null;
                                final transporterPrice = (isShipCod || isCodHoan) ? (transaction['transporter_price'] as num?) : null;
                                
                                final details = type == 'Phiếu Chuyển Kho Quốc Tế' ||
                                        type == 'Phiếu Chuyển Kho Nội Địa' ||
                                        type == 'Phiếu Nhập Kho Vận Chuyển'
                                    ? 'Sản phẩm: $productName, IMEI: ${transaction['imei']}'
                                    : type == 'Phiếu Bán Hàng'
                                        ? 'Sản phẩm: $productName, IMEI: ${transaction['imei']}'
                                        : type == 'Phiếu Nhập Lại Hàng (COD Hoàn)' || type == 'Phiếu Nhập Lại Hàng'
                                            ? 'Sản phẩm: $productName, IMEI: ${transaction['imei']}, Số lượng: ${transaction['quantity']}'
                                            : type == 'Chi Thanh Toán Đối Tác' || type == 'Phiếu Thu Tiền Đối Tác'
                                                ? 'Tài khoản: ${transaction['account']}, Ghi chú: ${transaction['note'] ?? ''}'
                                                : '';

                                // Xây dựng text hiển thị số tiền
                                String amountText = 'Số tiền: $formattedAmount $currency';
                                if ((isShipCod || isCodHoan) && customerPrice != null && transporterPrice != null) {
                                  amountText = 'Tiền cọc: ${formatNumber(customerPrice)} $currency\n'
                                      'Tiền COD: ${formatNumber(transporterPrice)} $currency';
                                }

                                return Card(
                                  margin: const EdgeInsets.symmetric(vertical: 4),
                                  child: ListTile(
                                    title: Text('$type - $createdAt'),
                                    subtitle: Text('$details\n$amountText'),
                                  ),
                                );
                              },
                            ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _exportToExcel,
          child: const Text('Xuất Excel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Đóng'),
        ),
      ],
    );
  }
}