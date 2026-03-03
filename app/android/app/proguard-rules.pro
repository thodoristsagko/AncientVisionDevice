# Flutter ProGuard Rules for Maximum Performance
# AncientVision Archaeological App

#-------------------------------------------
# Play Core (not used but referenced by Flutter)
#-------------------------------------------
-dontwarn com.google.android.play.core.**
-keep class com.google.android.play.core.** { *; }

#-------------------------------------------
# Flutter Engine
#-------------------------------------------
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }
-keep class io.flutter.embedding.** { *; }

#-------------------------------------------
# Firebase
#-------------------------------------------
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.firebase.**
-dontwarn com.google.android.gms.**

#-------------------------------------------
# Google Sign-In
#-------------------------------------------
-keep class com.google.android.gms.auth.** { *; }
-keep class com.google.android.gms.common.** { *; }

#-------------------------------------------
# Mobile Scanner (QR/Barcode)
#-------------------------------------------
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.vision.** { *; }
-dontwarn com.google.mlkit.**

#-------------------------------------------
# Google Generative AI (Gemini)
#-------------------------------------------
-keep class com.google.ai.** { *; }
-dontwarn com.google.ai.**

#-------------------------------------------
# TensorFlow Lite
#-------------------------------------------
-keep class org.tensorflow.lite.** { *; }
-keep class org.tensorflow.lite.gpu.** { *; }
-dontwarn org.tensorflow.lite.**
-dontwarn org.tensorflow.lite.gpu.**

#-------------------------------------------
# Camera
#-------------------------------------------
-keep class androidx.camera.** { *; }
-dontwarn androidx.camera.**

#-------------------------------------------
# Biometric / Local Auth
#-------------------------------------------
-keep class androidx.biometric.** { *; }
-keep class android.hardware.biometrics.** { *; }

#-------------------------------------------
# Bluetooth
#-------------------------------------------
-keep class android.bluetooth.** { *; }

#-------------------------------------------
# Geolocator
#-------------------------------------------
-keep class com.baseflow.geolocator.** { *; }
-keep class android.location.** { *; }

#-------------------------------------------
# Speech Recognition
#-------------------------------------------
-keep class com.csdcorp.speech_to_text.** { *; }
-keep class android.speech.** { *; }

#-------------------------------------------
# Optimizations
#-------------------------------------------
-optimizations !code/simplification/arithmetic,!code/simplification/cast,!field/*,!class/merging/*
-optimizationpasses 5
-allowaccessmodification

# Remove debug logging in release
-assumenosideeffects class android.util.Log {
    public static *** d(...);
    public static *** v(...);
    public static *** i(...);
}

# Remove Flutter debug prints in release
-assumenosideeffects class io.flutter.Log {
    public static *** d(...);
    public static *** v(...);
}

#-------------------------------------------
# Flutter Local Notifications
#-------------------------------------------
-keep class com.dexterous.** { *; }
-dontwarn com.dexterous.**

#-------------------------------------------
# Audioplayers
#-------------------------------------------
-keep class xyz.luan.audioplayers.** { *; }
-dontwarn xyz.luan.audioplayers.**

#-------------------------------------------
# Flutter Background Service
#-------------------------------------------
-keep class id.flutter.flutter_background_service.** { *; }
-dontwarn id.flutter.flutter_background_service.**

#-------------------------------------------
# Connectivity Plus
#-------------------------------------------
-keep class dev.fluttercommunity.plus.connectivity.** { *; }
-dontwarn dev.fluttercommunity.plus.connectivity.**

#-------------------------------------------
# Kotlin
#-------------------------------------------
-keep class kotlin.Metadata { *; }
-dontwarn kotlin.**
-keepclassmembers class **$WhenMappings {
    <fields>;
}
-keepclassmembers class kotlin.Metadata {
    public <methods>;
}

#-------------------------------------------
# Serialization
#-------------------------------------------
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes EnclosingMethod
-keepattributes InnerClasses

# Keep Parcelable
-keepclassmembers class * implements android.os.Parcelable {
    public static final android.os.Parcelable$Creator *;
}

# Keep Serializable
-keepclassmembers class * implements java.io.Serializable {
    static final long serialVersionUID;
    private static final java.io.ObjectStreamField[] serialPersistentFields;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
    java.lang.Object writeReplace();
    java.lang.Object readResolve();
}
