# ML Kit (traduzione, riconoscimento lingua) usa la "reflection":
# senza queste regole la versione finale cancella pezzi necessari.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_** { *; }
-keep class com.google_mlkit_** { *; }
-keep class com.google.firebase.components.** { *; }
-keepclassmembers class * implements com.google.firebase.components.ComponentRegistrar { <init>(); }
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.**
# Whisper / FFmpeg (codice nativo chiamato da Java)
-keep class com.antonkarpenko.ffmpegkit.** { *; }
-keep class com.arthenica.** { *; }
-dontwarn com.arthenica.**
