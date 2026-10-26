package io.flutter.embedding.engine

class FlutterEngine(val dartExecutor: DartExecutor = DartExecutor())

class DartExecutor(val binaryMessenger: Any = Any())
