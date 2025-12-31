import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:convert';

/// Service để gửi thông báo Telegram
class TelegramService {
  static SupabaseClient? _tenantClient;
  static String? _botToken;
  static String? _chatId;
  static Set<String> _enabledTransactionTypes = {}; // Danh sách loại phiếu được bật

  /// Khởi tạo service với tenant client
  static Future<void> init(SupabaseClient tenantClient) async {
    _tenantClient = tenantClient;
    await _loadConfig();
  }

  /// Load cấu hình từ database
  static Future<void> _loadConfig() async {
    if (_tenantClient == null) return;

    try {
      // Lấy bot token, chat ID và danh sách loại phiếu từ bảng settings
      final settings = await _tenantClient!
          .from('settings')
          .select('key, value')
          .inFilter('key', ['telegram_bot_token', 'telegram_chat_id', 'telegram_enabled_types']);

      for (var setting in settings) {
        final key = setting['key']?.toString();
        final value = setting['value']?.toString();
        
        if (key == 'telegram_bot_token') {
          _botToken = value;
        } else if (key == 'telegram_chat_id') {
          _chatId = value;
        } else if (key == 'telegram_enabled_types') {
          // Parse danh sách loại phiếu được bật (lưu dạng JSON array string)
          if (value != null && value.isNotEmpty) {
            try {
              final List<dynamic> typesList = jsonDecode(value);
              _enabledTransactionTypes = typesList.map((e) => e.toString()).toSet();
            } catch (e) {
              print('⚠️ Lỗi parse telegram_enabled_types: $e');
              _enabledTransactionTypes = {}; // Mặc định: không có loại nào được bật
            }
          } else {
            _enabledTransactionTypes = {}; // Mặc định: không có loại nào được bật
          }
        }
      }
      
      // Nếu chưa có cấu hình loại phiếu, mặc định bật tất cả
      if (_enabledTransactionTypes.isEmpty && _botToken != null && _chatId != null) {
        _enabledTransactionTypes = _getAllTransactionTypes();
      }
    } catch (e) {
      print('⚠️ Không thể load Telegram config: $e');
      print('💡 Tạo bảng settings nếu chưa có hoặc cấu hình thủ công');
    }
  }
  
  /// Lấy danh sách tất cả các loại phiếu
  static Set<String> _getAllTransactionTypes() {
    return {
      'sale',
      'import',
      'return',
      'reimport',
      'cod_return',
      'fix_send',
      'fix_receive',
      'transfer_local',
      'transfer_global',
      'transfer_receive',
      'payment',
      'receive',
      'cost',
      'transfer_fund',
      'exchange',
      'income_other',
    };
  }
  
  /// Lấy danh sách tên hiển thị của các loại phiếu
  static Map<String, String> getTransactionTypeLabels() {
    return {
      'sale': 'Bán hàng',
      'import': 'Nhập hàng',
      'return': 'Trả hàng',
      'reimport': 'Nhập lại hàng',
      'cod_return': 'COD Hoàn',
      'fix_send': 'Gửi sửa',
      'fix_receive': 'Nhận sửa',
      'transfer_local': 'Chuyển kho nội địa',
      'transfer_global': 'Chuyển kho quốc tế',
      'transfer_receive': 'Nhập kho vận chuyển',
      'payment': 'Chi đối tác',
      'receive': 'Thu đối tác',
      'cost': 'Chi phí',
      'transfer_fund': 'Chuyển quỹ',
      'exchange': 'Đổi tiền',
      'income_other': 'Thu khác',
    };
  }

  /// Lưu cấu hình bot token, chat ID và danh sách loại phiếu
  static Future<void> saveConfig(String botToken, String chatId, {Set<String>? enabledTypes}) async {
    if (_tenantClient == null) {
      throw Exception('TelegramService chưa được khởi tạo. Gọi init() trước.');
    }

    try {
      // Kiểm tra xem đã có config chưa
      final existingToken = await _tenantClient!
          .from('settings')
          .select('key')
          .eq('key', 'telegram_bot_token')
          .maybeSingle();

      final existingChatId = await _tenantClient!
          .from('settings')
          .select('key')
          .eq('key', 'telegram_chat_id')
          .maybeSingle();

      final existingEnabledTypes = await _tenantClient!
          .from('settings')
          .select('key')
          .eq('key', 'telegram_enabled_types')
          .maybeSingle();

      // Upsert bot token
      if (existingToken != null) {
        await _tenantClient!
            .from('settings')
            .update({'value': botToken})
            .eq('key', 'telegram_bot_token');
      } else {
        await _tenantClient!
            .from('settings')
            .insert({'key': 'telegram_bot_token', 'value': botToken});
      }

      // Upsert chat ID
      if (existingChatId != null) {
        await _tenantClient!
            .from('settings')
            .update({'value': chatId})
            .eq('key', 'telegram_chat_id');
      } else {
        await _tenantClient!
            .from('settings')
            .insert({'key': 'telegram_chat_id', 'value': chatId});
      }

      // Upsert danh sách loại phiếu được bật
      final typesToSave = enabledTypes ?? _enabledTransactionTypes;
      final typesJson = jsonEncode(typesToSave.toList());
      
      if (existingEnabledTypes != null) {
        await _tenantClient!
            .from('settings')
            .update({'value': typesJson})
            .eq('key', 'telegram_enabled_types');
      } else {
        await _tenantClient!
            .from('settings')
            .insert({'key': 'telegram_enabled_types', 'value': typesJson});
      }

      // Cập nhật cache
      _botToken = botToken;
      _chatId = chatId;
      _enabledTransactionTypes = typesToSave;

      print('✅ Đã lưu cấu hình Telegram');
    } catch (e) {
      print('❌ Lỗi khi lưu cấu hình Telegram: $e');
      throw Exception('Không thể lưu cấu hình Telegram: $e');
    }
  }

  /// Gửi thông báo đến nhóm Telegram
  static Future<void> sendMessage(String message) async {
    if (_botToken == null || _chatId == null) {
      print('⚠️ Telegram chưa được cấu hình. Bỏ qua gửi thông báo.');
      return;
    }

    try {
      final url = Uri.parse(
        'https://api.telegram.org/bot$_botToken/sendMessage',
      );

      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'chat_id': _chatId,
          'text': message,
          'parse_mode': 'HTML', // Hỗ trợ HTML formatting
        }),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final result = jsonDecode(response.body);
        if (result['ok'] == true) {
          print('✅ Đã gửi thông báo Telegram');
        } else {
          print('❌ Telegram API error: ${result['description']}');
        }
      } else {
        print('❌ Lỗi khi gửi Telegram: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      print('❌ Exception khi gửi Telegram: $e');
      // Không throw để không làm gián đoạn flow chính
    }
  }

  /// Gửi thông báo giao dịch với format đẹp và chi tiết
  /// [transactionType] là loại phiếu (sale, import, return, etc.)
  static Future<void> sendTransactionNotification({
    required String transactionType, // Loại phiếu (sale, import, etc.)
    required String type, // Tên hiển thị (Bán hàng, Nhập hàng, etc.)
    required String ticketId,
    // Thông tin đối tác (cho phiếu thu/chi)
    String? partnerType, // Loại đối tác: customers, suppliers, fix_units, transporters
    String? partnerName, // Tên đối tác
    // Thông tin hàng hóa (cho phiếu bán/nhập/trả)
    String? customer, // Khách hàng
    String? productName, // Tên sản phẩm
    int? quantity, // Số lượng
    String? imeiList, // Danh sách IMEI (có thể nhiều IMEI, phân cách bằng dấu phẩy)
    String? price, // Giá đơn vị
    String? totalAmount, // Tổng hóa đơn
    String? currency, // Đơn vị tiền
    String? paymentMethod, // Phương thức thanh toán (Công nợ, Ship COD, Tài khoản, etc.)
    String? account, // Tài khoản
    String? finalBalance, // Số dư cuối của tài khoản
    String? note, // Ghi chú
  }) async {
    // Kiểm tra xem loại phiếu này có được bật không
    if (!_enabledTransactionTypes.contains(transactionType)) {
      print('⚠️ Loại phiếu "$transactionType" chưa được bật trong cấu hình Telegram. Bỏ qua gửi thông báo.');
      return;
    }
    
    final buffer = StringBuffer();
    buffer.writeln('🔔 <b>Giao dịch mới</b>');
    buffer.writeln('');
    buffer.writeln('📋 <b>Loại:</b> $type');
    buffer.writeln('🎫 <b>Mã phiếu:</b> $ticketId');
    buffer.writeln('');
    
    // Thông tin đối tác (cho phiếu thu/chi)
    if (partnerType != null && partnerName != null && partnerName.isNotEmpty) {
      final partnerTypeLabel = _getPartnerTypeLabel(partnerType);
      buffer.writeln('🤝 <b>Đối tác:</b> $partnerTypeLabel');
      buffer.writeln('👤 <b>Tên đối tác:</b> $partnerName');
    }
    
    // Thông tin khách hàng (cho phiếu bán/nhập/trả)
    if (customer != null && customer.isNotEmpty) {
      buffer.writeln('👤 <b>Khách hàng:</b> $customer');
    }
    
    // Thông tin sản phẩm (cho phiếu hàng hóa)
    if (productName != null && productName.isNotEmpty) {
      buffer.writeln('📦 <b>Sản phẩm:</b> $productName');
    }
    
    if (quantity != null && quantity > 0) {
      buffer.writeln('🔢 <b>Số lượng:</b> $quantity');
    }
    
    if (imeiList != null && imeiList.isNotEmpty) {
      // Format IMEI: nếu nhiều IMEI, hiển thị mỗi IMEI 1 dòng
      final imeiArray = imeiList.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      if (imeiArray.length == 1) {
        buffer.writeln('📱 <b>IMEI:</b> ${imeiArray.first}');
      } else {
        buffer.writeln('📱 <b>IMEI:</b>');
        for (var imei in imeiArray) {
          buffer.writeln('   • $imei');
        }
      }
    }
    
    // Thông tin giá và tiền
    if (price != null && price.isNotEmpty && quantity != null && quantity > 1) {
      buffer.writeln('💵 <b>Giá đơn vị:</b> $price $currency');
    }
    
    if (totalAmount != null && totalAmount.isNotEmpty) {
      buffer.writeln('💰 <b>Tổng hóa đơn:</b> $totalAmount $currency');
    }
    
    // Phương thức thanh toán
    if (paymentMethod != null && paymentMethod.isNotEmpty) {
      buffer.writeln('💳 <b>Phương thức:</b> $paymentMethod');
    }
    
    // Tài khoản và số dư
    if (account != null && account.isNotEmpty) {
      buffer.writeln('🏦 <b>Tài khoản:</b> $account');
      if (finalBalance != null && finalBalance.isNotEmpty) {
        // Với exchange và transfer_fund, finalBalance đã chứa đầy đủ thông tin cả 2 tài khoản
        // Nên không cần thêm currency vào cuối
        if (transactionType == 'exchange' || transactionType == 'transfer_fund') {
          buffer.writeln('💼 <b>Số dư cuối:</b> $finalBalance');
        } else {
          buffer.writeln('💼 <b>Số dư cuối:</b> $finalBalance $currency');
        }
      }
    }
    
    if (note != null && note.isNotEmpty) {
      buffer.writeln('📝 <b>Ghi chú:</b> $note');
    }
    
    buffer.writeln('');
    buffer.writeln('⏰ <i>${DateTime.now().toString().substring(0, 19)}</i>');

    await sendMessage(buffer.toString());
  }
  
  /// Lấy tên hiển thị của loại đối tác
  static String _getPartnerTypeLabel(String partnerType) {
    switch (partnerType) {
      case 'customers':
        return 'Khách hàng';
      case 'suppliers':
        return 'Nhà cung cấp';
      case 'fix_units':
        return 'Đơn vị sửa chữa';
      case 'transporters':
        return 'Đơn vị vận chuyển';
      default:
        return partnerType;
    }
  }
  
  /// Lấy danh sách loại phiếu được bật
  static Set<String> getEnabledTransactionTypes() {
    return Set<String>.from(_enabledTransactionTypes);
  }
  
  /// Kiểm tra xem loại phiếu có được bật không
  static bool isTransactionTypeEnabled(String transactionType) {
    // Nếu chưa có cấu hình, mặc định bật tất cả
    if (_enabledTransactionTypes.isEmpty) {
      return true;
    }
    return _enabledTransactionTypes.contains(transactionType);
  }

  /// Kiểm tra xem Telegram đã được cấu hình chưa
  static bool isConfigured() {
    return _botToken != null && _chatId != null && _botToken!.isNotEmpty && _chatId!.isNotEmpty;
  }

  /// Lấy thông tin cấu hình hiện tại
  static Map<String, dynamic> getConfig() {
    return {
      'bot_token': _botToken,
      'chat_id': _chatId,
      'enabled_types': _enabledTransactionTypes.toList(),
    };
  }
}

