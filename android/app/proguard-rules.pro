-keep class com.sun.jna.** { *; }
-keep class com.goterl.lazysodium.** { *; }
-keepclasseswithmembernames class * { native <methods>; }
# JNA references desktop AWT, which does not exist on Android.
-dontwarn java.awt.**
