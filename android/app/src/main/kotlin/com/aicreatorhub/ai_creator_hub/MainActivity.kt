package com.aicreatorhub.ai_creator_hub

import android.os.Bundle
import com.pakai.ai.PdfDownloader
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        PdfDownloader.register(flutterEngine, applicationContext)
    }
}
