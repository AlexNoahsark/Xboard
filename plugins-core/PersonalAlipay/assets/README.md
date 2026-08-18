# 收款码图片

把你自己的支付宝个人收款码图片放到这个目录下，命名为 `qrcode.jpg`：

```text
plugins-core/PersonalAlipay/assets/qrcode.jpg
```

放好后，在「支付方式 → 个人支付宝转账」的配置里，「个人收款码图片地址」填：

```text
https://你的域名/api/v1/personal-alipay/qrcode.jpg
```

也可以不放这个文件，改用任意图床的图片直链。

这个目录本身不包含任何人的真实收款码（`qrcode.jpg` 已被 `.gitignore` 忽略），需要每个部署者自行放置自己的图片。
