import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../notification_service.dart';
import 'fix_send_form.dart';
import 'dart:math' as math;
import 'package:intl/intl.dart';

// Constants for batch processing and limits
const int maxBatchSize = 1000;
const int maxRetries = 3;
const Duration retryDelay = Duration(seconds: 1);
const int maxImeiLimit = 100000;
const int maxTicketItems = 100;
const int displayImeiLimit = 100;

/// Retries a function with exponential backoff
Future<T> retry<T>(Future<T> Function() fn, {String? operation}) async {
  for (int attempt = 0; attempt < maxRetries; attempt++) {
    try {
      return await fn();
    } catch (e) {
      if (attempt == maxRetries - 1) {
        throw Exception('${operation ?? 'Operation'} failed after $maxRetries attempts: $e');
      }
      await Future.delayed(retryDelay * math.pow(2, attempt));
    }
  }
  throw Exception('Retry failed');
}

class FixSendSummary extends StatefulWidget {
  final SupabaseClient tenantClient;
  final List<Map<String, dynamic>> ticketItems;

  const FixSendSummary({
    super.key,
    required this.tenantClient,
    required this.ticketItems,
  });

  @override
  State<FixSendSummary> createState() => _FixSendSummaryState();
}

class _FixSendSummaryState extends State<FixSendSummary> {
  bool isLoading = false;
  bool isProcessing = false;
  String? errorMessage;
  final NumberFormat numberFormat = NumberFormat.decimalPattern('vi_VN');

  @override
  void initState() {
    super.initState();
  }

  String generateTicketId() {
    final now = DateTime.now();
    final dateFormat = DateFormat('yyyyMMdd-HHmmss');
    final randomNum = (100 + (DateTime.now().millisecondsSinceEpoch % 900)).toString();
    return 'FIXSEND-${dateFormat.format(now)}-$randomNum';
  }

  String formatNumberLocal(num value) {
    return NumberFormat('#,###', 'vi_VN').format(value).replaceAll(',', '.');
  }

  Future<Map<String, dynamic>> _createSnapshot(String ticketId, List<String> imeiList) async {
    final supabase = widget.tenantClient;
    final snapshotData = <String, dynamic>{};

    try {
      if (imeiList.isNotEmpty) {
        List<Map<String, dynamic>> productsData = [];
        for (int i = 0; i < imeiList.length; i += maxBatchSize) {
          final batchImeis = imeiList.sublist(i, math.min(i + maxBatchSize, imeiList.length));
          final response = await retry(
            () => supabase
                .from('products')
                .select('imei, product_id, status, send_fix_date, fix_unit, fix_unit_id')
                .inFilter('imei', batchImeis),
            operation: 'Fetch products snapshot batch ${i ~/ maxBatchSize + 1}',
          );
          productsData.addAll(response.cast<Map<String, dynamic>>());
        }
        snapshotData['products'] = productsData;
      }

      snapshotData['fix_send_orders'] = widget.ticketItems.map((item) {
        return {
          'ticket_id': ticketId,
          'fixer': item['fixer'],
          'fix_unit_id': item['fixer_id'],
          'product_id': item['product_id'],
          'product_name': item['product_name'],
          'imei': item['imei'],
          'quantity': item['quantity'],
          'note': item['note'],
        };
      }).toList();

      return snapshotData;
    } catch (e) {
      throw Exception('Failed to create snapshot: $e');
    }
  }

  Future<void> createTicket(BuildContext scaffoldContext) async {
    if (isProcessing) return;
    
    // Set isProcessing ngay để ngăn double-submit
    setState(() {
      isProcessing = true;
    });

    if (widget.ticketItems.isEmpty) {
      setState(() {
        isProcessing = false;
      });
      if (mounted) {
        showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Vui lòng thêm ít nhất một sản phẩm để tạo phiếu!'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
      }
      return;
    }

    if (widget.ticketItems.length > maxTicketItems) {
      setState(() {
        isProcessing = false;
      });
      if (mounted) {
        showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text('Số lượng mục gửi sửa (${widget.ticketItems.length}) vượt quá $maxTicketItems. Vui lòng giảm số mục để tối ưu hiệu suất.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
      }
      return;
    }

    List<String> allImeis = [];
    for (var item in widget.ticketItems) {
      final imeiList = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).toList();
      allImeis.addAll(imeiList);
    }

    if (allImeis.length > maxImeiLimit) {
      setState(() {
        isProcessing = false;
      });
      if (mounted) {
        showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text('Số lượng IMEI (${formatNumberLocal(allImeis.length)}) vượt quá $maxImeiLimit. Vui lòng chia thành nhiều phiếu nhỏ hơn.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
      }
      return;
    }

    try {
      final supabase = widget.tenantClient;
      final now = DateTime.now();
      final ticketId = generateTicketId();

      // Hiển thị loading trong lúc tạo phiếu để tránh người dùng nghĩ app bị treo
      showDialog(
        context: scaffoldContext,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          content: Row(
            children: const [
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 16),
              Expanded(child: Text('Đang tạo phiếu...')),
            ],
          ),
        ),
      );

      // Validate IMEIs
      List<String> validImeis = [];
      for (int i = 0; i < allImeis.length; i += maxBatchSize) {
        final batchImeis = allImeis.sublist(i, math.min(i + maxBatchSize, allImeis.length));
        final response = await retry(
          () => supabase
              .from('products')
              .select('imei, product_id')
              .inFilter('imei', batchImeis),
          operation: 'Validate IMEIs batch ${i ~/ maxBatchSize + 1}',
        );

        validImeis.addAll(
          response
              .where((p) => widget.ticketItems.any((item) => p['product_id'] == item['product_id']))
              .map((p) => p['imei'] as String),
        );
      }

      final invalidImeis = allImeis.where((imei) => !validImeis.contains(imei)).toList();
      if (invalidImeis.isNotEmpty) {
        // Đóng loading trước khi báo lỗi
        if (Navigator.of(scaffoldContext, rootNavigator: true).canPop()) {
          Navigator.of(scaffoldContext, rootNavigator: true).pop();
        }
        throw Exception('Các IMEI sau không hợp lệ: ${invalidImeis.take(10).join(', ')}${invalidImeis.length > 10 ? '...' : ''}');
      }

      // Create snapshot (vẫn build snapshot ở client để giữ format cũ, khôi phục không đổi)
      final snapshotData = await retry(
        () => _createSnapshot(ticketId, allImeis),
        operation: 'Create snapshot',
      );

      // Chuẩn bị dữ liệu phiếu gửi sửa
      final fixSendOrders = widget.ticketItems.map((item) {
        return {
          'ticket_id': ticketId,
          'fixer': item['fixer'],
          'fix_unit_id': item['fixer_id'],
          'product_id': item['product_id'],
          'imei': item['imei'],
          'quantity': item['quantity'],
          'note': item['note'],
          'created_at': now.toIso8601String(),
          'iscancelled': false,
        };
      }).toList();

      // Gọi Supabase RPC để thực hiện toàn bộ transaction (insert snapshot + fix_send_orders + update products)
      await retry(
        () => supabase.rpc(
          'create_fix_send_transaction',
          params: {
            'p_ticket_id': ticketId,
            'p_fix_send_orders': fixSendOrders,
            'p_snapshot_data': snapshotData,
            'p_created_at': now.toIso8601String(),
          },
        ),
        operation: 'Create fix_send_transaction',
          );

      // Lấy thông tin sản phẩm và IMEI
      final firstItem = widget.ticketItems.isNotEmpty ? widget.ticketItems.first : null;
      final productName = firstItem != null ? (firstItem['product_name'] as String? ?? 'Không xác định') : 'Không xác định';
      final fixerName = firstItem != null ? (firstItem['fixer'] as String? ?? 'Không xác định') : 'Không xác định';
      final imeiList = widget.ticketItems
          .map((item) => item['imei'] as String)
          .join(', ');
      final totalQuantity = widget.ticketItems.fold<int>(0, (sum, item) => sum + (item['quantity'] as int? ?? 1));
      
      await NotificationService.showNotification(
        131,
        "Phiếu Gửi Sửa Đã Tạo",
        "Đã tạo phiếu gửi sửa với ${formatNumberLocal(widget.ticketItems.length)} mục",
        'fix_send_created',
      );
      
      // ✅ Gửi thông báo push đến tất cả thiết bị
      await NotificationService.sendNotificationToAll(
        "Phiếu Gửi Sửa Đã Tạo",
        "Đã tạo phiếu gửi sửa với ${formatNumberLocal(widget.ticketItems.length)} mục",
        data: {'type': 'fix_send_created'},
      );
      
      // ✅ Gửi thông báo Telegram với thông tin chi tiết
      await NotificationService.sendTransactionToTelegram(
        transactionType: 'fix_send',
        type: 'Phiếu Gửi Sửa',
        ticketId: ticketId,
        partnerType: 'fix_units',
        partnerName: fixerName,
        productName: productName,
        quantity: totalQuantity,
        imeiList: imeiList,
        note: firstItem != null ? (firstItem['note'] as String?) : null,
      );

      if (mounted) {
        // Đóng loading trước khi hiển thị thông báo thành công
        if (Navigator.of(scaffoldContext, rootNavigator: true).canPop()) {
          Navigator.of(scaffoldContext, rootNavigator: true).pop();
        }
        setState(() {
          isProcessing = false;
        });
        await showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: const Text('Đã tạo phiếu gửi sửa thành công'),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.pop(context);
                },
                child: const Text('Đóng'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        // Đóng loading trước khi hiển thị lỗi
        if (Navigator.of(scaffoldContext, rootNavigator: true).canPop()) {
          Navigator.of(scaffoldContext, rootNavigator: true).pop();
        }
        setState(() {
          isProcessing = false;
        });
        await showDialog(
          context: scaffoldContext,
          builder: (context) => AlertDialog(
            title: const Text('Thông báo'),
            content: Text('Lỗi khi tạo phiếu gửi sửa: $e'),
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

  Widget wrapField(Widget child, {bool isImeiField = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      margin: const EdgeInsets.symmetric(vertical: 4),
      height: isImeiField ? 80 : 48,
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(8),
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
                onPressed: () => setState(() {
                  isLoading = true;
                  errorMessage = null;
                }),
                child: const Text('Thử lại'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Danh sách sản phẩm gửi sửa', style: TextStyle(color: Colors.white)),
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
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Danh sách sản phẩm đã thêm:',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 300,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ListView.builder(
                      itemCount: widget.ticketItems.length,
                      itemBuilder: (context, index) {
                        final item = widget.ticketItems[index];
                        final imeiList = (item['imei'] as String).split(',').where((e) => e.trim().isNotEmpty).toList();
                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                          child: Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('Đơn vị sửa: ${item['fixer']}'),
                                      Text('Sản phẩm: ${item['product_name']}'),
                                      Text('Số lượng IMEI: ${formatNumberLocal(item['quantity'])}'),
                                      if (imeiList.length <= displayImeiLimit) ...[
                                        Text('IMEI:'),
                                        ...imeiList.map((imei) => Text('- $imei')),
                                      ] else
                                        Text('IMEI: ${imeiList.take(displayImeiLimit).join(', ')}... và ${formatNumberLocal(imeiList.length - displayImeiLimit)} IMEI khác'),
                                      Text('Ghi chú: ${item['note'] ?? ''}'),
                                    ],
                                  ),
                                ),
                                Column(
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.edit, color: Colors.blue, size: 20),
                                      onPressed: () {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (context) => FixSendForm(
                                              tenantClient: widget.tenantClient,
                                              initialFixer: item['fixer'],
                                              initialProductId: item['product_id'],
                                              initialImei: item['imei'],
                                              initialNote: item['note'],
                                              ticketItems: widget.ticketItems,
                                              editIndex: index,
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete, color: Colors.red, size: 20),
                                      onPressed: () {
                                        if (mounted) {
                                          setState(() {
                                            widget.ticketItems.removeAt(index);
                                          });
                                        }
                                      },
                                    ),
                                  ],
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
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => FixSendForm(
                            tenantClient: widget.tenantClient,
                            ticketItems: widget.ticketItems,
                          ),
                        ),
                      );
                    },
                    child: const Text('Thêm Sản Phẩm'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: isProcessing ? null : () => createTicket(context),
                    child: const Text('Tạo Phiếu'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}