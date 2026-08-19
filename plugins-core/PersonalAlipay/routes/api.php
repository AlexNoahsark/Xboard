<?php

use Illuminate\Support\Facades\Route;
use Plugin\PersonalAlipay\Controllers\PersonalAlipayController;

// Fixed paths matched exactly by the companion Android app's ApiClient.kt —
// do not change without also updating the app (see README.md).
Route::post('api/v1/personal-alipay/notify', [PersonalAlipayController::class, 'notify']);
Route::post('api/v1/personal-alipay/ping', [PersonalAlipayController::class, 'ping']);
Route::get('api/v1/personal-alipay/checkout/{tradeNo}', [PersonalAlipayController::class, 'checkout']);
Route::get('api/v1/personal-alipay/status/{tradeNo}', [PersonalAlipayController::class, 'status']);
Route::get('api/v1/personal-alipay/qrcode.jpg', [PersonalAlipayController::class, 'qrcode']);
Route::get('api/v1/personal-alipay/upload', [PersonalAlipayController::class, 'uploadPage']);
Route::post('api/v1/personal-alipay/upload', [PersonalAlipayController::class, 'upload']);
