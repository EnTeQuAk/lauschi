# music_kit plugin ProGuard rules

# Keep DRM callback and data source (used via ExoPlayer's interfaces)
-keep class app.misi.music_kit.AppleMusicDrmCallback { *; }
-keep class app.misi.music_kit.AppleMusicDrmPlayer { *; }
-keep class app.misi.music_kit.HlsMethodRewriteDataSource { *; }
-keep class app.misi.music_kit.DrmPlayerStateStreamHandler { *; }
