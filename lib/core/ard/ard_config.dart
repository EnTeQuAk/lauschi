/// ARD Audiothek API configuration.
abstract final class ArdConfig {
  static const graphqlEndpoint = 'https://api.ardaudiothek.de/graphql';

  /// Editorial category ID for "Für Kinder" content.
  static const kidsCategoryId = '42914714';

  /// Image service base URL. Append `?w={width}` for dynamic sizing.
  static const imageServiceBase = 'https://api.ardmediathek.de/image-service/images';

  /// Build a sized image URL from an ARD image URN.
  static String imageUrl(String urn, {int width = 400}) {
    // If already a full URL (some responses include the full path), use as-is.
    if (urn.startsWith('http')) {
      final uri = Uri.parse(urn);
      return uri.replace(queryParameters: {'w': '$width'}).toString();
    }
    return '$imageServiceBase/$urn?w=$width';
  }
}
