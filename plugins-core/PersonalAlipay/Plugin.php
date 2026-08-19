<?php

namespace Plugin\PersonalAlipay;

use App\Services\Plugin\AbstractPlugin;
use App\Contracts\PaymentInterface;
use Illuminate\Support\Facades\DB;

/**
 * Personal Alipay collection-code payment gateway.
 *
 * Unlike the other bundled payment plugins, this one does not talk to any
 * payment provider API. Instead:
 *  - pay() shows the merchant's own personal Alipay QR code plus a small
 *    per-order "fingerprint" amount (a few extra cents) so that every
 *    pending order has a unique amount to transfer.
 *  - The merchant's phone runs a companion Android app (PersonalAlipay,
 *    NotificationListenerService-based) that reads Alipay's own "收款到账"
 *    system notifications and POSTs the parsed amount, HMAC-signed, to this
 *    plugin's own fixed webhook routes (see routes/api.php) — NOT XBoard's
 *    per-instance dynamic notify URL, since the app targets a fixed path.
 *  - notify() (the PaymentInterface method) is intentionally unused.
 */
class Plugin extends AbstractPlugin implements PaymentInterface
{
    public function boot(): void
    {
        $this->filter('available_payment_methods', function ($methods) {
            if ($this->getConfig('enabled', true)) {
                $methods['PersonalAlipay'] = [
                    'name' => $this->getConfig('display_name', '个人支付宝转账'),
                    'icon' => $this->getConfig('icon', '🧧'),
                    'plugin_code' => $this->getPluginCode(),
                    'type' => 'plugin',
                ];
            }
            return $methods;
        });
    }

    public function form(): array
    {
        return [
            'webhook_secret' => [
                'label' => 'Webhook Secret',
                'type' => 'string',
                'required' => true,
                'description' => '必须与手机 App「设置」中填写的 Webhook Secret 完全一致，用于校验到账通知签名，不会展示给用户',
            ],
            'qrcode_image_url' => [
                'label' => '个人收款码图片地址',
                'type' => 'string',
                'required' => true,
                'default' => url('/api/v1/personal-alipay/qrcode.jpg'),
                'description' => '默认已填好本站自托管地址：先保存一次本页面，再访问 /api/v1/personal-alipay/upload 上传收款码图片（需输入这里的 Webhook Secret）即可；也可以改成任意图床直链',
            ],
            'fingerprint_max_cents' => [
                'label' => '尾款随机范围（分）',
                'type' => 'string',
                'default' => '99',
                'description' => '在应付金额基础上随机追加 1~N 分作为唯一标识，用于自动匹配到账，默认 99，无需修改',
            ],
        ];
    }

    public function pay($order): array
    {
        $tradeNo = (string) $order['trade_no'];
        $baseAmount = (int) $order['total_amount'];
        $maxCents = max(1, (int) $this->getConfig('fingerprint_max_cents', 99));

        $existing = DB::table('personal_alipay_charges')->where('trade_no', $tradeNo)->first();
        if (!$existing) {
            $targetAmount = $this->assignUniqueAmount($baseAmount, $maxCents);
            DB::table('personal_alipay_charges')->insert([
                'trade_no' => $tradeNo,
                'base_amount_cents' => $baseAmount,
                'target_amount_cents' => $targetAmount,
                'created_at' => time(),
                'updated_at' => time(),
            ]);
        }

        return [
            'type' => 1,
            'data' => url('/api/v1/personal-alipay/checkout/' . $tradeNo),
        ];
    }

    /**
     * Picks an amount = base + small random offset that no other currently
     * unmatched charge is already using, so every pending order has a
     * uniquely identifiable amount to transfer.
     */
    private function assignUniqueAmount(int $baseAmount, int $maxCents): int
    {
        for ($attempt = 0; $attempt < 30; $attempt++) {
            $offset = random_int(1, $maxCents);
            $candidate = $baseAmount + $offset;
            $collision = DB::table('personal_alipay_charges')
                ->where('target_amount_cents', $candidate)
                ->whereNull('matched_event_id')
                ->exists();
            if (!$collision) {
                return $candidate;
            }
        }
        // Extremely unlikely fallback: widen the search so we never fail outright.
        return $baseAmount + $maxCents + random_int(1, 999);
    }

    public function notify($params): array|bool
    {
        // See class docblock: this plugin uses its own fixed routes instead.
        return false;
    }
}
