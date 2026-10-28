package com.c12n.viulivetv

import android.app.SearchManager
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Main activity. Besides the Flutter embedding, it bridges external
/// intents to Dart over the "viu.tv/intents" channel:
///  - Android TV's Assistant media search
///    (android.media.action.MEDIA_PLAY_FROM_SEARCH, with a query extra)
///  - App Actions / deep links: viulivetv://play?name=<channel>
///    (also viulivetv://play?stream=<stream_id>, ?q=<query>)
/// Dart resolves the name to a channel and starts playback.
class MainActivity : FlutterActivity() {

    private var channel: MethodChannel? = null
    private var initialIntent: Map<String, Any?>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        initialIntent = parseIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "viu.tv/intents"
        )
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialIntent" -> result.success(initialIntent)
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val parsed = parseIntent(intent)
        if (parsed != null) {
            channel?.invokeMethod("onIntent", parsed)
        }
    }

    private fun parseIntent(intent: Intent?): Map<String, Any?>? {
        if (intent == null) return null
        if (intent.action == "android.media.action.MEDIA_PLAY_FROM_SEARCH") {
            val query = intent.getStringExtra(SearchManager.QUERY)
                ?: intent.getStringExtra("query")
                ?: return null
            return mapOf("type" to "searchplay", "query" to query)
        }
        val data = intent.data
        if (data != null && data.scheme == "viulivetv") {
            val name = data.getQueryParameter("name")
                ?: data.getQueryParameter("q")
                ?: data.getQueryParameter("query")
            val stream = data.getQueryParameter("stream")
            if (name == null && stream == null) return null
            return mapOf("type" to "play", "name" to name, "stream" to stream)
        }
        return null
    }
}
