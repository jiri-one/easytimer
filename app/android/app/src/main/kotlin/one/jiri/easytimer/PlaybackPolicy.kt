package one.jiri.easytimer

internal data class PlaybackGeneration(val generation: Long, val alarmGeneration: Long) {
    companion object {
        fun fromArguments(arguments: Any?): PlaybackGeneration? {
            val values = arguments as? Map<*, *> ?: return null
            val generation = channelInteger(values["generation"]) ?: return null
            val alarmGeneration = channelInteger(values["alarmGeneration"]) ?: return null
            if (generation < 0 || alarmGeneration < 0) return null
            return PlaybackGeneration(generation, alarmGeneration)
        }
    }
}

internal data class PlaybackRequest(
    val eventId: String,
    val generation: PlaybackGeneration,
    val plannedAtMs: Long,
    val deadlineMs: Long,
) {
    companion object {
        fun fromArguments(arguments: Any?): PlaybackRequest? {
            val values = arguments as? Map<*, *> ?: return null
            val eventId = values["eventId"] as? String ?: return null
            if (eventId.isEmpty() || eventId.length > 1_024 ||
                eventId.toByteArray(Charsets.UTF_8).size > 1_024) return null
            val generation = PlaybackGeneration.fromArguments(values) ?: return null
            val plannedAtMs = channelInteger(values["plannedAtMs"]) ?: return null
            val deadlineMs = channelInteger(values["deadlineMs"]) ?: return null
            if (plannedAtMs < 0 || deadlineMs < 0) return null
            return PlaybackRequest(eventId, generation, plannedAtMs, deadlineMs)
        }
    }
}

private fun channelInteger(value: Any?): Long? = when (value) {
    is Int -> value.toLong()
    is Long -> value
    else -> null
}

internal class PlaybackPolicy(private val nowMs: () -> Long) {
    class Pending internal constructor(
        internal val request: PlaybackRequest,
        internal val end: Boolean,
        internal val revision: Long,
        internal val alarmRevision: Long,
    )

    private var generation = 0L
    private var alarmGeneration = 0L
    private var revision = 0L
    private var alarmRevision = 0L
    private var lastAlarmPlannedAtMs: Long? = null
    private val successfulStarts = mutableMapOf<String, Long>()

    @Synchronized
    fun receive(request: PlaybackRequest, end: Boolean): Pending? {
        if (!acceptGeneration(request, end)) return null
        if (!end && request.eventId !in successfulStarts && nowMs() > request.deadlineMs) return null
        return Pending(request, end, revision, alarmRevision)
    }

    @Synchronized
    fun start(pending: Pending, play: () -> Boolean): Long? {
        if (stale(pending)) return null
        val request = pending.request
        val end = pending.end
        successfulStarts[request.eventId]?.let { return it }
        val lastAlarm = lastAlarmPlannedAtMs
        val now = nowMs()
        // Playback jitter must not suppress cues planned at least three seconds apart.
        if (!end && (now > request.deadlineMs ||
                     (lastAlarm != null && request.plannedAtMs - lastAlarm < 3_000))) return null
        if (stale(pending)) return null

        // Cancellation and duplicate requests must wait for the successful-start ledger update.
        if (!play()) return null
        val startedAt = nowMs()
        successfulStarts[request.eventId] = startedAt
        if (!end) lastAlarmPlannedAtMs = request.plannedAtMs
        return startedAt
    }

    @Synchronized
    fun beginWorkout(request: PlaybackGeneration, stopAlarm: () -> Unit) {
        if (request.generation < generation || request.alarmGeneration < alarmGeneration) return
        advanceGeneration(request.generation)
        revision++
        alarmRevision++
        alarmGeneration = request.alarmGeneration
        // A new workout must retire queued finishes without cutting off one already playing.
        stopAlarm()
    }

    @Synchronized
    fun cancel(request: PlaybackGeneration, alarmOnly: Boolean, stop: () -> Unit) {
        if (request.generation < generation) return
        if (alarmOnly && request.alarmGeneration < alarmGeneration) return
        if (!alarmOnly) {
            advanceGeneration(request.generation)
            revision++
        }
        alarmRevision++
        alarmGeneration = maxOf(alarmGeneration, request.alarmGeneration)
        stop()
    }

    @Synchronized
    fun invalidate() {
        revision++
    }

    private fun stale(pending: Pending): Boolean =
        pending.revision != revision ||
            pending.request.generation.generation < generation ||
            (!pending.end && (pending.alarmRevision != alarmRevision ||
                             pending.request.generation.alarmGeneration < alarmGeneration))

    private fun acceptGeneration(request: PlaybackRequest, end: Boolean): Boolean {
        val incoming = request.generation
        if (incoming.generation < generation) return false
        if (!end && incoming.alarmGeneration < alarmGeneration) return false
        advanceGeneration(incoming.generation)
        if (!end) alarmGeneration = incoming.alarmGeneration
        return true
    }

    private fun advanceGeneration(incoming: Long) {
        if (incoming > generation) {
            generation = incoming
            successfulStarts.clear()
        }
    }
}
