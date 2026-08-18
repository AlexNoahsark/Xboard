<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        if (Schema::hasTable('personal_alipay_charges')) {
            return;
        }

        Schema::create('personal_alipay_charges', function (Blueprint $table) {
            $table->id();
            $table->string('trade_no')->unique();
            $table->unsignedBigInteger('base_amount_cents');
            $table->unsignedBigInteger('target_amount_cents');
            $table->string('matched_event_id')->nullable();
            $table->unsignedBigInteger('matched_at')->nullable();
            $table->unsignedBigInteger('created_at')->nullable();
            $table->unsignedBigInteger('updated_at')->nullable();
            $table->index('target_amount_cents');
            $table->index('matched_event_id');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('personal_alipay_charges');
    }
};
