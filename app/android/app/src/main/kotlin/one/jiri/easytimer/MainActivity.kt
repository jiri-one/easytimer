package one.jiri.easytimer

import android.media.AudioManager
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Hardware keys must also adjust media volume while audio is idle.
        volumeControlStream = AudioManager.STREAM_MUSIC
    }
}
