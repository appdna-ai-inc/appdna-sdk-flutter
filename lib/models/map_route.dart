/// A route handed to a `map` content block at runtime.
///
/// Return one of these from [AppDNAOnboardingDelegate.onBeforeStepRender], keyed by the map block's
/// id, and the block draws it instead of its authored stops:
///
/// ```dart
/// @override
/// Future<Map<String, dynamic>?> onBeforeStepRender(
///   String flowId, String stepId, int stepIndex, String stepType,
///   Map<String, dynamic> responses,
/// ) async {
///   final route = await myRoutingService.routeForCurrentOrder();
///   return {
///     'mapRoutes': {
///       'delivery_map': MapRoute(
///         polyline: route.encodedPolyline,
///         stops: [
///           MapRouteStop(lat: 52.2297, lng: 21.0122, title: 'Warehouse'),
///           MapRouteStop(lat: 52.4064, lng: 16.9252, title: 'You'),
///         ],
///       ).toMap(),
///     },
///   };
/// }
/// ```
///
/// This is the only route source that can answer "where is it right now": authored stops are fixed
/// at publish time, and a template variable can only carry what the flow already knows.
///
/// A pure data shape, per ADR-001 — the rendering, the URL composition and the merge all happen in
/// the native core, so a Flutter host's map is byte-for-byte the map an iOS host's is.
class MapRoute {
  /// Google's encoded-polyline format, which is what every routing service returns.
  ///
  /// Supplying it draws the real road geometry. Supplying only [stops] draws straight lines between
  /// them. Both together is the normal case: the line follows the roads and the pins mark the stops.
  final String? polyline;

  /// The points to mark. Ordering is the route's order — stop 1 is the first pin.
  final List<MapRouteStop> stops;

  const MapRoute({this.polyline, this.stops = const []});

  /// The bridge shape the native decoder reads. Keys are part of the contract and pinned by the
  /// `map_delegate_route` shared fixture, so renaming one here fails a test rather than silently
  /// leaving every Flutter host's map on its authored route.
  Map<String, dynamic> toMap() => <String, dynamic>{
        // `isNotEmpty`, not `!= null`: an empty polyline is not a route, and the native decoder
        // drops it. Sending `{'polyline': ''}` where React Native sends `{}` would be two wrappers
        // disagreeing about the same call — exactly what the shared fixture exists to catch.
        if (polyline != null && polyline!.isNotEmpty) 'polyline': polyline,
        if (stops.isNotEmpty) 'stops': stops.map((s) => s.toMap()).toList(),
      };
}

/// One point on a host-supplied route.
class MapRouteStop {
  final double lat;
  final double lng;

  /// Shown on the pin's label where the map style has room for one. Optional: a coordinate is a
  /// place, a title is a courtesy.
  final String? title;

  const MapRouteStop({required this.lat, required this.lng, this.title});

  Map<String, dynamic> toMap() => <String, dynamic>{
        'lat': lat,
        'lng': lng,
        if (title != null) 'title': title,
      };
}
