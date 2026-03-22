# music_kit plugin ProGuard rules

# Apple's mediaplayback AAR pulls in javacpp and slf4j as transitive
# dependencies. These are compile-time only and not needed at runtime.
-dontwarn org.apache.maven.plugins.annotations.**
-dontwarn org.bytedeco.**
-dontwarn org.slf4j.impl.**
-dontwarn org.slf4j.**

# Keep our DRM callback and data source (used via ExoPlayer's interfaces)
-keep class app.misi.music_kit.AppleMusicDrmCallback { *; }
-keep class app.misi.music_kit.AppleMusicDrmPlayer { *; }
-keep class app.misi.music_kit.HlsMethodRewriteDataSource { *; }
