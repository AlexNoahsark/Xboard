<?php

namespace Plugin\PersonalAlipay\Controllers;

use App\Http\Controllers\Controller;
use App\Models\Order;
use App\Models\Payment;
use App\Services\OrderService;
use App\Services\Plugin\HookManager;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;

class PersonalAlipayController extends Controller
{
    /**
     * Reads the admin-configured settings (webhook_secret, qrcode_image_url, ...)
     * for this gateway. These live on the "支付方式" (Payment) instance row that
     * the admin creates via Plugin::form(), NOT on the Plugin row itself — the
     * Plugin row only tracks install/enable state.
     */
    private function config(): array
    {
        $payment = Payment::where('payment', 'PersonalAlipay')->where('enable', 1)->first();
        if (!$payment) {
            return [];
        }
        // 'config' is cast to array and only in $hidden for serialization purposes;
        // direct attribute access here still returns the decoded array.
        return $payment->config ?? [];
    }

    /** Plain connectivity check used by the App's "测试服务器" button (falls back if missing). */
    public function ping(Request $request)
    {
        return response()->json(['success' => true]);
    }

    /**
     * Serves the merchant's personal Alipay collection QR code image from this
     * plugin's own (bind-mounted, persistent) directory, so the admin doesn't
     * need a third-party image host. Uploaded once via SFTP to
     * plugins/PersonalAlipay/assets/qrcode.jpg.
     */
    public function qrcode(Request $request)
    {
        $path = __DIR__ . '/../assets/qrcode.jpg';
        if (!is_file($path)) {
            abort(404);
        }
        return response(file_get_contents($path))
            ->header('Content-Type', 'image/jpeg')
            ->header('Cache-Control', 'public, max-age=86400');
    }

    /**
     * Webhook the Android app calls after parsing an Alipay "收款到账" notification.
     * Verifies the HMAC signature, matches the amount to a pending fingerprinted
     * order, and credits it through the same OrderService::paid() path XBoard's
     * built-in payment gateways use.
     */
    public function notify(Request $request)
    {
        $config = $this->config();
        $secret = (string) ($config['webhook_secret'] ?? '');

        $amount = (int) $request->input('amount');
        $timestamp = (int) $request->input('timestamp');
        $eventId = (string) $request->input('event_id');
        $rawText = (string) $request->input('raw_text');

        if ($secret === '' || $amount <= 0 || $timestamp <= 0 || $eventId === '') {
            return response()->json(['success' => false, 'message' => 'invalid payload'], 400);
        }

        $signature = strtolower((string) $request->header('X-Signature', ''));
        $payload = "{$amount}\n{$timestamp}\n{$eventId}";
        $expected = hash_hmac('sha256', $payload, $secret);

        if ($signature === '' || !hash_equals($expected, $signature)) {
            Log::warning('PersonalAlipay: signature mismatch', ['event_id' => $eventId]);
            return response()->json(['success' => false, 'message' => 'bad signature'], 401);
        }

        // Idempotency: an event_id already matched to an order must not be reprocessed.
        $already = DB::table('personal_alipay_charges')->where('matched_event_id', $eventId)->first();
        if ($already) {
            return response()->json(['success' => true, 'duplicate' => true]);
        }

        $charge = DB::table('personal_alipay_charges')
            ->where('target_amount_cents', $amount)
            ->whereNull('matched_event_id')
            ->orderBy('created_at', 'asc')
            ->first();

        if (!$charge) {
            // Valid signature, but no pending order expects this exact amount —
            // e.g. an unrelated personal transfer. Acknowledge so the app does
            // not keep retrying an amount that will never match.
            Log::info('PersonalAlipay: no pending order matched amount', [
                'amount' => $amount,
                'raw_text' => $rawText,
            ]);
            return response()->json(['success' => true, 'matched' => false]);
        }

        $order = Order::where('trade_no', $charge->trade_no)->first();
        if (!$order) {
            return response()->json(['success' => true, 'matched' => false]);
        }

        DB::table('personal_alipay_charges')
            ->where('id', $charge->id)
            ->update(['matched_event_id' => $eventId, 'matched_at' => time(), 'updated_at' => time()]);

        if ((int) $order->status === Order::STATUS_PENDING) {
            $orderService = new OrderService($order);
            if (!$orderService->paid($eventId)) {
                return response()->json(['success' => false, 'message' => 'order paid() failed'], 500);
            }
            HookManager::call('payment.notify.success', $order);
        }

        return response()->json(['success' => true]);
    }

    /** Public payment page: QR code + exact fingerprinted amount to transfer. */
    public function checkout(Request $request, string $tradeNo)
    {
        $config = $this->config();
        $charge = DB::table('personal_alipay_charges')->where('trade_no', $tradeNo)->first();
        $order = Order::where('trade_no', $tradeNo)->first();

        if (!$charge || !$order) {
            return response('订单不存在或已过期', 404);
        }

        $amountYuan = number_format($charge->target_amount_cents / 100, 2);
        $qrcode = htmlspecialchars((string) ($config['qrcode_image_url'] ?? ''), ENT_QUOTES);
        $tradeNoSafe = htmlspecialchars($tradeNo, ENT_QUOTES);
        $paid = (int) $order->status !== Order::STATUS_PENDING;
        $statusText = $paid ? '支付成功！可以关闭此页面返回 App 查看' : '等待到账中，到账后将自动确认（无需刷新页面）…';
        $paidJs = $paid ? 'true' : 'false';

        $html = <<<HTML
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>个人支付宝收款</title>
<style>
body{font-family:-apple-system,PingFang SC,Helvetica,Arial,sans-serif;background:#f5f6f8;margin:0;padding:24px;color:#222}
.card{max-width:420px;margin:0 auto;background:#fff;border-radius:12px;padding:24px;box-shadow:0 2px 12px rgba(0,0,0,.08);text-align:center}
.amount{font-size:32px;font-weight:700;color:#1677ff;margin:12px 0}
.qrcode{width:240px;height:240px;object-fit:contain;border:1px solid #eee;border-radius:8px;margin:16px 0}
.tip{color:#e6710a;font-size:14px;line-height:1.6;background:#fff7e8;padding:12px;border-radius:8px;text-align:left}
.status{margin-top:16px;font-size:15px;color:#666}
.trade{color:#999;font-size:12px;margin-top:12px;word-break:break-all}
</style>
</head>
<body>
<div class="card">
  <div>使用支付宝扫码转账</div>
  <div class="amount">¥{$amountYuan}</div>
  <img class="qrcode" src="{$qrcode}" alt="收款码">
  <div class="tip">请务必转账 <b>¥{$amountYuan}</b> 这个精确金额（含分），多付或少付都无法自动确认到账；如遇问题请联系客服并提供下方订单号。</div>
  <div class="status" id="status">{$statusText}</div>
  <div class="trade">订单号：{$tradeNoSafe}</div>
</div>
<script>
var paid = {$paidJs};
function poll(){
  if (paid) return;
  fetch('/api/v1/personal-alipay/status/{$tradeNoSafe}').then(function(r){return r.json();}).then(function(d){
    if (d && d.paid) {
      paid = true;
      document.getElementById('status').textContent = '支付成功！可以关闭此页面返回 App 查看';
    }
  }).catch(function(){});
}
setInterval(poll, 4000);
</script>
</body>
</html>
HTML;

        return response($html)->header('Content-Type', 'text/html; charset=utf-8');
    }

    /** Polled by the checkout page's JS to detect when the order has been credited. */
    public function status(Request $request, string $tradeNo)
    {
        $order = Order::where('trade_no', $tradeNo)->first();
        if (!$order) {
            return response()->json(['success' => false], 404);
        }
        return response()->json([
            'success' => true,
            'paid' => (int) $order->status !== Order::STATUS_PENDING,
        ]);
    }
}
