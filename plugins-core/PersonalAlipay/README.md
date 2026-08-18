# PersonalAlipay 插件（内置）

个人支付宝收款码支付方式：向用户展示商家的个人支付宝收款码和一个精确到分的应付金额，商家手机上运行配套的 PersonalAlipay Android App（通过官方 `NotificationListenerService` 监听支付宝"收款到账"通知），检测到到账后自动调用本插件的 Webhook 确认订单。

这是一个**内置核心插件**（`plugins-core/`），随 XBoard 一起安装，首次启动时会和 AlipayF2f、Epay 等其他内置支付插件一样自动安装并启用——但和它们一样，启用只代表它出现在"添加支付方式"的可选列表里，还需要按下面步骤手动配置才能真正生效。

## 配置步骤

1. 把你自己的支付宝个人收款码图片放到 `plugins-core/PersonalAlipay/assets/qrcode.jpg`（仓库不包含这个文件，见 [assets/README.md](assets/README.md)）。
2. 管理后台 → 支付方式 → 添加支付方式 → 选择「个人支付宝转账」，填写：
   - **Webhook Secret**：自定义一串随机字符串，需要和手机 App「设置」页填写的完全一致。
   - **个人收款码图片地址**：`https://你的域名/api/v1/personal-alipay/qrcode.jpg`（对应第 1 步），或任意图床直链。
   - **尾款随机范围（分）**：默认 99，一般无需修改。
3. 保存后即可在用户下单时选择「个人支付宝转账」支付方式。
4. 下载并安装配套的 Android App，服务器地址填 `https://你的域名`，Webhook Secret 填第 2 步同一个值。

## ⚠️ 重要：站点必须已经配置好正确的 HTTPS 域名

XBoard 生成网关地址、支付跳转链接时，用的是**当前这次请求实际访问的域名**（而不是固定写死的配置），所以：

- 请务必通过您真实的 HTTPS 域名访问后台和站点，**不要用服务器裸 IP** 访问，否则生成的收款跳转链接会是 `http://IP/...`，App 端因安全策略会拒绝明文连接。
- 除了 `.env` 里的 `APP_URL`，数据库里还单独存了一份 `app_url` / `subscribe_url`（`v2_settings` 表），这两处都要改成正确的 HTTPS 域名，改完记得清缓存并重载：
  ```bash
  php artisan tinker --execute='DB::table("v2_settings")->where("name","app_url")->update(["value"=>"https://你的域名"]); DB::table("v2_settings")->where("name","subscribe_url")->update(["value"=>"https://你的域名"]);'
  php artisan cache:clear
  php artisan octane:reload
  ```
- 域名可以直接放在 Cloudflare 等提供免费边缘 HTTPS 的 CDN 后面（橙色云朵/proxied 开启），不需要在服务器上单独申请证书；只要域名能正常用 `https://` 访问站点即可。

## 工作原理

1. 用户下单并选择本支付方式时，`Plugin::pay()` 在应付金额基础上随机追加 1~N 分，生成一个当前唯一的"尾款金额"，并跳转到插件自带的收款页（二维码 + 金额 + 订单号）。
2. 商家的支付宝收到转账后，手机上的 PersonalAlipay App 读取到账通知，解析出金额（分），计算 HMAC-SHA256 签名后 POST 到 `/api/v1/personal-alipay/notify`。
3. 插件校验签名，按金额匹配到对应的待支付订单，调用 `OrderService::paid()` 自动确认订单（与官方支付网关走相同的确认流程）。
4. 收款页通过轮询 `/api/v1/personal-alipay/status/{trade_no}` 自动感知订单状态变化。

## 安全说明

- `/api/v1/personal-alipay/notify` 必须携带正确的 `X-Signature`（HMAC-SHA256，密钥为上面配置的 Webhook Secret）才会被处理，签名不匹配一律拒绝。
- 同一个 `event_id` 只会被确认一次（幂等），重复上传会直接返回 `duplicate: true`。
- 金额未匹配到任何待支付订单时（例如收到与订单无关的个人转账），会原样返回成功，避免 App 端无意义地无限重试。

## 接口一览

| 路径 | 方法 | 说明 |
| --- | --- | --- |
| `/api/v1/personal-alipay/notify` | POST | App 上传到账事件，HMAC 签名校验，按金额匹配订单并确认支付 |
| `/api/v1/personal-alipay/ping` | POST | App"测试服务器"按钮用的连通性检查 |
| `/api/v1/personal-alipay/checkout/{trade_no}` | GET | 用户下单后跳转的收款页（二维码 + 金额） |
| `/api/v1/personal-alipay/status/{trade_no}` | GET | 收款页轮询订单支付状态 |
| `/api/v1/personal-alipay/qrcode.jpg` | GET | 自托管的收款码图片（可选） |
