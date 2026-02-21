/// Replace `{width}` placeholder in ARD image URLs with actual pixel width.
///
/// ARD image service URLs contain a `{width}` token that gets replaced with
/// the desired pixel width. Returns null if the input URL is null.
String? ardImageUrl(String? url, {int width = 400}) {
  if (url == null) return null;
  return url.replaceAll('{width}', '$width');
}
