package one.jiri.easytimer

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.SoundPool
import android.os.Handler
import android.os.SystemClock
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

private fun arguments(
    id: String = "alarm:1",
    generation: Long = 0,
    alarmGeneration: Long = 0,
    deadline: Long = Long.MAX_VALUE,
    planned: Long = 0,
): Map<String, Any> = mapOf(
    "eventId" to id, "generation" to generation,
    "alarmGeneration" to alarmGeneration, "plannedAtMs" to planned, "deadlineMs" to deadline,
)

private fun generations(generation: Long, alarmGeneration: Long): Map<String, Any> =
    mapOf("generation" to generation, "alarmGeneration" to alarmGeneration)

private fun MethodChannel.Reply.expect(value: Any?) {
    check(completions == 1 && errorCode == null && this.value == value) {
        "Expected $value once; got ${this.value}, completions=$completions, error=$errorCode"
    }
}

private fun MethodChannel.Reply.started(at: Long?) = expect(at?.let { mapOf("startedAtMs" to it) })

private class Harness(loaded: Boolean) : AutoCloseable {
    val activity = MainActivity()
    val engine = FlutterEngine()
    val channel: MethodChannel
    val initialized: MethodChannel.Reply
    val pool: SoundPool

    init {
        SystemClock.now = 0
        SystemClock.beforeRead = null
        activity.onCreate(null)
        activity.configureFlutterEngine(engine)
        channel = MethodChannel.latest
        check(channel.name == "easytimer/platform")
        initialized = initialize()
        pool = SoundPool.instances.last()
        if (loaded) {
            pool.completeLoads()
            initialized.expect(true)
        }
    }

    fun initialize() = channel.call("initialize", mapOf(
        "alarm" to byteArrayOf(1, 2), "end" to byteArrayOf(3, 4),
    ))

    fun play(id: String = "alarm:1", generation: Long = 0, alarmGeneration: Long = 0,
             deadline: Long = Long.MAX_VALUE, planned: Long = SystemClock.now, end: Boolean = false) =
        channel.call(if (end) "playEnd" else "playAlarm",
                     arguments(id, generation, alarmGeneration, deadline, planned))

    override fun close() {
        SystemClock.beforeRead = null
        activity.cleanUpFlutterEngine(engine)
        activity.onDestroy()
        check(channel.handler == null)
        check(Handler.pending.isEmpty())
    }
}

private fun withHarness(loaded: Boolean = true, test: (Harness) -> Unit) {
    Harness(loaded).use(test)
}

private fun malformedArguments() = withHarness { h ->
    val invalid = mutableListOf<Any?>(null, true, 1, "alarm", emptyList<Any>(), emptyMap<String, Any>())
    for (field in listOf("eventId", "generation", "alarmGeneration", "plannedAtMs", "deadlineMs")) {
        invalid.add(arguments() - field)
        invalid.add(arguments() + (field to null))
        invalid.add(arguments() + (field to emptyList<Any>()))
    }
    invalid.add(arguments() + ("eventId" to ""))
    invalid.add(arguments() + ("eventId" to 42))
    invalid.add(arguments() + ("eventId" to "a".repeat(1_025)))
    invalid.add(arguments() + ("eventId" to "é".repeat(513)))
    for (field in listOf("generation", "alarmGeneration", "plannedAtMs", "deadlineMs")) {
        for (value in listOf(1.0, 1.5, Double.NaN, Double.POSITIVE_INFINITY, true, "1")) {
            invalid.add(arguments() + (field to value))
        }
    }
    invalid.add(arguments(generation = -1))
    invalid.add(arguments(alarmGeneration = -1))
    invalid.add(arguments(planned = -1))
    invalid.add(arguments(planned = Long.MIN_VALUE))
    invalid.add(arguments(deadline = -1))
    for (method in listOf("playAlarm", "playEnd")) {
        for (value in invalid) {
            val reply = h.channel.call(method, value)
            check(reply.completions == 1 && reply.errorCode == "invalid_arguments") {
                "$method accepted malformed arguments $value"
            }
        }
    }
    check(h.pool.plays.isEmpty())
    h.channel.call("playAlarm", mapOf(
        "eventId" to "int", "generation" to 0, "alarmGeneration" to 0,
        "plannedAtMs" to 0, "deadlineMs" to 0,
    )).started(0)
    h.play("a".repeat(1_024), end = true).started(0)
    h.play("é".repeat(512), end = true).started(0)
    h.play("long", generation = Int.MAX_VALUE.toLong() + 1,
           alarmGeneration = Long.MAX_VALUE, planned = Long.MAX_VALUE,
           deadline = Long.MAX_VALUE, end = true).started(0)

    val stream = h.pool.plays.last().stream
    for (method in listOf("stop", "cancelAlarm", "beginWorkout")) {
        for (value in listOf(null, emptyMap<String, Any>(), generations(-1, 0), generations(0, -1),
                             generations(1, 1) - "generation", generations(1, 1) - "alarmGeneration",
                             mapOf("generation" to 1.0, "alarmGeneration" to 1),
                             mapOf("generation" to 1, "alarmGeneration" to 1.0))) {
            val reply = h.channel.call(method, value)
            check(reply.completions == 1 && reply.errorCode == "invalid_arguments")
            check(stream in h.pool.activeStreams)
        }
    }
}

private fun deadlineAtReceipt() = withHarness { h ->
    SystemClock.now = 101
    h.play(deadline = 100).started(null)
    check(h.pool.plays.isEmpty())
    h.play(deadline = 101).started(101)
    SystemClock.now = 50_000
    h.play(deadline = 101).started(101)
    check(h.pool.plays.size == 1)
    h.play("end:1", deadline = 0, end = true).started(50_000)
}

private fun deadlineAtStart() = withHarness { h ->
    SystemClock.now = 100
    var reads = 0
    SystemClock.beforeRead = {
        if (++reads == 2) SystemClock.now = 151
    }
    h.play(deadline = 150).started(null)
    SystemClock.beforeRead = null
    check(reads == 2 && h.pool.plays.isEmpty())
    h.play(deadline = 151).started(151)
}

private fun plannedStartGuard() = withHarness { h ->
    SystemClock.now = 10_000
    h.pool.playDelayMs = 50
    h.play(planned = 10_000, deadline = 10_100).started(10_050)
    h.pool.playDelayMs = 0
    SystemClock.now = 13_000
    h.play("alarm:2", planned = 13_000, deadline = 13_100).started(13_000)
    check(h.pool.plays.size == 2)
}

private fun plannedGapGuard() = withHarness { h ->
    SystemClock.now = 10_050
    h.play(planned = 10_000).started(10_050)
    SystemClock.now = 50_000
    for (planned in listOf(0L, 9_999L, 10_000L, 12_999L)) {
        h.play("alarm:2", planned = planned).started(null)
    }
    check(h.pool.plays.size == 1)
    h.play("alarm:2", planned = 13_000).started(50_000)
    check(h.pool.plays.size == 2)
}

private fun zeroTimeGuard() = withHarness { h ->
    SystemClock.now = 50
    h.play(planned = 0).started(50)
    SystemClock.now = 10_000
    h.play("alarm:2", planned = 2_999).started(null)
    h.play("alarm:2", planned = 3_000).started(10_000)
}

private fun failedStartsRetry() = withHarness(loaded = false) { h ->
    h.play().started(null)
    check(h.pool.plays.isEmpty())
    h.pool.completeLoads()
    h.initialized.expect(true)
    h.pool.failures = 1
    h.play().started(null)
    h.pool.playException = IllegalStateException("fake unavailable stream")
    h.play().started(null)
    h.pool.playException = null
    SystemClock.now = 10
    h.play().started(10)
    check(h.pool.plays.count { it.stream != 0 } == 1)
    h.pool.failures = 1
    h.play("end:1", end = true).started(null)
    h.play("end:1", end = true).started(10)
    check(h.pool.plays.count { it.stream != 0 } == 2)
}

private fun failedStartsKeepPlannedGuard() = withHarness { h ->
    SystemClock.now = 10_000
    h.play(planned = 10_000).started(10_000)
    SystemClock.now = 20_000
    h.pool.failures = 1
    h.play("failed", planned = 20_000).started(null)
    h.play("alarm:2", planned = 13_000).started(20_000)
    h.pool.playException = IllegalStateException("fake unavailable stream")
    h.play("failed", planned = 20_000).started(null)
    h.pool.playException = null
    h.play("alarm:3", planned = 16_000).started(20_000)
    check(h.pool.plays.count { it.stream != 0 } == 3)
}

private fun duplicateAndFinishKeepPlannedGuard() = withHarness { h ->
    SystemClock.now = 10_050
    h.play(planned = 10_000).started(10_050)
    SystemClock.now = 20_000
    h.play(planned = 20_000, deadline = 0).started(10_050)
    h.play("alarm:2", planned = 13_000).started(20_000)
    h.play("end:1", planned = 20_000, deadline = 0, end = true).started(20_000)
    h.play("alarm:3", planned = 16_000).started(20_000)
    check(h.pool.plays.size == 4)
}

private fun cancellationKeepsGuardAndLedger() = withHarness { h ->
    SystemClock.now = 100
    h.play().started(100)
    val stream = h.pool.plays.last().stream
    h.channel.call("cancelAlarm", generations(0, 1)).expect(null)
    check(h.pool.stops == listOf(stream))
    h.play(alarmGeneration = 1).started(100)
    h.play("alarm:2", alarmGeneration = 0).started(null)
    SystemClock.now = 1_000
    h.play("alarm:2", alarmGeneration = 1).started(null)
    h.channel.call("stop", generations(1, 2)).expect(null)
    h.play().started(null)
    SystemClock.now = 3_099
    h.play(generation = 1, alarmGeneration = 2).started(null)
    SystemClock.now = 3_100
    h.play(generation = 1, alarmGeneration = 2).started(3_100)
    check(h.pool.plays.size == 2)
}

private fun cancellationPreservesFinish() = withHarness { h ->
    SystemClock.now = 100
    h.play("end:1", generation = 5, alarmGeneration = 5, end = true).started(100)
    val stream = h.pool.plays.last().stream
    h.channel.call("cancelAlarm", generations(6, 6)).expect(null)
    check(stream in h.pool.activeStreams && h.pool.stops.isEmpty())
    h.play("end:1", generation = 5, alarmGeneration = 0, deadline = 0, end = true).started(100)
    check(h.pool.plays.size == 1)
    h.play("pending end", generation = 5, alarmGeneration = 0, deadline = 0, end = true).started(100)
    h.play("end:2", generation = 6, alarmGeneration = 0, deadline = 0, end = true).started(100)
    val newStream = h.pool.plays.last().stream
    val stopped = h.pool.stops.toList()
    h.channel.call("stop", generations(5, 99)).expect(null)
    check(newStream in h.pool.activeStreams && h.pool.stops == stopped)
    h.play("old end", generation = 5, alarmGeneration = 99, end = true).started(null)
    h.play("old alarm", generation = 6, alarmGeneration = 5).started(null)
    h.channel.call("cancelAlarm", generations(6, 5)).expect(null)
    check(h.pool.stops == stopped)
    h.channel.call("stop", generations(6, 6)).expect(null)
    check(h.pool.activeStreams.isEmpty())
    h.play("alarm:2", generation = 6, alarmGeneration = 6).started(100)
}

private fun beginWorkoutPreservesPlayingFinish() = withHarness { h ->
    SystemClock.now = 100
    h.play("end:1", generation = 4, alarmGeneration = 4, deadline = 0, end = true).started(100)
    val stream = h.pool.plays.single().stream
    h.channel.call("beginWorkout", generations(5, 5)).expect(null)
    check(h.pool.activeStreams == setOf(stream) && h.pool.stops.isEmpty())
    h.channel.call("setVolume", 0.25).expect(null)
    check(h.pool.volumes.single() == SoundPool.Volume(stream, 0.25f, 0.25f))
    h.play("old alarm", generation = 4, alarmGeneration = 99).started(null)
    h.play("end:1", generation = 4, alarmGeneration = 99, end = true).started(null)
    h.play("old end", generation = 4, alarmGeneration = 99, end = true).started(null)
    check(h.pool.plays.size == 1 && h.pool.activeStreams == setOf(stream))
    h.channel.call("stop", generations(5, 5)).expect(null)
    check(h.pool.activeStreams.isEmpty() && h.pool.stops == listOf(stream))
    SystemClock.now = 200
    h.play("end:1", generation = 5, alarmGeneration = 5, deadline = 0, end = true).started(200)
    check(h.pool.plays.size == 2)
}

private fun beginWorkoutAllowsAlarmToReplaceFinish() = withHarness { h ->
    h.play("end:1", end = true).started(0)
    val endStream = h.pool.plays.single().stream
    h.channel.call("beginWorkout", generations(1, 1)).expect(null)
    check(h.pool.activeStreams == setOf(endStream))
    SystemClock.now = 3_000
    h.pool.failures = 1
    h.play(generation = 1, alarmGeneration = 1).started(null)
    check(h.pool.activeStreams == setOf(endStream) && h.pool.stops.isEmpty())
    h.play(generation = 1, alarmGeneration = 1).started(3_000)
    val alarmStream = h.pool.plays.last().stream
    check(h.pool.activeStreams == setOf(alarmStream) && h.pool.stops.isEmpty())
    check(h.pool.plays.last().sample == 1 && h.pool.plays.last().loop == 0)
    h.channel.call("stop", generations(1, 1)).expect(null)
    check(h.pool.activeStreams.isEmpty() && h.pool.stops == listOf(alarmStream))
}

private fun beginWorkoutKeepsGuardAndResetsLedger() = withHarness { h ->
    SystemClock.now = 10_050
    h.play(planned = 10_000).started(10_050)
    val stream = h.pool.plays.single().stream
    h.channel.call("beginWorkout", generations(1, 1)).expect(null)
    check(h.pool.activeStreams.isEmpty() && h.pool.stops == listOf(stream))
    SystemClock.now = 13_000
    h.play(generation = 1, alarmGeneration = 1, planned = 12_999).started(null)
    h.play(generation = 1, alarmGeneration = 1, planned = 13_000).started(13_000)
    h.play(generation = 0, alarmGeneration = 99).started(null)
    SystemClock.now = 20_000
    h.play(generation = 1, alarmGeneration = 1).started(13_000)
    check(h.pool.plays.size == 2)
}

private fun beginWorkoutInvalidatesPendingEvents() {
    val policy = PlaybackPolicy { 100L }
    val request = checkNotNull(PlaybackRequest.fromArguments(arguments()))
    val alarm = checkNotNull(policy.receive(request, end = false))
    val end = checkNotNull(policy.receive(request.copy(eventId = "end:1"), end = true))
    var cancelled = 0
    policy.beginWorkout(PlaybackGeneration(1, 1)) { cancelled++ }
    check(cancelled == 1)
    check(policy.start(alarm) { error("old-workout alarm started") } == null)
    check(policy.start(end) { error("old-workout finish started") } == null)
    check(policy.receive(request, end = false) == null)
    check(policy.receive(request.copy(eventId = "end:2"), end = true) == null)

    val current = request.copy(generation = PlaybackGeneration(1, 1))
    val nextAlarm = checkNotNull(policy.receive(current, end = false))
    val nextEnd = checkNotNull(policy.receive(current.copy(eventId = "end:1"), end = true))
    policy.beginWorkout(PlaybackGeneration(1, 1)) { cancelled++ }
    check(cancelled == 2)
    check(policy.start(nextAlarm) { error("invalidated same-generation alarm started") } == null)
    check(policy.start(nextEnd) { error("invalidated same-generation finish started") } == null)
    val freshEnd = checkNotNull(policy.receive(current.copy(eventId = "end:1"), end = true))
    policy.beginWorkout(PlaybackGeneration(0, 99)) { error("stale workout control accepted") }
    policy.beginWorkout(PlaybackGeneration(1, 0)) { error("stale alarm control accepted") }
    policy.beginWorkout(PlaybackGeneration(2, 0)) { error("stale alarm control advanced workout") }
    check(policy.start(freshEnd) { true } == 100L)
}

private fun staleBeginWorkoutKeepsCurrentPlayback() = withHarness { h ->
    SystemClock.now = 100
    h.play(generation = 5, alarmGeneration = 5).started(100)
    val stream = h.pool.plays.single().stream
    for (generation in listOf(generations(4, 99), generations(5, 4), generations(6, 4))) {
        h.channel.call("beginWorkout", generation).expect(null)
        check(h.pool.activeStreams == setOf(stream) && h.pool.stops.isEmpty())
    }
    SystemClock.now = 200
    h.play(generation = 5, alarmGeneration = 5).started(100)
    check(h.pool.plays.size == 1)
}

private fun requestsAdvanceFloors() = withHarness { h ->
    h.play("end:1", generation = 3, alarmGeneration = 4, end = true).started(0)
    h.play("end:2", generation = 2, alarmGeneration = 50, end = true).started(null)
    h.play("alarm:1", generation = 3, alarmGeneration = 0).started(0)
    h.play("alarm:2", generation = 3, alarmGeneration = 4).started(null)
    val stream = h.pool.plays.last().stream
    h.channel.call("cancelAlarm", generations(3, 3)).expect(null)
    check(stream in h.pool.activeStreams)
    h.channel.call("stop", generations(2, 100)).expect(null)
    check(stream in h.pool.activeStreams)
    h.play("end:2", generation = 3, alarmGeneration = 0, end = true).started(0)
}

private fun completionRetries() = withHarness { h ->
    SystemClock.now = 100
    h.play("end:1", end = true).started(100)
    SystemClock.now = 60_000
    h.channel.call("cancelAlarm", generations(0, 1)).expect(null)
    h.play("end:1", alarmGeneration = 0, deadline = 0, end = true).started(100)
    h.play("end:1", alarmGeneration = 1, deadline = 0).started(100)
    check(h.pool.plays.size == 1)
    h.channel.call("stop", generations(1, 2)).expect(null)
    h.play("end:1", generation = 1, alarmGeneration = 2, end = true).started(60_000)
    check(h.pool.plays.size == 2)
}

private fun staleAtStart() {
    var now = 100L
    val policy = PlaybackPolicy { now }
    val request = checkNotNull(PlaybackRequest.fromArguments(arguments(deadline = 150)))
    val alarm = checkNotNull(policy.receive(request, end = false))
    policy.cancel(PlaybackGeneration(0, 1), alarmOnly = true) {}
    check(policy.start(alarm) { error("cancelled alarm started") } == null)
    val end = checkNotNull(policy.receive(request, end = true))
    now = 1_000
    check(policy.start(end) { true } == 1_000L)
    policy.cancel(PlaybackGeneration(1, 2), alarmOnly = false) {}
    check(policy.start(end) { error("old-generation finish started") } == null)

    val current = request.copy(generation = PlaybackGeneration(1, 2), deadlineMs = 1_050)
    val expiring = checkNotNull(policy.receive(current, end = false))
    now = 1_051
    check(policy.start(expiring) { error("expired alarm started") } == null)

    val pendingEnd = checkNotNull(policy.receive(current.copy(eventId = "pending end"), end = true))
    policy.cancel(PlaybackGeneration(10, 10), alarmOnly = true) {}
    check(policy.start(pendingEnd) { true } == 1_051L)
}

private fun sameGenerationCancellation() {
    val policy = PlaybackPolicy { 100L }
    val request = checkNotNull(PlaybackRequest.fromArguments(arguments()))
    val alarm = checkNotNull(policy.receive(request, end = false))
    val end = checkNotNull(policy.receive(request.copy(eventId = "end:1"), end = true))
    policy.cancel(PlaybackGeneration(0, 0), alarmOnly = true) {}
    check(policy.start(alarm) { error("same-generation cancelled alarm started") } == null)
    check(policy.start(end) { true } == 100L)
    val retry = checkNotNull(policy.receive(request, end = false))
    check(policy.start(retry) { true } == 100L)

    val nextAlarm = checkNotNull(policy.receive(request.copy(eventId = "alarm:2"), end = false))
    val nextEnd = checkNotNull(policy.receive(request.copy(eventId = "end:2"), end = true))
    policy.cancel(PlaybackGeneration(0, 0), alarmOnly = false) {}
    check(policy.start(nextAlarm) { error("same-generation stopped alarm started") } == null)
    check(policy.start(nextEnd) { error("same-generation stopped finish started") } == null)
    val endRetry = checkNotNull(policy.receive(request.copy(eventId = "end:2"), end = true))
    check(policy.start(endRetry) { true } == 100L)
    policy.invalidate()
    check(policy.start(endRetry) { error("disposed receive started") } == null)
}

private fun newerRequestInvalidatesPendingStart() {
    val policy = PlaybackPolicy { 100L }
    val request = checkNotNull(PlaybackRequest.fromArguments(arguments()))
    val alarm = checkNotNull(policy.receive(request, end = false))
    val end = checkNotNull(policy.receive(request.copy(eventId = "end:1"), end = true))
    checkNotNull(policy.receive(request.copy(generation = PlaybackGeneration(0, 1)), end = false))
    check(policy.start(alarm) { error("older alarm epoch started") } == null)
    check(policy.start(end) { true } == 100L)
    checkNotNull(policy.receive(request.copy(generation = PlaybackGeneration(1, 1)), end = true))
    check(policy.start(end) { error("older full generation started") } == null)
}

private fun concurrentRetries(firstFails: Boolean) {
    val policy = PlaybackPolicy { 123L }
    val request = checkNotNull(PlaybackRequest.fromArguments(arguments(id = "end:race")))
    val calls = AtomicInteger()
    val executor = Executors.newFixedThreadPool(8)
    val go = CountDownLatch(1)
    try {
        val replies = (1..32).map {
            executor.submit<Long?> {
                check(go.await(5, TimeUnit.SECONDS))
                val pending = checkNotNull(policy.receive(request, end = true))
                policy.start(pending) { calls.incrementAndGet() != 1 || !firstFails }
            }
        }
        go.countDown()
        val starts = replies.map { it.get(5, TimeUnit.SECONDS) }
        check(starts.count { it == null } == if (firstFails) 1 else 0)
        check(starts.filterNotNull().all { it == 123L })
        check(calls.get() == if (firstFails) 2 else 1)
    } finally {
        go.countDown()
        executor.shutdownNow()
        check(executor.awaitTermination(5, TimeUnit.SECONDS))
    }
}

private fun stopRacesStart() {
    val policy = PlaybackPolicy { 123L }
    val request = checkNotNull(PlaybackRequest.fromArguments(arguments()))
    val entered = CountDownLatch(1)
    val finish = CountDownLatch(1)
    val stopping = CountDownLatch(1)
    val stream = AtomicInteger()
    val executor = Executors.newFixedThreadPool(2)
    try {
        val pending = checkNotNull(policy.receive(request, end = false))
        val start = executor.submit<Long?> {
            policy.start(pending) {
                entered.countDown()
                check(finish.await(5, TimeUnit.SECONDS))
                stream.set(1)
                true
            }
        }
        check(entered.await(5, TimeUnit.SECONDS))
        val stop = executor.submit {
            stopping.countDown()
            policy.cancel(PlaybackGeneration(0, 0), alarmOnly = false) { stream.set(0) }
        }
        check(stopping.await(5, TimeUnit.SECONDS))
        finish.countDown()
        check(start.get(5, TimeUnit.SECONDS) == 123L)
        stop.get(5, TimeUnit.SECONDS)
        check(stream.get() == 0)
        check(policy.start(pending) { error("stale retry played") } == null)
    } finally {
        finish.countDown()
        executor.shutdownNow()
        check(executor.awaitTermination(5, TimeUnit.SECONDS))
    }
}

private fun beginWorkoutRacesFinishStart() {
    val policy = PlaybackPolicy { 123L }
    val request = checkNotNull(PlaybackRequest.fromArguments(arguments(id = "end:race")))
    val entered = CountDownLatch(1)
    val finish = CountDownLatch(1)
    val beginning = CountDownLatch(1)
    val stream = AtomicInteger()
    val executor = Executors.newFixedThreadPool(2)
    try {
        val pending = checkNotNull(policy.receive(request, end = true))
        val start = executor.submit<Long?> {
            policy.start(pending) {
                entered.countDown()
                check(finish.await(5, TimeUnit.SECONDS))
                stream.set(1)
                true
            }
        }
        check(entered.await(5, TimeUnit.SECONDS))
        val begin = executor.submit {
            beginning.countDown()
            policy.beginWorkout(PlaybackGeneration(1, 1)) { check(stream.get() == 1) }
        }
        check(beginning.await(5, TimeUnit.SECONDS))
        finish.countDown()
        check(start.get(5, TimeUnit.SECONDS) == 123L)
        begin.get(5, TimeUnit.SECONDS)
        check(stream.get() == 1)
        check(policy.start(pending) { error("old finish replayed after beginning workout") } == null)
        check(policy.receive(request, end = true) == null)
        policy.cancel(PlaybackGeneration(1, 1), alarmOnly = false) { stream.set(0) }
        check(stream.get() == 0)
    } finally {
        finish.countDown()
        executor.shutdownNow()
        check(executor.awaitTermination(5, TimeUnit.SECONDS))
    }
}

private fun mediaBehavior() = withHarness { h ->
    check(h.activity.volumeControlStream == AudioManager.STREAM_MUSIC)
    check(h.activity.requestedOrientation == ActivityInfo.SCREEN_ORIENTATION_PORTRAIT)
    h.activity.onConfigurationChanged(Configuration(600))
    check(h.activity.requestedOrientation == ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED)
    h.activity.onConfigurationChanged(Configuration(400))
    check(h.activity.requestedOrientation == ActivityInfo.SCREEN_ORIENTATION_PORTRAIT)
    check(h.pool.maxStreams == 1)
    check(h.pool.attributes?.usage == AudioAttributes.USAGE_MEDIA)
    check(h.pool.attributes.contentType == AudioAttributes.CONTENT_TYPE_SONIFICATION)
    h.channel.call("setVolume", 0.4).expect(null)
    h.play("end:1", end = true).started(0)
    val play = h.pool.plays.single()
    check(play.sample == 2 && play.loop == 2 && play.rate == 1f)
    check(play.left == 0.4f && play.right == 0.4f)
    h.channel.call("setVolume", 0.2).expect(null)
    check(h.pool.volumes.single() == SoundPool.Volume(play.stream, 0.2f, 0.2f))
    h.channel.call("keepAwake", true).expect(null)
    check(h.activity.window.flags and WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON != 0)
    h.channel.call("dispose").expect(null)
    check(h.pool.released && h.pool.listener == null && h.pool.activeStreams.isEmpty())
    check(h.activity.window.flags == 0)
    h.play("after dispose", end = true).started(null)
}

private fun loadLifecycle() = withHarness(loaded = false) { h ->
    val oldListener = checkNotNull(h.pool.listener)
    check(h.pool.loads.all { File(it.first).isFile })
    val replacement = h.initialize()
    h.initialized.expect(false)
    check(h.pool.released && h.pool.loads.none { File(it.first).exists() })
    oldListener(h.pool, 1, 0)
    oldListener(h.pool, 2, 0)
    check(replacement.completions == 0)
    val pool = SoundPool.instances.last()
    pool.completeLoads()
    replacement.expect(true)
    check(pool.loads.none { File(it.first).exists() })
    h.play().started(0)
    val again = h.initialize()
    val newest = SoundPool.instances.last()
    newest.completeLoads()
    again.expect(true)
    SystemClock.now = 1_000
    h.play().started(0)
    h.play("alarm:2").started(null)
    check(newest.plays.isEmpty())
    SystemClock.now = 3_000
    h.play("alarm:2").started(3_000)
}

private fun loadTimeout() = withHarness(loaded = false) { h ->
    check(h.initialized.completions == 0)
    Handler.runPending()
    h.initialized.expect(false)
    check(h.pool.released && h.pool.loads.none { File(it.first).exists() })
    h.play().started(null)
    h.channel.call("initialize", mapOf("alarm" to "bad", "end" to byteArrayOf(1))).expect(false)
}

fun main() {
    val probes = listOf<Pair<String, () -> Unit>>(
        "malformed channel arguments and exact integer decoding" to ::malformedArguments,
        "receive deadline, inclusive boundary, expired duplicate, late finish" to ::deadlineAtReceipt,
        "deadline rechecked immediately before playback" to ::deadlineAtStart,
        "3000 ms planned gap survives 50 ms playback jitter with actual receipts" to ::plannedStartGuard,
        "actual elapsed time cannot admit cues planned less than 3000 ms apart" to ::plannedGapGuard,
        "successful planned time zero consumes the guard" to ::zeroTimeGuard,
        "not-ready, zero-stream and exception failures remain retryable" to ::failedStartsRetry,
        "failed playback leaves the previous successful planned guard unchanged" to ::failedStartsKeepPlannedGuard,
        "duplicate receipts and finishes do not move the planned alarm guard" to ::duplicateAndFinishKeepPlannedGuard,
        "cancellation preserves guard and successful ledger" to ::cancellationKeepsGuardAndLedger,
        "alarm cancellation preserves finish even with a newer supplied generation" to ::cancellationPreservesFinish,
        "beginWorkout preserves playing finish, rejects old events and full stop silences it" to ::beginWorkoutPreservesPlayingFinish,
        "next successful alarm naturally replaces the preserved finish" to ::beginWorkoutAllowsAlarmToReplaceFinish,
        "beginWorkout stops alarms, retains planned guard and resets the generation ledger" to ::beginWorkoutKeepsGuardAndResetsLedger,
        "beginWorkout invalidates pending alarms and ends including same-generation receives" to ::beginWorkoutInvalidatesPendingEvents,
        "stale beginWorkout controls preserve active playback and successful receipts" to ::staleBeginWorkoutKeepsCurrentPlayback,
        "accepted requests advance floors and stale controls do nothing" to ::requestsAdvanceFloors,
        "completion retries keep the original receipt until a new generation" to ::completionRetries,
        "stale generation, alarm generation and deadline rejected at start" to ::staleAtStart,
        "same-generation cancellation and disposal invalidate old receives" to ::sameGenerationCancellation,
        "newer requests invalidate pending starts without a Stop" to ::newerRequestInvalidatesPendingStart,
        "32 racing duplicate requests start once" to { concurrentRetries(firstFails = false) },
        "racing retry after failure starts once and retains only success" to { concurrentRetries(firstFails = true) },
        "stop racing a start silences it before accepting more work" to ::stopRacesStart,
        "beginWorkout racing a finish preserves the started stream until full stop" to ::beginWorkoutRacesFinishStart,
        "media usage, gain, finish repeats, orientation and disposal" to ::mediaBehavior,
        "reinitialization discards stale loads and preserves playback history" to ::loadLifecycle,
        "loading timeout cleans up and preserves initialize boolean contract" to ::loadTimeout,
    )
    for ((name, probe) in probes) {
        probe()
        println("PASS: $name")
    }
    println("PASS: ${probes.size} Android native JVM regression probes")
}
