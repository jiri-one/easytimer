@file:Suppress("UNUSED_PARAMETER")

package android.os

class Bundle

class Looper {
    companion object {
        fun getMainLooper() = Looper()
    }
}

class Handler(looper: Looper) {
    fun postDelayed(action: Runnable, delayMs: Long): Boolean {
        pending.add(action)
        return true
    }

    fun removeCallbacks(action: Runnable) {
        pending.removeAll { it === action }
    }

    companion object {
        val pending = mutableListOf<Runnable>()
        fun runPending() {
            val actions = pending.toList()
            pending.clear()
            actions.forEach { it.run() }
        }
    }
}

object SystemClock {
    var now = 0L
    var beforeRead: (() -> Unit)? = null
    fun elapsedRealtime(): Long {
        beforeRead?.invoke()
        return now
    }
}
