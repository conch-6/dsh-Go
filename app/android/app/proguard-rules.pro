# R8 rules for the release build (Flutter adds its own on top).

# Conscrypt's pre-Lollipop socket adapters reference platform classes that
# don't exist on minSdk 26; those paths are never reached.
-dontwarn com.android.org.conscrypt.SSLParametersImpl
-dontwarn org.apache.harmony.xnet.provider.jsse.SSLParametersImpl

# 不打扰模式: the privileged process is started by class name, outside R8's
# view (Shizuku UserService, `app_process … PrivilegedDisplayMain` over self-ADB),
# and talks to the app through a hand-written Binder and Parcel/Bundle protocol.
-keep class io.github.ccch1mneyyy.dsh_app.phone.background.** { *; }

# Independent Shizuku service and self-ADB/app_process command entry points.
-keep class io.github.ccch1mneyyy.dsh_app.phone.shell.** { *; }

# The one-attempt self-update UserService is loaded by Shizuku outside R8 references.
-keep class io.github.ccch1mneyyy.dsh_app.update.privileged.** { *; }

# Bouncy Castle and Conscrypt look providers and algorithms up by name;
# libadb-android drives both for wireless-debugging pairing and TLS.
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**
-keep class org.conscrypt.** { *; }
-keep class io.github.muntashirakon.adb.** { *; }
