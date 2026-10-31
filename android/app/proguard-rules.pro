-keep class com.sun.jna.** { *; }
-keep class com.goterl.lazysodium.** { *; }
-keepclasseswithmembernames class * { native <methods>; }
# JNA references desktop AWT, which does not exist on Android.
-dontwarn java.awt.**
# zxcvbn (app password guessability) loads its dictionaries from jar resources: keep it whole, so the minified release cannot lose
# the check (which fails open) to shrinking or optimisation.
-keep class com.nulabinc.zxcvbn.** { *; }
