# Flutter Wrapper
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# TFLite Flutter
-keep class com.tflite_flutter.** { *; }
-keep class org.tensorflow.lite.** { *; }
-dontwarn org.tensorflow.lite.**

# ONNX Runtime
-keep class ai.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**
-keep class com.microsoft.onnxruntime.** { *; }

# Camera & Image Picker
-keep class io.flutter.plugins.camera.** { *; }
-keep class io.flutter.plugins.imagepicker.** { *; }

# AndroidX Lifecycle (Already Present but good to keep clear)
-keep class androidx.lifecycle.DefaultLifecycleObserver

# Google Play Services (Deferred Components / Split Install)
# Referenced by Flutter internal code but not used if deferred components are disabled.
-dontwarn com.google.android.play.core.**
