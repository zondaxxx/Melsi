# gomobile bindings: JNI looks classes/methods up by name.
-keep class go.** { *; }
-keep class io.nekohasekai.** { *; }
-keepclassmembers class * implements go.Seq$Proxy { *; }
# Our implementations of libbox interfaces are called from Go through JNI.
-keep class app.melsi.vpn.** { *; }
-dontwarn go.**
-dontwarn io.nekohasekai.**
