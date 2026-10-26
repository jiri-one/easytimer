package io.flutter.embedding.android

import android.content.res.Configuration
import android.content.res.Resources
import android.os.Bundle
import android.view.Window
import io.flutter.embedding.engine.FlutterEngine
import java.io.File

open class FlutterActivity {
    val cacheDir = File(System.getProperty("java.io.tmpdir"))
    val resources = Resources()
    val window = Window()
    var volumeControlStream = 0
    var requestedOrientation = -1
    open fun onCreate(savedInstanceState: Bundle?) {}
    open fun onConfigurationChanged(newConfig: Configuration) {}
    open fun configureFlutterEngine(flutterEngine: FlutterEngine) {}
    open fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {}
    open fun onDestroy() {}
}
