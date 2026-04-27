# R8 / ProGuard rules.
#
# Most modern AndroidX libraries ship -keep rules transparently;
# the only entries we need are for our own kotlinx.serialization
# data classes (they're invoked reflectively at runtime by the
# generated serializers).

-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.AnnotationsKt

-keep,includedescriptorclasses class com.wasatchcode.lifting.**$$serializer { *; }
-keepclassmembers class com.wasatchcode.lifting.** {
    *** Companion;
}
-keepclasseswithmembers class com.wasatchcode.lifting.** {
    kotlinx.serialization.KSerializer serializer(...);
}
