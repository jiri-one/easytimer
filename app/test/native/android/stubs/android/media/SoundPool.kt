package android.media

import android.os.SystemClock

class SoundPool(val maxStreams: Int, val attributes: AudioAttributes?) {
    data class Play(val sample: Int, val left: Float, val right: Float, val priority: Int,
                    val loop: Int, val rate: Float, val stream: Int)
    data class Volume(val stream: Int, val left: Float, val right: Float)

    val loads = mutableListOf<Pair<String, Int>>()
    val plays = mutableListOf<Play>()
    val stops = mutableListOf<Int>()
    val volumes = mutableListOf<Volume>()
    val activeStreams = mutableSetOf<Int>()
    var listener: ((SoundPool, Int, Int) -> Unit)? = null
        private set
    var failures = 0
    var playDelayMs = 0L
    var playException: RuntimeException? = null
    var released = false
        private set
    private var nextStream = 10

    fun load(path: String, priority: Int): Int {
        check(!released)
        loads.add(path to priority)
        return loads.size
    }

    fun setOnLoadCompleteListener(value: ((SoundPool, Int, Int) -> Unit)?) {
        listener = value
    }

    fun completeLoads() {
        for (sample in 1..loads.size) listener?.invoke(this, sample, 0)
    }

    fun play(sample: Int, left: Float, right: Float, priority: Int, loop: Int, rate: Float): Int {
        check(!released)
        SystemClock.now += playDelayMs
        playException?.let { throw it }
        val stream = if (failures > 0) { failures--; 0 } else nextStream++
        plays.add(Play(sample, left, right, priority, loop, rate, stream))
        if (stream != 0) {
            if (activeStreams.size == maxStreams) activeStreams.clear()
            activeStreams.add(stream)
        }
        return stream
    }

    fun stop(stream: Int) {
        stops.add(stream)
        activeStreams.remove(stream)
    }

    fun setVolume(stream: Int, left: Float, right: Float) {
        volumes.add(Volume(stream, left, right))
    }

    fun release() {
        released = true
        activeStreams.clear()
    }

    class Builder {
        private var maxStreams = 1
        private var attributes: AudioAttributes? = null
        fun setMaxStreams(value: Int) = apply { maxStreams = value }
        fun setAudioAttributes(value: AudioAttributes) = apply { attributes = value }
        fun build() = SoundPool(maxStreams, attributes).also { instances.add(it) }
    }

    companion object {
        val instances = mutableListOf<SoundPool>()
    }
}
