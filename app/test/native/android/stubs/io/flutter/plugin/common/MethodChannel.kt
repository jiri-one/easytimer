@file:Suppress("UNUSED_PARAMETER")

package io.flutter.plugin.common

class MethodCall(val method: String, val arguments: Any?)

class MethodChannel(messenger: Any, val name: String) {
    init { latest = this }
    var handler: ((MethodCall, Result) -> Unit)? = null
        private set

    fun setMethodCallHandler(value: ((MethodCall, Result) -> Unit)?) { handler = value }

    fun call(method: String, arguments: Any? = null): Reply = Reply().also {
        checkNotNull(handler)(MethodCall(method, arguments), it)
    }

    interface Result {
        fun success(result: Any?)
        fun error(code: String, message: String?, details: Any?)
        fun notImplemented()
    }

    class Reply : Result {
        var completions = 0
        var value: Any? = null
        var errorCode: String? = null
        override fun success(result: Any?) { completions++; value = result }
        override fun error(code: String, message: String?, details: Any?) {
            completions++
            errorCode = code
        }
        override fun notImplemented() { completions++; errorCode = "not_implemented" }
    }

    companion object {
        lateinit var latest: MethodChannel
    }
}
