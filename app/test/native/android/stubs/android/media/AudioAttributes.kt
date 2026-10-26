package android.media

class AudioAttributes(val usage: Int, val contentType: Int) {
    class Builder {
        private var usage = 0
        private var contentType = 0
        fun setUsage(value: Int) = apply { usage = value }
        fun setContentType(value: Int) = apply { contentType = value }
        fun build() = AudioAttributes(usage, contentType)
    }

    companion object {
        const val USAGE_MEDIA = 1
        const val CONTENT_TYPE_SONIFICATION = 4
    }
}

object AudioManager {
    const val STREAM_MUSIC = 3
}
