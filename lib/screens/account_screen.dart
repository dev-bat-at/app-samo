import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:bcrypt/bcrypt.dart';
import 'package:intl/intl.dart';
import 'package:excel/excel.dart' as excel;
import 'package:open_file/open_file.dart';
import 'dart:io';
import '../helpers/storage_helper.dart';
import '../helpers/excel_style_helper.dart';

class SubAccount {
  String id;
  String username;
  List<String> permissions;
  int doanhso;

  SubAccount({
    required this.id,
    required this.username,
    required this.permissions,
    required this.doanhso,
  });

  factory SubAccount.fromMap(Map<String, dynamic> map) {
    return SubAccount(
      id: map['id'] ?? '',
      username: map['username'] ?? '',
      permissions: List<String>.from(map['permissions'] ?? []),
      doanhso: (map['doanhso'] as num?)?.toInt() ?? 0,
    );
  }
}

class AccountScreen extends StatefulWidget {
  final SupabaseClient tenantClient;

  const AccountScreen({super.key, required this.tenantClient});

  @override
  _AccountScreenState createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final List<Map<String, String>> availablePermissions = [
    {'value': 'admin', 'display': 'Quyền quản trị viên (toàn quyền)'},
    {'value': 'access_import_form', 'display': 'Truy cập phiếu nhập hàng'},
    {'value': 'access_return_form', 'display': 'Truy cập phiếu trả hàng'},
    {'value': 'access_sale_form', 'display': 'Truy cập phiếu bán hàng'},
    {'value': 'access_fix_send_form', 'display': 'Truy cập phiếu gửi sửa'},
    {'value': 'access_fix_receive_form', 'display': 'Truy cập phiếu nhận sửa'},
    {'value': 'access_reimport_form', 'display': 'Truy cập phiếu nhập lại hàng'},
    {'value': 'access_transfer_local_form', 'display': 'Truy cập phiếu chuyển nội địa'},
    {'value': 'access_transfer_global_form', 'display': 'Truy cập phiếu chuyển quốc tế'},
    {'value': 'access_transfer_receive_form', 'display': 'Truy cập phiếu nhập kho vận chuyển'},
    {'value': 'access_transfer_fee_form', 'display': 'Truy cập phiếu cước vận chuyển'},
    {'value': 'access_warehouse_form', 'display': 'Truy cập phiếu thêm/sửa kho'},
    {'value': 'access_payment_form', 'display': 'Truy cập phiếu chi đối tác'},
    {'value': 'access_receive_form', 'display': 'Truy cập phiếu thu đối tác'},
    {'value': 'access_income_other_form', 'display': 'Truy cập phiếu thu nhập khác'},
    {'value': 'access_cost_form', 'display': 'Truy cập phiếu chi phí'},
    {'value': 'access_exchange_form', 'display': 'Truy cập phiếu đổi tiền'},
    {'value': 'access_transfer_fund_form', 'display': 'Truy cập phiếu chuyển quỹ'},
    {'value': 'access_financial_account_form', 'display': 'Truy cập phiếu tài khoản thanh toán'},
    {'value': 'access_customers_screen', 'display': 'Truy cập màn hình khách hàng'},
    {'value': 'access_suppliers_screen', 'display': 'Truy cập màn hình nhà cung cấp'},
    {'value': 'access_transporters_screen', 'display': 'Truy cập màn hình đơn vị vận chuyển'},
    {'value': 'access_fixers_screen', 'display': 'Truy cập màn hình đơn vị sửa chữa'},
    {'value': 'access_crm_screen', 'display': 'Truy cập màn hình CRM'},
    {'value': 'access_orders_screen', 'display': 'Truy cập màn hình khách đặt hàng'},
    {'value': 'access_history_screen', 'display': 'Truy cập màn hình lịch sử phiếu'},
    {'value': 'view_import_price', 'display': 'Xem giá nhập'},
    {'value': 'view_cost_price', 'display': 'Xem giá vốn'},
    {'value': 'view_supplier', 'display': 'Xem nhà cung cấp'},
    {'value': 'view_sale_price', 'display': 'Xem giá bán'},
    {'value': 'view_customer', 'display': 'Xem khách hàng'},
    {'value': 'view_transporter', 'display': 'Xem đơn vị vận chuyển'},
    {'value': 'view_fixer', 'display': 'Xem đơn vị fix lỗi'},
    {'value': 'create_transaction', 'display': 'Tạo giao dịch'},
    {'value': 'edit_transaction', 'display': 'Sửa giao dịch'},
    {'value': 'cancel_transaction', 'display': 'Hủy giao dịch'},
    {'value': 'manage_accounts', 'display': 'Quản lý tài khoản phụ'},
    {'value': 'view_company_value', 'display': 'Xem giá trị công ty'},
    {'value': 'view_profit', 'display': 'Xem lợi nhuận'},
    {'value': 'view_finance', 'display': 'Xem tab tài chính'},
    {'value': 'access_excel_report', 'display': 'Nhập xuất báo cáo tổng hợp'},
  ];

  List<String> get allPermissions => availablePermissions.map((p) => p['value']!).toList();

  Future<List<SubAccount>> getSubAccounts() async {
    final response = await widget.tenantClient.from('sub_accounts').select('id, username, permissions, doanhso');
    return (response as List<dynamic>).map((map) => SubAccount.fromMap(map)).toList();
  }

  // ✅ Format số với dấu phân cách hàng nghìn (ví dụ: 1000000 → 1.000.000)
  String _formatNumber(num value) {
    return NumberFormat('#,###', 'vi_VN').format(value).replaceAll(',', '.');
  }

  // ✅ Reset doanh số về 0
  Future<void> resetDoanhso(String id, String username) async {
    // Hiển thị dialog xác nhận
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text(
          'Xác nhận reset doanh số',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        content: Text(
          'Bạn có chắc chắn muốn reset doanh số của tài khoản "$username" về 0 không?\nThao tác này không thể hoàn tác.',
          style: const TextStyle(color: Colors.red),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Hủy'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            child: const Text('Reset', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await widget.tenantClient
          .from('sub_accounts')
          .update({'doanhso': 0})
          .eq('id', id);

      setState(() {}); // Refresh danh sách
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Đã reset doanh số của "$username" về 0')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi khi reset doanh số: $e')),
      );
    }
  }

  void addSubAccount() {
    showDialog(
      context: context,
      builder: (context) => AddSubAccountDialog(
        availablePermissions: availablePermissions,
        onSave: (username, password, permissions) async {
          if (username.toLowerCase() == 'admin') {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Không thể thêm tài khoản với tên "admin"')),
            );
            return;
          }
          try {
            final passwordHash = BCrypt.hashpw(password, BCrypt.gensalt());
            await widget.tenantClient.from('sub_accounts').insert({
              'username': username,
              'password_hash': passwordHash,
              'permissions': permissions,
            });
            setState(() {});
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Thêm tài khoản phụ thành công')),
            );
          } catch (e) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Lỗi khi thêm tài khoản phụ: $e')),
            );
          }
        },
      ),
    );
  }

  void editSubAccount(SubAccount account) {
    final isAdmin = account.username.toLowerCase() == 'admin';
    showDialog(
      context: context,
      builder: (context) => EditSubAccountDialog(
        account: account,
        availablePermissions: availablePermissions,
        isAdmin: isAdmin,
        onSave: (username, password, permissions) async {
          try {
            final updateData = {
              if (!isAdmin) 'username': username,
              'permissions': isAdmin ? allPermissions : permissions,
            };
            if (password.isNotEmpty) {
              updateData['password_hash'] = BCrypt.hashpw(password, BCrypt.gensalt());
            }
            await widget.tenantClient.from('sub_accounts').update(updateData).eq('id', account.id);
            setState(() {});
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(isAdmin ? 'Cập nhật mật khẩu admin thành công' : 'Sửa tài khoản phụ thành công')),
            );
          } catch (e) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Lỗi khi sửa tài khoản: $e')),
            );
          }
        },
      ),
    );
  }

  void deleteSubAccount(String id, String username) async {
    if (username.toLowerCase() == 'admin') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Không thể xóa tài khoản admin')),
      );
      return;
    }
    try {
      await widget.tenantClient.from('sub_accounts').delete().eq('id', id);
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Xóa tài khoản phụ thành công')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi khi xóa tài khoản phụ: $e')),
      );
    }
  }

  void showDoanhSoDialog(String username) {
    showDialog(
      context: context,
      builder: (context) => DoanhSoDialog(
        tenantClient: widget.tenantClient,
        username: username,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tài Khoản Phụ', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.grey[800],
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: FutureBuilder<List<SubAccount>>(
        future: getSubAccounts(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Lỗi: ${snapshot.error}'));
          }
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final accounts = snapshot.data ?? [];
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ElevatedButton(
                  onPressed: addSubAccount,
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                  child: const Text('Thêm Tài Khoản Phụ', style: TextStyle(color: Colors.white)),
                ),
                const SizedBox(height: 16),
                ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: accounts.length,
                  itemBuilder: (context, index) {
                    final account = accounts[index];
                    final isAdmin = account.username.toLowerCase() == 'admin';
                    final displayPermissions = isAdmin
                        ? availablePermissions.map((p) => p['display']!).toList()
                        : account.permissions.map((perm) {
                            final permission = availablePermissions.firstWhere(
                              (p) => p['value'] == perm,
                              orElse: () => {'value': perm, 'display': perm},
                            );
                            return permission['display']!;
                          }).toList();

                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 8),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // ✅ Hàng đầu: Tên tài khoản và Doanh số trong container màu
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.blue.shade50, // Màu xanh nhạt
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.blue.shade200, width: 1),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      'Tên: ${account.username}',
                                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    'DS: ${_formatNumber(account.doanhso)} Đ',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.blue.shade700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),
                            // Quyền
                            Text(
                              'Quyền: ${displayPermissions.isEmpty ? 'Không có' : displayPermissions.join(', ')}',
                              style: const TextStyle(fontSize: 14),
                            ),
                            const SizedBox(height: 8),
                            // ✅ Hàng nút: Doanh số, Reset doanh số, Edit, Delete
                            Row(
                              children: [
                                ElevatedButton.icon(
                                  onPressed: () => showDoanhSoDialog(account.username),
                                  icon: const Icon(Icons.bar_chart, size: 18),
                                  label: const Text('Giao dịch'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.green,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                ElevatedButton.icon(
                                  onPressed: () => resetDoanhso(account.id, account.username),
                                  icon: const Icon(Icons.refresh, size: 18),
                                  label: const Text('Reset doanh số'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.orange,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  ),
                                ),
                                const Spacer(),
                                IconButton(
                                  icon: const Icon(Icons.edit, color: Colors.blue),
                                  onPressed: () => editSubAccount(account),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete, color: Colors.red),
                                  onPressed: isAdmin ? null : () => deleteSubAccount(account.id, account.username),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class AddSubAccountDialog extends StatefulWidget {
  final List<Map<String, String>> availablePermissions;
  final Future<void> Function(String username, String password, List<String> permissions) onSave;

  const AddSubAccountDialog({
    super.key,
    required this.availablePermissions,
    required this.onSave,
  });

  @override
  _AddSubAccountDialogState createState() => _AddSubAccountDialogState();
}

class _AddSubAccountDialogState extends State<AddSubAccountDialog> {
  final usernameController = TextEditingController();
  final passwordController = TextEditingController();
  final selectedPermissions = <String>{};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Thêm Tài Khoản Phụ'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: usernameController,
              decoration: const InputDecoration(labelText: 'Tên tài khoản'),
            ),
            TextField(
              controller: passwordController,
              decoration: const InputDecoration(labelText: 'Mật khẩu'),
              obscureText: true,
            ),
            const SizedBox(height: 16),
            const Text('Quyền:', style: TextStyle(fontWeight: FontWeight.bold)),
            ...widget.availablePermissions.map((permission) => CheckboxListTile(
                  title: Text(permission['display']!),
                  value: selectedPermissions.contains(permission['value']),
                  onChanged: (value) {
                    setState(() {
                      if (value == true) {
                        selectedPermissions.add(permission['value']!);
                      } else {
                        selectedPermissions.remove(permission['value']);
                      }
                    });
                  },
                )),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Hủy'),
        ),
        TextButton(
          onPressed: () async {
            await widget.onSave(
              usernameController.text.trim(),
              passwordController.text.trim(),
              selectedPermissions.toList(),
            );
            Navigator.pop(context);
          },
          child: const Text('Lưu'),
        ),
      ],
    );
  }
}

class EditSubAccountDialog extends StatefulWidget {
  final SubAccount account;
  final List<Map<String, String>> availablePermissions;
  final bool isAdmin;
  final Future<void> Function(String username, String password, List<String> permissions) onSave;

  const EditSubAccountDialog({
    super.key,
    required this.account,
    required this.availablePermissions,
    required this.isAdmin,
    required this.onSave,
  });

  @override
  _EditSubAccountDialogState createState() => _EditSubAccountDialogState();
}

class _EditSubAccountDialogState extends State<EditSubAccountDialog> {
  final usernameController = TextEditingController();
  final passwordController = TextEditingController();
  final selectedPermissions = <String>{};

  @override
  void initState() {
    super.initState();
    usernameController.text = widget.account.username;
    selectedPermissions.addAll(widget.account.permissions);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isAdmin ? 'Sửa Mật Khẩu Admin' : 'Sửa Tài Khoản Phụ'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!widget.isAdmin)
              TextField(
                controller: usernameController,
                decoration: const InputDecoration(labelText: 'Tên tài khoản'),
              ),
            TextField(
              controller: passwordController,
              decoration: const InputDecoration(labelText: 'Mật khẩu mới (để trống nếu không đổi)'),
              obscureText: true,
            ),
            if (!widget.isAdmin) ...[
              const SizedBox(height: 16),
              const Text('Quyền:', style: TextStyle(fontWeight: FontWeight.bold)),
              ...widget.availablePermissions.map((permission) => CheckboxListTile(
                    title: Text(permission['display']!),
                    value: selectedPermissions.contains(permission['value']),
                    onChanged: (value) {
                      setState(() {
                        if (value == true) {
                          selectedPermissions.add(permission['value']!);
                        } else {
                          selectedPermissions.remove(permission['value']);
                        }
                      });
                    },
                  )),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Hủy'),
        ),
        TextButton(
          onPressed: () async {
            await widget.onSave(
              usernameController.text.trim(),
              passwordController.text.trim(),
              selectedPermissions.toList(),
            );
            Navigator.pop(context);
          },
          child: const Text('Lưu'),
        ),
      ],
    );
  }
}
// Dialog hiển thị doanh số và giao dịch
class DoanhSoDialog extends StatefulWidget {
  final SupabaseClient tenantClient;
  final String username;

  const DoanhSoDialog({
    super.key,
    required this.tenantClient,
    required this.username,
  });

  @override
  _DoanhSoDialogState createState() => _DoanhSoDialogState();
}

class _DoanhSoDialogState extends State<DoanhSoDialog> {
  String selectedFilter = '30 ngày';
  DateTime? customDateFrom;
  DateTime? customDateTo;
  List<Map<String, dynamic>> transactions = [];
  bool isLoading = false;
  bool isExporting = false;

  @override
  void initState() {
    super.initState();
    _loadTransactions();
  }

  DateTime getDateFrom() {
    final now = DateTime.now();
    switch (selectedFilter) {
      case '7 ngày':
        return now.subtract(const Duration(days: 7));
      case '30 ngày':
        return now.subtract(const Duration(days: 30));
      case 'Tùy chỉnh':
        return customDateFrom ?? now.subtract(const Duration(days: 30));
      default:
        return now.subtract(const Duration(days: 30));
    }
  }

  DateTime getDateTo() {
    if (selectedFilter == 'Tùy chỉnh' && customDateTo != null) {
      return customDateTo!;
    }
    return DateTime.now();
  }

  Future<void> _loadTransactions() async {
    if (!mounted) return;
    setState(() => isLoading = true);
    try {
      final dateFrom = getDateFrom();
      final dateTo = getDateTo();
      final dateFromStr = dateFrom.toIso8601String();
      final dateToStr = dateTo.add(const Duration(days: 1)).toIso8601String();

      // Query sale_orders
      final saleOrders = await widget.tenantClient
          .from('sale_orders')
          .select('ticket_id, created_at, customer, product_name, imei, price, currency, doanhso, iscancelled')
          .eq('saleman', widget.username)
          .eq('iscancelled', false)
          .gte('created_at', dateFromStr)
          .lte('created_at', dateToStr)
          .order('created_at', ascending: false);

      // Query reimport_orders - cần tìm qua sale_orders để lấy saleman
      final reimportOrders = await widget.tenantClient
          .from('reimport_orders')
          .select('ticket_id, created_at, imei, price, currency, iscancelled')
          .eq('iscancelled', false)
          .gte('created_at', dateFromStr)
          .lte('created_at', dateToStr)
          .order('created_at', ascending: false);

      // Lọc reimport_orders dựa vào saleman từ sale_orders và tính doanh số âm
      final filteredReimportOrders = <Map<String, dynamic>>[];
      for (var reimportOrder in reimportOrders) {
        final imei = reimportOrder['imei']?.toString() ?? '';
        // Tìm sale_order có chứa IMEI này và có saleman = username
        final matchingSaleOrders = await widget.tenantClient
            .from('sale_orders')
            .select('saleman, customer, product_name, doanhso, imei, quantity')
            .ilike('imei', '%$imei%')
            .eq('saleman', widget.username)
            .eq('iscancelled', false)
            .order('created_at', ascending: false)
            .limit(10);

        // Filter để tìm sale_order chứa IMEI chính xác
        Map<String, dynamic>? matchingSaleOrder;
        for (var order in matchingSaleOrders) {
          final imeiString = order['imei']?.toString() ?? '';
          final imeiList = imeiString.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
          if (imeiList.contains(imei)) {
            matchingSaleOrder = order;
            break;
          }
        }

        if (matchingSaleOrder != null) {
          // Tính doanh số âm cho reimport/cod_return
          final totalDoanhso = (matchingSaleOrder['doanhso'] as num?)?.toDouble() ?? 0.0;
          final imeiString = matchingSaleOrder['imei']?.toString() ?? '';
          final imeiList = imeiString.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
          final imeiCount = imeiList.length > 0 ? imeiList.length : 1;
          final doanhsoPerItem = imeiCount > 0 ? totalDoanhso / imeiCount : 0.0;
          
          // Kiểm tra xem là reimport hay cod_return dựa vào account
          final account = reimportOrder['account']?.toString() ?? '';
          final isCodReturn = account.toLowerCase() == 'cod hoàn' || account.toLowerCase() == 'cod hoan';
          
          filteredReimportOrders.add({
            ...reimportOrder,
            'type': isCodReturn ? 'cod_return' : 'reimport',
            'customer': matchingSaleOrder['customer'] ?? '',
            'product_name': matchingSaleOrder['product_name'] ?? '',
            'doanhso': -doanhsoPerItem, // Doanh số âm cho hoàn hàng
          });
        }
      }

      // Kết hợp và format dữ liệu
      final allTransactions = <Map<String, dynamic>>[];
      
      // Thêm sale orders
      for (var order in saleOrders) {
        allTransactions.add({
          'type': 'sale',
          'ticket_id': order['ticket_id'],
          'created_at': order['created_at'],
          'customer': order['customer'] ?? '',
          'product_name': order['product_name'] ?? '',
          'imei': order['imei'] ?? '',
          'price': order['price'] ?? 0,
          'currency': order['currency'] ?? 'VND',
          'doanhso': order['doanhso'] ?? 0,
        });
      }

      // Thêm reimport orders (đã được lọc)
      allTransactions.addAll(filteredReimportOrders);

      // Sắp xếp theo ngày tạo (mới nhất trước)
      allTransactions.sort((a, b) {
        final dateA = DateTime.parse(a['created_at'] ?? DateTime.now().toIso8601String());
        final dateB = DateTime.parse(b['created_at'] ?? DateTime.now().toIso8601String());
        return dateB.compareTo(dateA);
      });

      if (mounted) {
        setState(() {
          transactions = allTransactions;
          isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi khi tải dữ liệu: $e')),
        );
      }
    }
  }

  Future<void> _exportToExcel() async {
    if (isExporting || transactions.isEmpty) return;

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
      final hasPermission = await StorageHelper.requestStoragePermissionIfNeeded();
      if (!hasPermission) {
        if (mounted) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cần quyền lưu trữ để xuất Excel')),
          );
        }
        return;
      }

      final excelFile = excel.Excel.createExcel();
      final sheet = excelFile['GiaoDich'];
      
      // Xóa Sheet1 nếu có
      if (excelFile.sheets.containsKey('Sheet1')) {
        excelFile.delete('Sheet1');
      }

      // Header
      final headers = [
        'Loại giao dịch',
        'Ticket ID',
        'Ngày tạo',
        'Khách hàng',
        'Sản phẩm',
        'IMEI',
        'Giá',
        'Đơn vị tiền',
        'Doanh số',
      ];
      final columnCount = headers.length;
      final sizingTracker = ExcelSizingTracker(columnCount);
      final styles = ExcelCellStyles.build();

      // Thêm header với style
      for (int columnIndex = 0; columnIndex < columnCount; columnIndex++) {
        final cell = sheet.cell(
          excel.CellIndex.indexByColumnRow(
            columnIndex: columnIndex,
            rowIndex: 0,
          ),
        );
        final label = headers[columnIndex];
        cell.value = excel.TextCellValue(label);
        cell.cellStyle = styles.header;
        sizingTracker.update(0, columnIndex, label);
      }

      // Data
      int currentRow = 1;
      const multilineHeaders = {'IMEI'};
      
      for (var transaction in transactions) {
        final type = transaction['type'] as String;
        final typeLabel = type == 'sale' 
            ? 'Bán hàng' 
            : (type == 'cod_return' ? 'COD Hoàn' : 'Nhập lại hàng');
        final ticketId = transaction['ticket_id']?.toString() ?? '';
        final createdAt = DateFormat('dd/MM/yyyy HH:mm').format(
          DateTime.parse(transaction['created_at'] ?? DateTime.now().toIso8601String()),
        );
        final customer = transaction['customer']?.toString() ?? '';
        final productName = transaction['product_name']?.toString() ?? '';
        final imeiStr = transaction['imei']?.toString() ?? '';
        final price = (transaction['price'] as num?)?.toDouble() ?? 0.0;
        final currency = transaction['currency']?.toString() ?? 'VND';
        final doanhso = (transaction['doanhso'] as num?)?.toDouble() ?? 0.0;

        // Format IMEI: nếu có nhiều IMEI (phân tách bằng dấu phẩy), hiển thị mỗi IMEI 1 dòng trong cùng 1 ô
        final imeiList = imeiStr.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
        final formattedImei = imeiList.isNotEmpty 
            ? imeiList.join('\n')  // Mỗi IMEI 1 dòng
            : imeiStr;

        final rowValues = [
          typeLabel,
          ticketId,
          createdAt,
          customer,
          productName,
          formattedImei,
          price,
          currency,
          doanhso,
        ];

        for (int columnIndex = 0; columnIndex < columnCount; columnIndex++) {
          final cell = sheet.cell(
            excel.CellIndex.indexByColumnRow(
              columnIndex: columnIndex,
              rowIndex: currentRow,
            ),
          );
          final header = headers[columnIndex];
          final value = rowValues[columnIndex];
          final isMultiline = multilineHeaders.contains(header);

          // Xác định loại cell value dựa trên header
          if (header == 'Giá' || header == 'Doanh số') {
            // Cột số tiền - số thực
            final doubleValue = value is double ? value : double.tryParse(value.toString()) ?? 0.0;
            cell.value = excel.DoubleCellValue(doubleValue);
          } else {
            // Cột text
            cell.value = excel.TextCellValue(value.toString());
          }

          cell.cellStyle = isMultiline ? styles.multiline : styles.centered;
          sizingTracker.update(currentRow, columnIndex, value.toString());
        }
        currentRow++;
      }

      sizingTracker.applyToSheet(sheet);

      // Lưu file
      final downloadsDir = await StorageHelper.getDownloadDirectory();
      if (downloadsDir == null) {
        if (mounted) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Không thể truy cập thư mục Downloads')),
          );
        }
        return;
      }

      final now = DateTime.now();
      final fileName = 'GiaoDich_${widget.username}_${now.day}_${now.month}_${now.year}_${now.hour}_${now.minute}_${now.second}.xlsx';
      final filePath = '${downloadsDir.path}/$fileName';
      final file = File(filePath);

      final excelBytes = excelFile.encode();
      if (excelBytes == null) {
        throw Exception('Không thể tạo file Excel');
      }
      await file.writeAsBytes(excelBytes);

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Đã xuất file Excel: $fileName')),
        );

        final openResult = await OpenFile.open(filePath);
        if (openResult.type != ResultType.done) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('File đã được lưu tại: $filePath')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi khi xuất Excel: $e')),
        );
      }
    } finally {
      setState(() => isExporting = false);
    }
  }

  Future<void> _selectCustomDateRange() async {
    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      initialDateRange: customDateFrom != null && customDateTo != null
          ? DateTimeRange(start: customDateFrom!, end: customDateTo!)
          : DateTimeRange(
              start: DateTime.now().subtract(const Duration(days: 30)),
              end: DateTime.now(),
            ),
    );
    if (picked != null) {
      setState(() {
        customDateFrom = picked.start;
        customDateTo = picked.end;
        selectedFilter = 'Tùy chỉnh';
      });
      _loadTransactions();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Tính tổng doanh số (bao gồm cả số âm từ hoàn hàng)
    final totalDoanhso = transactions.fold<double>(
      0.0,
      (sum, t) => sum + ((t['doanhso'] as num?)?.toDouble() ?? 0.0),
    );

    return Dialog(
      child: Container(
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.8,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Giao dịch: ${widget.username}',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Bộ lọc thời gian
            Row(
              children: [
                Expanded(
                  child: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: '7 ngày', label: Text('7 ngày')),
                      ButtonSegment(value: '30 ngày', label: Text('30 ngày')),
                      ButtonSegment(value: 'Tùy chỉnh', label: Text('Tùy chỉnh')),
                    ],
                    selected: {selectedFilter},
                    onSelectionChanged: (Set<String> newSelection) {
                      setState(() {
                        selectedFilter = newSelection.first;
                      });
                      if (selectedFilter == 'Tùy chỉnh') {
                        _selectCustomDateRange();
                      } else {
                        _loadTransactions();
                      }
                    },
                  ),
                ),
              ],
            ),
            if (selectedFilter == 'Tùy chỉnh' && customDateFrom != null && customDateTo != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Từ ${DateFormat('dd/MM/yyyy').format(customDateFrom!)} đến ${DateFormat('dd/MM/yyyy').format(customDateTo!)}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            const SizedBox(height: 16),
            // Tổng doanh số
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: Text(
                'Tổng doanh số: ${totalDoanhso >= 0 ? '' : '-'}${NumberFormat('#,###', 'vi_VN').format(totalDoanhso.abs()).replaceAll(',', '.')} Đ',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: totalDoanhso >= 0 ? Colors.blue.shade700 : Colors.red.shade700,
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Danh sách giao dịch
            Expanded(
              child: isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : transactions.isEmpty
                      ? const Center(child: Text('Không có giao dịch nào'))
                      : ListView.builder(
                          itemCount: transactions.length,
                          itemBuilder: (context, index) {
                            final transaction = transactions[index];
                            final date = DateTime.parse(
                              transaction['created_at'] ?? DateTime.now().toIso8601String(),
                            );
                            final type = transaction['type'] as String;
                            final isSale = type == 'sale';
                            final isCodReturn = type == 'cod_return';
                            final doanhso = (transaction['doanhso'] as num?)?.toDouble() ?? 0.0;
                            
                            String typeLabel;
                            Color cardColor;
                            Color textColor;
                            if (isSale) {
                              typeLabel = 'Bán hàng';
                              cardColor = Colors.green.shade50;
                              textColor = Colors.green.shade700;
                            } else if (isCodReturn) {
                              typeLabel = 'COD Hoàn';
                              cardColor = Colors.red.shade50;
                              textColor = Colors.red.shade700;
                            } else {
                              typeLabel = 'Nhập lại hàng';
                              cardColor = Colors.orange.shade50;
                              textColor = Colors.orange.shade700;
                            }

                            return Card(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              color: cardColor,
                              child: ListTile(
                                title: Text(
                                  typeLabel,
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: textColor,
                                  ),
                                ),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Ngày: ${DateFormat('dd/MM/yyyy HH:mm').format(date)}'),
                                    Text('Khách: ${transaction['customer'] ?? ''}'),
                                    Text('Sản phẩm: ${transaction['product_name'] ?? ''}'),
                                    Text('IMEI: ${transaction['imei'] ?? ''}'),
                                    Text(
                                      'Giá: ${NumberFormat('#,###', 'vi_VN').format((transaction['price'] as num?)?.toDouble() ?? 0.0).replaceAll(',', '.')} ${transaction['currency'] ?? 'VND'}',
                                    ),
                                    if (doanhso != 0)
                                      Text(
                                        'Doanh số: ${doanhso >= 0 ? '' : '-'}${NumberFormat('#,###', 'vi_VN').format(doanhso.abs()).replaceAll(',', '.')} Đ',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: doanhso >= 0 ? Colors.blue.shade700 : Colors.red.shade700,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
            ),
            const SizedBox(height: 16),
            // Nút xuất Excel
            ElevatedButton.icon(
              onPressed: isExporting || transactions.isEmpty ? null : _exportToExcel,
              icon: const Icon(Icons.file_download),
              label: Text(isExporting ? 'Đang xuất...' : 'Xuất Excel'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
