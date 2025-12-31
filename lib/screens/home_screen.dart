import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:bcrypt/bcrypt.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'transactions/forms/import_form.dart';
import 'transactions/forms/return_form.dart';
import 'transactions/forms/sale_form.dart';
import 'transactions/forms/fix_send_form.dart';
import 'transactions/forms/fix_receive_form.dart';
import 'transactions/forms/transfer_local_form.dart';
import 'transactions/forms/transfer_global_form.dart';
import 'transactions/forms/transfer_receive_form.dart';
import 'transactions/forms/transfer_fee_form.dart';
import 'transactions/forms/payment_form.dart';
import 'transactions/forms/receive_form.dart';
import 'transactions/forms/income_other_form.dart';
import 'transactions/forms/cost_form.dart';
import 'transactions/forms/exchange_form.dart';
import 'transactions/forms/transfer_fund_form.dart';
import 'transactions/forms/warehouse_form.dart';
import 'transactions/forms/reimport_form.dart';
import 'transactions/forms/cod_return_form.dart';
import 'inventory_screen.dart';
import 'overview_screen.dart';
import 'customers_screen.dart';
import 'suppliers_screen.dart';
import 'fixers_screen.dart';
import 'transporters_screen.dart';
import 'history_screen.dart';
import 'account_screen.dart';
import 'initial_data_screen.dart';
import 'crm_screen.dart';
import 'notification_service.dart';
import 'excel_report_screen.dart';
import 'orders_screen.dart';
import 'categories_screen.dart';
import 'telegram_config_screen.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:intl/intl.dart';
import '../helpers/global_cache_manager.dart';

class HomeScreen extends StatefulWidget {
  final SupabaseClient tenantClient;
  final String? tenantUrl;
  final String? tenantAnonKey;
  final bool isFirstLogin; // ✅ Flag để biết có phải đăng nhập lần đầu không

  const HomeScreen({
    super.key,
    required this.tenantClient,
    this.tenantUrl,
    this.tenantAnonKey,
    this.isFirstLogin = false, // ✅ Default false
  });

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final usernameController = TextEditingController();
  final passwordController = TextEditingController();
  bool isLoading = false;
  String? errorText;
  List<String> permissions = [];
  bool isSubAccountLoggedIn = false;
  String? loggedInUsername;
  double? loggedInDoanhso;
  bool isPasswordHidden = true;
  bool rememberMe = true;
  bool isAutoLoginInProgress = false; // ✅ Flag để biết đang auto-login

  final List<String> allPermissions = [
    'admin',
    'access_import_form',
    'access_return_form',
    'access_sale_form',
    'access_fix_send_form',
    'access_fix_receive_form',
    'access_reimport_form',
    'access_transfer_local_form',
    'access_transfer_global_form',
    'access_transfer_receive_form',
    'access_transfer_fee_form',
    'access_warehouse_form',
    'access_payment_form',
    'access_receive_form',
    'access_income_other_form',
    'access_cost_form',
    'access_exchange_form',
    'access_transfer_fund_form',
    'access_financial_account_form',
    'access_customers_screen',
    'access_suppliers_screen',
    'access_transporters_screen',
    'access_fixers_screen',
    'access_history_screen',
    'view_import_price',
    'view_cost_price',
    'view_supplier',
    'view_sale_price',
    'view_customer',
    'view_transporter',
    'view_fixer',
    'create_transaction',
    'edit_transaction',
    'cancel_transaction',
    'manage_accounts',
    'view_company_value',
    'view_profit',
    'view_finance',
    'access_crm_screen',
    'access_excel_report',
    'access_orders_screen',
  ];

  @override
  void initState() {
    super.initState();
    _initializeApp(); // ✅ Gọi function khởi tạo theo thứ tự đúng
    _startBackgroundSync();
  }
  
  // ✅ Khởi tạo app theo thứ tự: load preferences → check auto-login → init notifications
  Future<void> _initializeApp() async {
    await _loadSavedPreferences(); // ✅ Load trước
    await _checkAutoLogin(); // ✅ Check auto-login sau khi đã có preferences
    await _initializeNotifications();
  }

  void _startBackgroundSync() {
    // Start background cache sync
    GlobalCacheManager().startBackgroundSync(widget.tenantClient);
    print('🔄 Background cache sync started');
  }

  @override
  void dispose() {
    // Stop background sync when leaving screen
    GlobalCacheManager().stopBackgroundSync();
    super.dispose();
  }

  Future<void> _initializeNotifications() async {
    print('Initializing NotificationService...');
    await Firebase.initializeApp();
    await NotificationService.init(
      widget.tenantClient,
      tenantUrl: widget.tenantUrl,
      tenantAnonKey: widget.tenantAnonKey,
      shouldGetFCMToken: widget.isFirstLogin, // ✅ CHỈ lấy token khi đăng nhập lần đầu
      permissions: permissions, // ✅ Truyền quyền để gate thông báo
    );
  }

  Future<void> _loadSavedPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      isPasswordHidden = prefs.getBool('home_isPasswordHidden') ?? true;
      rememberMe = prefs.getBool('home_rememberPassword') ?? true;
      if (rememberMe) {
        usernameController.text = prefs.getString('home_username') ?? '';
        passwordController.text = prefs.getString('home_password') ?? '';
      }
    });
  }

  Future<void> _checkAutoLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final savedUsername = prefs.getString('home_username');
    final savedPassword = prefs.getString('home_password');
    final savedRememberPassword = prefs.getBool('home_rememberPassword') ?? false;
    final hasDatabaseSession = prefs.getBool('has_database_session') ?? false;

    print('🔍 Auto-login check: username=$savedUsername, hasDatabaseSession=$hasDatabaseSession, rememberPassword=$savedRememberPassword');

    // ✅ Nếu đã có database session (đã đăng nhập tài khoản nhân sự trước đó)
    if (hasDatabaseSession && savedUsername != null && savedPassword != null && savedRememberPassword) {
      // ✅ Tự động đăng nhập tài khoản nhân sự KHÔNG HIỂN thị form đăng nhập
      print('✅ Auto-login sub-account: $savedUsername');
      setState(() {
        isAutoLoginInProgress = true; // ✅ Đánh dấu đang auto-login
      });
      
      usernameController.text = savedUsername;
      passwordController.text = savedPassword;
      
      // ✅ Gọi loginSubAccount() để authenticate
      await loginSubAccount();
      
      setState(() {
        isAutoLoginInProgress = false; // ✅ Hoàn thành auto-login
      });
    } else {
      print('⏭️ No auto-login: showing login screen');
      // ✅ Không có hardcode tài khoản nào - Mọi user đều phải đăng nhập bình thường
    }
  }

  Future<void> _savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('home_isPasswordHidden', isPasswordHidden);
    await prefs.setBool('home_rememberPassword', rememberMe);
    if (rememberMe) {
      await prefs.setString('home_username', usernameController.text.trim());
      await prefs.setString('home_password', passwordController.text.trim());
      print('✅ Saved sub-account credentials: ${usernameController.text.trim()}');
    } else {
      await prefs.remove('home_username');
      await prefs.remove('home_password');
    }
  }

  Future<void> loginSubAccount() async {
    setState(() {
      isLoading = true;
      errorText = null;
    });
    try {
      final response = await widget.tenantClient
          .from('sub_accounts')
          .select('id, username, password_hash, permissions, doanhso')
          .eq('username', usernameController.text.trim())
          .maybeSingle();

      if (response == null) {
        setState(() {
          errorText = 'Tài khoản không tồn tại';
          isLoading = false;
        });
        return;
      }

      final passwordHash = response['password_hash'] as String;
      final isPasswordValid = BCrypt.checkpw(passwordController.text.trim(), passwordHash);
      if (!isPasswordValid) {
        setState(() {
          errorText = 'Mật khẩu không đúng';
          isLoading = false;
        });
        return;
      }

      // Nếu là admin, đảm bảo có tất cả quyền
      var userPermissions = (response['permissions'] as List<dynamic>?)?.map((perm) => perm.toString()).toList() ?? [];
      if (response['username'].toString().toLowerCase() == 'admin') {
        // Kiểm tra xem admin có thiếu quyền nào không
        final missingPermissions = allPermissions.where((perm) => !userPermissions.contains(perm)).toList();
        if (missingPermissions.isNotEmpty) {
          // Cập nhật quyền cho admin trong database
          await widget.tenantClient
              .from('sub_accounts')
              .update({'permissions': allPermissions})
              .eq('username', 'admin');
          userPermissions = List<String>.from(allPermissions);
          print('✅ Updated admin permissions. Added: $missingPermissions');
        }
      }

      // ✅ Luôn lưu preferences khi đăng nhập thành công
      await _savePreferences();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('has_database_session', true);
      
      // ✅ Nếu checkbox "Nhớ mật khẩu" được chọn, lưu credentials
      if (rememberMe) {
        await prefs.setString('home_username', usernameController.text.trim());
        await prefs.setString('home_password', passwordController.text.trim());
        await prefs.setBool('home_rememberPassword', true);
        print('✅ Saved credentials for auto-login: ${usernameController.text.trim()}');
      }
      
      // Fetch doanhso
      final doanhsoValue = double.tryParse(response['doanhso']?.toString() ?? '0') ?? 0;
      
      setState(() {
        loggedInUsername = response['username'].toString();
        loggedInDoanhso = doanhsoValue;
        permissions = userPermissions;
        print('Permissions set for user $loggedInUsername: $permissions');
        isSubAccountLoggedIn = true;
        isLoading = false;
      });
    } catch (e) {
      setState(() {
        errorText = 'Lỗi khi đăng nhập: $e';
        isLoading = false;
      });
    }
  }

  String _formatNumber(double value) {
    return NumberFormat('#,###', 'vi_VN').format(value).replaceAll(',', '.');
  }

  Future<void> _logoutSubAccount() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_database_session', false);
    await prefs.remove('home_username');
    await prefs.remove('home_password');
    await prefs.setBool('home_rememberPassword', false);
    
    setState(() {
      isSubAccountLoggedIn = false;
      loggedInUsername = null;
      loggedInDoanhso = null;
      permissions = [];
      usernameController.clear();
      passwordController.clear();
    });
  }

  Future<void> _logoutCompletely() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_database_session', false);
    await prefs.remove('home_username');
    await prefs.remove('home_password');
    await prefs.setBool('home_rememberPassword', false);
    await prefs.remove('tenant_url');
    await prefs.remove('tenant_anon_key');
    await prefs.setBool('has_logged_in', false); // ✅ Xóa flag đã đăng nhập
    await prefs.remove('login_email');
    await prefs.remove('login_password');
    await prefs.setBool('login_rememberPassword', false);
    
    setState(() {
      isSubAccountLoggedIn = false;
      loggedInUsername = null;
      permissions = [];
      usernameController.clear();
      passwordController.clear();
    });
    
    Navigator.pushReplacementNamed(context, '/');
  }

  Widget _buildIconButton(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback? onTap,
    Color bgColor,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 64,
            height: 64,
        decoration: BoxDecoration(
          color: bgColor,
              borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
                  color: bgColor.withOpacity(0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
            )
          ],
        ),
            child: Icon(icon, size: 32, color: Colors.white),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              color: Colors.black87,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTransactionTile(
    BuildContext context,
    String label,
    IconData icon,
    Widget page,
    Color color,
  ) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => page),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withOpacity(0.5), width: 1.5),
        ),
        padding: const EdgeInsets.all(8),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircleAvatar(
                backgroundColor: color,
                radius: 18,
                child: Icon(icon, color: Colors.white, size: 18),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _hasAnyPermissionForTab(List<String> requiredPermissions) {
    return requiredPermissions.any((perm) => permissions.contains(perm));
  }

  Widget _buildTransactionTabs() {
    final buySellPermissions = [
      'access_import_form',
      'access_return_form',
      'access_sale_form',
      'access_fix_send_form',
      'access_fix_receive_form',
      'access_reimport_form',
    ];
    final transportPermissions = [
      'access_transfer_local_form',
      'access_transfer_global_form',
      'access_transfer_receive_form',
      'access_transfer_fee_form',
      'access_warehouse_form',
    ];
    final financePermissions = [
      'access_payment_form',
      'access_receive_form',
      'access_income_other_form',
      'access_cost_form',
      'access_exchange_form',
      'access_transfer_fund_form',
    ];

    return DefaultTabController(
      length: 3,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            color: Colors.black,
            child: TabBar(
              indicatorColor: Colors.yellow,
              labelColor: Colors.yellow,
              unselectedLabelColor: Colors.white70,
              labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              tabs: const [
                Tab(text: 'Mua / Bán'),
                Tab(text: 'Vận chuyển'),
                Tab(text: 'Tài chính'),
              ],
            ),
          ),
          SizedBox(
            height: 280,
            child: TabBarView(
              children: [
                _hasAnyPermissionForTab(buySellPermissions)
                    ? Builder(
                        builder: (context) {
                          final tiles = <Widget>[];
                          if (permissions.contains('access_import_form')) {
                            tiles.add(_buildTransactionTile(
                              context,
                              'Nhập hàng',
                              Icons.download,
                              ImportForm(tenantClient: widget.tenantClient),
                              Colors.green,
                            ));
                          }
                          if (permissions.contains('access_return_form')) {
                            tiles.add(_buildTransactionTile(
                              context,
                              'Trả hàng',
                              Icons.undo,
                              ReturnForm(tenantClient: widget.tenantClient),
                              Colors.orange,
                            ));
                          }
                          if (permissions.contains('access_sale_form')) {
                            tiles.add(_buildTransactionTile(
                              context,
                              'Bán hàng',
                              Icons.point_of_sale,
                              SaleForm(tenantClient: widget.tenantClient),
                              Colors.blue,
                            ));
                          }
                          if (permissions.contains('access_fix_send_form')) {
                            tiles.add(_buildTransactionTile(
                              context,
                              'Gửi fix lỗi',
                              Icons.build,
                              FixSendForm(tenantClient: widget.tenantClient),
                              Colors.deepPurple,
                            ));
                          }
                          if (permissions.contains('access_fix_receive_form')) {
                            tiles.add(_buildTransactionTile(
                              context,
                              'Nhận fix về',
                              Icons.assignment_turned_in,
                              FixReceiveForm(tenantClient: widget.tenantClient),
                              Colors.teal,
                            ));
                          }
                          if (permissions.contains('access_reimport_form')) {
                            tiles.add(_buildTransactionTile(
                              context,
                              'Nhập lại hàng',
                              Icons.replay,
                              ReimportForm(tenantClient: widget.tenantClient),
                              Colors.brown,
                            ));
                            tiles.add(_buildTransactionTile(
                              context,
                              'Cod Hoàn Hàng',
                              Icons.assignment_return,
                              CodReturnForm(tenantClient: widget.tenantClient),
                              Colors.deepPurpleAccent,
                            ));
                          }
                          return GridView.count(
                            padding: const EdgeInsets.all(12),
                            crossAxisCount: 4,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 10,
                            childAspectRatio: 1.0,
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            children: tiles,
                          );
                        },
                      )
                    : const Center(
                        child: Text(
                          'Bạn không có quyền truy cập chức năng nào trong tab Mua / Bán',
                          style: TextStyle(fontSize: 14, color: Colors.grey),
                          textAlign: TextAlign.center,
                        ),
                      ),
                _hasAnyPermissionForTab(transportPermissions)
                    ? Builder(
                        builder: (context) {
                          final tiles = <Widget>[];
                          if (permissions.contains('access_transfer_local_form')) {
                            tiles.add(_buildTransactionTile(
                              context,
                              'Chuyển nội địa',
                              Icons.local_shipping,
                              TransferLocalForm(tenantClient: widget.tenantClient),
                              Colors.orangeAccent,
                            ));
                          }
                          if (permissions.contains('access_transfer_global_form')) {
                            tiles.add(_buildTransactionTile(
                              context,
                              'Chuyển quốc tế',
                              Icons.flight_takeoff,
                              TransferGlobalForm(tenantClient: widget.tenantClient),
                              Colors.pink,
                            ));
                          }
                          if (permissions.contains('access_transfer_receive_form')) {
                            tiles.add(_buildTransactionTile(
                              context,
                              'Nhập kho VC',
                              Icons.inventory,
                              TransferReceiveForm(tenantClient: widget.tenantClient),
                              Colors.deepOrange,
                            ));
                          }
                          if (permissions.contains('access_transfer_fee_form')) {
                            tiles.add(_buildTransactionTile(
                              context,
                              'Cước vận chuyển',
                              Icons.price_change,
                              TransferFeeForm(tenantClient: widget.tenantClient),
                              Colors.green,
                            ));
                          }
                          if (permissions.contains('access_warehouse_form')) {
                            tiles.add(_buildTransactionTile(
                              context,
                              'Thêm / Sửa kho',
                              Icons.warehouse,
                              WarehouseForm(tenantClient: widget.tenantClient),
                              Colors.indigo,
                            ));
                          }
                          return GridView.count(
                            padding: const EdgeInsets.all(12),
                            crossAxisCount: 4,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 10,
                            childAspectRatio: 1.0,
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            children: tiles,
                          );
                        },
                      )
                    : const Center(
                        child: Text(
                          'Bạn không có quyền truy cập chức năng nào trong tab Vận chuyển',
                          style: TextStyle(fontSize: 14, color: Colors.grey),
                          textAlign: TextAlign.center,
                        ),
                      ),
                _hasAnyPermissionForTab(financePermissions)
                    ? Builder(
                        builder: (context) {
                          final tiles = <Widget>[];
                          if (permissions.contains('access_payment_form')) {
                            tiles.add(_buildTransactionTile(
                              context,
                              'Chi đối tác',
                              Icons.money_off,
                              PaymentForm(tenantClient: widget.tenantClient),
                              Colors.redAccent,
                            ));
                          }
                          if (permissions.contains('access_receive_form')) {
                            tiles.add(_buildTransactionTile(
                              context,
                              'Thu đối tác',
                              Icons.attach_money,
                              ReceiveForm(tenantClient: widget.tenantClient),
                              Colors.green,
                            ));
                          }
                          if (permissions.contains('access_income_other_form')) {
                            tiles.add(_buildTransactionTile(
                              context,
                              'Thu nhập khác',
                              Icons.add_card,
                              IncomeOtherForm(tenantClient: widget.tenantClient),
                              Colors.lightBlue,
                            ));
                          }
                          if (permissions.contains('access_cost_form')) {
                            tiles.add(_buildTransactionTile(
                              context,
                              'Chi phí',
                              Icons.money_off_csred,
                              CostForm(tenantClient: widget.tenantClient),
                              Colors.deepOrange,
                            ));
                          }
                          if (permissions.contains('access_exchange_form')) {
                            tiles.add(_buildTransactionTile(
                              context,
                              'Đổi tiền',
                              Icons.currency_exchange,
                              ExchangeForm(tenantClient: widget.tenantClient),
                              Colors.amber,
                            ));
                          }
                          if (permissions.contains('access_transfer_fund_form')) {
                            tiles.add(_buildTransactionTile(
                              context,
                              'Chuyển quỹ',
                              Icons.account_balance_wallet,
                              TransferFundForm(tenantClient: widget.tenantClient),
                              Colors.indigo,
                            ));
                          }
                          return GridView.count(
                            padding: const EdgeInsets.all(12),
                            crossAxisCount: 4,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 10,
                            childAspectRatio: 1.0,
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            children: tiles,
                          );
                        },
                      )
                    : const Center(
                        child: Text(
                          'Bạn không có quyền truy cập chức năng nào trong tab Tài chính',
                          style: TextStyle(fontSize: 14, color: Colors.grey),
                          textAlign: TextAlign.center,
                        ),
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // ✅ Nếu đang auto-login, hiển thị loading screen
    if (isAutoLoginInProgress) {
      return Scaffold(
        backgroundColor: const Color(0xFF121826),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(color: Colors.white),
              const SizedBox(height: 16),
              Text(
                'Đang tự động đăng nhập...',
                style: const TextStyle(color: Colors.white70, fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }
    
    // ✅ Nếu chưa đăng nhập và không phải đang auto-login, hiển thị form đăng nhập
    if (!isSubAccountLoggedIn) {
      return Scaffold(
        backgroundColor: const Color(0xFF121826),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      onPressed: () async {
                        await _logoutCompletely();
                      },
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      tooltip: 'Thoát hoàn toàn',
                    ),
                    const Expanded(
                      child: Text(
                        'Làm Việc Chăm Chỉ Nhé',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                    ),
                    const SizedBox(width: 48),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Tài Khoản Nhân Sự',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: usernameController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Tên tài khoản',
                    hintStyle: const TextStyle(color: Colors.white54),
                    filled: true,
                    fillColor: const Color(0xFF1E293B),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: passwordController,
                  obscureText: isPasswordHidden,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Mật khẩu',
                    hintStyle: const TextStyle(color: Colors.white54),
                    filled: true,
                    fillColor: const Color(0xFF1E293B),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  ),
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  title: const Text('Ẩn mật khẩu', style: TextStyle(color: Colors.white)),
                  value: isPasswordHidden,
                  onChanged: (value) {
                    setState(() {
                      isPasswordHidden = value ?? true;
                    });
                    _savePreferences();
                  },
                  activeColor: Colors.blue,
                  checkColor: Colors.white,
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                ),
                CheckboxListTile(
                  title: const Text('Nhớ mật khẩu', style: TextStyle(color: Colors.white)),
                  value: rememberMe,
                  onChanged: (value) {
                    setState(() {
                      rememberMe = value ?? true;
                    });
                    _savePreferences();
                  },
                  activeColor: Colors.blue,
                  checkColor: Colors.white,
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: isLoading ? null : loginSubAccount,
                  child: isLoading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text('Đăng nhập', style: TextStyle(fontSize: 16, color: Colors.white)),
                ),
                if (errorText != null) ...[
                  const SizedBox(height: 12),
                  Text(errorText!, style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF6F9FF),
      appBar: AppBar(
        centerTitle: true, // ✅ Căn giữa title trong AppBar
        title: loggedInUsername != null
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ✅ Container 1: Tài khoản (màu vàng)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade700,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'Tài Khoản : $loggedInUsername',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8), // ✅ Khoảng cách giữa 2 container
                  // ✅ Container 2: Doanh số (màu xanh lá)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.green.shade700,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'Doanh Số : ${_formatNumber(loggedInDoanhso ?? 0)} đ',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              )
            : const Text('Home', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 4,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onSelected: (value) async {
              if (value == 'logout_subaccount') {
                await _logoutSubAccount();
              } else if (value == 'logout_complete') {
                await _logoutCompletely();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'logout_subaccount',
                child: Row(
                  children: [
                    Icon(Icons.logout, color: Colors.orange),
                    SizedBox(width: 8),
                    Text('Thoát tài khoản nhân sự'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'logout_complete',
                child: Row(
                  children: [
                    Icon(Icons.exit_to_app, color: Colors.red),
                    SizedBox(width: 8),
                    Text('Thoát hoàn toàn'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshDoanhso,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            children: [
              // Phần trên: Phiếu giao dịch với TabBar
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: _buildTransactionTabs(),
              ),
              // Phần dưới: Các chức năng khác
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'Chức năng khác',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                    GridView.count(
                      crossAxisCount: 4,
                      crossAxisSpacing: 12,
          mainAxisSpacing: 16,
                      childAspectRatio: 0.75,
          shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
          children: [
            _buildIconButton(context, Icons.dashboard, 'Tổng quan', () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => OverviewScreen(
                    permissions: permissions,
                    tenantClient: widget.tenantClient,
                  ),
                ),
              );
            }, Colors.deepPurple),
            _buildIconButton(context, Icons.store, 'Kho', () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => InventoryScreen(
                    permissions: permissions,
                    tenantClient: widget.tenantClient,
                  ),
                ),
              );
            }, Colors.teal),
            if (permissions.contains('access_customers_screen'))
              _buildIconButton(context, Icons.people, 'Khách hàng', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => CustomersScreen(
                      permissions: permissions,
                      tenantClient: widget.tenantClient,
                    ),
                  ),
                );
              }, Colors.pink),
            if (permissions.contains('access_suppliers_screen'))
              _buildIconButton(context, Icons.business, 'Nhà cung cấp', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SuppliersScreen(
                      permissions: permissions,
                      tenantClient: widget.tenantClient,
                    ),
                  ),
                );
              }, Colors.blue),
            if (permissions.contains('access_fixers_screen'))
              _buildIconButton(context, Icons.build, 'Đơn vị fix lỗi', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => FixersScreen(
                      permissions: permissions,
                      tenantClient: widget.tenantClient,
                    ),
                  ),
                );
              }, Colors.green),
            if (permissions.contains('access_transporters_screen'))
              _buildIconButton(context, Icons.local_shipping, 'Đơn vị\nvận chuyển', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TransportersScreen(
                      permissions: permissions,
                      tenantClient: widget.tenantClient,
                    ),
                  ),
                );
              }, Colors.indigo),
            if (permissions.contains('access_crm_screen'))
              _buildIconButton(context, Icons.support_agent, 'CRM', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => CRMScreen(
                      permissions: permissions,
                      tenantClient: widget.tenantClient,
                    ),
                  ),
                );
              }, Colors.red),
            if (permissions.contains('access_orders_screen'))
              _buildIconButton(context, Icons.shopping_cart, 'Khách\nĐặt Hàng', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => OrdersScreen(
                      permissions: permissions,
                      tenantClient: widget.tenantClient,
                    ),
                  ),
                );
              }, Colors.purple),
            _buildIconButton(context, Icons.category, 'Danh mục', () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => CategoriesScreen(
                    permissions: permissions,
                    tenantClient: widget.tenantClient,
                  ),
                ),
              );
            }, Colors.blueGrey),
            _buildIconButton(context, Icons.history, 'Lịch sử phiếu', () {
              print('Navigating to HistoryScreen with permissions: $permissions');
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => HistoryScreen(
                    permissions: permissions,
                    tenantClient: widget.tenantClient,
                  ),
                ),
              );
            }, Colors.lime),
            if (loggedInUsername != null && loggedInUsername!.toLowerCase() == 'admin')
              _buildIconButton(context, Icons.input, 'Nhập đầu kỳ', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => InitialDataScreen(tenantClient: widget.tenantClient),
                  ),
                );
              }, Colors.brown),
            if (permissions.contains('access_excel_report'))
              _buildIconButton(context, Icons.file_copy, 'Nhập Xuất\nExcel', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ExcelReportScreen(
                      permissions: permissions,
                      tenantClient: widget.tenantClient,
                    ),
                  ),
                );
              }, Colors.amber),
            if (permissions.contains('manage_accounts'))
              _buildIconButton(context, Icons.account_circle, 'Tài khoản', () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AccountScreen(tenantClient: widget.tenantClient),
                  ),
                );
              }, Colors.cyan),
                          if (loggedInUsername != null && loggedInUsername!.toLowerCase() == 'admin')
                            _buildIconButton(context, Icons.telegram, 'Telegram', () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => TelegramConfigScreen(tenantClient: widget.tenantClient),
                                ),
                              );
                            }, Colors.blue),
                        ],
                      ),
          ],
              ),
            ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _refreshDoanhso() async {
    if (loggedInUsername == null) return;
    
    try {
      final response = await widget.tenantClient
          .from('sub_accounts')
          .select('doanhso')
          .eq('username', loggedInUsername!)
          .maybeSingle();

      if (response != null && mounted) {
        final doanhsoValue = double.tryParse(response['doanhso']?.toString() ?? '0') ?? 0;
        setState(() {
          loggedInDoanhso = doanhsoValue;
        });
      }
    } catch (e) {
      print('Error refreshing doanhso: $e');
    }
  }
}