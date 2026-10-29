/// Resolved location for an onboarding location field.
/// Mirrors the native `LocationData` (iOS `LocationData` / Android
/// `ai.appdna.sdk.onboarding.LocationData`).
///
/// Every field except [formattedAddress] is optional. A user who
/// typed an address without picking a suggestion yields
/// `{formattedAddress: <text>, rawQuery: <text>}` with every other field `null`
/// (no coordinates); a picked suggestion fills the rest when the lookup had it.
/// A missing value is `null` — never a made-up `''`, `0.0`, `'UTC'` or `0`.
class LocationData {
  final String formattedAddress;
  final String? city;
  final String? state;
  final String? stateCode;
  final String? country;
  final String? countryCode;
  final double? latitude;
  final double? longitude;
  final String? timezone;
  final int? timezoneOffset;
  final String? postalCode;
  final String? rawQuery;

  /// Set only on an answer resolved through a permanent Mapbox geocode: an opaque marker of that provenance, not a
  /// stable place id to look up (for an interpolated address it encodes the request that produced it).
  final String? mapboxId;

  /// Set only on an answer resolved from a Google suggestion: the Places id the user tapped.
  final String? placeId;

  const LocationData({
    required this.formattedAddress,
    this.city,
    this.state,
    this.stateCode,
    this.country,
    this.countryCode,
    this.latitude,
    this.longitude,
    this.timezone,
    this.timezoneOffset,
    this.postalCode,
    this.rawQuery,
    this.mapboxId,
    this.placeId,
  });

  /// The answer map a location field stores: `formatted_address` and each field that is set, with the
  /// native SDKs' snake_case keys. It is what `identify` sends for a `LocationData` trait.
  Map<String, Object> toMap() => <String, Object>{
        'formatted_address': formattedAddress,
        if (city != null) 'city': city!,
        if (state != null) 'state': state!,
        if (stateCode != null) 'state_code': stateCode!,
        if (country != null) 'country': country!,
        if (countryCode != null) 'country_code': countryCode!,
        if (latitude != null && latitude!.isFinite) 'latitude': latitude!,
        if (longitude != null && longitude!.isFinite) 'longitude': longitude!,
        if (timezone != null) 'timezone': timezone!,
        if (timezoneOffset != null) 'timezone_offset': timezoneOffset!,
        if (postalCode != null) 'postal_code': postalCode!,
        if (rawQuery != null) 'raw_query': rawQuery!,
        if (mapboxId != null) 'mapbox_id': mapboxId!,
        if (placeId != null) 'place_id': placeId!,
      };

  factory LocationData.fromMap(Map<dynamic, dynamic> map) {
    return LocationData(
      formattedAddress: map['formatted_address'] as String? ?? '',
      city: map['city'] as String?,
      state: map['state'] as String?,
      stateCode: map['state_code'] as String?,
      country: map['country'] as String?,
      countryCode: map['country_code'] as String?,
      latitude: (map['latitude'] as num?)?.toDouble(),
      longitude: (map['longitude'] as num?)?.toDouble(),
      timezone: map['timezone'] as String?,
      timezoneOffset: (map['timezone_offset'] as num?)?.toInt(),
      postalCode: map['postal_code'] as String?,
      rawQuery: map['raw_query'] as String?,
      mapboxId: map['mapbox_id'] as String?,
      placeId: map['place_id'] as String?,
    );
  }
}
