# Music Kit
<?code-excerpt path-base="example/lib"?>

[![pub package](https://img.shields.io/pub/v/music_kit.svg)](https://pub.dev/packages/music_kit)

A Flutter plugin to access and play Apple Music. Supports Android, iOS and macOS.
Not all methods are supported on all platforms.

|             | Android | iOS   | macOS |
|-------------|---------|-------|-------|
| **Support** | SDK 21+ | 15.0+ | 14.0+ |


## Usage

To use this plugin, add `music_kit` as a dependency in your pubspec.yaml file.

### Extra steps needs for Android

1. Add the JitPack repository to your build file.

```
repositories {
  ...
  maven { url 'https://jitpack.io' }
}
```

2. Add your apple developer teamId, keyId and base64-encoded key to your `AndroidManifest.xml`

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application>
      ...
       <meta-data android:name="music_kit.teamId" android:value="<TEAM_ID>" />
       <meta-data android:name="music_kit.keyId"  android:value="<KEY_ID>" />
       <meta-data android:name="music_kit.key"    android:value="<BASE64_ENCODED_KEY>" />
    </application>
</manifest>
```

### Example

```dart
// Import package
import 'package:music_kit/music_kit.dart';

// Instantiate it
var musicKit = MusicKit();

// Set Queue
await musicKit.setQueue(item.type, item: item.toJson())

// Play
await musicKit.play();

// Be informed when the player state changes
musicKit.onMusicPlayerStateChanged.listen((MusicPlayerState state) {
  // Do something with new state
});
```
