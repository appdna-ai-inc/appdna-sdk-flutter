/// SPEC-070-C §3.13 — resolved location for an onboarding location field.
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
  });

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
    );
  }
}
