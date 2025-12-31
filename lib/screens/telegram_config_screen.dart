import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../helpers/telegram_service.dart';

class TelegramConfigScreen extends StatefulWidget {
  final SupabaseClient tenantClient;

  const TelegramConfigScreen({
    super.key,
    required this.tenantClient,
  });

  @override
  State<TelegramConfigScreen> createState() => _TelegramConfigScreenState();
}

class _TelegramConfigScreenState extends State<TelegramConfigScreen> {
  final _botTokenController = TextEditingController();
  final _chatIdController = TextEditingController();
  bool _isLoading = false;
  bool _isSaving = false;
  String? _errorMessage;
  String? _successMessage;
  Set<String> _selectedTransactionTypes = {}; // Danh sách loại phiếu được chọn

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _botTokenController.dispose();
    _chatIdController.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await TelegramService.init(widget.tenantClient);
      final config = TelegramService.getConfig();
      
      setState(() {
        _botTokenController.text = config['bot_token'] ?? '';
        _chatIdController.text = config['chat_id'] ?? '';
        
        // Load danh sách loại phiếu được chọn
        final enabledTypes = config['enabled_types'] as List<dynamic>?;
        if (enabledTypes != null && enabledTypes.isNotEmpty) {
          _selectedTransactionTypes = enabledTypes.map((e) => e.toString()).toSet();
        } else {
          // Mặc định: chọn tất cả các loại phiếu
          _selectedTransactionTypes = TelegramService.getTransactionTypeLabels().keys.toSet();
        }
        
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Không thể tải cấu hình: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _saveConfig() async {
    final botToken = _botTokenController.text.trim();
    final chatId = _chatIdController.text.trim();

    if (botToken.isEmpty || chatId.isEmpty) {
      setState(() {
        _errorMessage = 'Vui lòng điền đầy đủ Bot Token và Chat ID';
      });
      return;
    }

    if (_selectedTransactionTypes.isEmpty) {
      setState(() {
        _errorMessage = 'Vui lòng chọn ít nhất một loại phiếu để gửi thông báo';
      });
      return;
    }

    setState(() {
      _isSaving = true;
      _errorMessage = null;
      _successMessage = null;
    });

    try {
      await TelegramService.saveConfig(botToken, chatId, enabledTypes: _selectedTransactionTypes);
      
      // Test gửi thông báo
      await TelegramService.sendMessage('✅ <b>Test thông báo</b>\n\nCấu hình Telegram đã được lưu thành công!');
      
      setState(() {
        _successMessage = 'Đã lưu cấu hình và gửi thông báo test thành công!';
        _isSaving = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Lỗi khi lưu cấu hình: $e';
        _isSaving = false;
      });
    }
  }
  
  void _toggleTransactionType(String type) {
    setState(() {
      if (_selectedTransactionTypes.contains(type)) {
        _selectedTransactionTypes.remove(type);
      } else {
        _selectedTransactionTypes.add(type);
      }
    });
  }
  
  void _selectAllTransactionTypes() {
    setState(() {
      _selectedTransactionTypes = TelegramService.getTransactionTypeLabels().keys.toSet();
    });
  }
  
  void _deselectAllTransactionTypes() {
    setState(() {
      _selectedTransactionTypes.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cấu hình Telegram', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Hướng dẫn
                  Card(
                    color: Colors.blue.shade50,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '📱 Hướng dẫn cấu hình Telegram Bot',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 12),
                          _buildInstructionStep(
                            '1',
                            'Tạo Telegram Bot',
                            'Tìm @BotFather trên Telegram và gửi lệnh /newbot. Làm theo hướng dẫn để tạo bot mới và lấy Bot Token.',
                          ),
                          const SizedBox(height: 8),
                          _buildInstructionStep(
                            '2',
                            'Thêm bot vào nhóm',
                            'Thêm bot vừa tạo vào nhóm Telegram của bạn. Sau đó gửi một tin nhắn bất kỳ trong nhóm.',
                          ),
                          const SizedBox(height: 8),
                          _buildInstructionStep(
                            '3',
                            'Lấy Chat ID',
                            'Truy cập: https://api.telegram.org/bot<BOT_TOKEN>/getUpdates\nThay <BOT_TOKEN> bằng token của bạn. Tìm "chat":{"id":-123456789} trong kết quả. Số âm là Chat ID của nhóm.',
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  
                  // Form cấu hình
                  TextField(
                    controller: _botTokenController,
                    decoration: const InputDecoration(
                      labelText: 'Bot Token',
                      hintText: 'Nhập Bot Token từ @BotFather',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.vpn_key),
                    ),
                    obscureText: true,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _chatIdController,
                    decoration: const InputDecoration(
                      labelText: 'Chat ID',
                      hintText: 'Nhập Chat ID của nhóm (số âm)',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.chat),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 24),
                  
                  // Danh sách loại phiếu
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                '📋 Loại phiếu gửi thông báo',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Row(
                                children: [
                                  TextButton(
                                    onPressed: _selectAllTransactionTypes,
                                    child: const Text('Chọn tất cả', style: TextStyle(fontSize: 12)),
                                  ),
                                  TextButton(
                                    onPressed: _deselectAllTransactionTypes,
                                    child: const Text('Bỏ chọn tất cả', style: TextStyle(fontSize: 12)),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Chọn các loại phiếu sẽ gửi thông báo Telegram:',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                          const SizedBox(height: 12),
                          ...TelegramService.getTransactionTypeLabels().entries.map((entry) {
                            final type = entry.key;
                            final label = entry.value;
                            final isSelected = _selectedTransactionTypes.contains(type);
                            
                            return CheckboxListTile(
                              title: Text(label),
                              value: isSelected,
                              onChanged: (value) => _toggleTransactionType(type),
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                            );
                          }).toList(),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  
                  // Thông báo lỗi/thành công
                  if (_errorMessage != null)
                    Card(
                      color: Colors.red.shade50,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            const Icon(Icons.error, color: Colors.red),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _errorMessage!,
                                style: const TextStyle(color: Colors.red),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_successMessage != null)
                    Card(
                      color: Colors.green.shade50,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            const Icon(Icons.check_circle, color: Colors.green),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _successMessage!,
                                style: const TextStyle(color: Colors.green),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_errorMessage != null || _successMessage != null)
                    const SizedBox(height: 16),
                  
                  // Nút lưu
                  ElevatedButton(
                    onPressed: _isSaving ? null : _saveConfig,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: _isSaving
                        ? const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                ),
                              ),
                              SizedBox(width: 12),
                              Text('Đang lưu...'),
                            ],
                          )
                        : const Text('Lưu cấu hình'),
                  ),
                  const SizedBox(height: 16),
                  
                  // Nút test
                  OutlinedButton(
                    onPressed: _isSaving ? null : () async {
                      if (!TelegramService.isConfigured()) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Vui lòng lưu cấu hình trước khi test'),
                            backgroundColor: Colors.orange,
                          ),
                        );
                        return;
                      }
                      
                      try {
                        await TelegramService.sendMessage('🧪 <b>Test thông báo</b>\n\nĐây là thông báo test từ ứng dụng!');
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Đã gửi thông báo test thành công!'),
                              backgroundColor: Colors.green,
                            ),
                          );
                        }
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Lỗi: $e'),
                              backgroundColor: Colors.red,
                            ),
                          );
                        }
                      }
                    },
                    child: const Text('Gửi thông báo test'),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildInstructionStep(String number, String title, String description) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: Colors.blue,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              number,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                description,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

