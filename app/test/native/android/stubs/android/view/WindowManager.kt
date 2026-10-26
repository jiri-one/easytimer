package android.view

object WindowManager {
    object LayoutParams {
        const val FLAG_KEEP_SCREEN_ON = 128
    }
}

class Window {
    var flags = 0
        private set
    fun addFlags(value: Int) { flags = flags or value }
    fun clearFlags(value: Int) { flags = flags and value.inv() }
}
