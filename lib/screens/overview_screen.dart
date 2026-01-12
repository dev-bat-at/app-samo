import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dart:math';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../helpers/global_cache_manager.dart';
import 'package:shared_preferences/shared_preferences.dart'; // added for persistence

// Backward compatibility alias
class CacheUtil {
  static Map<String, String> get productNameCache => GlobalCacheManager().productNameCache;
  static Map<String, String> get warehouseNameCache => GlobalCacheManager().warehouseNameCache;
  static void cacheProductName(String id, String name) => GlobalCacheManager().cacheProductName(id, name);
  static void cacheWarehouseName(String id, String name) => GlobalCacheManager().cacheWarehouseName(id, name);
  static String getProductName(String? id) => GlobalCacheManager().getProductName(id);
  static String getWarehouseName(String? id) => GlobalCacheManager().getWarehouseName(id);
}

class OverviewScreen extends StatefulWidget {
  final List<String> permissions;
  final SupabaseClient tenantClient;

  const OverviewScreen({
    super.key,
    required this.permissions,
    required this.tenantClient,
  });

  @override
  State<OverviewScreen> createState() => _OverviewScreenState();
}

class _OverviewScreenState extends State<OverviewScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  String _selectedTimeFilter = '7 ngày qua';
  DateTime? _fromDate;
  DateTime? _toDate;
  int? _selectedCategoryId;
  List<Map<String, dynamic>> _categories = [];
  String? _selectedWarehouse = 'Tất cả chi nhánh';
  List<String> _warehouseOptions = ['Tất cả chi nhánh'];

  double revenue = 0;
  double profit = 0;
  double profitAfterCost = 0;
  double companyValue = 0;
  double totalIncome = 0;
  double totalExpense = 0;
  double totalCost = 0;
  double totalSupplierDebt = 0;
  double totalCustomerDebt = 0;
  double totalFixerDebt = 0;
  double totalTransporterDebt = 0;
  double totalInventoryCost = 0;
  double totalEmployeeCommission = 0; // Hoa hồng nhân viên = tổng doanhso từ sub_accounts
  int soldProductsCount = 0;
  List<Map<String, dynamic>> accounts = [];
  Map<String, Map<String, int>> stockData = {};

  List<FlSpot> revenueSpots = [];
  List<FlSpot> profitSpots = [];
  List<FlSpot> incomeSpots = [];
  List<FlSpot> expenseSpots = [];
  List<String> timeLabels = [];

  String? selectedStatus;
  List<Map<String, dynamic>> productDistribution = [];
  final List<Color> chartColors = [
    Colors.blue,
    Colors.red,
    Colors.green,
    Colors.orange,
    Colors.purple,
    Colors.cyan,
    Colors.yellow,
    Colors.pink,
  ];

  List<String> filters = ['Hôm nay', '7 ngày qua', '30 ngày qua', 'Tùy chọn'];

  // --- new state for ordering and persistence ---
  List<String> businessOrder = [];
  List<String> financeOrder = [];
  static const String _prefsBusinessKey = 'overview_business_order';
  static const String _prefsFinanceKey = 'overview_finance_order';

  final List<String> _businessDefaultOrder = [
    'company_value',
    'employee_commission',
    'sales',
    'profit',
    'cost',
    'profit_after_cost',
    'chart_business',
  ];

  final List<String> _financeDefaultOrder = [
    // accounts will be inserted dynamically as 'account:<id>'
    'accounts_section', // placeholder to keep accounts grouped
    'supplier_debt',
    'customer_debt',
    'fixer_debt',
    'transporter_debt',
    'inventory_cost',
    'total_income',
    'total_expense',
    'chart_finance',
  ];
  // --- end new state ---

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: widget.permissions.contains('view_finance') ? 3 : 2, vsync: this);
    _initCaches().then((_) async {
      await _loadSavedOrders();
      fetchAllData();
    });
  }

  // Thêm hàm khởi tạo cache nếu chưa có — sửa lỗi line đỏ khi gọi _initCaches()
  Future<void> _initCaches() async {
    try {
      // Kiểm tra cache trước
      final warehouseMap = CacheUtil.warehouseNameCache;
      List<String> names = warehouseMap.values.toList();
      
      // Nếu cache trống, fetch trực tiếp từ database
      if (names.isEmpty) {
        try {
          final warehouseResponse = await widget.tenantClient.from('warehouses').select('id, name');
          names = warehouseResponse
              .map((e) => e['name'] as String?)
              .whereType<String>()
              .toList()
            ..sort();
          
          // Cập nhật cache
          for (var warehouse in warehouseResponse) {
            final id = warehouse['id']?.toString();
            final name = warehouse['name'] as String?;
            if (id != null && name != null) {
              CacheUtil.cacheWarehouseName(id, name);
            }
          }
        } catch (e) {
          print('Error fetching warehouses: $e');
        }
      }
      
      setState(() {
        _warehouseOptions = ['Tất cả chi nhánh', ...names];
        // đảm bảo _selectedWarehouse hợp lệ
        if (_selectedWarehouse == null || !_warehouseOptions.contains(_selectedWarehouse)) {
          _selectedWarehouse = 'Tất cả chi nhánh';
        }
      });
    } catch (e) {
      // Không để lỗi làm crash UI
      setState(() {
        _warehouseOptions = ['Tất cả chi nhánh'];
        _selectedWarehouse = 'Tất cả chi nhánh';
      });
    }
  }

  Future<void> _loadSavedOrders() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedBusiness = prefs.getStringList(_prefsBusinessKey);
      final savedFinance = prefs.getStringList(_prefsFinanceKey);

      setState(() {
        businessOrder = savedBusiness != null && savedBusiness.isNotEmpty ? savedBusiness : List.from(_businessDefaultOrder);
        financeOrder = savedFinance != null && savedFinance.isNotEmpty ? savedFinance : List.from(_financeDefaultOrder);
      });
    } catch (e) {
      print('Error loading saved orders: $e');
      setState(() {
        businessOrder = List.from(_businessDefaultOrder);
        financeOrder = List.from(_financeDefaultOrder);
      });
    }
  }

  Future<void> _saveBusinessOrder() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefsBusinessKey, businessOrder);
    } catch (e) {
      print('Error saving business order: $e');
    }
  }

  Future<void> _saveFinanceOrder() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefsFinanceKey, financeOrder);
    } catch (e) {
      print('Error saving finance order: $e');
    }
  }

  Future<void> _selectDate(BuildContext context, bool isFrom) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        if (isFrom) {
          _fromDate = picked;
        } else {
          _toDate = picked;
        }
        fetchAllData();
      });
    }
  }

  Widget _buildTimeFilter() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            children: filters.map((f) {
              return ChoiceChip(
                label: Text(f),
                selected: _selectedTimeFilter == f,
                onSelected: (v) {
                  if (v) setState(() => _selectedTimeFilter = f);
                  fetchAllData();
                },
              );
            }).toList(),
          ),
          if (_selectedTimeFilter == 'Tùy chọn')
            Row(
              children: [
                TextButton(
                  onPressed: () => _selectDate(context, true),
                  child: Text(_fromDate != null ? DateFormat('dd/MM/yyyy').format(_fromDate!) : 'Từ ngày'),
                ),
                const Text(' - '),
                TextButton(
                  onPressed: () => _selectDate(context, false),
                  child: Text(_toDate != null ? DateFormat('dd/MM/yyyy').format(_toDate!) : 'Tới ngày'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildWarehouseFilter() {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: DropdownButtonFormField<String>(
          value: _selectedWarehouse,
          hint: const Text('Chi nhánh'),
          icon: const Padding(
            padding: EdgeInsets.only(right: 8),
            child: Icon(Icons.arrow_drop_down),
          ),
          items: _warehouseOptions.map((option) {
            return DropdownMenuItem(
              value: option,
              child: Text(option),
            );
          }).toList(),
          onChanged: (value) {
            setState(() {
              _selectedWarehouse = value;
            });
            fetchAllData();
            fetchProductDistribution(selectedStatus);
          },
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
          isExpanded: true,
        ),
      ),
    );
  }

  Widget _buildCategoryFilter() {
    return Flexible(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: DropdownButtonFormField<int>(
          value: _selectedCategoryId,
          items: [
            const DropdownMenuItem<int>(
              value: null,
              child: Text('Tất cả danh mục'),
            ),
            ..._categories.map((cat) => DropdownMenuItem<int>(
                  value: cat['id'],
                  child: Text(cat['name']),
                )),
          ],
          hint: const Text('Chọn danh mục'),
          onChanged: (val) {
            setState(() {
              _selectedCategoryId = val;
            });
            fetchProductDistribution(selectedStatus);
            fetchAllData();
          },
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
        ),
      ),
    );
  }

  DateTime get startDate {
    final now = DateTime.now();
    if (_selectedTimeFilter == 'Hôm nay') {
      return DateTime(now.year, now.month, now.day, 8);
    } else if (_selectedTimeFilter == '7 ngày qua') {
      return now.subtract(const Duration(days: 6));
    } else if (_selectedTimeFilter == '30 ngày qua') {
      return now.subtract(const Duration(days: 29));
    } else if (_fromDate != null) {
      return _fromDate!;
    }
    return now;
  }

  DateTime get endDate {
    final now = DateTime.now();
    if (_selectedTimeFilter == 'Tùy chọn' && _toDate != null) {
      return _toDate!;
    }
    return now;
  }

  List<DateTime> getTimePoints() {
    List<DateTime> points = [];
    if (_selectedTimeFilter == 'Hôm nay') {
      final today = DateTime.now();
      points = [
        DateTime(today.year, today.month, today.day, 8),
        DateTime(today.year, today.month, today.day, 12),
        DateTime(today.year, today.month, today.day, 14),
        DateTime(today.year, today.month, today.day, 16),
        DateTime(today.year, today.month, today.day, 18),
        DateTime(today.year, today.month, today.day, 24),
      ];
    } else if (_selectedTimeFilter == '7 ngày qua') {
      for (int i = 0; i < 7; i++) {
        points.add(startDate.add(Duration(days: i)));
      }
    } else if (_selectedTimeFilter == '30 ngày qua') {
      for (int i = 0; i < 30; i += 5) {
        points.add(startDate.add(Duration(days: i)));
      }
      points.add(endDate);
    } else if (_selectedTimeFilter == 'Tùy chọn' && _fromDate != null && _toDate != null) {
      final days = _toDate!.difference(_fromDate!).inDays + 1;
      int numPoints = days <= 7 ? days : (days <= 30 ? 6 : 7);
      int interval = (days / numPoints).ceil();
      for (int i = 0; i < days; i += interval) {
        points.add(_fromDate!.add(Duration(days: i)));
      }
      points.add(_toDate!);
    }
    return points;
  }

  Future<void> fetchAllData() async {
    try {
      final categoriesResponse = await widget.tenantClient.from('categories').select('id, name');
      setState(() {
        _categories = List<Map<String, dynamic>>.from(categoriesResponse);
      });

      // Lấy warehouse_id nếu có filter
      String? warehouseIdFilter;
      if (_selectedWarehouse != 'Tất cả chi nhánh') {
        warehouseIdFilter = CacheUtil.warehouseNameCache.entries
            .firstWhere((entry) => entry.value == _selectedWarehouse, orElse: () => MapEntry('', ''))
            .key;
        if (warehouseIdFilter.isEmpty) warehouseIdFilter = null;
      }

      // GỌI DATABASE FUNCTION thay vì query toàn bộ products
      final salesSummaryResponse = await widget.tenantClient.rpc(
        'get_sales_summary',
        params: {
          'p_start_date': startDate.toIso8601String(),
          'p_end_date': endDate.toIso8601String(),
          'p_category_id': _selectedCategoryId,
          'p_warehouse_id': warehouseIdFilter,
        },
      );

      double totalRev = 0;
      double totalProfit = 0;
      int soldCount = 0;
      
      if (salesSummaryResponse != null && salesSummaryResponse is List && salesSummaryResponse.isNotEmpty) {
        final summary = salesSummaryResponse[0];
        totalRev = (summary['total_revenue'] as num?)?.toDouble() ?? 0.0;
        totalProfit = (summary['total_profit'] as num?)?.toDouble() ?? 0.0;
        soldCount = (summary['sold_count'] as num?)?.toInt() ?? 0;
      }

      final categories = Map.fromEntries(
        (categoriesResponse as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .map((c) => MapEntry(c['id'] as int, c['name'] as String)),
      );

      final exchangeRateResponse = await widget.tenantClient
          .from('financial_orders')
          .select('rate_vnd_cny, rate_vnd_usd')
          .eq('type', 'exchange')
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();

      double rateVndCny = 1.0;
      double rateVndUsd = 1.0;
      if (exchangeRateResponse != null) {
        rateVndCny = (exchangeRateResponse['rate_vnd_cny'] as num?)?.toDouble() ?? 1.0;
        rateVndUsd = (exchangeRateResponse['rate_vnd_usd'] as num?)?.toDouble() ?? 1.0;
      }

      final financialOrders = await widget.tenantClient
          .from('financial_orders')
          .select('type, amount, created_at, currency')
          .gte('created_at', startDate.toIso8601String())
          .lte('created_at', endDate.toIso8601String());

      final acc = await widget.tenantClient.from('financial_accounts').select();
      setState(() {
        accounts = List<Map<String, dynamic>>.from(acc);
      });

      // Ensure financeOrder includes account ids if needed
      _ensureFinanceOrderIncludesAccounts();

      double totalAccountBalance = 0;
      for (final account in accounts) {
        final balanceRaw = account['balance'];
        final balance = balanceRaw is String ? num.tryParse(balanceRaw)?.toDouble() ?? 0.0 : (balanceRaw as num?)?.toDouble() ?? 0.0;
        final currency = account['currency']?.toString() ?? 'VND';
        if (currency == 'VND') {
          totalAccountBalance += balance;
        } else if (currency == 'CNY') {
          totalAccountBalance += balance * rateVndCny;
        } else if (currency == 'USD') {
          totalAccountBalance += balance * rateVndUsd;
        }
      }

      // GỌI DATABASE FUNCTION để tính inventory cost
      final inventoryCostResponse = await widget.tenantClient.rpc(
        'get_inventory_cost_summary',
        params: {
          'p_category_id': _selectedCategoryId,
          'p_warehouse_id': warehouseIdFilter,
        },
      );

      double totalInventoryCostValue = 0;
      if (inventoryCostResponse != null && inventoryCostResponse is List && inventoryCostResponse.isNotEmpty) {
        final summary = inventoryCostResponse[0];
        totalInventoryCostValue = (summary['total_inventory_cost'] as num?)?.toDouble() ?? 0.0;
      }

      double totalCustomerDebtValue = 0;
      final customers = await widget.tenantClient.from('customers').select('debt_vnd, debt_cny, debt_usd');
      for (final customer in customers) {
        final debtVnd = (customer['debt_vnd'] as num?)?.toDouble() ?? 0.0;
        final debtCny = (customer['debt_cny'] as num?)?.toDouble() ?? 0.0;
        final debtUsd = (customer['debt_usd'] as num?)?.toDouble() ?? 0.0;
        totalCustomerDebtValue += debtVnd + (debtCny * rateVndCny) + (debtUsd * rateVndUsd);
      }

      double totalSupplierDebtValue = 0;
      final suppliers = await widget.tenantClient.from('suppliers').select('debt_vnd, debt_cny, debt_usd');
      for (final supplier in suppliers) {
        final debtVnd = (supplier['debt_vnd'] as num?)?.toDouble() ?? 0.0;
        final debtCny = (supplier['debt_cny'] as num?)?.toDouble() ?? 0.0;
        final debtUsd = (supplier['debt_usd'] as num?)?.toDouble() ?? 0.0;
        totalSupplierDebtValue += debtVnd + (debtCny * rateVndCny) + (debtUsd * rateVndUsd);
      }

      double totalFixerDebtValue = 0;
      final fixers = await widget.tenantClient.from('fix_units').select('debt_vnd, debt_cny, debt_usd');
      for (final fixer in fixers) {
        final debtVnd = (fixer['debt_vnd'] as num?)?.toDouble() ?? 0.0;
        final debtCny = (fixer['debt_cny'] as num?)?.toDouble() ?? 0.0;
        final debtUsd = (fixer['debt_usd'] as num?)?.toDouble() ?? 0.0;
        totalFixerDebtValue += debtVnd + (debtCny * rateVndCny) + (debtUsd * rateVndUsd);
      }

      double totalTransporterDebtValue = 0;
      final transporters = await widget.tenantClient.from('transporters').select('debt');
      for (final transporter in transporters) {
        final debt = (transporter['debt'] as num?)?.toDouble() ?? 0.0;
        totalTransporterDebtValue += debt;
      }

      // ✅ Tính hoa hồng nhân viên = tổng doanhso từ bảng sub_accounts
      double totalEmployeeCommissionValue = 0;
      try {
        final subAccounts = await widget.tenantClient.from('sub_accounts').select('doanhso');
        for (final account in subAccounts) {
          final doanhso = (account['doanhso'] as num?)?.toInt() ?? 0;
          totalEmployeeCommissionValue += doanhso.toDouble();
        }
      } catch (e) {
        print('Error fetching employee commission: $e');
      }

      final timePoints = getTimePoints();
      timeLabels = timePoints.map((point) {
        if (_selectedTimeFilter == 'Hôm nay') {
          return DateFormat('HH').format(point);
        } else {
          return DateFormat('dd/MM').format(point);
        }
      }).toList();

      // GỌI DATABASE FUNCTION để lấy time series data cho biểu đồ
      final timeSeriesResponse = await widget.tenantClient.rpc(
        'get_time_series_data',
        params: {
          'p_time_points': timePoints.map((t) => t.toIso8601String()).toList(),
          'p_category_id': _selectedCategoryId,
          'p_warehouse_id': warehouseIdFilter,
        },
      );

      Map<int, double> revenueMap = {};
      Map<int, double> profitMap = {};
      
      if (timeSeriesResponse != null && timeSeriesResponse is List) {
        for (final point in timeSeriesResponse) {
          final pointIndex = (point['point_index'] as num?)?.toInt() ?? 0;
          final revenue = (point['revenue'] as num?)?.toDouble() ?? 0.0;
          final profit = (point['profit'] as num?)?.toDouble() ?? 0.0;
          revenueMap[pointIndex] = revenue;
          profitMap[pointIndex] = profit;
        }
      }

      Map<int, double> incomeMap = {};
      Map<int, double> expenseMap = {};
      double totalInc = 0;
      double totalExp = 0;

      double totalCostValue = 0;
      
      for (final transaction in financialOrders) {
        final amountRaw = transaction['amount'];
        final amount = amountRaw is String ? num.tryParse(amountRaw)?.toDouble() ?? 0.0 : (amountRaw as num?)?.toDouble() ?? 0.0;
        final currency = transaction['currency']?.toString() ?? 'VND';
        final dt = DateTime.tryParse(transaction['created_at']?.toString() ?? '');
        final type = transaction['type']?.toString().toLowerCase() ?? '';

        double amountInVnd = amount;
        if (currency == 'CNY') {
          amountInVnd = amount * rateVndCny;
        } else if (currency == 'USD') {
          amountInVnd = amount * rateVndUsd;
        }

        if (dt != null) {
          if (type == 'receive') {
            totalInc += amountInVnd;
          } else if (type == 'payment') {
            totalExp += amountInVnd;
          } else if (type == 'cost') {
            totalCostValue += amountInVnd;
          }

          int pointIndex = -1;
          if (_selectedTimeFilter == 'Hôm nay') {
            for (int i = 0; i < timePoints.length - 1; i++) {
              if (dt.isAfter(timePoints[i]) && (dt.isBefore(timePoints[i + 1]) || dt.isAtSameMomentAs(timePoints[i + 1]))) {
                pointIndex = i;
                break;
              }
            }
            if (pointIndex == -1) {
              if (dt.isBefore(timePoints[0])) {
                pointIndex = 0;
              } else if (dt.isAfter(timePoints.last) || dt.isAtSameMomentAs(timePoints.last)) pointIndex = timePoints.length - 1;
            }
          } else {
            for (int i = 0; i < timePoints.length - 1; i++) {
              final nextPoint = i == timePoints.length - 2 ? endDate : timePoints[i + 1];
              if (dt.isAfter(timePoints[i]) && (dt.isBefore(nextPoint) || dt.isAtSameMomentAs(nextPoint))) {
                pointIndex = i;
                break;
              }
            }
            if (pointIndex == -1) {
              if (dt.isBefore(timePoints[0])) {
                pointIndex = 0;
              } else if (dt.isAfter(timePoints.last) || dt.isAtSameMomentAs(timePoints.last)) pointIndex = timePoints.length - 1;
            }
          }

          if (pointIndex != -1) {
            if (type == 'receive') {
              incomeMap[pointIndex] = (incomeMap[pointIndex] ?? 0) + amountInVnd;
            } else if (type == 'payment') {
              expenseMap[pointIndex] = (expenseMap[pointIndex] ?? 0) + amountInVnd;
            }
          }
        }
      }

      // GỌI DATABASE FUNCTION để lấy stock summary
      final stockSummaryResponse = await widget.tenantClient.rpc(
        'get_stock_summary',
        params: {
          'p_category_id': _selectedCategoryId,
          'p_warehouse_id': warehouseIdFilter,
        },
      );

      Map<String, Map<String, int>> stock = {};
      if (stockSummaryResponse != null && stockSummaryResponse is List) {
        for (final item in stockSummaryResponse) {
          final status = item['status']?.toString() ?? '';
          final categoryId = item['category_id'] as int?;
          final productCount = (item['product_count'] as num?)?.toInt() ?? 0;
          
          if (status.isEmpty || categoryId == null) continue;

          final categoryName = categories[categoryId] ?? 'Không xác định';
          final categoryShort = categoryName == 'điện thoại' ? 'ĐT' : categoryName == 'phụ kiện' ? 'PK' : categoryName;

          stock[status] ??= {};
          stock[status]![categoryShort] = (stock[status]![categoryShort] ?? 0) + productCount;
        }
      }

      setState(() {
        revenue = totalRev;
        profit = totalProfit;
        totalCost = totalCostValue;
        profitAfterCost = totalProfit - totalCostValue;
        totalIncome = totalInc;
        totalExpense = totalExp;
        totalSupplierDebt = totalSupplierDebtValue;
        totalCustomerDebt = totalCustomerDebtValue;
        totalFixerDebt = totalFixerDebtValue;
        totalTransporterDebt = totalTransporterDebtValue;
        totalInventoryCost = totalInventoryCostValue;
        totalEmployeeCommission = totalEmployeeCommissionValue;
        soldProductsCount = soldCount;
        stockData = stock;

        revenueSpots = List.generate(timeLabels.length, (i) => FlSpot(i.toDouble(), revenueMap[i] ?? 0));
        profitSpots = List.generate(timeLabels.length, (i) => FlSpot(i.toDouble(), profitMap[i] ?? 0));
        incomeSpots = List.generate(timeLabels.length, (i) => FlSpot(i.toDouble(), incomeMap[i] ?? 0));
        expenseSpots = List.generate(timeLabels.length, (i) => FlSpot(i.toDouble(), expenseMap[i] ?? 0));

        // ✅ Giá trị công ty mới = giá trị công ty hiện tại - hoa hồng nhân viên
        final baseCompanyValue = totalAccountBalance +
            totalInventoryCost +
            totalCustomerDebt -
            (totalSupplierDebt + totalFixerDebt + totalTransporterDebt);
        companyValue = baseCompanyValue - totalEmployeeCommissionValue;

        if (selectedStatus != null && !stockData.containsKey(selectedStatus)) {
          selectedStatus = null;
        }
      });

      await fetchProductDistribution(selectedStatus);
    } catch (e) {
      print('Error fetching data: $e');
      setState(() {
        revenue = 0;
        profit = 0;
        profitAfterCost = 0;
        totalCost = 0;
        soldProductsCount = 0;
        companyValue = 0;
      });
    }
  }

  // Ensure financeOrder contains account:<id> entries for existing accounts
  void _ensureFinanceOrderIncludesAccounts() {
    final accountIds = accounts.map((a) => 'account:${a['id'] ?? a['name'] ?? accounts.indexOf(a)}').toList();
    // If financeOrder is empty (not loaded), set defaults
    if (financeOrder.isEmpty) financeOrder = List.from(_financeDefaultOrder);
    // Replace placeholder 'accounts_section' with actual accounts if present in order
    if (!financeOrder.contains('accounts_section')) {
      // if saved order has explicit accounts, keep them; otherwise insert placeholder
      financeOrder.insert(0, 'accounts_section');
    }
    // Build new list: start with saved financeOrder except we will expand accounts_section into actual accounts
    List<String> expanded = [];
    for (final id in financeOrder) {
      if (id == 'accounts_section') {
        // append accounts preserving any saved account order that matches
        // find saved account ids in financeOrder (those starting with 'account:')
        final savedAccounts = financeOrder.where((x) => x.startsWith('account:')).toList();
        if (savedAccounts.isNotEmpty) {
          // keep saved existing ones first
          for (final sa in savedAccounts) {
            if (accountIds.contains(sa)) expanded.add(sa);
          }
          // then add any missing accounts
          for (final aid in accountIds) {
            if (!expanded.contains(aid)) expanded.add(aid);
          }
        } else {
          expanded.addAll(accountIds);
        }
      } else if (id.startsWith('account:')) {
        // skip here because handled in accounts_section expansion
        continue;
      } else {
        expanded.add(id);
      }
    }
    // Remove duplicates while preserving order
    final seen = <String>{};
    final deduped = <String>[];
    for (final e in expanded) {
      if (!seen.contains(e)) {
        seen.add(e);
        deduped.add(e);
      }
    }
    financeOrder = deduped;
    // Finally save to prefs
    _saveFinanceOrder();
  }

  Future<void> fetchProductDistribution(String? status) async {
    try {
      // Lấy warehouse_id nếu có filter
      String? warehouseIdFilter;
      if (_selectedWarehouse != 'Tất cả chi nhánh') {
        warehouseIdFilter = CacheUtil.warehouseNameCache.entries
            .firstWhere((entry) => entry.value == _selectedWarehouse, orElse: () => MapEntry('', ''))
            .key;
        if (warehouseIdFilter.isEmpty) warehouseIdFilter = null;
      }

      // GỌI DATABASE FUNCTION để lấy product distribution
      final productDistResponse = await widget.tenantClient.rpc(
        'get_product_distribution',
        params: {
          'p_status': status,
          'p_category_id': _selectedCategoryId,
          'p_warehouse_id': warehouseIdFilter,
        },
      );

      // Dùng product_id làm key chính, sau đó đối chiếu để hiển thị tên sản phẩm
      Map<String, int> productCounts = {};
      if (productDistResponse != null && productDistResponse is List) {
        for (final product in productDistResponse) {
          final productId = product['product_id']?.toString();
          if (productId == null || productId.isEmpty) continue;
          final productCount = (product['product_count'] as num?)?.toInt() ?? 0;
          // Dùng product_id làm key thay vì productName
          productCounts[productId] = (productCounts[productId] ?? 0) + productCount;
        }
      }

      // Sort theo tên sản phẩm (lấy từ cache) nhưng vẫn dùng product_id làm key
      List<MapEntry<String, int>> sortedProducts = productCounts.entries.toList()
        ..sort((a, b) {
          final nameA = CacheUtil.getProductName(a.key);
          final nameB = CacheUtil.getProductName(b.key);
          return nameA.compareTo(nameB);
        });

      List<Map<String, dynamic>> distribution = [];
      int index = 0;
      for (var entry in sortedProducts) {
        // Lấy tên sản phẩm từ cache dựa vào product_id
        final productName = CacheUtil.getProductName(entry.key);
        distribution.add({
          'product_id': entry.key, // Lưu product_id để tham chiếu sau này nếu cần
          'name': productName, // Hiển thị tên sản phẩm
          'count': entry.value,
          'color': chartColors[index % chartColors.length],
        });
        index++;
      }

      setState(() {
        productDistribution = distribution;
      });
    } catch (e) {
      print('Error fetching product distribution: $e');
      setState(() {
        productDistribution = [];
      });
    }
  }

  String formatMoney(num value, {String currency = 'VND'}) {
    if (currency == 'CNY' || currency == 'USD') {
      return NumberFormat('#,###', 'vi_VN').format(value);
    }
    // VND: chỉ dùng hàng nghìn (k), không dùng hàng triệu (tr)
    // Đảm bảo value là số hợp lệ
    final doubleValue = value.toDouble();
    if (doubleValue.isNaN || doubleValue.isInfinite) {
      return '0';
    }
    // Làm tròn về số nguyên để tránh vấn đề với số thập phân
    final roundedValue = doubleValue.roundToDouble();
    final absValue = roundedValue.abs();
    // Luôn format theo hàng nghìn nếu >= 1000
    // Sử dụng so sánh với epsilon để tránh vấn đề với floating point
    if (absValue - 1000.0 >= -0.0001) {
      final thousands = (roundedValue / 1000.0).round();
      // Format với dấu chấm phân cách hàng nghìn
      // Sử dụng NumberFormat với pattern '#,###' và thay dấu phẩy bằng dấu chấm
      final formatted = NumberFormat('#,###', 'vi_VN').format(thousands.abs()).replaceAll(',', '.');
      return thousands < 0 ? '-$formatted k' : '$formatted k';
    } else {
      return roundedValue.toStringAsFixed(0);
    }
  }

  String formatStock(String status, Map<String, int> categories) {
    final dtCount = categories['ĐT'] ?? 0;
    final pkCount = categories['PK'] ?? 0;
    if (dtCount > 0 && pkCount > 0) {
      return '$dtCount ĐT | $pkCount PK';
    } else if (dtCount > 0) {
      return '$dtCount ĐT';
    } else if (pkCount > 0) {
      return '$pkCount PK';
    }
    return '0';
  }

  Widget _buildHeaderTile(String label, String value, Color color, {VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: TextStyle(fontSize: 16, color: color, fontWeight: FontWeight.bold)),
            Text(value, style: TextStyle(fontSize: 16, color: color)),
          ],
        ),
      ),
    );
  }

  Widget _buildLineChart(String title, List<FlSpot> spots1, Color color1, {List<FlSpot>? spots2, Color? color2}) {
    if ((spots1.isEmpty || spots1.every((spot) => spot.y == 0)) &&
        (spots2 == null || spots2.isEmpty || spots2.every((spot) => spot.y == 0))) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(child: Text('Không có dữ liệu để hiển thị $title', style: const TextStyle(color: Colors.grey))),
      );
    }

    double maxY = spots1.map((e) => e.y).fold(0.0, (a, b) => max(a, b));
    double minY = spots1.map((e) => e.y).fold(0.0, (a, b) => a < b ? a : b);
    if (spots2 != null) {
      maxY = max(maxY, spots2.map((e) => e.y).fold(0.0, (a, b) => max(a, b)));
      minY = min(minY, spots2.map((e) => e.y).fold(0.0, (a, b) => a < b ? a : b));
    }
    
    // Nếu tất cả giá trị đều >= 0, đặt minY = 0 (trục ngang)
    if (minY >= 0) {
      minY = 0;
      maxY = maxY * 1.2; // Thêm padding phía trên
    } else {
      // Nếu có giá trị âm, thêm padding cho cả 2 phía
      final yRange = maxY - minY;
      maxY = maxY + (yRange * 0.1);
      minY = minY - (yRange * 0.1);
    }
    
    if (maxY == minY) maxY = minY + 100000;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
        AspectRatio(
          aspectRatio: 1.6,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: LineChart(
              LineChartData(
                maxY: maxY,
                minY: minY,
                clipData: const FlClipData.all(),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots1,
                    isCurved: true,
                    color: color1,
                    barWidth: 2,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(show: false),
                    preventCurveOverShooting: true,
                  ),
                  if (spots2 != null && color2 != null)
                    LineChartBarData(
                      spots: spots2,
                      isCurved: true,
                      color: color2,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(show: false),
                      preventCurveOverShooting: true,
                    ),
                ],
                titlesData: FlTitlesData(
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: (maxY - minY) / 5,
                      reservedSize: 45,
                      getTitlesWidget: (val, _) {
                        return Text(formatMoney(val), style: const TextStyle(fontSize: 10));
                      },
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: 1,
                      getTitlesWidget: (val, _) {
                        int idx = val.toInt();
                        if (idx >= 0 && idx < timeLabels.length) {
                          return Text(timeLabels[idx], style: const TextStyle(fontSize: 10));
                        }
                        return const Text('');
                      },
                    ),
                  ),
                  topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                ),
                borderData: FlBorderData(show: true),
                gridData: const FlGridData(show: true),
                lineTouchData: LineTouchData(
                  getTouchedSpotIndicator: (LineChartBarData barData, List<int> spotIndexes) {
                    final barColor = barData.color ?? Colors.blue;
                    return spotIndexes.map((index) {
                      return TouchedSpotIndicatorData(
                        FlLine(color: barColor, strokeWidth: 2),
                        FlDotData(
                          getDotPainter: (spot, percent, barData, index) => FlDotCirclePainter(
                            radius: 6,
                            color: barColor,
                            strokeWidth: 2,
                            strokeColor: Colors.white,
                          ),
                        ),
                      );
                    }).toList();
                  },
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipItems: (List<LineBarSpot> touchedSpots) {
                      return touchedSpots.map((LineBarSpot touchedSpot) {
                        final value = touchedSpot.y;
                        final formattedValue = NumberFormat('#,###', 'vi_VN').format(value.round()).replaceAll(',', '.');
                        final barColor = touchedSpot.bar.color ?? Colors.blue;
                        return LineTooltipItem(
                          '$formattedValue VND',
                          TextStyle(
                            color: barColor,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        );
                      }).toList();
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPieChart() {
    if (productDistribution.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(child: Text('Không có dữ liệu để hiển thị', style: TextStyle(color: Colors.grey))),
      );
    }

    return Column(
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: PieChart(
            PieChartData(
              sections: productDistribution.map((data) {
                return PieChartSectionData(
                  value: data['count'].toDouble(),
                  color: data['color'],
                  radius: 80,
                  title: '${data['count']}',
                  titleStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                );
              }).toList(),
              sectionsSpace: 2,
              centerSpaceRadius: 40,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            children: productDistribution.map((data) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Container(
                      width: 16,
                      height: 16,
                      color: data['color'],
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${data['name']} : ${data['count']}sp',
                      style: const TextStyle(fontSize: 14),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  // Helper to build a business tile by id (used for reorderable list)
  Widget _businessTileForId(String id) {
    switch (id) {
      case 'company_value':
        if (!widget.permissions.contains('view_company_value')) return const SizedBox.shrink();
        return _buildHeaderTile('Giá trị công ty', '${formatMoney(companyValue)} VND', Colors.purple);
      case 'employee_commission':
        if (!widget.permissions.contains('view_company_value')) return const SizedBox.shrink();
        return _buildHeaderTile('Hoa hồng nhân viên', '${formatMoney(totalEmployeeCommission)} VND', Colors.teal);
      case 'sales':
        return _buildHeaderTile('Doanh số', '$soldProductsCount sp / ${formatMoney(revenue)} VND', Colors.green);
      case 'profit':
        if (!widget.permissions.contains('view_profit')) return const SizedBox.shrink();
        return _buildHeaderTile('Lợi nhuận', '${formatMoney(profit)} VND', Colors.orange);
      case 'cost':
        if (!widget.permissions.contains('view_profit')) return const SizedBox.shrink();
        return _buildHeaderTile('Chi phí', '${formatMoney(totalCost)} VND', Colors.red);
      case 'profit_after_cost':
        if (!widget.permissions.contains('view_profit')) return const SizedBox.shrink();
        return _buildHeaderTile('Lợi nhuận sau chi phí', '${formatMoney(profitAfterCost)} VND', profitAfterCost >= 0 ? Colors.blue : Colors.red);
      case 'chart_business':
        return _buildLineChart('Doanh số và lợi nhuận theo thời gian', revenueSpots, Colors.green, spots2: profitSpots, color2: Colors.orange);
      default:
        return const SizedBox.shrink();
    }
  }

  // Helper to build a finance tile by id (used for reorderable list)
  Widget _financeTileForId(String id) {
    if (id.startsWith('account:')) {
      final accId = id.split(':').elementAt(1);
      final acc = accounts.firstWhere((a) => (a['id']?.toString() ?? a['name']?.toString() ?? '') == accId, orElse: () => {});
      if (acc.isEmpty) return const SizedBox.shrink();
      final currency = acc['currency']?.toString() ?? 'VND';
      final balance = (acc['balance'] is String ? num.tryParse(acc['balance'])?.toDouble() : (acc['balance'] as num?)?.toDouble()) ?? 0.0;
      return _buildHeaderTile(
        acc['name'] ?? 'Tài khoản',
        '${formatMoney(balance, currency: currency)} $currency',
        Colors.blue,
      );
    }
    switch (id) {
      case 'supplier_debt':
        return _buildHeaderTile('Công nợ nhà cung cấp', '${formatMoney(totalSupplierDebt)} VND', Colors.orange);
      case 'customer_debt':
        return _buildHeaderTile('Công nợ khách hàng', '${formatMoney(totalCustomerDebt)} VND', Colors.orange);
      case 'fixer_debt':
        return _buildHeaderTile('Công nợ đơn vị fix lỗi', '${formatMoney(totalFixerDebt)} VND', Colors.orange);
      case 'transporter_debt':
        return _buildHeaderTile('Công nợ đơn vị vận chuyển', '${formatMoney(totalTransporterDebt)} VND', Colors.orange);
      case 'inventory_cost':
        return _buildHeaderTile('Tổng tiền hàng tồn', '${formatMoney(totalInventoryCost)} VND', Colors.purple);
      case 'total_income':
        return _buildHeaderTile('Tổng thu', '${formatMoney(totalIncome)} VND', Colors.green);
      case 'total_expense':
        return _buildHeaderTile('Tổng chi', '${formatMoney(totalExpense)} VND', Colors.red);
      case 'chart_finance':
        return _buildLineChart('Tổng thu và chi theo thời gian', incomeSpots, Colors.green, spots2: expenseSpots, color2: Colors.red);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildBusinessTab() {
    // Filter businessOrder to available ids given permissions
    final visibleIds = businessOrder.where((id) {
      if (id == 'company_value' || id == 'employee_commission') return widget.permissions.contains('view_company_value');
      if (id == 'profit' || id == 'cost' || id == 'profit_after_cost') return widget.permissions.contains('view_profit');
      return true;
    }).toList();

    return RefreshIndicator(
      onRefresh: fetchAllData,
      child: Column(
        children: [
          _buildTimeFilter(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey),
                borderRadius: BorderRadius.circular(4),
              ),
              child: DropdownButtonFormField<String>(
                value: _selectedWarehouse,
                hint: const Text('Chi nhánh'),
                items: _warehouseOptions.map((option) {
                  return DropdownMenuItem(
                    value: option,
                    child: Text(option),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedWarehouse = value;
                  });
                  fetchAllData();
                },
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                ),
              ),
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.only(bottom: 16),
              onReorder: (oldIndex, newIndex) async {
                // Map visible index to businessOrder index
                final movedId = visibleIds[oldIndex];
                final targetId = (newIndex > oldIndex) ? visibleIds[newIndex - 1] : (newIndex < visibleIds.length ? visibleIds[newIndex] : null);
                // Update businessOrder by removing movedId and inserting before targetId (or at end)
                setState(() {
                  businessOrder.remove(movedId);
                  if (targetId == null) {
                    businessOrder.add(movedId);
                  } else {
                    final insertIdx = businessOrder.indexOf(targetId);
                    businessOrder.insert(insertIdx, movedId);
                  }
                });
                await _saveBusinessOrder();
              },
              itemCount: visibleIds.length,
              itemBuilder: (context, index) {
                final id = visibleIds[index];
                final tile = _businessTileForId(id);
                return Container(
                  key: ValueKey(id),
                  child: tile,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFinanceTab() {
    // Build visible finance ids based on current accounts and permissions
    final visibleIds = financeOrder.where((id) {
      if (id.startsWith('account:')) {
        final accId = id.split(':').elementAt(1);
        return accounts.any((a) => (a['id']?.toString() ?? a['name']?.toString() ?? '') == accId);
      }
      // non-account tiles always visible (some may be guarded by permissions in original code; keep same visibility)
      return true;
    }).toList();

    return RefreshIndicator(
      onRefresh: fetchAllData,
      child: Column(
        children: [
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.only(bottom: 16),
              onReorder: (oldIndex, newIndex) async {
                final movedId = visibleIds[oldIndex];
                setState(() {
                  financeOrder.remove(movedId);
                  if (newIndex >= visibleIds.length) {
                    financeOrder.add(movedId);
                  } else {
                    final targetId = visibleIds[newIndex];
                    final insertIdx = financeOrder.indexOf(targetId);
                    financeOrder.insert(insertIdx, movedId);
                  }
                });
                await _saveFinanceOrder();
              },
              itemCount: visibleIds.length,
              itemBuilder: (context, index) {
                final id = visibleIds[index];
                final tile = _financeTileForId(id);
                return Container(
                  key: ValueKey(id),
                  child: tile,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInventoryTab() {
    List<Widget> stockWidgets = [];
    final statuses = stockData.keys.toList();

    for (final status in statuses) {
      final categories = stockData[status] ?? {};
      stockWidgets.add(
        _buildHeaderTile(
          status,
          formatStock(status, categories),
          Colors.blue,
          onTap: () async {
            setState(() {
              selectedStatus = status;
            });
            await fetchProductDistribution(status);
          },
        ),
      );
    }

    if (stockWidgets.isEmpty) {
      stockWidgets.add(
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Center(child: Text('Không có dữ liệu hàng hóa', style: TextStyle(color: Colors.grey))),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async {
        await fetchAllData();
        await fetchProductDistribution(selectedStatus);
      },
      child: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                _buildCategoryFilter(),
                _buildWarehouseFilter(),
              ],
            ),
          ),
          ...stockWidgets,
          _buildPieChart(),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: widget.permissions.contains('view_finance') ? 3 : 2,
      child: Scaffold(
        appBar: AppBar(
          iconTheme: const IconThemeData(color: Colors.white),
          title: const Text('Tổng quan', style: TextStyle(color: Colors.white)),
          backgroundColor: Colors.black,
          bottom: TabBar(
            controller: _tabController,
            labelColor: Colors.amber,
            unselectedLabelColor: Colors.white70,
            indicatorColor: Colors.amber,
            tabs: [
              const Tab(text: 'Hiệu quả'),
              const Tab(text: 'Hàng hóa'),
              if (widget.permissions.contains('view_finance')) const Tab(text: 'Tài chính'),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tabController,
          children: [
            _buildBusinessTab(),
            _buildInventoryTab(),
            if (widget.permissions.contains('view_finance')) _buildFinanceTab(),
          ],
        ),
      ),
    );
  }
}