import 'package:flutter/material.dart' hide Border, BorderStyle;
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:excel/excel.dart';
import 'package:open_file/open_file.dart';
import 'dart:io';
import 'dart:async';
import 'dart:developer' as developer;
import '../helpers/export_progress_dialog.dart';
import '../helpers/error_handler.dart';
import '../helpers/storage_helper.dart';
import '../helpers/excel_style_helper.dart';

// Cache utility class
class CacheUtil {
  static final Map<String, String> productNameCache = {};
  static final Map<String, String> warehouseNameCache = {};

  static void cacheProductName(String id, String name) => productNameCache[id] = name;
  static void cacheWarehouseName(String id, String name) => warehouseNameCache[id] = name;
  static String getProductName(String? id) => id != null ? productNameCache[id] ?? 'Không xác định' : 'Không xác định';
  static String getWarehouseName(String? id) => id != null ? warehouseNameCache[id] ?? 'Không xác định' : 'Không xác định';
}

// Hàm định dạng số với dấu phân cách hàng nghìn
String formatNumber(num? amount) {
  if (amount == null) return '0';
  return NumberFormat.decimalPattern('vi_VN').format(amount);
}

// Hàm định dạng ngày từ ISO 8601 sang dd-MM-yyyy
String formatDate(String? dateStr) {
  if (dateStr == null) return '';
  try {
    final parsedDate = DateTime.parse(dateStr);
    return DateFormat('dd-MM-yyyy').format(parsedDate);
  } catch (e) {
    return dateStr;
  }
}

// Widget hiển thị text có thể copy khi bấm giữ
class CopyableText extends StatelessWidget {
  final String label;
  final String value;

  const CopyableText({
    super.key,
    required this.label,
    required this.value,
  });

  void _showCopyNotification(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle, color: Colors.green, size: 24),
                SizedBox(width: 12),
                Text(
                  'Đã sao chép vào clipboard',
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    
    Future.delayed(const Duration(milliseconds: 1000), () {
      if (context.mounted) {
        Navigator.of(context).pop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: () {
        if (value.isNotEmpty) {
          Clipboard.setData(ClipboardData(text: value));
          _showCopyNotification(context);
        }
      },
      child: Text('$label: $value'),
    );
  }
}

class CustomersScreen extends StatefulWidget {
  final List<String> permissions;
  final SupabaseClient tenantClient;

  const CustomersScreen({
    super.key,
    required this.permissions,
    required this.tenantClient,
  });

  @override
  _CustomersScreenState createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  String searchText = '';
  String sortOption = 'name-asc';
  List<Map<String, dynamic>> customers = [];
  List<Map<String, dynamic>> searchResults = [];
  bool isLoading = true;
  bool isSearching = false;
  String? errorMessage;
  int pageSize = 30;
  int currentPage = 0;
  bool hasMoreData = true;
  bool isLoadingMore = false;
  final ScrollController _scrollController = ScrollController();
  Timer? _debounce;
  Map<String, DateTime?> latestOrderDateCache = {};
  bool isLoadingLatestDates = false;

  @override
  void initState() {
    super.initState();
    _fetchCustomers();

    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
              _scrollController.position.maxScrollExtent - 200 &&
          !isLoadingMore &&
          hasMoreData &&
          searchText.isEmpty) {
        _loadMoreCustomers();
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _fetchCustomers() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
      customers = [];
      searchResults = [];
      currentPage = 0;
      hasMoreData = true;
    });

    try {
      // Fetch product name cache
      final productResponse = await widget.tenantClient.from('products_name').select('id, products');
      developer.log('Loaded ${productResponse.length} products into CacheUtil');
      for (var product in productResponse) {
        CacheUtil.cacheProductName(product['id'].toString(), product['products'] as String);
      }

      // Fetch warehouse name cache
      final warehouseResponse = await widget.tenantClient.from('warehouses').select('id, name');
      developer.log('Loaded ${warehouseResponse.length} warehouses into CacheUtil');
      for (var warehouse in warehouseResponse) {
        CacheUtil.cacheWarehouseName(warehouse['id'].toString(), warehouse['name'] as String);
      }

      await _loadMoreCustomers();
    } catch (e) {
      setState(() {
        errorMessage = 'Không thể tải dữ liệu từ Supabase: $e';
        isLoading = false;
      });
    }
  }

  Future<void> _loadMoreCustomers() async {
    if (!hasMoreData || isLoadingMore) return;

    setState(() {
      isLoadingMore = true;
    });

    try {
      final start = currentPage * pageSize;
      final end = start + pageSize - 1;

      final response = await widget.tenantClient
          .from('customers')
          .select()
          .range(start, end);

      final newCustomers = (response as List<dynamic>).cast<Map<String, dynamic>>();

      setState(() {
        customers.addAll(newCustomers);
        if (newCustomers.length < pageSize) {
          hasMoreData = false;
        }
        currentPage++;
        isLoading = false;
        isLoadingMore = false;
      });
    } catch (e) {
      setState(() {
        errorMessage = 'Không thể tải thêm khách hàng: $e';
        isLoadingMore = false;
      });
    }
  }

  Future<void> _searchCustomers(String query) async {
    if (query.isEmpty) {
      setState(() {
        searchResults = [];
        isSearching = false;
      });
      return;
    }

    setState(() {
      isSearching = true;
      errorMessage = null;
    });

    try {
      final response = await widget.tenantClient
          .from('customers')
          .select()
          .or('name.ilike.%$query%,phone.ilike.%$query%');

      setState(() {
        searchResults = (response as List<dynamic>).cast<Map<String, dynamic>>();
        isSearching = false;
      });
    } catch (e) {
      setState(() {
        errorMessage = 'Không thể tìm kiếm khách hàng: $e';
        isSearching = false;
      });
    }
  }

  Future<DateTime?> _getLatestOrderDate(String customerId) async {
    try {
      final saleOrdersResponse = await widget.tenantClient
          .from('sale_orders')
          .select('created_at')
          .eq('customer_id', customerId)
          .eq('iscancelled', false)
          .order('created_at', ascending: false)
          .limit(1);

      final saleOrders = saleOrdersResponse as List<dynamic>;
      
      if (saleOrders.isNotEmpty) {
        final dateStr = saleOrders[0]['created_at']?.toString();
        if (dateStr != null && dateStr.isNotEmpty) {
          final date = DateTime.tryParse(dateStr);
          return date;
        }
      }

      return null;
    } catch (e) {
      developer.log('Error getting latest order date for customer $customerId: $e');
      return null;
    }
  }

  Future<void> _loadLatestOrderDates() async {
    if (isLoadingLatestDates) return;

    setState(() {
      isLoadingLatestDates = true;
      latestOrderDateCache.clear();
    });

    try {
      final customersWithDebt = (searchText.isNotEmpty ? searchResults : customers)
          .where((customer) {
            final debtVnd = customer['debt_vnd'] as num? ?? 0;
            final debtCny = customer['debt_cny'] as num? ?? 0;
            final debtUsd = customer['debt_usd'] as num? ?? 0;
            final totalDebt = debtVnd + debtCny + debtUsd;
            return totalDebt > 0;
          })
          .toList();

      for (final customer in customersWithDebt) {
        final customerId = customer['id']?.toString() ?? '';
        if (customerId.isNotEmpty) {
          final latestDate = await _getLatestOrderDate(customerId);
          latestOrderDateCache[customerId] = latestDate;
        }
      }
    } catch (e) {
      developer.log('Error loading latest order dates: $e');
    } finally {
      setState(() {
        isLoadingLatestDates = false;
      });
    }
  }

  List<Map<String, dynamic>> get filteredCustomers {
    var filtered = searchText.isNotEmpty ? searchResults : customers;

    if (sortOption == 'name-asc') {
      filtered.sort((a, b) => (a['name']?.toString() ?? '').compareTo(b['name']?.toString() ?? ''));
    } else if (sortOption == 'name-desc') {
      filtered.sort((a, b) => (b['name']?.toString() ?? '').compareTo(a['name']?.toString() ?? ''));
    } else if (sortOption == 'debt-desc') {
      filtered.sort((a, b) {
        final debtA = (a['debt_vnd'] as num? ?? 0) + (a['debt_cny'] as num? ?? 0) + (a['debt_usd'] as num? ?? 0);
        final debtB = (b['debt_vnd'] as num? ?? 0) + (b['debt_cny'] as num? ?? 0) + (b['debt_usd'] as num? ?? 0);
        return debtB.compareTo(debtA);
      });
    } else if (sortOption == 'debt-asc') {
      filtered.sort((a, b) {
        final debtA = (a['debt_vnd'] as num? ?? 0) + (a['debt_cny'] as num? ?? 0) + (a['debt_usd'] as num? ?? 0);
        final debtB = (b['debt_vnd'] as num? ?? 0) + (b['debt_cny'] as num? ?? 0) + (b['debt_usd'] as num? ?? 0);
        return debtA.compareTo(debtB);
      });
    } else if (sortOption == 'debt-oldest' || sortOption == 'debt-newest') {
      filtered = filtered.where((customer) {
        final debtVnd = customer['debt_vnd'] as num? ?? 0;
        final debtCny = customer['debt_cny'] as num? ?? 0;
        final debtUsd = customer['debt_usd'] as num? ?? 0;
        final totalDebt = debtVnd + debtCny + debtUsd;
        return totalDebt > 0;
      }).toList();

      filtered.sort((a, b) {
        final customerIdA = a['id']?.toString() ?? '';
        final customerIdB = b['id']?.toString() ?? '';
        final dateA = latestOrderDateCache[customerIdA];
        final dateB = latestOrderDateCache[customerIdB];

        if (dateA == null && dateB == null) return 0;
        if (dateA == null) return 1;
        if (dateB == null) return -1;

        if (sortOption == 'debt-oldest') {
          return dateA.compareTo(dateB);
        } else {
          return dateB.compareTo(dateA);
        }
      });
    }

    return filtered;
  }

  void _showCustomerDetails(Map<String, dynamic> customer) {
    showDialog(
      context: context,
      builder: (context) => CustomerDetailsDialog(
        customer: customer,
        tenantClient: widget.tenantClient,
      ),
    );
  }

  void _showEditCustomerDialog(Map<String, dynamic> customer) {
    showDialog(
      context: context,
      builder: (context) => EditCustomerDialog(
        customer: customer,
        onSave: (updatedCustomer) async {
          try {
            await widget.tenantClient
                .from('customers')
                .update({
                  'name': updatedCustomer['name'],
                  'phone': updatedCustomer['phone'],
                  'address': updatedCustomer['address'],
                  'social_link': updatedCustomer['social_link'],
                })
                .eq('id', customer['id']);

            setState(() {
              final index = customers.indexWhere((c) => c['id'] == customer['id']);
              if (index != -1) {
                customers[index] = {...customers[index], ...updatedCustomer};
              }
              final searchIndex = searchResults.indexWhere((c) => c['id'] == customer['id']);
              if (searchIndex != -1) {
                searchResults[searchIndex] = {...searchResults[searchIndex], ...updatedCustomer};
              }
            });

            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Đã cập nhật thông tin khách hàng')),
            );
          } catch (e) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Lỗi khi cập nhật: $e')),
            );
          }
        },
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
                onPressed: _fetchCustomers,
                child: const Text('Thử lại'),
              ),
            ],
          ),
        ),
      );
    }

    return GestureDetector(
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity != null && details.primaryVelocity! > 0) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: Colors.white),
          title: const Text('Khách Hàng', style: TextStyle(color: Colors.white)),
        ),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      decoration: InputDecoration(
                        labelText: 'Tìm kiếm khách hàng',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                      onChanged: (value) {
                        setState(() {
                          searchText = value;
                        });
                        if (_debounce?.isActive ?? false) _debounce!.cancel();
                        _debounce = Timer(const Duration(milliseconds: 300), () {
                          _searchCustomers(value);
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<String>(
                      decoration: InputDecoration(
                        labelText: 'Sắp xếp',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                      ),
                      isDense: true,
                      value: sortOption,
                      items: const [
                        DropdownMenuItem(value: 'name-asc', child: Text('Tên (A-Z)', overflow: TextOverflow.ellipsis)),
                        DropdownMenuItem(value: 'name-desc', child: Text('Tên (Z-A)', overflow: TextOverflow.ellipsis)),
                        DropdownMenuItem(value: 'debt-asc', child: Text('Công nợ thấp đến cao', overflow: TextOverflow.ellipsis)),
                        DropdownMenuItem(value: 'debt-desc', child: Text('Công nợ cao đến thấp', overflow: TextOverflow.ellipsis)),
                        DropdownMenuItem(value: 'debt-oldest', child: Text('Công nợ lâu nhất', overflow: TextOverflow.ellipsis)),
                        DropdownMenuItem(value: 'debt-newest', child: Text('Công nợ mới nhất', overflow: TextOverflow.ellipsis)),
                      ],
                      onChanged: (value) async {
                        final newSortOption = value ?? 'name-asc';
                        setState(() {
                          sortOption = newSortOption;
                        });
                        
                        if (newSortOption == 'debt-oldest' || newSortOption == 'debt-newest') {
                          await _loadLatestOrderDates();
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: isSearching
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.builder(
                        controller: _scrollController,
                        itemCount: filteredCustomers.length + (isLoadingMore && searchText.isEmpty ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == filteredCustomers.length && isLoadingMore && searchText.isEmpty) {
                            return const Center(child: CircularProgressIndicator());
                          }
                          final customer = filteredCustomers[index];
                          final debtVnd = customer['debt_vnd'] as num? ?? 0;
                          final debtCny = customer['debt_cny'] as num? ?? 0;
                          final debtUsd = customer['debt_usd'] as num? ?? 0;
                          final debtDetails = <String>[];
                          if (debtVnd != 0) debtDetails.add('${formatNumber(debtVnd)} VND');
                          if (debtCny != 0) debtDetails.add('${formatNumber(debtCny)} CNY');
                          if (debtUsd != 0) debtDetails.add('${formatNumber(debtUsd)} USD');
                          final debtText = debtDetails.isNotEmpty ? debtDetails.join(', ') : '0 VND';

                          return Card(
                            elevation: 2,
                            margin: const EdgeInsets.symmetric(vertical: 8),
                            child: ListTile(
                              title: Text(customer['name']?.toString() ?? ''),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('Điện thoại: ${customer['phone']?.toString() ?? ''}'),
                                  Text('Công nợ: $debtText'),
                                ],
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.edit, color: Colors.orange),
                                    onPressed: () => _showEditCustomerDialog(customer),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.visibility, color: Colors.blue),
                                    onPressed: () => _showCustomerDetails(customer),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class EditCustomerDialog extends StatefulWidget {
  final Map<String, dynamic> customer;
  final Function(Map<String, dynamic>) onSave;

  const EditCustomerDialog({super.key, required this.customer, required this.onSave});

  @override
  _EditCustomerDialogState createState() => _EditCustomerDialogState();
}

class _EditCustomerDialogState extends State<EditCustomerDialog> {
  late TextEditingController nameController;
  late TextEditingController phoneController;
  late TextEditingController addressController;
  late TextEditingController socialLinkController;

  @override
  void initState() {
    super.initState();
    nameController = TextEditingController(text: widget.customer['name']?.toString() ?? '');
    phoneController = TextEditingController(text: widget.customer['phone']?.toString() ?? '');
    addressController = TextEditingController(text: widget.customer['address']?.toString() ?? '');
    socialLinkController = TextEditingController(text: widget.customer['social_link']?.toString() ?? '');
  }

  @override
  void dispose() {
    nameController.dispose();
    phoneController.dispose();
    addressController.dispose();
    socialLinkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Sửa Thông Tin Khách Hàng'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Tên'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: phoneController,
              decoration: const InputDecoration(labelText: 'Số Điện Thoại'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: addressController,
              decoration: const InputDecoration(labelText: 'Địa Chỉ'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: socialLinkController,
              decoration: const InputDecoration(labelText: 'Link Mạng Xã Hội'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Hủy'),
        ),
        ElevatedButton(
          onPressed: () {
            if (nameController.text.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Tên không được để trống!')),
              );
              return;
            }
            final updatedCustomer = {
              'name': nameController.text,
              'phone': phoneController.text,
              'address': addressController.text,
              'social_link': socialLinkController.text,
            };
            widget.onSave(updatedCustomer);
            Navigator.pop(context);
          },
          child: const Text('Lưu'),
        ),
      ],
    );
  }
}

class CustomerDetailsDialog extends StatefulWidget {
  final Map<String, dynamic> customer;
  final SupabaseClient tenantClient;

  const CustomerDetailsDialog({
    super.key,
    required this.customer,
    required this.tenantClient,
  });

  @override
  _CustomerDetailsDialogState createState() => _CustomerDetailsDialogState();
}

class _CustomerDetailsDialogState extends State<CustomerDetailsDialog> {
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
      final customerId = widget.customer['id']?.toString().trim() ?? '';
      final customerName = widget.customer['name']?.toString().trim() ?? '';
      developer.log('Fetching transactions for customer: "$customerName" (id: $customerId)');

      final start = currentPage * pageSize;
      final end = start + pageSize - 1;

      dynamic saleOrdersQuery = widget.tenantClient
          .from('sale_orders')
          .select('id, product_id, imei, quantity, price, currency, created_at, account, note, customer_price, transporter_price, transporter, warehouse_id')
          .eq('customer_id', customerId)
          .eq('iscancelled', false);

      dynamic financialOrdersQuery = widget.tenantClient
          .from('financial_orders')
          .select('id, amount, currency, created_at, account, note, type')
          .eq('partner_type', 'customers')
          .eq('partner_id', customerId)
          .eq('iscancelled', false);

      dynamic reimportOrdersQuery = widget.tenantClient
          .from('reimport_orders')
          .select('id, product_id, imei, quantity, price, currency, created_at, account, note, warehouse_id')
          .eq('customer_id', customerId)
          .eq('iscancelled', false);

      // Add date filters if dates are selected
      if (startDate != null) {
        saleOrdersQuery = saleOrdersQuery.gte('created_at', startDate!.toIso8601String());
        financialOrdersQuery = financialOrdersQuery.gte('created_at', startDate!.toIso8601String());
        reimportOrdersQuery = reimportOrdersQuery.gte('created_at', startDate!.toIso8601String());
      }
      if (endDate != null) {
        final endDateTime = endDate!.add(const Duration(days: 1));
        saleOrdersQuery = saleOrdersQuery.lt('created_at', endDateTime.toIso8601String());
        financialOrdersQuery = financialOrdersQuery.lt('created_at', endDateTime.toIso8601String());
        reimportOrdersQuery = reimportOrdersQuery.lt('created_at', endDateTime.toIso8601String());
      }

      // Add order and range after all filters
      saleOrdersQuery = saleOrdersQuery.order('created_at', ascending: false).range(start, end);
      financialOrdersQuery = financialOrdersQuery.order('created_at', ascending: false).range(start, end);
      reimportOrdersQuery = reimportOrdersQuery.order('created_at', ascending: false).range(start, end);

      developer.log('Executing queries for customer: "$customerName"');
      final results = await Future.wait<dynamic>([
        saleOrdersQuery,
        financialOrdersQuery,
        reimportOrdersQuery,
      ]);
      developer.log('Queries completed');

      final saleOrders = (results[0] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map((order) => {...order, 'type': 'Phiếu Bán Hàng'})
          .toList();
      developer.log('Sale Orders: ${saleOrders.length}, First order: ${saleOrders.isNotEmpty ? saleOrders.first : "none"}');

      final financialOrders = (results[1] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map((order) {
            final orderType = order['type']?.toString() ?? '';
            String displayType;
            if (orderType == 'payment') {
              displayType = 'Chi đối tác';
            } else if (orderType == 'receive') {
              displayType = 'Thu đối tác';
            } else {
              displayType = 'Thu Tiền Đối Tác'; // Fallback cho các loại khác
            }
            return {...order, 'type': displayType};
          })
          .toList();
      developer.log('Financial Orders: ${financialOrders.length}, First order: ${financialOrders.isNotEmpty ? financialOrders.first : "none"}');

      final reimportOrders = (results[2] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map((order) => {...order, 'type': 'Phiếu Nhập Lại Hàng'})
          .toList();
      developer.log('Reimport Orders: ${reimportOrders.length}, First order: ${reimportOrders.isNotEmpty ? reimportOrders.first : "none"}');

      final newTransactions = [...saleOrders, ...financialOrders, ...reimportOrders];
      developer.log('Total transactions: ${newTransactions.length}');

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
        final customerId = widget.customer['id']?.toString().trim() ?? '';

        final saleOrdersFuture = widget.tenantClient
            .from('sale_orders')
            .select('id, product_id, imei, quantity, price, currency, created_at, account, note, customer_price, transporter_price, transporter, warehouse_id')
            .eq('customer_id', customerId)
            .eq('iscancelled', false)
            .order('created_at', ascending: false);

        final financialOrdersFuture = widget.tenantClient
            .from('financial_orders')
            .select('id, amount, currency, created_at, account, note, type')
            .eq('partner_type', 'customers')
            .eq('partner_id', customerId)
            .eq('iscancelled', false)
            .order('created_at', ascending: false);

        final reimportOrdersFuture = widget.tenantClient
            .from('reimport_orders')
            .select('id, product_id, imei, quantity, price, currency, created_at, account, note, warehouse_id')
            .eq('customer_id', customerId)
            .eq('iscancelled', false)
            .order('created_at', ascending: false);

        final results = await Future.wait([
          saleOrdersFuture,
          financialOrdersFuture,
          reimportOrdersFuture,
        ]);

        final saleOrders = (results[0] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .map((order) => {...order, 'type': 'Phiếu Bán Hàng'})
            .toList();
        final financialOrders = (results[1] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .map((order) {
              final orderType = order['type']?.toString() ?? '';
              String displayType;
              if (orderType == 'payment') {
                displayType = 'Chi đối tác';
              } else if (orderType == 'receive') {
                displayType = 'Thu đối tác';
              } else {
                displayType = 'Thu Tiền Đối Tác'; // Fallback cho các loại khác
              }
              return {...order, 'type': displayType};
            })
            .toList();
        final reimportOrders = (results[2] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .map((order) => {...order, 'type': 'Phiếu Nhập Lại Hàng'})
            .toList();

        exportTransactions = [...saleOrders, ...financialOrders, ...reimportOrders];
        exportTransactions.sort((a, b) {
          final dateA = DateTime.tryParse(a['created_at']?.toString() ?? '1900-01-01') ?? DateTime(1900);
          final dateB = DateTime.tryParse(b['created_at']?.toString() ?? '1900-01-01') ?? DateTime(1900);
          return dateB.compareTo(dateA);
        });
      }

      var excel = Excel.createExcel();
      excel.delete('Sheet1');

      Sheet sheet = excel['GiaoDichKhachHang'];

      // Thêm thông tin khách hàng
      final customerName = widget.customer['name']?.toString() ?? '';
      final customerPhone = widget.customer['phone']?.toString() ?? '';
      final customerAddress = widget.customer['address']?.toString() ?? '';
      final debtVnd = widget.customer['debt_vnd'] as num? ?? 0;
      final debtCny = widget.customer['debt_cny'] as num? ?? 0;
      final debtUsd = widget.customer['debt_usd'] as num? ?? 0;
      final debtDetails = <String>[];
      if (debtVnd != 0) debtDetails.add('${formatNumber(debtVnd)} VND');
      if (debtCny != 0) debtDetails.add('${formatNumber(debtCny)} CNY');
      if (debtUsd != 0) debtDetails.add('${formatNumber(debtUsd)} USD');
      final debtText = debtDetails.isNotEmpty ? debtDetails.join(', ') : '0 VND';

      sheet.cell(CellIndex.indexByString("A1")).value = TextCellValue('Tên khách hàng: $customerName');
      sheet.cell(CellIndex.indexByString("A2")).value = TextCellValue('Số điện thoại: $customerPhone');
      sheet.cell(CellIndex.indexByString("A3")).value = TextCellValue('Địa chỉ: $customerAddress');
      sheet.cell(CellIndex.indexByString("A4")).value = TextCellValue('Công nợ: $debtText');
      
      int currentRow = 5;
      
      // Thêm thông tin bộ lọc thời gian nếu có
      if (startDate != null && endDate != null) {
        final startDateStr = formatDate(startDate!.toIso8601String());
        final endDateStr = formatDate(endDate!.toIso8601String());
        sheet.cell(CellIndex.indexByString("A$currentRow")).value = TextCellValue('Thời gian: Từ $startDateStr đến $endDateStr');
        currentRow++;
      }

      final headerLabels = [
        'Loại giao dịch',
        'Ngày',
        'Tên sản phẩm',
        'IMEI',
        'Số lượng',
        'Số tiền',
        'Đơn vị tiền',
        'Tiền cọc',
        'Tiền COD',
        'Kho',
        'Tài khoản',
        'Ghi chú',
      ];
      final columnCount = headerLabels.length;
      final sizingTracker = ExcelSizingTracker(columnCount);
      final styles = ExcelCellStyles.build();

      for (int columnIndex = 0; columnIndex < columnCount; columnIndex++) {
        final cell = sheet.cell(
          CellIndex.indexByColumnRow(
            columnIndex: columnIndex,
            rowIndex: currentRow - 1,
          ),
      );
        final label = headerLabels[columnIndex];
        cell.value = TextCellValue(label);
        cell.cellStyle = styles.header;
        sizingTracker.update(currentRow - 1, columnIndex, label);
      }
      
      currentRow++;

      const multilineHeaders = {'IMEI', 'Ghi chú'};

      for (int i = 0; i < exportTransactions.length; i++) {
        final transaction = exportTransactions[i];
        final type = transaction['type'] as String;
        final createdAt = formatDate(transaction['created_at']?.toString());
        num totalAmount;
        final currency = transaction['currency']?.toString() ?? 'VND';
        final price = transaction['price'] as num?;
        final qtyNum = transaction['quantity'] as num? ?? 0;
        
        if (type == 'Phiếu Bán Hàng' || type == 'Phiếu Nhập Lại Hàng') {
          totalAmount = (price ?? 0) * qtyNum;
        } else {
          totalAmount = (transaction['amount'] as num?) ?? 0;
        }
        
        final productId = transaction['product_id']?.toString() ?? '';
        final productName = CacheUtil.getProductName(productId);
        final imeiStr = transaction['imei']?.toString() ?? '';
        final imeiList = imeiStr.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
        final hasMultipleImeis = imeiList.length > 1;
        final warehouseId = transaction['warehouse_id']?.toString() ?? '';
        final warehouseName = CacheUtil.getWarehouseName(warehouseId);
        final account = transaction['account']?.toString() ?? '';
        final note = transaction['note']?.toString() ?? '';
        
        // Lấy customer_price và transporter_price
        final customerPrice = transaction['customer_price'] as num?;
        final transporterPrice = transaction['transporter_price'] as num?;
        
        // Tính số tiền cho mỗi IMEI
        num amountPerImei;
        num customerPricePerImei = 0;
        num transporterPricePerImei = 0;
        if (type == 'Phiếu Bán Hàng' || type == 'Phiếu Nhập Lại Hàng') {
          // Với phiếu có price, mỗi IMEI = price (đơn giá)
          amountPerImei = price ?? 0;
          // Tính tiền cọc và tiền COD per IMEI
          if (customerPrice != null && qtyNum > 0) {
            customerPricePerImei = customerPrice / qtyNum;
          }
          if (transporterPrice != null && qtyNum > 0) {
            transporterPricePerImei = transporterPrice / qtyNum;
          }
        } else {
          // Với financial_orders (không có IMEI hoặc không chia được), dùng totalAmount
          amountPerImei = totalAmount;
        }

        if (hasMultipleImeis) {
          // ✅ Mỗi IMEI là 1 dòng - thứ tự cột: Loại giao dịch, Ngày, Tên sản phẩm, IMEI, Số lượng, Số tiền, Đơn vị tiền, Tiền cọc, Tiền COD, Kho, Tài khoản, Ghi chú
          for (final singleImei in imeiList) {
            for (int columnIndex = 0; columnIndex < columnCount; columnIndex++) {
              final cell = sheet.cell(
                CellIndex.indexByColumnRow(
                  columnIndex: columnIndex,
                  rowIndex: currentRow - 1,
                ),
              );
              final header = headerLabels[columnIndex];
              final isMultiline = multilineHeaders.contains(header);
              
              // Xác định loại cell value dựa trên header
              if (header == 'Loại giao dịch') {
                cell.value = TextCellValue(type);
              } else if (header == 'Ngày') {
                cell.value = TextCellValue(createdAt);
              } else if (header == 'Tên sản phẩm') {
                cell.value = TextCellValue(productName);
              } else if (header == 'IMEI') {
                cell.value = TextCellValue(singleImei);
              } else if (header == 'Số lượng') {
                cell.value = IntCellValue(1);
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
              } else if (header == 'Kho') {
                cell.value = TextCellValue(warehouseName);
              } else if (header == 'Tài khoản') {
                cell.value = TextCellValue(account);
              } else if (header == 'Ghi chú') {
                cell.value = TextCellValue(note);
              } else {
                cell.value = TextCellValue('');
              }
              
              cell.cellStyle = isMultiline ? styles.multiline : styles.centered;
              if (header == 'Số lượng' || header == 'Số tiền' || header == 'Tiền cọc' || header == 'Tiền COD') {
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
            final header = headerLabels[columnIndex];
            final isMultiline = multilineHeaders.contains(header);
            
            // Xác định loại cell value dựa trên header
            if (header == 'Loại giao dịch') {
              cell.value = TextCellValue(type);
            } else if (header == 'Ngày') {
              cell.value = TextCellValue(createdAt);
            } else if (header == 'Tên sản phẩm') {
              cell.value = TextCellValue(productName);
            } else if (header == 'IMEI') {
              cell.value = TextCellValue(imeiStr);
            } else if (header == 'Số lượng') {
              final qtyInt = qtyNum is int ? qtyNum : qtyNum.toInt();
              cell.value = IntCellValue(qtyInt);
            } else if (header == 'Số tiền') {
              // ✅ Dùng trực tiếp giá trị num thay vì toString() để tránh format sai
              final totalAmountValue = totalAmount.toDouble();
              cell.value = DoubleCellValue(totalAmountValue);
            } else if (header == 'Đơn vị tiền') {
              cell.value = TextCellValue(currency);
            } else if (header == 'Tiền cọc') {
              if (customerPrice != null) {
                final customerPriceValue = customerPrice.toDouble();
                cell.value = DoubleCellValue(customerPriceValue);
              } else {
                cell.value = TextCellValue('');
              }
            } else if (header == 'Tiền COD') {
              if (transporterPrice != null) {
                final transporterPriceValue = transporterPrice.toDouble();
                cell.value = DoubleCellValue(transporterPriceValue);
              } else {
                cell.value = TextCellValue('');
              }
            } else if (header == 'Kho') {
              cell.value = TextCellValue(warehouseName);
            } else if (header == 'Tài khoản') {
              cell.value = TextCellValue(account);
            } else if (header == 'Ghi chú') {
              cell.value = TextCellValue(note);
            } else {
              cell.value = TextCellValue('');
            }
            
            cell.cellStyle = isMultiline ? styles.multiline : styles.centered;
            if (header == 'Số lượng' || header == 'Số tiền' || header == 'Tiền cọc' || header == 'Tiền COD') {
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
      final customerNameForFile = widget.customer['name']?.toString() ?? 'Unknown';
      final fileName = 'Báo Cáo Giao Dịch Khách Hàng $customerNameForFile ${now.day}_${now.month}_${now.year} ${now.hour}_${now.minute}_${now.second}.xlsx';
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
        // Hiển thị error với retry option
        final shouldRetry = await ErrorHandler.showErrorDialog(
          context: context,
          title: 'Lỗi xuất Excel',
          error: e,
          showRetry: true,
        );
        
        if (shouldRetry) {
          // User muốn thử lại
          await _exportToExcel();
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final customer = widget.customer;
    final debtDetails = <String>[];
    final debtVnd = customer['debt_vnd'] as num? ?? 0;
    final debtCny = customer['debt_cny'] as num? ?? 0;
    final debtUsd = customer['debt_usd'] as num? ?? 0;
    if (debtVnd != 0) debtDetails.add('${formatNumber(debtVnd)} VND');
    if (debtCny != 0) debtDetails.add('${formatNumber(debtCny)} CNY');
    if (debtUsd != 0) debtDetails.add('${formatNumber(debtUsd)} USD');
    final debtText = debtDetails.isNotEmpty ? debtDetails.join(', ') : '0 VND';

    return AlertDialog(
      title: const Text('Chi tiết khách hàng'),
      content: Container(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CopyableText(
              label: 'Tên',
              value: customer['name']?.toString() ?? '',
            ),
            const SizedBox(height: 8),
            CopyableText(
              label: 'Số điện thoại',
              value: customer['phone']?.toString() ?? '',
            ),
            const SizedBox(height: 8),
            CopyableText(
              label: 'Link mạng xã hội',
              value: customer['social_link']?.toString() ?? '',
            ),
            const SizedBox(height: 8),
            CopyableText(
              label: 'Địa chỉ',
              value: customer['address']?.toString() ?? '',
            ),
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
            if (isLoadingTransactions)
              const Center(child: CircularProgressIndicator())
            else if (transactionError != null)
              Text(transactionError!)
            else if (filteredTransactions.isEmpty)
              const Text('Không có giao dịch trong khoảng thời gian này.')
            else
              Expanded(
                child: ListView.builder(
                  controller: _scrollController,
                  shrinkWrap: true,
                  itemCount: filteredTransactions.length + (isLoadingMore ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == filteredTransactions.length && isLoadingMore) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final transaction = filteredTransactions[index];
                    final type = transaction['type'] as String;
                    final createdAt = formatDate(transaction['created_at']?.toString());
                    num totalAmount;
                    final currency = transaction['currency']?.toString() ?? 'VND';
                    if (type == 'Phiếu Bán Hàng' || type == 'Phiếu Nhập Lại Hàng') {
                      final price = (transaction['price'] as num?) ?? 0;
                      final quantity = (transaction['quantity'] as num?) ?? 0;
                      totalAmount = price * quantity;
                    } else {
                      totalAmount = (transaction['amount'] as num?) ?? 0;
                    }
                    final formattedAmount = formatNumber(totalAmount);
                    final productId = transaction['product_id']?.toString() ?? '';
                    final productName = CacheUtil.getProductName(productId);
                    final imei = transaction['imei']?.toString() ?? '';
                    final quantity = transaction['quantity']?.toString() ?? '';
                    final warehouseId = transaction['warehouse_id']?.toString() ?? '';
                    final warehouseName = CacheUtil.getWarehouseName(warehouseId);
                    final customerPrice = transaction['customer_price']?.toString() ?? '';
                    final transporterPrice = transaction['transporter_price']?.toString() ?? '';
                    final transporter = transaction['transporter']?.toString() ?? '';
                    final account = transaction['account']?.toString() ?? '';
                    final note = transaction['note']?.toString() ?? '';

                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: ListTile(
                        title: Text('$type - $createdAt'),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (type != 'Chi đối tác' && type != 'Thu đối tác' && type != 'Thu Tiền Đối Tác') ...[
                              Text('Sản phẩm: $productName'),
                              if (imei.isNotEmpty) Text('IMEI: $imei'),
                              if (quantity.isNotEmpty) Text('Số lượng: $quantity'),
                              if (warehouseName != 'Không xác định') Text('Kho: $warehouseName'),
                              if (customerPrice.isNotEmpty) Text('Tiền cọc: $customerPrice'),
                              if (transporterPrice.isNotEmpty) Text('Tiền COD: $transporterPrice'),
                              if (transporter.isNotEmpty) Text('ĐV vận chuyển: $transporter'),
                            ],
                            Text('Số tiền: $formattedAmount $currency'),
                            if (account.isNotEmpty) Text('Tài khoản: $account'),
                            if (note.isNotEmpty) Text('Ghi chú: $note'),
                          ],
                        ),
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