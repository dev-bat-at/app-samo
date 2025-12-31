import 'package:flutter/material.dart' hide BorderStyle;
import 'package:flutter/services.dart' show Clipboard, ClipboardData, rootBundle;
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:excel/excel.dart' as excel;
import 'package:open_file/open_file.dart';
import 'dart:io';
import 'dart:math' as math;
import 'dart:developer' as developer;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:barcode/barcode.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../helpers/storage_helper.dart';
import '../helpers/bluetooth_print_helper.dart';
import 'customers_screen.dart';
import 'suppliers_screen.dart';
import 'transporters_screen.dart';
import 'fixers_screen.dart';

class HistoryScreen extends StatefulWidget {
  final List<String> permissions;
  final SupabaseClient tenantClient;

  const HistoryScreen({super.key, required this.permissions, required this.tenantClient});

  @override
  _HistoryScreenState createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  Set<String> selectedFilterTypes = {'all'};
  DateTime? dateFrom;
  DateTime? dateTo;
  final TextEditingController _dateFromController = TextEditingController();
  final TextEditingController _dateToController = TextEditingController();

  final List<Map<String, String>> allTicketTypeOptions = [
    {'value': 'all', 'display': 'Loại Phiếu', 'permission': ''},
    {'value': 'transfer_fund', 'display': 'Chuyển Quỹ', 'permission': 'access_transfer_fund_form'},
    {'value': 'exchange', 'display': 'Đổi Tiền', 'permission': 'access_financial_account_form'},
    {'value': 'cost', 'display': 'Chi phí', 'permission': 'access_financial_account_form'},
    {'value': 'income_other', 'display': 'Thu Nhập Khác', 'permission': 'access_financial_account_form'},
    {'value': 'payment', 'display': 'Chi Thanh Toán Đối Tác', 'permission': 'access_financial_account_form'},
    {'value': 'receive', 'display': 'Thu Tiền Đối Tác', 'permission': 'access_financial_account_form'},
    {'value': 'import_orders', 'display': 'Nhập Hàng', 'permission': 'access_import_form'},
    {'value': 'return_orders', 'display': 'Trả Hàng', 'permission': 'access_return_form'},
    {'value': 'fix_send_orders', 'display': 'Gửi Sửa', 'permission': 'access_fix_send_form'},
    {'value': 'fix_receive_orders', 'display': 'Nhận Hàng Sửa Xong', 'permission': 'access_fix_receive_form'},
    {'value': 'chuyển kho nội địa', 'display': 'Chuyển Kho Nội Địa', 'permission': 'access_transfer_local_form'},
    {'value': 'chuyển kho quốc tế', 'display': 'Chuyển Kho Quốc Tế', 'permission': 'access_transfer_global_form'},
    {'value': 'nhập kho vận chuyển', 'display': 'Nhập Kho Vận Chuyển', 'permission': 'access_transfer_receive_form'},
    {'value': 'sale_orders', 'display': 'Bán Hàng', 'permission': 'access_sale_form'},
    {'value': 'reimport_orders', 'display': 'Nhập Lại Hàng', 'permission': 'access_reimport_form'},
  ];

  late List<Map<String, String>> ticketTypeOptions;
  List<Map<String, dynamic>> tickets = [];
  bool isLoadingTickets = true;
  String? ticketError;
  bool isExporting = false;
  Map<String, String> productMap = {};
  Map<String, String> warehouseMap = {};
  Map<String, String> customerMap = {};
  Map<String, String> supplierMap = {};
  Map<String, String> fixerMap = {};
  Map<String, String> transporterMap = {};

  int pageSize = 50;
  int currentPage = 0;
  bool hasMoreData = true;
  bool isLoadingMore = false;
  final ScrollController _scrollController = ScrollController();

  // Cài đặt in tem (giống inventory_screen.dart)
  String _defaultPrintType = 'a4';
  int _defaultLabelsPerRow = 1;
  int _defaultLabelHeight = 30;
  bool _hasDefaultSettings = false;

  @override
  void initState() {
    super.initState();
    ticketTypeOptions = allTicketTypeOptions.where((option) {
      if (option['value'] == 'all') return true;
      final requiredPermission = option['permission']!;
      return requiredPermission.isEmpty || widget.permissions.contains(requiredPermission);
    }).toList();

    developer.log('init: User permissions: ${widget.permissions.join(', ')}');
    _loadPrintSettings();
    _loadInitialData();
    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
              _scrollController.position.maxScrollExtent - 200 &&
          !isLoadingMore &&
          hasMoreData &&
          selectedFilterTypes.contains('all') &&
          dateFrom == null &&
          dateTo == null) {
        _loadMoreTickets();
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _dateFromController.dispose();
    _dateToController.dispose();
    super.dispose();
  }

  Future<void> _loadPrintSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _defaultPrintType = prefs.getString('default_print_type') ?? 'a4';
        _defaultLabelsPerRow = prefs.getInt('default_labels_per_row') ?? 1;
        _defaultLabelHeight = prefs.getInt('default_label_height') ?? 30;
        _hasDefaultSettings = prefs.getBool('has_default_print_settings') ?? false;
      });
    } catch (e) {
      // Ignore errors, use defaults
    }
  }

  Future<void> _savePrintSettings(String printType, int labelsPerRow, int labelHeight) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('default_print_type', printType);
      await prefs.setInt('default_labels_per_row', labelsPerRow);
      await prefs.setInt('default_label_height', labelHeight);
      await prefs.setBool('has_default_print_settings', true);
      setState(() {
        _hasDefaultSettings = true;
      });
    } catch (e) {
      // Ignore errors
    }
  }

  Future<void> _loadInitialData() async {
    developer.log('loadInitialData: Starting');
    setState(() {
      isLoadingTickets = true;
      ticketError = null;
    });

    try {
      await Future.wait([
        _fetchProducts(),
        _fetchWarehouses(),
        _fetchCustomers(),
        _fetchSuppliers(),
        _fetchFixers(),
        _fetchTransporters(),
      ]);

      if (productMap.isEmpty) {
        ticketError = 'Không tải được danh sách sản phẩm';
        developer.log('loadInitialData: productMap is empty');
      } else if (warehouseMap.isEmpty) {
        ticketError = 'Không tải được danh sách kho';
        developer.log('loadInitialData: warehouseMap is empty');
      }

      await _loadTickets();
    } catch (e) {
      setState(() {
        ticketError = 'Có lỗi xảy ra khi tải dữ liệu ban đầu: $e';
        isLoadingTickets = false;
      });
      developer.log('loadInitialData: Error: $e');
    } finally {
      setState(() {
        isLoadingTickets = false;
      });
    }
  }

  Future<void> _fetchProducts() async {
    try {
      final response = await widget.tenantClient.from('products_name').select('id, products');
      setState(() {
        productMap = Map.fromEntries(
          response.map((e) => MapEntry(e['id'].toString(), e['products'] as String)),
        );
      });
      developer.log('products: Loaded ${productMap.length} products');
    } catch (e) {
      developer.log('products: Error: $e');
      productMap = {};
    }
  }

  Future<void> _fetchWarehouses() async {
    try {
      final response = await widget.tenantClient.from('warehouses').select('id, name');
      setState(() {
        warehouseMap = Map.fromEntries(
          response.map((e) => MapEntry(e['id'].toString(), e['name'] as String)),
        );
      });
      developer.log('warehouses: Loaded ${warehouseMap.length} warehouses');
    } catch (e) {
      developer.log('warehouses: Error: $e');
      warehouseMap = {};
    }
  }

  Future<void> _fetchCustomers() async {
    try {
      final response = await widget.tenantClient.from('customers').select('id, name');
      setState(() {
        customerMap = Map.fromEntries(
          response.map((e) => MapEntry(e['id'].toString(), e['name'] as String)),
        );
      });
      developer.log('customers: Loaded ${customerMap.length} customers');
    } catch (e) {
      developer.log('customers: Error: $e');
      customerMap = {};
    }
  }

  Future<void> _fetchSuppliers() async {
    try {
      final response = await widget.tenantClient.from('suppliers').select('id, name');
      setState(() {
        supplierMap = Map.fromEntries(
          response.map((e) => MapEntry(e['id'].toString(), e['name'] as String)),
        );
      });
      developer.log('suppliers: Loaded ${supplierMap.length} suppliers');
    } catch (e) {
      developer.log('suppliers: Error: $e');
      supplierMap = {};
    }
  }

  Future<void> _fetchFixers() async {
    try {
      final response = await widget.tenantClient.from('fix_units').select('id, name');
      setState(() {
        fixerMap = Map.fromEntries(
          response.map((e) => MapEntry(e['id'].toString(), e['name'] as String)),
        );
      });
      developer.log('fixers: Loaded ${fixerMap.length} fixers');
    } catch (e) {
      developer.log('fixers: Error: $e');
      fixerMap = {};
    }
  }

  Future<void> _fetchTransporters() async {
    try {
      final response = await widget.tenantClient.from('transporters').select('id, name');
      setState(() {
        transporterMap = Map.fromEntries(
          response.map((e) => MapEntry(e['id'].toString(), e['name'] as String)),
        );
      });
      developer.log('transporters: Loaded ${transporterMap.length} transporters');
    } catch (e) {
      developer.log('transporters: Error: $e');
      transporterMap = {};
    }
  }

  Future<void> _loadTickets() async {
    developer.log('loadTickets: Starting');
    setState(() {
      isLoadingTickets = true;
      ticketError = null;
      tickets = [];
      currentPage = 0;
      hasMoreData = true;
    });

    try {
      await _loadMoreTickets();
    } catch (e) {
      setState(() {
        ticketError = 'Có lỗi xảy ra khi tải phiếu: $e';
      });
      developer.log('loadTickets: Error: $e');
    } finally {
      setState(() {
        isLoadingTickets = false;
      });
    }
  }

  Future<void> _loadMoreTickets() async {
    if (!hasMoreData || isLoadingMore) {
      developer.log('loadMoreTickets: No more data or loading');
      return;
    }

    developer.log('loadMoreTickets: Page $currentPage');
    setState(() {
      isLoadingMore = true;
    });

    try {
      final newTickets = await _fetchTickets(paginated: true);
      setState(() {
        tickets.addAll(newTickets);
        if (newTickets.length < pageSize) {
          hasMoreData = false;
        }
        currentPage++;
      });
      developer.log('tickets: Loaded ${newTickets.length}, total: ${tickets.length}');
    } catch (e) {
      setState(() {
        ticketError = 'Có lỗi khi tải thêm dữ liệu: $e';
        isLoadingMore = false;
      });
      developer.log('loadMoreTickets: Error: $e');
    } finally {
      setState(() {
        isLoadingMore = false;
      });
    }
  }

  Future<void> _selectDate(BuildContext context, bool isFrom) async {
    final initialDate = DateTime.now();
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: isFrom ? (dateFrom ?? initialDate) : (dateTo ?? initialDate),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        if (isFrom) {
          dateFrom = picked;
          _dateFromController.text = DateFormat('dd/MM/yyyy').format(picked);
        } else {
          dateTo = picked;
          _dateToController.text = DateFormat('dd/MM/yyyy').format(picked);
        }
        hasMoreData = false;
      });
      developer.log('selectDate: Picked $picked, isFrom: $isFrom');
      await _loadTickets();
    }
  }

  String _formatDate(String? dateStr) {
    if (dateStr == null) return '';
    try {
      final parsedDate = DateTime.parse(dateStr);
      return DateFormat('dd/MM/yyyy').format(parsedDate);
    } catch (e) {
      developer.log('formatDate: Error $dateStr: $e');
      return dateStr;
    }
  }

  String _formatDateTime(String? dateStr) {
    if (dateStr == null) return '';
    try {
      final parsedDate = DateTime.parse(dateStr);
      return DateFormat('HH:mm:ss - dd/MM/yyyy').format(parsedDate);
    } catch (e) {
      developer.log('formatDateTime: Error $dateStr: $e');
      return dateStr;
    }
  }

  String _formatNumber(num? amount) {
    if (amount == null) return '0';
    try {
      return NumberFormat.decimalPattern('vi_VN').format(amount);
    } catch (e) {
      developer.log('formatNumber: Error $amount: $e');
      return '0';
    }
  }

  String _formatImeiForExcelCell(dynamic imeiData) {
    if (imeiData == null) {
      return 'N/A';
    }
    final raw = imeiData.toString().trim();
    if (raw.isEmpty || raw == 'N/A') {
      return 'N/A';
    }
    final normalized = raw.replaceAll('\r', '');
    final entries = normalized
        .split(RegExp(r'[,;\n]+'))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    if (entries.isEmpty) {
      return 'N/A';
    }
    return entries.join('\r\n');
  }

  // Gom nhóm sản phẩm cùng loại theo product_name
  List<Map<String, dynamic>> _groupProductsByName(List<dynamic> items) {
    final Map<String, num> productGroups = {};
    
    for (var item in items) {
      final productName = item['product_name']?.toString() ?? 'N/A';
      final quantity = item['quantity'] as num? ?? 0;
      
      if (productName != 'N/A' && quantity > 0) {
        productGroups[productName] = (productGroups[productName] ?? 0) + quantity;
      }
    }
    
    return productGroups.entries.map((entry) {
      return {
        'product_name': entry.key,
        'total_quantity': entry.value,
      };
    }).toList();
  }

  void _updateExcelMetrics({
    required Map<int, int> rowLineCounts,
    required List<double> maxColumnWidths,
    required int rowIndex,
    required int columnIndex,
    required String value,
  }) {
    final sanitized = value.replaceAll('\r\n', '\n');
    final lines = sanitized.isEmpty ? <String>[''] : sanitized.split('\n');
    final longestLineLength = lines.fold<int>(
      0,
      (currentMax, line) => math.max(currentMax, line.length),
    );
    maxColumnWidths[columnIndex] =
        math.max(maxColumnWidths[columnIndex], longestLineLength.toDouble());
    final currentRowLineCount = rowLineCounts[rowIndex] ?? 1;
    rowLineCounts[rowIndex] = math.max(currentRowLineCount, lines.length);
  }

  void _applyExcelSizing({
    required excel.Sheet sheet,
    required List<double> maxColumnWidths,
    required Map<int, int> rowLineCounts,
  }) {
    final baseRowHeight = (sheet.defaultRowHeight ?? 15).toDouble();
    final baseColumnWidth = (sheet.defaultColumnWidth ?? 8.43).toDouble();

    for (int columnIndex = 0;
        columnIndex < maxColumnWidths.length;
        columnIndex++) {
      final contentWidth = maxColumnWidths[columnIndex];
      final computedWidth =
          contentWidth > 0 ? contentWidth + 2 : baseColumnWidth;
      sheet.setColumnWidth(
        columnIndex,
        math.max(baseColumnWidth, computedWidth),
      );
    }

    rowLineCounts.forEach((rowIndex, lineCount) {
      final effectiveLineCount = lineCount < 1 ? 1 : lineCount;
      sheet.setRowHeight(rowIndex, baseRowHeight * effectiveLineCount);
    });
  }

  String _getPartnerName(String? partnerId, String? partnerType, String? partnerName) {
    // Nếu đã có partner_name thì dùng luôn
    if (partnerName != null && partnerName.isNotEmpty && partnerName != 'N/A') {
      return partnerName;
    }
    
    // Nếu không có partner_id hoặc partner_type thì trả về N/A
    if (partnerId == null || partnerType == null) {
      return 'N/A';
    }
    
    // Tra cứu tên từ cache dựa vào partner_type
    switch (partnerType) {
      case 'suppliers':
        return supplierMap[partnerId] ?? 'N/A';
      case 'customers':
        return customerMap[partnerId] ?? 'N/A';
      case 'fix_units':
        return fixerMap[partnerId] ?? 'N/A';
      case 'transporters':
        return transporterMap[partnerId] ?? 'N/A';
      default:
        return 'N/A';
    }
  }


  String _getDisplayType(String type, String table, {String? account}) {
    // Xử lý riêng cho transfer_fund
    if (type == 'transfer_fund') {
      return 'Chuyển quỹ';
    }
    
    String typeKey = type;
    if (table == 'fix_receive_orders') {
      typeKey = 'fix_receive_orders';
    } else if (table == 'fix_send_orders') {
      typeKey = 'fix_send_orders';
    } else if (table == 'import_orders') {
      typeKey = 'import_orders';
    } else if (table == 'reimport_orders') {
      // Nếu account là "Cod hoàn" thì hiển thị "Cod Hoàn"
      if (account != null && account == 'Cod hoàn') {
        return 'Cod Hoàn';
      }
      typeKey = 'reimport_orders';
    } else if (table == 'sale_orders') {
      typeKey = 'sale_orders';
    } else if (table == 'return_orders') {
      typeKey = 'return_orders';
    } else if (table == 'transporter_orders') {
      typeKey = type;
    }

    final option = ticketTypeOptions.firstWhere(
      (opt) => opt['value'] == typeKey,
      orElse: () => {'display': typeKey},
    );
    return option['display'] ?? typeKey;
  }

  Future<List<Map<String, dynamic>>> _fetchTickets({bool paginated = false}) async {
    developer.log('fetchTickets: Paginated: $paginated, selectedFilterTypes: $selectedFilterTypes');
    List<Map<String, dynamic>> allTickets = [];
    final ticketIds = <String>{};

    final hasTransportPermission = widget.permissions.contains('access_transfer_global_form') ||
        widget.permissions.contains('access_transfer_local_form') ||
        widget.permissions.contains('access_transfer_receive_form');

    if (!hasTransportPermission &&
        (selectedFilterTypes.contains('chuyển kho quốc tế') || selectedFilterTypes.contains('chuyển kho nội địa') || selectedFilterTypes.contains('nhập kho vận chuyển'))) {
      setState(() {
        ticketError = 'Bạn không có quyền xem các phiếu vận chuyển';
      });
      return [];
    }

    final tables = [
      if (widget.permissions.contains('access_financial_account_form'))
        {
          'table': 'financial_orders',
          'key': 'id',
          'select': 'id, type, created_at, partner_name, partner_id, amount, currency, iscancelled, from_amount, from_currency, from_account, to_amount, to_currency, to_account, partner_type, account, note',
          'partnerField': 'partner_name',
          'amountField': 'amount',
          'dateField': 'created_at',
          'snapshotKey': 'id',
        },
      if (widget.permissions.contains('access_fix_receive_form'))
        {
          'table': 'fix_receive_orders',
          'key': 'ticket_id',
          'select': 'ticket_id, created_at, fixer, fix_unit_id, price, quantity, currency, account, iscancelled, product_id, warehouse_id, imei, note',
          'partnerField': 'fix_unit_id',
          'amountField': 'price',
          'dateField': 'created_at',
          'snapshotKey': 'ticket_id',
        },
      if (widget.permissions.contains('access_fix_send_form'))
        {
          'table': 'fix_send_orders',
          'key': 'ticket_id',
          'select': 'ticket_id, created_at, fixer, fix_unit_id, quantity, iscancelled, product_id, warehouse_id, imei',
          'partnerField': 'fix_unit_id',
          'amountField': null,
          'dateField': 'created_at',
          'snapshotKey': 'ticket_id',
        },
      if (widget.permissions.contains('access_import_form'))
        {
          'table': 'import_orders',
          'key': 'id',
          'select': 'id, created_at, supplier_id, price, quantity, total_amount, currency, account, iscancelled, product_id, warehouse_id, imei, note',
          'partnerField': 'supplier_id',
          'amountField': 'price',
          'dateField': 'created_at',
          'snapshotKey': 'id',
        },
      if (widget.permissions.contains('access_reimport_form'))
        {
          'table': 'reimport_orders',
          'key': 'ticket_id',
          'select': 'ticket_id, created_at, customer_id, price, quantity, currency, account, customer_price, transporter_price, transporter, iscancelled, product_id, warehouse_id, imei, note',
          'partnerField': 'customer_id',
          'amountField': 'price',
          'dateField': 'created_at',
          'snapshotKey': 'ticket_id',
        },
      if (widget.permissions.contains('access_sale_form'))
        {
          'table': 'sale_orders',
          'key': 'ticket_id',
          'select': 'ticket_id, created_at, customer_id, price, quantity, currency, account, customer_price, transporter_price, transporter, iscancelled, product_id, warehouse_id, imei, saleman, note, doanhso',
          'partnerField': 'customer_id',
          'amountField': 'price',
          'dateField': 'created_at',
          'snapshotKey': 'ticket_id',
        },
      if (widget.permissions.contains('access_return_form'))
        {
          'table': 'return_orders',
          'key': 'ticket_id',
          'select': 'ticket_id, created_at, supplier_id, price, quantity, total_amount, currency, account, iscancelled, product_id, warehouse_id, imei',
          'partnerField': 'supplier_id',
          'amountField': 'price',
          'dateField': 'created_at',
          'snapshotKey': 'ticket_id',
        },
      if (hasTransportPermission)
        {
          'table': 'transporter_orders',
          'key': 'id',
          'select': 'id, ticket_id, type, created_at, transporter, transport_fee, iscancelled, product_id, warehouse_id, imei, note',
          'partnerField': 'transporter',
          'amountField': 'transport_fee',
          'dateField': 'created_at',
          'snapshotKey': 'id',
        },
    ];

    for (final table in tables) {
      try {
        final tableName = table['table'] as String;
        final select = table['select'] as String;
        final partnerField = table['partnerField'] as String;
        final amountField = table['amountField'];
        final dateField = table['dateField'] as String;
        final keyField = table['key'] as String;

        // Thử SELECT với note, nếu lỗi thì SELECT lại không có note
        List<dynamic> response;
        String selectToUse = select;
        try {
          dynamic query = widget.tenantClient.from(tableName).select(selectToUse);
        query = query.eq('iscancelled', false);
        if (dateFrom != null) {
          query = query.gte(dateField, dateFrom!.toIso8601String());
        }
        if (dateTo != null) {
          query = query.lte(dateField, dateTo!.toIso8601String());
        }
        query = query.order(dateField, ascending: false);

        if (paginated && selectedFilterTypes.contains('all') && dateFrom == null && dateTo == null) {
          final start = currentPage * pageSize;
          final end = start + pageSize - 1;
          response = await query.range(start, end);
          developer.log('fetchTickets: Fetched ${response.length} from $tableName (paginated)');
        } else {
          response = await query;
          developer.log('fetchTickets: Fetched ${response.length} from $tableName');
          }
        } catch (e) {
          // Nếu lỗi (có thể do cột note không tồn tại), thử lại không có note
          developer.log('fetchTickets: Error with note column for $tableName, retrying without note: $e');
          // Loại bỏ note khỏi SELECT statement (xử lý các trường hợp: note ở đầu, giữa, cuối)
          final selectParts = select.split(',').map((s) => s.trim()).where((s) => s != 'note').toList();
          selectToUse = selectParts.join(', ');
          dynamic query = widget.tenantClient.from(tableName).select(selectToUse);
          query = query.eq('iscancelled', false);
          if (dateFrom != null) {
            query = query.gte(dateField, dateFrom!.toIso8601String());
          }
          if (dateTo != null) {
            query = query.lte(dateField, dateTo!.toIso8601String());
          }
          query = query.order(dateField, ascending: false);

          if (paginated && selectedFilterTypes.contains('all') && dateFrom == null && dateTo == null) {
            final start = currentPage * pageSize;
            final end = start + pageSize - 1;
            response = await query.range(start, end);
            developer.log('fetchTickets: Fetched ${response.length} from $tableName without note (paginated)');
          } else {
            response = await query;
            developer.log('fetchTickets: Fetched ${response.length} from $tableName without note');
          }
        }

        final groupedTickets = <String, Map<String, dynamic>>{};
        for (var tx in response) {
          String ticketKey;
          String ticketKeyField;
          if (tableName == 'transporter_orders' && tx['type'] == 'nhập kho vận chuyển' && tx['ticket_id'] != null) {
            ticketKey = tx['ticket_id'].toString();
            ticketKeyField = 'ticket_id';
          } else {
            ticketKey = tx[keyField]?.toString() ?? '';
            ticketKeyField = keyField;
            if (ticketKey.isEmpty) {
              developer.log('fetchTickets: Invalid ticket key for $tableName, skipping');
              continue;
            }
          }

          String productName = 'N/A';
          String warehouseName = 'N/A';
          String imeiList = tx['imei']?.toString() ?? 'N/A';

          final productId = tx['product_id']?.toString();
          final warehouseId = tx['warehouse_id']?.toString();

          if (productId != null && productMap.containsKey(productId)) {
            productName = productMap[productId]!;
          }
          if (warehouseId != null && warehouseMap.containsKey(warehouseId)) {
            warehouseName = warehouseMap[warehouseId]!;
          }

          num quantity = 0;
          if (tableName != 'transporter_orders') {
            try {
              quantity = num.tryParse(tx['quantity']?.toString() ?? '0') ?? 0;
            } catch (e) {
              developer.log('fetchTickets: Error parsing quantity for $tableName, record: ${tx['id'] ?? tx['ticket_id']}, quantity: ${tx['quantity']}, error: $e');
            }
          } else {
            quantity = imeiList != 'N/A' ? imeiList.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).length : 0;
          }

          if (!groupedTickets.containsKey(ticketKey)) {
            // Lấy tên đối tác - đặc biệt xử lý cho các loại phiếu
            String partnerName;
            String? partnerId;
            String? partnerType;
            
            if (tableName == 'financial_orders') {
              partnerId = tx['partner_id']?.toString();
              partnerType = tx['partner_type']?.toString();
              partnerName = _getPartnerName(
                partnerId,
                partnerType,
                tx[partnerField]?.toString(),
              );
            } else if (tableName == 'import_orders' || tableName == 'return_orders') {
              // Nhà cung cấp - dùng supplier_id
              partnerId = tx[partnerField]?.toString();
              partnerType = 'suppliers';
              partnerName = partnerId != null ? (supplierMap[partnerId] ?? 'N/A') : 'N/A';
            } else if (tableName == 'sale_orders' || tableName == 'reimport_orders') {
              // Khách hàng - dùng customer_id
              partnerId = tx[partnerField]?.toString();
              partnerType = 'customers';
              partnerName = partnerId != null ? (customerMap[partnerId] ?? 'N/A') : 'N/A';
            } else if (tableName == 'fix_send_orders' || tableName == 'fix_receive_orders') {
              // Đơn vị fix - dùng fix_unit_id nếu có, nếu không dùng fixer (tên)
              final fixUnitId = tx['fix_unit_id']?.toString();
              if (fixUnitId != null) {
                partnerId = fixUnitId;
                partnerType = 'fix_units';
                partnerName = fixerMap[fixUnitId] ?? 'N/A';
              } else {
                partnerName = tx[partnerField]?.toString() ?? 'N/A';
                partnerType = 'fix_units';
              }
            } else if (tableName == 'transporter_orders') {
              // Đơn vị vận chuyển - dùng transporter (tên)
              partnerName = tx[partnerField]?.toString() ?? 'N/A';
              partnerType = 'transporters';
            } else {
              partnerName = tx[partnerField]?.toString() ?? 'N/A';
            }
            
            groupedTickets[ticketKey] = {
              'table': tableName,
              'key': ticketKeyField,
              'id': ticketKey,
              'type': tableName == 'financial_orders' || tableName == 'transporter_orders' ? (tx['type'] ?? tableName) : tableName,
              'partner': partnerName,
              'partner_id': partnerId,
              'partner_type': partnerType,
              'date': tx[dateField]?.toString() ?? '',
              'snapshot_data': null,
              'snapshot_created_at': null,
              'items': [],
              'total_quantity': 0,
              'total_amount': 0,
              'currency': 'VND',
              'product_name': productName,
              'warehouse_name': warehouseName,
              'imei': tableName == 'transporter_orders' || tableName == 'fix_send_orders' || tableName == 'fix_receive_orders' || tableName == 'sale_orders' || tableName == 'return_orders' || tableName == 'reimport_orders' || tableName == 'import_orders' ? '' : null,
              'note': tx['note']?.toString(),
            };
          }

          // Lấy tên đối tác cho item - đặc biệt xử lý cho các loại phiếu
          String itemPartnerName;
          String? itemPartnerId;
          String? itemPartnerType;
          
          if (tableName == 'financial_orders') {
            itemPartnerId = tx['partner_id']?.toString();
            itemPartnerType = tx['partner_type']?.toString();
            itemPartnerName = _getPartnerName(
              itemPartnerId,
              itemPartnerType,
              tx[partnerField]?.toString(),
            );
          } else if (tableName == 'import_orders' || tableName == 'return_orders') {
            // Nhà cung cấp - dùng supplier_id
            itemPartnerId = tx[partnerField]?.toString();
            itemPartnerType = 'suppliers';
            itemPartnerName = itemPartnerId != null ? (supplierMap[itemPartnerId] ?? 'N/A') : 'N/A';
          } else if (tableName == 'sale_orders' || tableName == 'reimport_orders') {
            // Khách hàng - dùng customer_id
            itemPartnerId = tx[partnerField]?.toString();
            itemPartnerType = 'customers';
            itemPartnerName = itemPartnerId != null ? (customerMap[itemPartnerId] ?? 'N/A') : 'N/A';
          } else if (tableName == 'fix_send_orders' || tableName == 'fix_receive_orders') {
            // Đơn vị fix - dùng fix_unit_id nếu có, nếu không dùng fixer (tên)
            final fixUnitId = tx['fix_unit_id']?.toString();
            if (fixUnitId != null) {
              itemPartnerId = fixUnitId;
              itemPartnerType = 'fix_units';
              itemPartnerName = fixerMap[fixUnitId] ?? 'N/A';
            } else {
              itemPartnerName = tx[partnerField]?.toString() ?? 'N/A';
              itemPartnerType = 'fix_units';
            }
          } else if (tableName == 'transporter_orders') {
            // Đơn vị vận chuyển - dùng transporter (tên)
            itemPartnerName = tx[partnerField]?.toString() ?? 'N/A';
            itemPartnerType = 'transporters';
          } else {
            itemPartnerName = tx[partnerField]?.toString() ?? 'N/A';
          }
          
          final item = {
            'amount': amountField != null ? num.tryParse(tx[amountField]?.toString() ?? '0') : null,
            'currency': tx['currency']?.toString() ?? 'VND',
            'quantity': quantity,
            'total_amount': tx['total_amount'],
            'account': tx['account']?.toString(),
            'from_amount': tx['from_amount'],
            'from_currency': tx['from_currency'],
            'from_account': tx['from_account']?.toString(),
            'to_amount': tx['to_amount'],
            'to_currency': tx['to_currency'],
            'to_account': tx['to_account']?.toString(),
            'customer_price': tx['customer_price'],
            'transporter_price': tx['transporter_price'],
            'transporter': tx['transporter'],
            'product_id': tx['product_id'],
            'warehouse_id': tx['warehouse_id'],
            'imei': tx['imei'],
            'product_name': productName,
            'warehouse_name': warehouseName,
            'partner': itemPartnerName, // Lưu partner cho từng item
            'partner_id': itemPartnerId, // Lưu partner_id cho từng item
            'partner_type': itemPartnerType, // Lưu partner_type cho từng item
            'saleman': tx['saleman']?.toString(), // Lưu nhân viên bán
            'note': tx['note']?.toString(), // Lưu ghi chú
            'doanhso': tx['doanhso'], // Lưu doanh số nhân viên
          };

          final ticket = groupedTickets[ticketKey]!;
          (ticket['items'] as List<dynamic>).add(item);
          ticket['total_quantity'] = (ticket['total_quantity'] as num) + quantity;

          if (tableName == 'transporter_orders' && tx['type'] == 'nhập kho vận chuyển') {
            final amount = num.tryParse(tx['transport_fee']?.toString() ?? '0') ?? 0;
            ticket['total_amount'] = (ticket['total_amount'] as num) + amount;
            developer.log('fetchTickets: Added transport_fee=$amount to total_amount=${ticket['total_amount']} for ticket_id=$ticketKey');
          } else if (tableName != 'fix_send_orders') {
            final amount = tx['total_amount'] ?? (item['amount'] ?? 0) * (quantity > 0 ? quantity : 1);
            ticket['total_amount'] = (ticket['total_amount'] as num) + amount;
            ticket['currency'] = tx['currency']?.toString() ?? ticket['currency'];
          }

          if ((tableName == 'transporter_orders' || tableName == 'fix_send_orders' || tableName == 'fix_receive_orders' || tableName == 'sale_orders' || tableName == 'return_orders' || tableName == 'reimport_orders' || tableName == 'import_orders') &&
              item['imei'] != null) {
            ticket['imei'] = ticket['imei']!.isEmpty ? item['imei'] : '${ticket['imei']}, ${item['imei']}';
          }

          ticketIds.add(ticketKey);
        }

        allTickets.addAll(groupedTickets.values);
      } catch (e) {
        developer.log('fetchTickets: Error fetching ${table['table']}: $e');
      }
    }

    if (ticketIds.isNotEmpty) {
      try {
        final snapshotResponse = await widget.tenantClient
            .from('snapshots')
            .select('ticket_id, ticket_table, snapshot_data, created_at')
            .inFilter('ticket_id', ticketIds.toList());

        final snapshotMap = <String, Map<String, dynamic>>{};
        for (var snapshot in snapshotResponse) {
          final key = '${snapshot['ticket_table']}:${snapshot['ticket_id']}';
          snapshotMap[key] = snapshot;
        }

        for (var ticket in allTickets) {
          final snapshot = snapshotMap['${ticket['table']}:${ticket['id']}'];
          ticket['snapshot_data'] = snapshot?['snapshot_data'] ?? {};
          ticket['snapshot_created_at'] = snapshot?['created_at'];
        }
      } catch (e) {
        developer.log('fetchTickets: Error fetching snapshots: $e');
        for (var ticket in allTickets) {
          ticket['snapshot_data'] = {};
        }
      }
    }

    allTickets = allTickets.where((ticket) {
      if (selectedFilterTypes.contains('all')) return true;
      return selectedFilterTypes.contains(ticket['type']);
    }).toList();

    allTickets.sort((a, b) {
      final dateA = DateTime.tryParse(a['date']?.toString() ?? '1900-01-01') ?? DateTime(1900);
      final dateB = DateTime.tryParse(b['date']?.toString() ?? '1900-01-01') ?? DateTime(1900);
      return dateB.compareTo(dateA);
    });

    return allTickets;
  }

  Widget _buildDetailRow(String label, String value, {String? partnerId, String? partnerType, BuildContext? dialogContext}) {
    final isPartner = label == 'Đối tác' || label == '  Đối tác';
    final isTransporter = label == 'Đơn vị vận chuyển';
    final canViewTransporter = isTransporter && widget.permissions.contains('access_transporters_screen');
    
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label: ',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          Expanded(
            child: (isPartner && partnerType != null && value.isNotEmpty && value != 'N/A') || 
                   (canViewTransporter && value.isNotEmpty && value != 'N/A')
                ? InkWell(
                    onTap: () {
                      if (isTransporter && canViewTransporter) {
                        // Mở trực tiếp chi tiết đơn vị vận chuyển
                        _openTransporterDetails(value, dialogContext ?? context);
                      } else if (isPartner) {
                        // Hiển thị menu với 2 tùy chọn cho đối tác
                        showModalBottomSheet(
                          context: dialogContext ?? context,
                          builder: (context) => SafeArea(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ListTile(
                                  leading: const Icon(Icons.copy),
                                  title: const Text('Sao chép'),
                                  onTap: () {
                                    Clipboard.setData(ClipboardData(text: value));
                                    Navigator.pop(context);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('Đã sao chép vào clipboard'),
                                        duration: Duration(seconds: 1),
                                      ),
                                    );
                                  },
                                ),
                                ListTile(
                                  leading: const Icon(Icons.visibility),
                                  title: const Text('Xem đối tác'),
                                  onTap: () {
                                    Navigator.pop(context);
                                    if (partnerType == 'customers') {
                                      _openCustomerDetails(value, partnerId, dialogContext ?? context);
                                    } else if (partnerType == 'suppliers') {
                                      _openSupplierDetails(partnerId, dialogContext ?? context);
                                    } else if (partnerType == 'transporters') {
                                      _openTransporterDetails(value, dialogContext ?? context);
                                    } else if (partnerType == 'fix_units') {
                                      _openFixerDetails(value, partnerId, dialogContext ?? context);
                                    }
                                  },
                                ),
                              ],
                            ),
                          ),
                        );
                      }
                    },
                    child: Text(
                      value,
                      style: const TextStyle(
                        fontWeight: FontWeight.normal,
                        color: Colors.blue,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  )
                : GestureDetector(
                    onLongPress: () {
                      if (value.isNotEmpty) {
                        Clipboard.setData(ClipboardData(text: value));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Đã sao chép vào clipboard'),
                            duration: Duration(seconds: 1),
                          ),
                        );
                      }
                    },
                    child: SelectableText(
                      value,
                      style: const TextStyle(fontWeight: FontWeight.normal),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _openCustomerDetails(String? customerName, String? customerId, BuildContext dialogContext) async {
    if (customerName == null || customerName.isEmpty || customerName == 'N/A') return;
    
    // Kiểm tra quyền truy cập màn hình khách hàng
    if (!widget.permissions.contains('access_customers_screen')) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bạn không có quyền truy cập màn hình khách hàng')),
        );
      }
      return;
    }
    
    try {
      final response = await widget.tenantClient
          .from('customers')
          .select('id, name, phone, address, social_link, debt_vnd, debt_cny, debt_usd')
          .eq(customerId != null ? 'id' : 'name', customerId ?? customerName)
          .maybeSingle();
      
      if (response != null && mounted) {
        Navigator.of(dialogContext, rootNavigator: true).pop();
        await Future.delayed(const Duration(milliseconds: 100));
        
        if (!mounted) return;
        
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (newContext) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (newContext.mounted) {
                  showDialog(
                    context: newContext,
                    builder: (context) => CustomerDetailsDialog(
                      customer: response,
                      tenantClient: widget.tenantClient,
                    ),
                  );
                }
              });
              
              return CustomersScreen(
                permissions: widget.permissions,
                tenantClient: widget.tenantClient,
              );
            },
          ),
        );
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Không tìm thấy thông tin khách hàng')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không thể mở chi tiết khách hàng: $e')),
        );
      }
    }
  }

  Future<void> _openSupplierDetails(String? supplierId, BuildContext dialogContext) async {
    if (supplierId == null || supplierId.isEmpty) return;
    
    // Kiểm tra quyền truy cập màn hình nhà cung cấp
    if (!widget.permissions.contains('access_suppliers_screen')) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bạn không có quyền truy cập màn hình nhà cung cấp')),
        );
      }
      return;
    }
    
    try {
      final response = await widget.tenantClient
          .from('suppliers')
          .select('id, name, phone, address, social_link, debt_vnd, debt_cny, debt_usd')
          .eq('id', supplierId)
          .maybeSingle();
      
      if (response != null && mounted) {
        Navigator.of(dialogContext, rootNavigator: true).pop();
        await Future.delayed(const Duration(milliseconds: 100));
        
        if (!mounted) return;
        
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (newContext) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (newContext.mounted) {
                  showDialog(
                    context: newContext,
                    builder: (context) => SupplierDetailsDialog(
                      supplier: response,
                      tenantClient: widget.tenantClient,
                    ),
                  );
                }
              });
              
              return SuppliersScreen(
                permissions: widget.permissions,
                tenantClient: widget.tenantClient,
              );
            },
          ),
        );
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Không tìm thấy thông tin nhà cung cấp')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không thể mở chi tiết nhà cung cấp: $e')),
        );
      }
    }
  }

  Future<void> _openTransporterDetails(String? transporterName, BuildContext dialogContext) async {
    if (transporterName == null || transporterName.isEmpty || transporterName == 'N/A') return;
    
    // Kiểm tra quyền truy cập màn hình đơn vị vận chuyển
    if (!widget.permissions.contains('access_transporters_screen')) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bạn không có quyền truy cập màn hình đơn vị vận chuyển')),
        );
      }
      return;
    }
    
    try {
      final response = await widget.tenantClient
          .from('transporters')
          .select('id, name, phone, address, debt')
          .eq('name', transporterName)
          .maybeSingle();
      
      if (response != null && mounted) {
        Navigator.of(dialogContext, rootNavigator: true).pop();
        await Future.delayed(const Duration(milliseconds: 100));
        
        if (!mounted) return;
        
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (newContext) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (newContext.mounted) {
                  showDialog(
                    context: newContext,
                    builder: (context) => TransporterDetailsDialog(
                      transporter: response,
                      tenantClient: widget.tenantClient,
                    ),
                  );
                }
              });
              
              return TransportersScreen(
                permissions: widget.permissions,
                tenantClient: widget.tenantClient,
              );
            },
          ),
        );
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Không tìm thấy thông tin đơn vị vận chuyển')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không thể mở chi tiết đơn vị vận chuyển: $e')),
        );
      }
    }
  }

  Future<void> _openFixerDetails(String? fixerName, String? fixerId, BuildContext dialogContext) async {
    if (fixerName == null || fixerName.isEmpty || fixerName == 'N/A') return;
    
    // Kiểm tra quyền truy cập màn hình đơn vị fix lỗi
    if (!widget.permissions.contains('access_fixers_screen')) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bạn không có quyền truy cập màn hình đơn vị fix lỗi')),
        );
      }
      return;
    }
    
    try {
      final response = await widget.tenantClient
          .from('fix_units')
          .select('id, name, phone, address, social_link, debt_vnd, debt_cny, debt_usd')
          .eq(fixerId != null ? 'id' : 'name', fixerId ?? fixerName)
          .maybeSingle();
      
      if (response != null && mounted) {
        Navigator.of(dialogContext, rootNavigator: true).pop();
        await Future.delayed(const Duration(milliseconds: 100));
        
        if (!mounted) return;
        
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (newContext) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (newContext.mounted) {
                  showDialog(
                    context: newContext,
                    builder: (context) => FixerDetailsDialog(
                      fixer: response,
                      tenantClient: widget.tenantClient,
                    ),
                  );
                }
              });
              
              return FixersScreen(
                permissions: widget.permissions,
                tenantClient: widget.tenantClient,
              );
            },
          ),
        );
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Không tìm thấy thông tin đơn vị fix lỗi')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không thể mở chi tiết đơn vị fix lỗi: $e')),
        );
      }
    }
  }

  void _showTransactionDetails(Map<String, dynamic> ticket) {
    String? saleman;
    num? totalDoanhso;
    if (ticket['table'] == 'sale_orders' && ticket['items'] is List<dynamic>) {
      final items = ticket['items'] as List<dynamic>;
      if (items.isNotEmpty) {
        final salemanSet = items
            .map((item) => item['saleman'])
            .whereType<String>()
            .where((s) => s.isNotEmpty)
            .toSet();
        saleman = salemanSet.isNotEmpty ? salemanSet.join(', ') : null;
        
        // Tính tổng doanh số của phiếu
        totalDoanhso = items.fold<num>(
          0,
          (sum, item) {
            final doanhso = item['doanhso'];
            if (doanhso != null) {
              final doanhsoValue = num.tryParse(doanhso.toString()) ?? 0;
              return sum + doanhsoValue;
            }
            return sum;
          },
        );
      }
    }

    final isFinancialTicket = ticket['table'] == 'financial_orders';
    final financialType = ticket['type'] as String?;
    final isTransferFund = financialType == 'transfer_fund';
    // Các loại phiếu không có đối tác: transfer_fund, cost, exchange, income_other
    final hasNoPartner = isTransferFund || 
        financialType == 'cost' || 
        financialType == 'exchange' || 
        financialType == 'income_other';
    
    // Kiểm tra nếu có nhiều đối tác khác nhau trong ticket
    final hasMultiplePartners = ticket['table'] == 'return_orders' || ticket['table'] == 'reimport_orders';
    final uniquePartners = hasMultiplePartners 
        ? (ticket['items'] as List).map((item) => item['partner'] as String? ?? 'N/A').toSet()
        : <String>{};
    final displayPartner = hasMultiplePartners && uniquePartners.length > 1
        ? 'Nhiều đối tác (${uniquePartners.length})'
        : ticket['partner'];
    
    // Tính tổng tiền cọc và tiền COD cho Ship COD orders và COD hoàn (tổng của toàn phiếu)
    num totalCustomerPrice = 0;
    num totalTransporterPrice = 0;
    String? transporterName;
    final isShipCod = ticket['table'] == 'sale_orders' && 
        ticket['items'] is List<dynamic> &&
        ticket['items'].isNotEmpty &&
        ticket['items'][0]['account']?.toString() == 'Ship COD';
    final isCodHoan = ticket['table'] == 'reimport_orders' && 
        ticket['items'] is List<dynamic> &&
        ticket['items'].isNotEmpty &&
        ticket['items'][0]['account']?.toString() == 'Cod hoàn';
    
    if (isShipCod || isCodHoan) {
      for (var item in ticket['items'] as List) {
        if (item['customer_price'] != null) {
          final price = num.tryParse(item['customer_price'].toString()) ?? 0;
          totalCustomerPrice += price;
        }
        if (item['transporter_price'] != null) {
          final price = num.tryParse(item['transporter_price'].toString()) ?? 0;
          totalTransporterPrice += price;
        }
        if (transporterName == null && item['transporter'] != null && item['transporter'].toString().isNotEmpty) {
          transporterName = item['transporter'].toString();
        }
      }
    }

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Chi tiết phiếu', style: TextStyle(fontWeight: FontWeight.bold)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildDetailRow('Loại Phiếu', _getDisplayType(
                  ticket['type'], 
                  ticket['table'],
                  account: ticket['items'] is List && (ticket['items'] as List).isNotEmpty 
                      ? (ticket['items'][0]['account']?.toString())
                      : null,
                )),
                if (!hasNoPartner)
                _buildDetailRow(
                  'Đối tác',
                  displayPartner ?? 'N/A',
                  partnerId: ticket['partner_id']?.toString(),
                  partnerType: ticket['partner_type']?.toString(),
                  dialogContext: context,
                ),
                if (isFinancialTicket && financialType == 'exchange') ...[
                  _buildDetailRow('Số Tiền Đổi', '${_formatNumber(ticket['items'][0]['from_amount'])} ${ticket['items'][0]['from_currency']}'),
                  if (ticket['items'][0]['to_amount'] != null && ticket['items'][0]['to_currency'] != null)
                    _buildDetailRow('Số Tiền Nhận', '${_formatNumber(ticket['items'][0]['to_amount'])} ${ticket['items'][0]['to_currency']}'),
                ] else if (isFinancialTicket && isTransferFund)
                  _buildDetailRow('Số Tiền', '${_formatNumber(ticket['items'][0]['from_amount'])} ${ticket['items'][0]['from_currency'] ?? 'VND'}')
                else if (isFinancialTicket)
                  _buildDetailRow('Số Tiền', '${_formatNumber(ticket['items'][0]['amount'])} ${ticket['items'][0]['currency'] ?? 'VND'}')
                else
                  _buildDetailRow('Tổng Tiền', '${_formatNumber(ticket['total_amount'])} ${ticket['currency'] ?? 'VND'}'),
                _buildDetailRow('Thời gian', _formatDateTime(ticket['date'])),
                if (!isFinancialTicket) ...[
                  _buildDetailRow('Số Lượng', ticket['table'] == 'transporter_orders' ? ticket['total_quantity'].toString() : _formatNumber(ticket['total_quantity'])),
                ],
                // Hiển thị tài khoản cho financial_orders (payment, receive, cost, income_other) nhưng không hiển thị cho exchange và transfer_fund (vì có to_account riêng)
                // Và hiển thị cho non-financial tickets nhưng không hiển thị nếu là Ship COD hoặc Cod hoàn (vì thừa)
                if (ticket['items'][0]['account'] != null && 
                    ((isFinancialTicket && financialType != 'exchange' && financialType != 'transfer_fund') ||
                     (!isFinancialTicket && 
                      ticket['items'][0]['account'].toString() != 'Ship COD' &&
                      ticket['items'][0]['account'].toString() != 'Cod hoàn')))
                  _buildDetailRow('Tài Khoản', ticket['items'][0]['account'].toString()),
                // Hiển thị tài khoản chuyển và tài khoản nhận cho transfer_fund
                if (isTransferFund) ...[
                  if (ticket['items'][0]['from_account'] != null && ticket['items'][0]['from_account'].toString().isNotEmpty)
                    _buildDetailRow('Tài khoản chuyển', ticket['items'][0]['from_account'].toString()),
                  if (ticket['items'][0]['to_account'] != null && ticket['items'][0]['to_account'].toString().isNotEmpty)
                    _buildDetailRow('Tài khoản nhận', ticket['items'][0]['to_account'].toString()),
                ],
                // Hiển thị thông tin Ship COD: tiền cọc, tiền COD, đơn vị vận chuyển (tổng của toàn phiếu)
                if (isShipCod) ...[
                  if (totalCustomerPrice > 0)
                    _buildDetailRow('Tiền cọc', '${_formatNumber(totalCustomerPrice)} ${ticket['currency'] ?? 'VND'}'),
                  if (totalTransporterPrice > 0)
                    _buildDetailRow('Tiền COD', '${_formatNumber(totalTransporterPrice)} ${ticket['currency'] ?? 'VND'}'),
                  if (transporterName != null && transporterName.isNotEmpty)
                    _buildDetailRow(
                      'Đơn vị vận chuyển', 
                      transporterName,
                      partnerType: 'transporters', // Thêm partnerType để có thể click
                      dialogContext: context,
                    ),
                ],
                // Hiển thị thông tin COD hoàn: tiền cọc, tiền COD (tổng của toàn phiếu)
                if (isCodHoan) ...[
                  if (totalCustomerPrice > 0)
                    _buildDetailRow('Tiền cọc', '${_formatNumber(totalCustomerPrice)} ${ticket['currency'] ?? 'VND'}'),
                  if (totalTransporterPrice > 0)
                    _buildDetailRow('Tiền COD', '${_formatNumber(totalTransporterPrice)} ${ticket['currency'] ?? 'VND'}'),
                ],
                if (saleman != null) _buildDetailRow('Nhân viên bán', saleman),
                if (totalDoanhso != null && totalDoanhso > 0)
                  _buildDetailRow('Doanh số nhân viên', _formatNumber(totalDoanhso)),
                if (!isFinancialTicket) ...[
                  // Gom nhóm sản phẩm cùng loại để hiển thị gọn
                  ..._groupProductsByName(ticket['items'] as List<dynamic>).map<Widget>((group) {
                    final productName = group['product_name'] as String;
                    final totalQuantity = group['total_quantity'] as num;
                    if (productName != 'N/A' && totalQuantity > 0) {
                      return _buildDetailRow('Sản phẩm', '$productName x${totalQuantity.toInt()}');
                    }
                    return const SizedBox.shrink();
                  }).toList(),
                ],
                if (ticket['warehouse_name'] != null && ticket['warehouse_name'] != 'N/A')
                  _buildDetailRow('Kho', ticket['warehouse_name']),
                if (ticket['note'] != null && ticket['note'].toString().isNotEmpty)
                  _buildDetailRow('Ghi chú', ticket['note'].toString()),
                if (!isFinancialTicket) ...[
                  const SizedBox(height: 8),
                  const Text('Chi tiết sản phẩm:', style: TextStyle(fontWeight: FontWeight.bold)),
                  ...ticket['items'].asMap().entries.map((entry) {
                    final item = entry.value;
                    final currentTable = ticket['table'] as String;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (ticket['items'].length > 1) 
                          Padding(
                            padding: const EdgeInsets.only(top: 8.0),
                            child: Text('Sản phẩm ${entry.key + 1}:', style: const TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        if (hasMultiplePartners && item['partner'] != null)
                          _buildDetailRow(
                            '  Đối tác',
                            item['partner'].toString(),
                            partnerId: item['partner_id']?.toString(),
                            partnerType: item['partner_type']?.toString(),
                            dialogContext: context,
                          ),
                        if (currentTable != 'transporter_orders' && item['quantity'] != null)
                          _buildDetailRow('  Số Lượng', item['quantity'].toString()),
                        if (currentTable == 'transporter_orders' && item['imei'] != null)
                          _buildDetailRow('  Số Lượng', (item['imei'] as String).split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).length.toString()),
                        if (item['amount'] != null) 
                          _buildDetailRow('  Giá', '${_formatNumber(item['amount'])} ${item['currency']}'),
                        if (item['total_amount'] != null) 
                          _buildDetailRow('  Tổng', '${_formatNumber(item['total_amount'])} ${item['currency']}'),
                        if (item['product_name'] != null && item['product_name'] != 'N/A')
                          _buildDetailRow('  Sản phẩm', item['product_name'].toString()),
                        if (item['warehouse_name'] != null && item['warehouse_name'] != 'N/A')
                          _buildDetailRow('  Kho', item['warehouse_name'].toString()),
                        if (item['imei'] != null) 
                          _buildDetailRow('  IMEI', item['imei'].toString()),
                        if (item['doanhso'] != null && item['doanhso'] != 0)
                          _buildDetailRow('  Doanh số', _formatNumber(item['doanhso'])),
                        if (item['note'] != null && item['note'].toString().isNotEmpty)
                          _buildDetailRow('  Ghi chú', item['note'].toString()),
                      ],
                    );
                  }),
                ],
              ],
            ),
          ),
          actions: [
            if (widget.permissions.contains('cancel_transaction'))
              TextButton(
                onPressed: () => _confirmCancelTicket(ticket),
                child: const Text('Hủy Phiếu', style: TextStyle(color: Colors.red)),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Đóng'),
            ),
          ],
        );
      },
    );
  }

  Future<bool> _isLatestTicket(Map<String, dynamic> ticket) async {
    final table = ticket['table'] as String;
    final ticketId = ticket['id'] as String;
    final keyField = ticket['key'] as String;

    try {
      developer.log('isLatestTicket: Checking ticket_id: $ticketId in table: $table, keyField: $keyField');

      // Kiểm tra snapshot tồn tại cho phiếu cần hủy
      final snapshot = await widget.tenantClient
          .from('snapshots')
          .select('ticket_id, ticket_table, created_at')
          .eq('ticket_id', ticketId)
          .eq('ticket_table', table)
          .limit(1)
          .maybeSingle();

      if (snapshot == null) {
        developer.log('isLatestTicket: No snapshot found for ticket_id: $ticketId in table: $table');
        return false;
      }

      // Lấy snapshot mới nhất từ bảng snapshots
      final latestSnapshot = await widget.tenantClient
          .from('snapshots')
          .select('ticket_id, ticket_table, created_at')
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();

      if (latestSnapshot == null) {
        developer.log('isLatestTicket: No snapshots found in snapshots table');
        return false;
      }

      final latestTicketId = latestSnapshot['ticket_id']?.toString();
      final latestTicketTable = latestSnapshot['ticket_table']?.toString();
      final latestSnapshotCreatedAt = latestSnapshot['created_at']?.toString();

      developer.log('isLatestTicket: Latest snapshot: ticket_id=$latestTicketId, table=$latestTicketTable, created_at=$latestSnapshotCreatedAt');

      // So sánh snapshot của phiếu cần hủy với snapshot mới nhất
      if (latestTicketId != ticketId || latestTicketTable != table) {
        developer.log('isLatestTicket: Ticket $ticketId in $table is not the latest. Latest is $latestTicketId in $latestTicketTable');
        return false;
      }

      // Kiểm tra phiếu có iscancelled = false
      final ticketRecord = await widget.tenantClient
          .from(table)
          .select(keyField)
          .eq(keyField, ticketId)
          .eq('iscancelled', false)
          .limit(1)
          .maybeSingle();

      if (ticketRecord == null) {
        developer.log('isLatestTicket: Ticket $ticketId in $table is already cancelled or does not exist');
        return false;
      }

      developer.log('isLatestTicket: Ticket $ticketId in $table is the latest with valid snapshot');
      return true;
    } catch (e) {
      developer.log('isLatestTicket: Error checking ticket_id: $ticketId in table: $table, error: $e');
      return false;
    }
  }

  Future<void> _confirmCancelTicket(Map<String, dynamic> ticket) async {
    final table = ticket['table'] as String;
    final ticketId = ticket['id'] as String;
    developer.log('confirmCancelTicket: Initiating for ticket_id: $ticketId, table: $table');

    // Kiểm tra snapshot
    if (ticket['snapshot_data'] == null || ticket['snapshot_data'].isEmpty) {
      developer.log('confirmCancelTicket: No snapshot data found for ticket_id: $ticketId');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Không thể hủy: Không tìm thấy snapshot')),
      );
      return;
    }
    developer.log('confirmCancelTicket: Snapshot data exists for ticket_id: $ticketId');

    // Kiểm tra phiếu mới nhất
    final isLatest = await _isLatestTicket(ticket);
    if (!isLatest) {
      developer.log('confirmCancelTicket: Ticket $ticketId is not the latest in $table');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Không thể hủy: Chỉ hủy được phiếu mới nhất chưa bị hủy')),
      );
      return;
    }
    developer.log('confirmCancelTicket: Ticket $ticketId is confirmed as the latest');

    // Hiển thị dialog xác nhận
    developer.log('confirmCancelTicket: Showing confirmation dialog for ticket_id: $ticketId');
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Xác nhận hủy phiếu'),
          content: const Text('Bạn có chắc muốn hủy phiếu này? Dữ liệu sẽ được khôi phục từ snapshot.'),
          actions: [
            TextButton(
              onPressed: () {
                developer.log('confirmCancelTicket: User cancelled for ticket_id: $ticketId');
                Navigator.pop(context);
              },
              child: const Text('Hủy bỏ'),
            ),
            TextButton(
              onPressed: () async {
                developer.log('confirmCancelTicket: User confirmed cancellation for ticket_id: $ticketId');
                try {
                  // Khôi phục snapshot (bao gồm cả doanhso từ sub_accounts nếu có trong snapshot)
                  developer.log('confirmCancelTicket: Restoring snapshot for ticket_id: $ticketId');
                  await _restoreFromSnapshot(ticket);

                  // Cập nhật iscancelled
                  final keyField = ticket['key'] as String;
                  developer.log('confirmCancelTicket: Updating iscancelled for ticket_id: $ticketId in $table, keyField: $keyField');
                  await widget.tenantClient
                      .from(table)
                      .update({'iscancelled': true})
                      .eq(keyField, ticketId);
                  developer.log('confirmCancelTicket: Updated iscancelled to true for ticket_id: $ticketId');

                  // Xóa snapshot
                  developer.log('confirmCancelTicket: Deleting snapshot for ticket_id: $ticketId');
                  await widget.tenantClient
                      .from('snapshots')
                      .delete()
                      .eq('ticket_id', ticketId)
                      .eq('ticket_table', table);
                  developer.log('confirmCancelTicket: Snapshot deleted for ticket_id: $ticketId');

                  Navigator.pop(context); // Đóng dialog xác nhận
                  Navigator.pop(context); // Đóng dialog chi tiết
                  setState(() {
                    _loadTickets();
                  });
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Hủy phiếu thành công')),
                  );
                  developer.log('confirmCancelTicket: Successfully cancelled ticket_id: $ticketId');
                } catch (e) {
                  developer.log('confirmCancelTicket: Error cancelling ticket_id: $ticketId, error: $e');
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Lỗi khi hủy phiếu: $e')),
                  );
                }
              },
              child: const Text('Xác nhận', style: TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    );
  }

  Future<void> _restoreFromSnapshot(Map<String, dynamic> ticket) async {
    final snapshotData = ticket['snapshot_data'] as Map<String, dynamic>?;
    final table = ticket['table'] as String;
    final ticketId = ticket['id'] as String;

    developer.log('restoreSnapshot: Starting for ticket_id: $ticketId in table: $table');

    if (snapshotData == null) {
      developer.log('restoreSnapshot: Snapshot data is null for ticket_id: $ticketId');
      throw Exception('Snapshot data is null');
    }

    try {
      if (snapshotData['products'] != null) {
        final productsData = snapshotData['products'] as List<dynamic>;
        developer.log('restoreSnapshot: Restoring ${productsData.length} products');
        if (table == 'import_orders') {
          final orders = snapshotData['import_orders'] as List<dynamic>? ?? [];
          final imeiList = orders
              .expand((order) => (order['imei'] as String?)?.split(',').where((e) => e.trim().isNotEmpty) ?? [])
              .toList();
          developer.log('restoreSnapshot: Deleting ${imeiList.length} IMEIs');
          for (int i = 0; i < imeiList.length; i += 1000) {
            final batchImeis = imeiList.sublist(i, i + 1000 < imeiList.length ? i + 1000 : imeiList.length);
            developer.log('restoreSnapshot: Deleting batch of ${batchImeis.length} IMEIs');
            await widget.tenantClient.from('products').delete().inFilter('imei', batchImeis);
          }
        } else if (table == 'return_orders' || table == 'sale_orders' || table == 'fix_send_orders' || table == 'fix_receive_orders' || table == 'reimport_orders' || table == 'transporter_orders') {
          for (var product in productsData) {
            if (product['imei'] != null) {
              developer.log('restoreSnapshot: Updating product with IMEI: ${product['imei']}');
              await widget.tenantClient.from('products').update(product).eq('imei', product['imei']);
            } else if (product['id'] != null) {
              developer.log('restoreSnapshot: Updating product with ID: ${product['id']}');
              await widget.tenantClient.from('products').update(product).eq('id', product['id']);
            } else {
              developer.log('restoreSnapshot: Skipping product update: no IMEI or ID');
            }
          }
        }
      } else {
        developer.log('restoreSnapshot: No products data in snapshot');
      }

      if (snapshotData['suppliers'] != null) {
        final suppliersData = snapshotData['suppliers'];
        if (suppliersData is List) {
          // New format: List of suppliers
          developer.log('restoreSnapshot: Restoring ${suppliersData.length} suppliers');
          for (var supplierData in suppliersData) {
            final supplierId = supplierData['id']?.toString();
            final supplierName = supplierData['name'];
            developer.log('restoreSnapshot: Restoring supplier: $supplierName (id: $supplierId)');
            if (supplierId != null) {
              await widget.tenantClient.from('suppliers').update({
                'debt_vnd': supplierData['debt_vnd'] ?? 0,
                'debt_cny': supplierData['debt_cny'] ?? 0,
                'debt_usd': supplierData['debt_usd'] ?? 0,
              }).eq('id', supplierId);
            } else {
              // Fallback to name if id not available (for old snapshots)
              developer.log('restoreSnapshot: Warning - Using name fallback for supplier: $supplierName');
              await widget.tenantClient.from('suppliers').update({
                'debt_vnd': supplierData['debt_vnd'] ?? 0,
                'debt_cny': supplierData['debt_cny'] ?? 0,
                'debt_usd': supplierData['debt_usd'] ?? 0,
              }).eq('name', supplierName);
            }
          }
        } else {
          // Old format: Single supplier as Map (backward compatibility)
          final supplierData = suppliersData as Map<String, dynamic>;
          final supplierId = supplierData['id']?.toString();
          final supplierName = supplierData['name'];
          developer.log('restoreSnapshot: Restoring supplier: $supplierName (id: $supplierId)');
          if (supplierId != null) {
            await widget.tenantClient.from('suppliers').update({
              'debt_vnd': supplierData['debt_vnd'] ?? 0,
              'debt_cny': supplierData['debt_cny'] ?? 0,
              'debt_usd': supplierData['debt_usd'] ?? 0,
            }).eq('id', supplierId);
          } else {
            // Fallback to name if id not available (for old snapshots)
            developer.log('restoreSnapshot: Warning - Using name fallback for supplier: $supplierName');
            await widget.tenantClient.from('suppliers').update({
              'debt_vnd': supplierData['debt_vnd'] ?? 0,
              'debt_cny': supplierData['debt_cny'] ?? 0,
              'debt_usd': supplierData['debt_usd'] ?? 0,
            }).eq('name', supplierName);
          }
        }
      }

      if (snapshotData['customers'] != null) {
        final customersData = snapshotData['customers'] is List ? snapshotData['customers'] as List<dynamic> : [snapshotData['customers']];
        developer.log('restoreSnapshot: Restoring ${customersData.length} customers');
        for (var customerData in customersData) {
          final customerId = customerData['id']?.toString();
          final customerName = customerData['name'];
          developer.log('restoreSnapshot: Restoring customer: $customerName (id: $customerId)');
          if (customerId != null) {
            await widget.tenantClient.from('customers').update({
              'debt_vnd': customerData['debt_vnd'] ?? 0,
              'debt_cny': customerData['debt_cny'] ?? 0,
              'debt_usd': customerData['debt_usd'] ?? 0,
            }).eq('id', customerId);
          } else {
            // Fallback to name if id not available (for old snapshots)
            developer.log('restoreSnapshot: Warning - Using name fallback for customer: $customerName');
            await widget.tenantClient.from('customers').update({
              'debt_vnd': customerData['debt_vnd'] ?? 0,
              'debt_cny': customerData['debt_cny'] ?? 0,
              'debt_usd': customerData['debt_usd'] ?? 0,
            }).eq('name', customerName);
          }
        }
      }

      if (snapshotData['financial_accounts'] != null) {
        final accountData = snapshotData['financial_accounts'] as Map<String, dynamic>;
        if (accountData['from_account'] != null) {
          final fromAccountData = Map<String, dynamic>.from(accountData['from_account']);
          fromAccountData.remove('id');
          developer.log('restoreSnapshot: Restoring from_account: ${fromAccountData['name']}');
          await widget.tenantClient.from('financial_accounts').update(fromAccountData).eq('name', fromAccountData['name']);
        }
        if (accountData['to_account'] != null) {
          final toAccountData = Map<String, dynamic>.from(accountData['to_account']);
          toAccountData.remove('id');
          developer.log('restoreSnapshot: Restoring to_account: ${toAccountData['name']}');
          await widget.tenantClient.from('financial_accounts').update(toAccountData).eq('name', toAccountData['name']);
        } else if (accountData['name'] != null) {
          final singleAccountData = Map<String, dynamic>.from(accountData);
          singleAccountData.remove('id');
          developer.log('restoreSnapshot: Restoring single account: ${singleAccountData['name']}');
          await widget.tenantClient.from('financial_accounts').update(singleAccountData).eq('name', singleAccountData['name']);
        }
      }

      if (snapshotData['transporters'] != null) {
        final transportersData = snapshotData['transporters'] is List ? snapshotData['transporters'] as List<dynamic> : [snapshotData['transporters']];
        developer.log('restoreSnapshot: Restoring ${transportersData.length} transporters');
        for (var transporterData in transportersData) {
          developer.log('restoreSnapshot: Restoring transporter: ${transporterData['name']}, debt: ${transporterData['debt']}');
          await widget.tenantClient.from('transporters').update({
            'debt': transporterData['debt'] ?? 0,
          }).eq('name', transporterData['name']);
        }
      }

      if (snapshotData['fix_units'] != null) {
        final fixUnitsData = snapshotData['fix_units'] is List ? snapshotData['fix_units'] as List<dynamic> : [snapshotData['fix_units']];
        developer.log('restoreSnapshot: Restoring ${fixUnitsData.length} fix units');
        for (var fixUnitData in fixUnitsData) {
          developer.log('restoreSnapshot: Restoring fix_unit: ${fixUnitData['name']}');
          // Use id if available, otherwise fallback to name
          if (fixUnitData['id'] != null) {
            await widget.tenantClient.from('fix_units').update(fixUnitData).eq('id', fixUnitData['id']);
          } else {
            await widget.tenantClient.from('fix_units').update(fixUnitData).eq('name', fixUnitData['name']);
          }
        }
      }

      // ✅ Khôi phục doanhso từ sub_accounts snapshot (cho sale_orders và reimport_orders)
      if (snapshotData['sub_accounts'] != null && (table == 'sale_orders' || table == 'reimport_orders')) {
        final subAccountData = snapshotData['sub_accounts'];
        
        // Xử lý cả Map (1 nhân viên) và List (nhiều nhân viên)
        if (subAccountData is Map<String, dynamic>) {
          // Trường hợp 1 nhân viên
          final username = subAccountData['username']?.toString();
          final doanhso = subAccountData['doanhso'];
          
          if (username != null && username.isNotEmpty) {
            try {
              developer.log('restoreSnapshot: Restoring sub_account doanhso for username: $username, doanhso: $doanhso');
              
              // Parse doanhso - có thể là int hoặc double
              final doanhsoValue = doanhso is int 
                  ? doanhso
                  : doanhso is double
                      ? doanhso.round()
                      : int.tryParse(doanhso?.toString() ?? '0') ?? 0;
              
              await widget.tenantClient
                  .from('sub_accounts')
                  .update({'doanhso': doanhsoValue})
                  .eq('username', username);
              
              developer.log('restoreSnapshot: ✅ Successfully restored sub_account doanhso for username: $username');
            } catch (e) {
              developer.log('restoreSnapshot: ❌ ERROR restoring sub_account doanhso: $e');
              // Không throw để tiếp tục restore các dữ liệu khác
            }
          }
        } else if (subAccountData is List) {
          // Trường hợp nhiều nhân viên (reimport_orders có thể có nhiều IMEI từ nhiều nhân viên)
          for (var accountData in subAccountData) {
            if (accountData is Map<String, dynamic>) {
              final username = accountData['username']?.toString();
              final doanhso = accountData['doanhso'];
              
              if (username != null && username.isNotEmpty) {
                try {
                  developer.log('restoreSnapshot: Restoring sub_account doanhso for username: $username, doanhso: $doanhso');
                  
                  // Parse doanhso - có thể là int hoặc double
                  final doanhsoValue = doanhso is int 
                      ? doanhso
                      : doanhso is double
                          ? doanhso.round()
                          : int.tryParse(doanhso?.toString() ?? '0') ?? 0;
                  
                  await widget.tenantClient
                      .from('sub_accounts')
                      .update({'doanhso': doanhsoValue})
                      .eq('username', username);
                  
                  developer.log('restoreSnapshot: ✅ Successfully restored sub_account doanhso for username: $username');
                } catch (e) {
                  developer.log('restoreSnapshot: ❌ ERROR restoring sub_account doanhso for username $username: $e');
                  // Không throw để tiếp tục restore các nhân viên khác
                }
              }
            }
          }
        }
      }

      // Xử lý restore reimport_orders riêng (bao gồm cả 3 cột mới: account, customer_price, transporter_price)
      if (table == 'reimport_orders' && snapshotData['reimport_orders'] != null) {
        // Xóa các records hiện tại với ticket_id này
        developer.log('restoreSnapshot: Deleting existing reimport_orders for ticket_id: $ticketId');
        await widget.tenantClient
            .from('reimport_orders')
            .delete()
            .eq('ticket_id', ticketId);
        
        // Restore lại từ snapshot (bao gồm cả 3 cột mới)
        final orders = snapshotData['reimport_orders'] as List<dynamic>;
        developer.log('restoreSnapshot: Restoring ${orders.length} reimport_orders for ticket_id: $ticketId');
        for (var order in orders) {
          // Đảm bảo restore đầy đủ các cột, bao gồm account, customer_price, transporter_price
          // Xử lý các giá trị null đúng cách
          final restoreData = <String, dynamic>{
            'ticket_id': order['ticket_id'],
            'customer_id': order['customer_id'],
            'product_id': order['product_id'],
            'warehouse_id': order['warehouse_id'],
            'imei': order['imei'],
            'quantity': order['quantity'] ?? 1,
            'price': order['price'],
            'currency': order['currency'],
            'note': order['note'],
            'created_at': order['created_at'] ?? DateTime.now().toIso8601String(),
          };
          
          // Chỉ thêm các cột mới nếu có trong snapshot (để tương thích với snapshot cũ)
          if (order.containsKey('account')) {
            restoreData['account'] = order['account']; // ✅ Restore account (có thể là "Cod hoàn")
          }
          if (order.containsKey('customer_price')) {
            restoreData['customer_price'] = order['customer_price']; // ✅ Restore customer_price
          }
          if (order.containsKey('transporter_price')) {
            restoreData['transporter_price'] = order['transporter_price']; // ✅ Restore transporter_price
          }
          
          await widget.tenantClient.from('reimport_orders').insert(restoreData);
        }
      }
      
      const validTables = [
        'financial_orders',
        'sale_orders',
        'import_orders',
        'return_orders',
        'fix_send_orders',
        'fix_receive_orders',
        'transporter_orders',
      ];
      for (var relatedTable in validTables) {
        if (snapshotData[relatedTable] != null && relatedTable != table) {
          final orders = snapshotData[relatedTable] as List<dynamic>;
          developer.log('restoreSnapshot: Restoring ${orders.length} orders in $relatedTable');
          for (var order in orders) {
            await widget.tenantClient.from(relatedTable).upsert(order);
          }
        }
      }

      developer.log('restoreSnapshot: Success for ticket_id: $ticketId in table: $table');
    } catch (e) {
      developer.log('restoreSnapshot: Error for ticket_id: $ticketId in table: $table, error: $e');
      throw Exception('Failed to restore snapshot: $e');
    }
  }

  Future<void> _exportToExcel() async {
    if (isExporting) return;

    setState(() => isExporting = true);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Đang xuất Excel...', textAlign: TextAlign.center),
          ],
        ),
      ),
    );

    try {
      // Kiểm tra và yêu cầu quyền lưu trữ (nếu cần) - Android 13+ không cần
      final hasPermission = await StorageHelper.requestStoragePermissionIfNeeded();
      if (!hasPermission) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cần quyền lưu trữ để xuất Excel')),
          );
          return;
      }

      List<Map<String, dynamic>> exportTickets = tickets;
      if (hasMoreData && selectedFilterTypes.contains('all') && dateFrom == null && dateTo == null) {
        exportTickets = await _fetchTickets(paginated: false);
      }

      if (exportTickets.isEmpty) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Không có phiếu để xuất')),
        );
        return;
      }

      final excelFile = excel.Excel.createExcel();
      excelFile.delete('Sheet1');
      final sheet = excelFile['LichSuPhieu'];

      final headerLabels = <String>[
        'Loại Phiếu',
        'Đối Tác',
        'Sản phẩm',
        'Kho',
        'IMEI',
        'Số Tiền',
        'Đơn Vị Tiền',
        'Số Lượng',
        'Thành tiền',
        'Ngày',
        'Tài Khoản',
        'Tài khoản chuyển',
        'Tài khoản nhận',
        'Tiền cọc',
        'Tiền COD',
        'Đơn vị vận chuyển',
        'Nhân viên bán',
        'Doanh số nhân viên',
        'Ghi chú',
      ];
      final headers = headerLabels.map(excel.TextCellValue.new).toList();

      sheet.appendRow(headers);
      
      final border = excel.Border(borderStyle: excel.BorderStyle.Thin);
      final headerStyle = excel.CellStyle(
        bold: true,
        topBorder: border,
        bottomBorder: border,
        leftBorder: border,
        rightBorder: border,
        verticalAlign: excel.VerticalAlign.Center,
        horizontalAlign: excel.HorizontalAlign.Center,
        textWrapping: excel.TextWrapping.WrapText,
      );
      final dataStyle = excel.CellStyle(
        topBorder: border,
        bottomBorder: border,
        leftBorder: border,
        rightBorder: border,
        verticalAlign: excel.VerticalAlign.Center,
        horizontalAlign: excel.HorizontalAlign.Center,
        textWrapping: excel.TextWrapping.WrapText,
      );
      final multilineDataStyle = excel.CellStyle(
        topBorder: border,
        bottomBorder: border,
        leftBorder: border,
        rightBorder: border,
        verticalAlign: excel.VerticalAlign.Top,
        horizontalAlign: excel.HorizontalAlign.Center,
        textWrapping: excel.TextWrapping.WrapText,
      );

      final columnCount = headers.length;
      final maxColumnWidths = List<double>.filled(columnCount, 0);
      final Map<int, int> rowLineCounts = {};

      for (int columnIndex = 0; columnIndex < columnCount; columnIndex++) {
        final cell = sheet.cell(
          excel.CellIndex.indexByColumnRow(columnIndex: columnIndex, rowIndex: 0),
        );
        cell.cellStyle = headerStyle;
        _updateExcelMetrics(
          rowLineCounts: rowLineCounts,
          maxColumnWidths: maxColumnWidths,
          rowIndex: 0,
          columnIndex: columnIndex,
          value: headerLabels[columnIndex],
        );
      }

      int dataRowIndex = 2; // Bắt đầu từ row 2 (sau header row)
      const multilineColumns = {4, 18}; // IMEI (4) và Ghi chú (18)
      for (var ticket in exportTickets) {
        final tableName = ticket['table'] as String;
        final account = ticket['items'] is List && (ticket['items'] as List).isNotEmpty 
            ? (ticket['items'][0]['account']?.toString())
            : null;
        final type = _getDisplayType(ticket['type'], tableName, account: account);
        final date = _formatDate(ticket['date']);

        // Create separate rows for each product in the ticket
        for (var item in ticket['items']) {
          // Sử dụng partner từ item nếu có (cho return_orders, reimport_orders), nếu không dùng partner chung
          final itemPartner = item['partner']?.toString() ?? ticket['partner'] ?? 'N/A';
          final productName = item['product_name']?.toString() ?? 'N/A';
          final warehouseName = item['warehouse_name']?.toString() ?? 'N/A';
          final imei = item['imei']?.toString() ?? 'N/A';
          final isTransferFund = ticket['type'] == 'transfer_fund';
          // Xử lý số tiền cho transfer_fund
          final amount = isTransferFund 
              ? (item['from_amount'] ?? 0)
              : (item['amount'] ?? item['total_amount'] ?? 0);
          final currency = isTransferFund
              ? (item['from_currency']?.toString() ?? 'VND')
              : (item['currency']?.toString() ?? 'VND');
          // Hiển thị tài khoản cho financial_orders (payment, receive, cost, income_other) nhưng không hiển thị cho exchange và transfer_fund (vì có to_account riêng)
          // Và hiển thị cho non-financial tickets nhưng không hiển thị nếu là Ship COD hoặc Cod hoàn (vì thừa)
          final account = (item['account'] != null && 
              ticket['type'] != 'exchange' && 
              ticket['type'] != 'transfer_fund' &&
              item['account'].toString() != 'Ship COD' &&
              item['account'].toString() != 'Cod hoàn')
              ? item['account'].toString()
              : '';
          // Tài khoản chuyển và tài khoản nhận cho transfer_fund
          final fromAccount = isTransferFund ? (item['from_account']?.toString() ?? '') : '';
          final toAccount = isTransferFund ? (item['to_account']?.toString() ?? '') : '';
          // Tiền cọc và tiền COD hiển thị cho sale_orders với account == 'Ship COD' hoặc reimport_orders với account == 'Cod hoàn'
          final isShipCodItem = tableName == 'sale_orders' && item['account']?.toString() == 'Ship COD';
          final isCodHoanItem = tableName == 'reimport_orders' && item['account']?.toString() == 'Cod hoàn';
          final transporterName = ((isShipCodItem || isCodHoanItem) && 
              item['transporter'] != null && 
              item['transporter'].toString().isNotEmpty)
              ? item['transporter'].toString()
              : '';
          final saleman = item['saleman']?.toString() ?? '';
          // Ưu tiên note của item, nếu không có thì lấy note của ticket
          final note = (item['note'] != null && item['note'].toString().isNotEmpty)
              ? item['note'].toString()
              : (ticket['note'] != null && ticket['note'].toString().isNotEmpty)
                  ? ticket['note'].toString()
                  : '';
          final imeiCellValue = _formatImeiForExcelCell(imei);

          // Tính số lượng và thành tiền
          final quantity = tableName == 'transporter_orders'
              ? (item['imei'] != null ? (item['imei'] as String).split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).length : 0)
              : (num.tryParse((item['quantity'] ?? 0).toString())?.toInt() ?? 0);
          final amountValue = num.tryParse(amount.toString())?.toDouble() ?? 0.0;
          final totalAmount = amountValue * quantity;

          // Tạo danh sách cell values với đúng kiểu dữ liệu
          final rowData = <excel.CellValue>[
            excel.TextCellValue(type),
            excel.TextCellValue(itemPartner),
            excel.TextCellValue(productName),
            excel.TextCellValue(warehouseName),
            excel.TextCellValue(imeiCellValue),
            // Số Tiền (index 5) - số thực
            amount != null && amount != 0 
                ? excel.DoubleCellValue(amountValue)
                : excel.DoubleCellValue(0.0),
            excel.TextCellValue(currency),
            // Số Lượng (index 7) - số nguyên
            excel.IntCellValue(quantity),
            // Thành tiền (index 8) - số thực (Số Tiền * Số Lượng)
            excel.DoubleCellValue(totalAmount),
            excel.TextCellValue(date),
            excel.TextCellValue(account),
            // Tài khoản chuyển (index 11) - cho transfer_fund
            excel.TextCellValue(fromAccount),
            // Tài khoản nhận (index 12) - cho transfer_fund
            excel.TextCellValue(toAccount),
            // Tiền cọc (index 13) - số thực
            (isShipCodItem || isCodHoanItem) && item['customer_price'] != null
                ? excel.DoubleCellValue(num.tryParse(item['customer_price'].toString())?.toDouble() ?? 0.0)
                : excel.TextCellValue(''),
            // Tiền COD (index 14) - số thực
            (isShipCodItem || isCodHoanItem) && item['transporter_price'] != null
                ? excel.DoubleCellValue(num.tryParse(item['transporter_price'].toString())?.toDouble() ?? 0.0)
                : excel.TextCellValue(''),
            excel.TextCellValue(transporterName),
            excel.TextCellValue(saleman),
            // Doanh số nhân viên (index 14) - số thực
            item['doanhso'] != null && item['doanhso'] != 0
                ? excel.DoubleCellValue(num.tryParse(item['doanhso'].toString())?.toDouble() ?? 0.0)
                : excel.TextCellValue(''),
            excel.TextCellValue(note),
          ];
          
          sheet.appendRow(rowData);
          
          final currentRowIndex = dataRowIndex - 1;
          for (int columnIndex = 0;
              columnIndex < columnCount;
              columnIndex++) {
            final cell = sheet.cell(
              excel.CellIndex.indexByColumnRow(
                columnIndex: columnIndex,
                rowIndex: currentRowIndex,
              ),
          );
            final isMultiline = multilineColumns.contains(columnIndex);
            cell.cellStyle = isMultiline ? multilineDataStyle : dataStyle;
            // Lấy giá trị string để tính toán metrics (cho text wrapping)
            final cellValue = rowData[columnIndex];
            String valueString;
            if (cellValue is excel.TextCellValue) {
              // Lấy giá trị từ TextCellValue một cách an toàn
              final value = cellValue.value;
              valueString = value.toString();
            } else if (cellValue is excel.IntCellValue) {
              valueString = cellValue.value.toString();
            } else if (cellValue is excel.DoubleCellValue) {
              valueString = cellValue.value.toString();
            } else {
              valueString = '';
            }
            _updateExcelMetrics(
              rowLineCounts: rowLineCounts,
              maxColumnWidths: maxColumnWidths,
              rowIndex: currentRowIndex,
              columnIndex: columnIndex,
              value: valueString,
            );
          }
          
          dataRowIndex++;
        }
      }

      _applyExcelSizing(
        sheet: sheet,
        maxColumnWidths: maxColumnWidths,
        rowLineCounts: rowLineCounts,
      );

      if (excelFile.sheets.containsKey('Sheet1')) {
        excelFile.delete('Sheet1');
        print('Sheet1 đã được xóa trước khi xuất file.');
      } else {
        print('Không tìm thấy Sheet1 sau khi tạo các sheet.');
      }

      // Sử dụng StorageHelper để lấy thư mục Downloads (hỗ trợ Android 13+)
      final downloadsDir = await StorageHelper.getDownloadDirectory();
      if (downloadsDir == null) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Không thể truy cập thư mục Downloads')),
        );
        return;
      }

      final now = DateTime.now();
      final fileName = 'BaoCao_${now.day}_${now.month}_${now.year}_${now.hour}_${now.minute}_${now.second}.xlsx';
      final filePath = '${downloadsDir.path}/$fileName';
      final file = File(filePath);

      final excelBytes = excelFile.encode();
      if (excelBytes == null) {
        throw Exception('Không tạo được file Excel');
      }
      await file.writeAsBytes(excelBytes);

      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Đã xuất Excel: $filePath')),
      );

      final openResult = await OpenFile.open(filePath);
      if (openResult.type != ResultType.done) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không mở được file. File lưu tại: $filePath')),
        );
      }
    } catch (e) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi xuất Excel: $e')),
      );
    } finally {
      setState(() => isExporting = false);
    }
  }

  Widget _buildFilterRow() {
    final displayText = selectedFilterTypes.contains('all')
        ? 'Loại Phiếu'
        : selectedFilterTypes.length == 1
            ? ticketTypeOptions.firstWhere((opt) => opt['value'] == selectedFilterTypes.first, orElse: () => {'display': 'Loại Phiếu'})['display']!
            : '${selectedFilterTypes.length} loại phiếu';
    
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: InkWell(
            onTap: () => _showFilterDialog(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                children: [
                  Expanded(
                  child: Text(
                      displayText,
                      style: const TextStyle(fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Icon(Icons.arrow_drop_down, size: 20),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: TextField(
            controller: _dateFromController,
            decoration: const InputDecoration(
              labelText: 'Từ Ngày',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
            readOnly: true,
            onTap: () => _selectDate(context, true),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: TextField(
            controller: _dateToController,
            decoration: const InputDecoration(
              labelText: 'Đến Ngày',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
            readOnly: true,
            onTap: () => _selectDate(context, false),
          ),
        ),
      ],
    );
  }

  void _showFilterDialog() {
    // Tạo bản sao của selectedFilterTypes để chỉnh sửa trong dialog
    Set<String> tempSelectedTypes = Set.from(selectedFilterTypes);
    
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Chọn loại phiếu'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: ticketTypeOptions.length,
              itemBuilder: (context, index) {
                final option = ticketTypeOptions[index];
                final value = option['value']!;
                final display = option['display']!;
                final isSelected = tempSelectedTypes.contains(value);
                
                return InkWell(
                  onTap: () {
                    setDialogState(() {
                      if (value == 'all') {
                        // Nếu chọn "all", chỉ giữ lại "all"
                        tempSelectedTypes = {'all'};
                      } else {
                        // Bỏ "all" nếu đang chọn
                        tempSelectedTypes.remove('all');
                        // Toggle selection
                        if (isSelected) {
                          tempSelectedTypes.remove(value);
                          // Nếu không còn gì được chọn, chọn "all"
                          if (tempSelectedTypes.isEmpty) {
                            tempSelectedTypes.add('all');
                          }
                        } else {
                          tempSelectedTypes.add(value);
                        }
                      }
                    });
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isSelected ? Colors.blue : Colors.grey,
                              width: 2,
                            ),
                            color: isSelected ? Colors.blue : Colors.transparent,
                          ),
                          child: isSelected
                              ? const Icon(Icons.check, size: 14, color: Colors.white)
                              : null,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            display,
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                setDialogState(() {
                  tempSelectedTypes = {'all'};
                });
              },
              child: const Text('Chọn tất cả'),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  selectedFilterTypes = tempSelectedTypes;
                  hasMoreData = false;
                });
                Navigator.pop(context);
                _loadTickets();
              },
              child: const Text('Áp dụng'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lịch Sử Giao Dịch', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Stack(
          children: [
            Column(
              children: [
                _buildFilterRow(),
                const SizedBox(height: 12),
                Expanded(
                  child: isLoadingTickets
                      ? const Center(child: CircularProgressIndicator())
                      : ticketError != null
                          ? Center(child: Text(ticketError!))
                          : tickets.isEmpty
                              ? const Center(child: Text('Không có giao dịch.'))
                              : ListView.builder(
                                  controller: _scrollController,
                                  itemCount: tickets.length + (isLoadingMore ? 1 : 0),
                                  itemBuilder: (context, index) {
                                    if (index == tickets.length) {
                                      return const Center(child: CircularProgressIndicator());
                                    }
                                    return _buildTicketCard(tickets[index]);
                                  },
                                ),
                ),
              ],
            ),
            Positioned(
              bottom: 16,
              right: 16,
              child: FloatingActionButton.extended(
                onPressed: _exportToExcel,
                label: const Text('Xuất Excel'),
                icon: const Icon(Icons.file_download),
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTicketCard(Map<String, dynamic> ticket) {
    final isFinancialTicket = ticket['table'] == 'financial_orders';
    final financialType = ticket['type'] as String?;
    final isTransferFund = financialType == 'transfer_fund';
    // Các loại phiếu không có đối tác: transfer_fund, cost, exchange, income_other
    final hasNoPartner = isTransferFund || 
        financialType == 'cost' || 
        financialType == 'exchange' || 
        financialType == 'income_other';
    
    // Kiểm tra nếu có nhiều đối tác khác nhau trong ticket
    final hasMultiplePartners = ticket['table'] == 'return_orders' || ticket['table'] == 'reimport_orders';
    final uniquePartners = hasMultiplePartners 
        ? (ticket['items'] as List).map((item) => item['partner'] as String? ?? 'N/A').toSet()
        : <String>{};
    final displayPartner = hasMultiplePartners && uniquePartners.length > 1
        ? 'Nhiều đối tác (${uniquePartners.length})'
        : ticket['partner'];

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
      child: ListTile(
        title: Text(_getDisplayType(
          ticket['type'], 
          ticket['table'],
          account: ticket['items'] is List && (ticket['items'] as List).isNotEmpty 
              ? (ticket['items'][0]['account']?.toString())
              : null,
        )),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!hasNoPartner)
            Text('Đối Tác: $displayPartner'),
            if (isFinancialTicket && financialType == 'exchange')
              Text('Số Tiền: ${_formatNumber(ticket['items'][0]['from_amount'])} ${ticket['items'][0]['from_currency']}')
            else if (isFinancialTicket && isTransferFund)
              Text('Số Tiền: ${_formatNumber(ticket['items'][0]['from_amount'])} ${ticket['items'][0]['from_currency'] ?? 'VND'}')
            else if (isFinancialTicket)
              Text('Số Tiền: ${_formatNumber(ticket['items'][0]['amount'])} ${ticket['items'][0]['currency'] ?? 'VND'}')
            else if (ticket['total_amount'] != null)
              Text('Số Tiền: ${_formatNumber(ticket['total_amount'])} ${ticket['currency'] ?? 'VND'}'),
            if (!isFinancialTicket) ...[
              Text('Số Lượng: ${ticket['table'] == 'transporter_orders' ? ticket['total_quantity'] : _formatNumber(ticket['total_quantity'])}'),
            ],
            Text('Ngày: ${_formatDate(ticket['date'])}'),
            if (!isFinancialTicket) ...[
              // Gom nhóm sản phẩm cùng loại để hiển thị gọn
              ..._groupProductsByName(ticket['items'] as List<dynamic>).map<Widget>((group) {
                final productName = group['product_name'] as String;
                final totalQuantity = group['total_quantity'] as num;
                if (productName != 'N/A' && totalQuantity > 0) {
                  return Text('Sản phẩm: $productName x${totalQuantity.toInt()}');
                }
                return const SizedBox.shrink();
              }).toList(),
            ],
            if (ticket['warehouse_name'] != null && ticket['warehouse_name'] != 'N/A')
              Text('Kho: ${ticket['warehouse_name']}'),
          ],
        ),
            ),
          ),
          IntrinsicHeight(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.print, color: Colors.green),
                  onPressed: () => _showPrintOptions(ticket),
                  tooltip: 'In',
                ),
                IconButton(
          icon: const Icon(Icons.visibility, color: Colors.blue),
          onPressed: () => _showTransactionDetails(ticket),
                  tooltip: 'Xem chi tiết',
        ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showPrintOptions(Map<String, dynamic> ticket) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.receipt, color: Colors.blue),
              title: const Text('In phiếu'),
              subtitle: const Text('In hóa đơn phiếu giao dịch'),
              onTap: () {
                Navigator.pop(context);
                _printTicket(ticket);
              },
            ),
            ListTile(
              leading: const Icon(Icons.label, color: Colors.green),
              title: const Text('In tem IMEI'),
              subtitle: const Text('In tem nhãn IMEI cho tất cả sản phẩm'),
              onTap: () {
                Navigator.pop(context);
                _printImeiLabels(ticket);
              },
            ),
          ],
        ),
      ),
    );
  }

  // Helper để lấy tên sản phẩm từ product_id
  String _getProductName(String? productId) {
    if (productId == null || productId.isEmpty) return 'N/A';
    return productMap[productId] ?? 'N/A';
  }

  /// In tem IMEI qua Bluetooth từ ticket
  Future<void> _executeBluetoothPrintImeiLabels(Map<String, dynamic> ticket) async {
    try {
      // Kiểm tra kết nối Bluetooth
      bool connected = await BluetoothPrintHelper.isConnected();
      
      // Nếu chưa kết nối, hiển thị dialog chọn máy in
      if (!connected) {
        final device = await BluetoothPrintHelper.showDevicePicker(context);
        if (device == null) {
          return; // User hủy chọn máy in
        }
        
        // Kết nối với máy in
        final success = await BluetoothPrintHelper.connect(device);
        if (!success) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Không thể kết nối với máy in Bluetooth')),
            );
          }
          return;
        }
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Đã kết nối với máy in Bluetooth')),
          );
        }
      }

      // Thu thập tất cả IMEI từ ticket
      final List<Map<String, dynamic>> itemsToPrint = [];
      
      if (ticket['items'] is List) {
        for (var item in ticket['items'] as List) {
          final productId = item['product_id']?.toString();
          final imeiString = item['imei']?.toString() ?? '';
          final imeis = _parseImeis(imeiString);
          
          if (imeis.isNotEmpty && productId != null) {
            for (var imei in imeis) {
              itemsToPrint.add({
                'product_id': productId,
                'imei': imei,
              });
            }
          }
        }
      }

      if (itemsToPrint.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Không có IMEI để in')),
          );
        }
        return;
      }

      // Hiển thị loading
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text('Đang in ${itemsToPrint.length} tem qua Bluetooth...'),
            ],
          ),
        ),
      );

      // In từng item
      int successCount = 0;
      int failCount = 0;
      
      for (var item in itemsToPrint) {
        final productId = item['product_id']?.toString() ?? '';
        final imei = item['imei']?.toString() ?? '';
        final productName = _getProductName(productId);
        
        if (imei.isNotEmpty && productName.isNotEmpty) {
          final success = await BluetoothPrintHelper.printImeiLabel(
            productName: productName,
            imei: imei,
            labelHeight: 30, // Mặc định 30mm cho Bluetooth
          );
          
          if (success) {
            successCount++;
            // Đợi một chút giữa các lần in để tránh quá tải
            await Future.delayed(const Duration(milliseconds: 500));
          } else {
            failCount++;
          }
        }
      }

      if (mounted) {
        Navigator.pop(context); // Đóng loading dialog
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Đã in $successCount tem. ${failCount > 0 ? 'Lỗi: $failCount tem' : ''}'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi khi in qua Bluetooth: $e')),
        );
      }
    }
  }

  // Helper để parse IMEI từ string (có thể là comma-separated)
  List<String> _parseImeis(String? imeiString) {
    if (imeiString == null || imeiString.isEmpty || imeiString == 'N/A') {
      return [];
    }
    return imeiString
        .split(RegExp(r'[,;\n]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  // Helper function để load font hỗ trợ Unicode
  // Sử dụng font mặc định của package pdf (hỗ trợ Unicode)
  // Nếu có font trong assets thì load từ đó, nếu không thì dùng font mặc định
  Future<pw.Font?> _loadUnicodeFont() async {
    try {
      // Thử load font từ assets nếu có
      final fontData = await rootBundle.load('assets/fonts/Roboto-Regular.ttf');
      return pw.Font.ttf(fontData);
    } catch (e) {
      // Nếu không có font trong assets, trả về null để dùng font mặc định
      // Package pdf 3.11.1 có hỗ trợ Unicode với font mặc định
      return null;
    }
  }

  Future<pw.Font?> _loadUnicodeFontBold() async {
    try {
      final fontData = await rootBundle.load('assets/fonts/Roboto-Bold.ttf');
      return pw.Font.ttf(fontData);
    } catch (e) {
      // Trả về null để dùng font mặc định
      return null;
    }
  }

  // In phiếu (hóa đơn)
  Future<void> _printTicket(Map<String, dynamic> ticket) async {
    try {
      final pdf = pw.Document();
      // Load font hỗ trợ Unicode (nếu có trong assets)
      final baseFont = await _loadUnicodeFont();
      final boldFont = await _loadUnicodeFontBold();
      
      final tableName = ticket['table'] as String;
      final account = ticket['items'] is List && (ticket['items'] as List).isNotEmpty 
          ? (ticket['items'][0]['account']?.toString())
          : null;
      final ticketType = _getDisplayType(ticket['type'], tableName, account: account);
      final ticketId = ticket['id']?.toString() ?? '';
      final date = _formatDate(ticket['date']);
      
      // Lấy thông tin đối tác
      // Kiểm tra nếu có nhiều đối tác khác nhau trong ticket (giống logic trong _showTransactionDetails)
      final hasMultiplePartners = tableName == 'return_orders' || tableName == 'reimport_orders';
      final uniquePartners = hasMultiplePartners 
          ? (ticket['items'] as List).map((item) => item['partner'] as String? ?? 'N/A').toSet()
          : <String>{};
      final displayPartner = hasMultiplePartners && uniquePartners.length > 1
          ? 'Nhiều đối tác (${uniquePartners.length})'
          : (ticket['partner']?.toString() ?? 'N/A');

      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(40),
          theme: baseFont != null && boldFont != null
              ? pw.ThemeData.withFont(
                  base: baseFont,
                  bold: boldFont,
                )
              : null, // Dùng font mặc định nếu không có font từ assets
          build: (context) {
            return pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                // Header: Tên phiếu
                pw.Center(
                  child: pw.Text(
                    ticketType,
                    style: pw.TextStyle(
                      fontSize: 24,
                      fontWeight: pw.FontWeight.bold,
                      font: boldFont,
                    ),
                  ),
                ),
                pw.SizedBox(height: 20),
                
                // Thông tin phiếu
                pw.Container(
                  padding: const pw.EdgeInsets.all(16),
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(color: PdfColors.grey800, width: 1),
                    borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
                  ),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      _buildInfoRow('Mã phiếu:', ticketId, baseFont: baseFont, boldFont: boldFont),
                      _buildInfoRow('Đối tác:', displayPartner, baseFont: baseFont, boldFont: boldFont),
                      if (ticket['total_amount'] != null)
                        _buildInfoRow(
                          'Tổng tiền:',
                          '${_formatNumber(ticket['total_amount'])} ${ticket['currency'] ?? 'VND'}',
                          baseFont: baseFont,
                          boldFont: boldFont,
                        ),
                      if (ticket['total_quantity'] != null && tableName != 'financial_orders')
                        _buildInfoRow(
                          'Số lượng:',
                          tableName == 'transporter_orders'
                              ? ticket['total_quantity'].toString()
                              : _formatNumber(ticket['total_quantity']),
                          baseFont: baseFont,
                          boldFont: boldFont,
                        ),
                      if (ticket['warehouse_name'] != null && ticket['warehouse_name'] != 'N/A')
                        _buildInfoRow('Kho:', ticket['warehouse_name'].toString(), baseFont: baseFont, boldFont: boldFont),
                      if (ticket['items'] is List && (ticket['items'] as List).isNotEmpty) ...[
                        pw.SizedBox(height: 12),
                        pw.Divider(),
                        pw.SizedBox(height: 12),
                        pw.Text(
                          'Chi tiết sản phẩm:',
                          style: pw.TextStyle(
                            fontSize: 14,
                            fontWeight: pw.FontWeight.bold,
                            font: boldFont,
                          ),
                        ),
                        pw.SizedBox(height: 8),
                        // Bảng sản phẩm
                        pw.Table(
                          border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
                          children: [
                            // Header row
                            pw.TableRow(
                              decoration: const pw.BoxDecoration(color: PdfColors.grey200),
                              children: [
                                _buildTableCell('STT', isHeader: true, baseFont: baseFont, boldFont: boldFont),
                                _buildTableCell('Sản phẩm', isHeader: true, baseFont: baseFont, boldFont: boldFont),
                                _buildTableCell('Số lượng', isHeader: true, baseFont: baseFont, boldFont: boldFont),
                                _buildTableCell('Đơn giá', isHeader: true, baseFont: baseFont, boldFont: boldFont),
                                _buildTableCell('Thành tiền', isHeader: true, baseFont: baseFont, boldFont: boldFont),
                                _buildTableCell('IMEI', isHeader: true, baseFont: baseFont, boldFont: boldFont),
                              ],
                            ),
                            // Data rows
                            ...(ticket['items'] as List).asMap().entries.map((entry) {
                              final index = entry.key;
                              final item = entry.value;
                              final productName = item['product_name']?.toString() ?? 'N/A';
                              final quantity = item['quantity']?.toString() ?? '0';
                              final amount = item['amount'] ?? item['total_amount'] ?? 0;
                              final currency = item['currency']?.toString() ?? 'VND';
                              final totalAmount = item['total_amount'] ?? (amount * (num.tryParse(quantity) ?? 0));
                              final imeiString = item['imei']?.toString() ?? '';
                              final imeis = _parseImeis(imeiString);
                              
                              return pw.TableRow(
                                children: [
                                  _buildTableCell('${index + 1}', baseFont: baseFont, boldFont: boldFont),
                                  _buildTableCell(productName, baseFont: baseFont, boldFont: boldFont),
                                  _buildTableCell(quantity, baseFont: baseFont, boldFont: boldFont),
                                  _buildTableCell('${_formatNumber(amount)} $currency', baseFont: baseFont, boldFont: boldFont),
                                  _buildTableCell('${_formatNumber(totalAmount)} $currency', baseFont: baseFont, boldFont: boldFont),
                                  _buildTableCell(
                                    imeis.isEmpty ? 'N/A' : imeis.join('\n'),
                                    isMultiline: true,
                                    baseFont: baseFont,
                                    boldFont: boldFont,
                                  ),
                                ],
                              );
                            }).toList(),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                
                pw.Spacer(),
                
                // Footer: Ngày tạo phiếu
                pw.Align(
                  alignment: pw.Alignment.centerRight,
                  child: pw.Text(
                    'Ngày tạo: $date',
                    style: pw.TextStyle(
                      fontSize: 12,
                      color: PdfColors.grey600,
                      font: baseFont,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      );

      await Printing.layoutPdf(
        onLayout: (format) async => pdf.save(),
        name: 'Phieu_${ticketId}_${DateTime.now().millisecondsSinceEpoch}.pdf',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi khi in phiếu: $e')),
        );
      }
    }
  }

  pw.Widget _buildInfoRow(String label, String value, {pw.Font? baseFont, pw.Font? boldFont}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 8),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(
            width: 120,
            child: pw.Text(
              label,
              style: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                fontSize: 12,
                font: boldFont,
              ),
            ),
          ),
          pw.Expanded(
            child: pw.Text(
              value,
              style: pw.TextStyle(
                fontSize: 12,
                font: baseFont,
              ),
            ),
          ),
        ],
      ),
    );
  }

  pw.Widget _buildTableCell(String text, {bool isHeader = false, bool isMultiline = false, pw.Font? baseFont, pw.Font? boldFont}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.all(4),
      child: pw.Text(
        text,
        style: pw.TextStyle(
          fontSize: isHeader ? 11 : 10,
          fontWeight: isHeader ? pw.FontWeight.bold : pw.FontWeight.normal,
          font: isHeader ? boldFont : baseFont,
        ),
        textAlign: pw.TextAlign.center,
        maxLines: isMultiline ? null : 1,
      ),
    );
  }

  // In tem IMEI (giống inventory_screen.dart)
  Future<void> _printImeiLabels(Map<String, dynamic> ticket) async {
    String printType;
    int labelsPerRow;
    int labelHeight;
    bool saveAsDefault = false;

    if (_hasDefaultSettings) {
      printType = _defaultPrintType;
      labelsPerRow = _defaultLabelsPerRow;
      labelHeight = _defaultLabelHeight;
    } else {
      final result = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Cài đặt in tem'),
          content: SingleChildScrollView(
            child: _PrintSettingsDialog(
              defaultPrintType: _defaultPrintType,
              defaultLabelsPerRow: _defaultLabelsPerRow,
              defaultLabelHeight: _defaultLabelHeight,
            ),
          ),
        ),
      );

      if (result == null) return;

      printType = result['printType'] as String;
      labelsPerRow = result['labelsPerRow'] as int;
      labelHeight = result['labelHeight'] as int;
      saveAsDefault = result['saveAsDefault'] as bool;

      if (saveAsDefault) {
        await _savePrintSettings(printType, labelsPerRow, labelHeight);
        setState(() {
          _defaultPrintType = printType;
          _defaultLabelsPerRow = labelsPerRow;
          _defaultLabelHeight = labelHeight;
        });
      }
    }

    // Nếu chọn in qua Bluetooth, xử lý riêng
    // Trên iOS, tạm thời disable Bluetooth do package có bug
    if (printType == 'bluetooth') {
      if (Platform.isIOS) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Tính năng in qua Bluetooth tạm thời không khả dụng trên iOS. Vui lòng sử dụng in PDF/thermal.'),
              duration: Duration(seconds: 3),
            ),
          );
        }
        return;
      }
      await _executeBluetoothPrintImeiLabels(ticket);
      return;
    }

    try {
      // Thu thập tất cả IMEI từ ticket
      final List<Map<String, dynamic>> itemsToPrint = [];
      
      if (ticket['items'] is List) {
        for (var item in ticket['items'] as List) {
          final productId = item['product_id']?.toString();
          final imeiString = item['imei']?.toString() ?? '';
          final imeis = _parseImeis(imeiString);
          
          if (imeis.isNotEmpty && productId != null) {
            for (var imei in imeis) {
              itemsToPrint.add({
                'product_id': productId,
                'imei': imei,
              });
            }
          }
        }
      }

      if (itemsToPrint.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Không có IMEI để in')),
          );
        }
        return;
      }

      final pdf = pw.Document();
      final barcodeGen = Barcode.code128();

      if (printType == 'thermal') {
        if (labelsPerRow == 1) {
          for (var item in itemsToPrint) {
            pdf.addPage(
              pw.Page(
                pageFormat: PdfPageFormat(
                  40 * PdfPageFormat.mm,
                  labelHeight * PdfPageFormat.mm,
                  marginAll: 1 * PdfPageFormat.mm,
                ),
                build: (context) => _buildThermalLabel(item, barcodeGen, labelHeight),
              ),
            );
          }
        } else {
          final pageWidth = labelsPerRow == 2
              ? 85 * PdfPageFormat.mm
              : 125 * PdfPageFormat.mm;

          for (int i = 0; i < itemsToPrint.length; i += labelsPerRow) {
            final rowItems = itemsToPrint.skip(i).take(labelsPerRow).toList();

            pdf.addPage(
              pw.Page(
                pageFormat: PdfPageFormat(
                  pageWidth,
                  labelHeight * PdfPageFormat.mm,
                  marginAll: 1 * PdfPageFormat.mm,
                ),
                build: (context) {
                  return pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceEvenly,
                    children: rowItems.map((item) {
                      return pw.Container(
                        width: 38 * PdfPageFormat.mm,
                        child: _buildThermalLabel(item, barcodeGen, labelHeight),
                      );
                    }).toList(),
                  );
                },
              ),
            );
          }
        }
      } else {
        const itemsPerPage = 4;
        for (int i = 0; i < itemsToPrint.length; i += itemsPerPage) {
          final pageItems = itemsToPrint.skip(i).take(itemsPerPage).toList();

          pdf.addPage(
            pw.Page(
              pageFormat: PdfPageFormat.a4,
              margin: const pw.EdgeInsets.all(20),
              build: (context) {
                return pw.Column(
                  children: [
                    pw.Row(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        if (pageItems.isNotEmpty)
                          pw.Expanded(child: _buildA4Label(pageItems[0], barcodeGen)),
                        pw.SizedBox(width: 10),
                        if (pageItems.length > 1)
                          pw.Expanded(child: _buildA4Label(pageItems[1], barcodeGen))
                        else
                          pw.Expanded(child: pw.Container()),
                      ],
                    ),
                    pw.SizedBox(height: 20),
                    pw.Row(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        if (pageItems.length > 2)
                          pw.Expanded(child: _buildA4Label(pageItems[2], barcodeGen))
                        else
                          pw.Expanded(child: pw.Container()),
                        pw.SizedBox(width: 10),
                        if (pageItems.length > 3)
                          pw.Expanded(child: _buildA4Label(pageItems[3], barcodeGen))
                        else
                          pw.Expanded(child: pw.Container()),
                      ],
                    ),
                  ],
                );
              },
            ),
          );
        }
      }

      await Printing.layoutPdf(
        onLayout: (format) async => pdf.save(),
        name: 'Tem_IMEI_${DateTime.now().millisecondsSinceEpoch}.pdf',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi khi in tem IMEI: $e')),
        );
      }
    }
  }

  pw.Widget _buildThermalLabel(Map<String, dynamic> item, Barcode barcodeGen, int labelHeight) {
    final productId = item['product_id']?.toString() ?? '';
    final imei = item['imei']?.toString() ?? '';
    final productName = _getProductName(productId);

    double titleFontSize;
    double imeiFontSize;
    double barcodeHeight;
    int maxLines;

    if (labelHeight <= 20) {
      titleFontSize = 5;
      imeiFontSize = 4;
      barcodeHeight = 10;
      maxLines = 1;
    } else if (labelHeight <= 25) {
      titleFontSize = 6;
      imeiFontSize = 4.5;
      barcodeHeight = 13;
      maxLines = 1;
    } else if (labelHeight <= 30) {
      titleFontSize = 7;
      imeiFontSize = 5;
      barcodeHeight = 16;
      maxLines = 1;
    } else {
      titleFontSize = 9;
      imeiFontSize = 6;
      barcodeHeight = 22;
      maxLines = 2;
    }

    final enlargedImeiFontSize = imeiFontSize * 2;
    final enlargedBarcodeHeight = barcodeHeight * 1.8;

    return pw.Container(
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.black, width: 0.5),
      ),
      child: pw.Column(
        mainAxisAlignment: pw.MainAxisAlignment.center,
        children: [
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(horizontal: 2),
            child: pw.Text(
              productName,
              style: pw.TextStyle(
                fontSize: titleFontSize,
                fontWeight: pw.FontWeight.bold,
              ),
              textAlign: pw.TextAlign.center,
              maxLines: maxLines,
              overflow: pw.TextOverflow.clip,
            ),
          ),
          pw.SizedBox(height: 1),
          pw.Container(
            height: enlargedBarcodeHeight,
            padding: const pw.EdgeInsets.symmetric(horizontal: 2),
            child: pw.BarcodeWidget(
              barcode: barcodeGen,
              data: imei,
              drawText: false,
              width: 95,
            ),
          ),
          pw.SizedBox(height: 1),
          pw.Text(
            imei,
            style: pw.TextStyle(
              fontSize: enlargedImeiFontSize,
            ),
            textAlign: pw.TextAlign.center,
          ),
        ],
      ),
    );
  }

  pw.Widget _buildA4Label(Map<String, dynamic> item, Barcode barcodeGen) {
    final productId = item['product_id']?.toString() ?? '';
    final imei = item['imei']?.toString() ?? '';
    final productName = _getProductName(productId);

    return pw.Container(
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.black, width: 1),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
      ),
      padding: const pw.EdgeInsets.all(8),
      child: pw.Column(
        mainAxisAlignment: pw.MainAxisAlignment.center,
        children: [
          pw.Text(
            productName,
            style: pw.TextStyle(
              fontSize: 12,
              fontWeight: pw.FontWeight.bold,
            ),
            textAlign: pw.TextAlign.center,
            maxLines: 2,
            overflow: pw.TextOverflow.clip,
          ),
          pw.SizedBox(height: 8),
          pw.Container(
            height: 100,
            child: pw.BarcodeWidget(
              barcode: barcodeGen,
              data: imei,
              drawText: false,
            ),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            imei,
            style: pw.TextStyle(
              fontSize: 18,
            ),
            textAlign: pw.TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// Widget dialog cài đặt in tem (giống inventory_screen.dart)
class _PrintSettingsDialog extends StatefulWidget {
  final String defaultPrintType;
  final int defaultLabelsPerRow;
  final int defaultLabelHeight;

  const _PrintSettingsDialog({
    required this.defaultPrintType,
    required this.defaultLabelsPerRow,
    required this.defaultLabelHeight,
  });

  @override
  State<_PrintSettingsDialog> createState() => _PrintSettingsDialogState();
}

class _PrintSettingsDialogState extends State<_PrintSettingsDialog> {
  late String _selectedPrintType;
  late int _selectedLabelsPerRow;
  late int _selectedLabelHeight;
  bool _saveAsDefault = false;

  @override
  void initState() {
    super.initState();
    _selectedPrintType = widget.defaultPrintType;
    _selectedLabelsPerRow = widget.defaultLabelsPerRow;
    _selectedLabelHeight = widget.defaultLabelHeight;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Loại máy in:',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        ),
        const SizedBox(height: 8),
        RadioListTile<String>(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Máy in thông thường (A4)'),
          subtitle: const Text('In 4 tem trên 1 tờ giấy A4', style: TextStyle(fontSize: 12)),
          value: 'a4',
          groupValue: _selectedPrintType,
          onChanged: (value) {
            setState(() {
              _selectedPrintType = value!;
            });
          },
        ),
        RadioListTile<String>(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Máy in tem nhiệt'),
          subtitle: const Text('Cuộn tem nhãn (mọi loại máy)', style: TextStyle(fontSize: 12)),
          value: 'thermal',
          groupValue: _selectedPrintType,
          onChanged: (value) {
            setState(() {
              _selectedPrintType = value!;
            });
          },
        ),
        // Tạm thời ẩn Bluetooth trên iOS do package có bug
        if (!Platform.isIOS)
          RadioListTile<String>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('In qua Bluetooth'),
            subtitle: const Text('Kết nối trực tiếp với máy in Bluetooth (CLabel CT221B)', style: TextStyle(fontSize: 12)),
            value: 'bluetooth',
            groupValue: _selectedPrintType,
            onChanged: (value) {
              setState(() {
                _selectedPrintType = value!;
              });
            },
          ),
        if (Platform.isIOS)
          RadioListTile<String>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('In qua Bluetooth (iOS - Tạm thời không khả dụng)'),
            subtitle: const Text('Tính năng này đang được phát triển cho iOS. Vui lòng sử dụng in PDF/thermal.', style: TextStyle(fontSize: 12, color: Colors.orange)),
            value: 'bluetooth_disabled',
            groupValue: 'bluetooth_disabled',
            onChanged: null, // Disabled
          ),
        if (_selectedPrintType == 'thermal') ...[
          const Divider(),
          const SizedBox(height: 8),
          const Text(
            'Chiều cao tem (mm):',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          const SizedBox(height: 8),
          RadioListTile<int>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('20mm'),
            value: 20,
            groupValue: _selectedLabelHeight,
            onChanged: (value) {
              setState(() {
                _selectedLabelHeight = value!;
              });
            },
          ),
          RadioListTile<int>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('25mm'),
            value: 25,
            groupValue: _selectedLabelHeight,
            onChanged: (value) {
              setState(() {
                _selectedLabelHeight = value!;
              });
            },
          ),
          RadioListTile<int>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('30mm'),
            value: 30,
            groupValue: _selectedLabelHeight,
            onChanged: (value) {
              setState(() {
                _selectedLabelHeight = value!;
              });
            },
          ),
          RadioListTile<int>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('40mm'),
            value: 40,
            groupValue: _selectedLabelHeight,
            onChanged: (value) {
              setState(() {
                _selectedLabelHeight = value!;
              });
            },
          ),
          const Divider(),
          const SizedBox(height: 8),
          const Text(
            'Số tem trên 1 hàng:',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          const SizedBox(height: 8),
          RadioListTile<int>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('1 tem/hàng'),
            value: 1,
            groupValue: _selectedLabelsPerRow,
            onChanged: (value) {
              setState(() {
                _selectedLabelsPerRow = value!;
              });
            },
          ),
          RadioListTile<int>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('2 tem/hàng'),
            value: 2,
            groupValue: _selectedLabelsPerRow,
            onChanged: (value) {
              setState(() {
                _selectedLabelsPerRow = value!;
              });
            },
          ),
          RadioListTile<int>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('3 tem/hàng'),
            value: 3,
            groupValue: _selectedLabelsPerRow,
            onChanged: (value) {
              setState(() {
                _selectedLabelsPerRow = value!;
              });
            },
          ),
        ],
        const Divider(),
        const SizedBox(height: 8),
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Ghi nhớ và dùng làm mặc định'),
          value: _saveAsDefault,
          onChanged: (value) {
            setState(() {
              _saveAsDefault = value ?? false;
            });
          },
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Hủy'),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: () {
                // Nếu chọn Bluetooth, không cần labelsPerRow và labelHeight
                Navigator.pop(context, {
                  'printType': _selectedPrintType,
                  'labelsPerRow': _selectedPrintType == 'bluetooth' ? 1 : _selectedLabelsPerRow,
                  'labelHeight': _selectedPrintType == 'bluetooth' ? 30 : _selectedLabelHeight,
                  'saveAsDefault': _saveAsDefault,
                });
              },
              icon: const Icon(Icons.print),
              label: const Text('In Tem'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ],
    );
  }
}