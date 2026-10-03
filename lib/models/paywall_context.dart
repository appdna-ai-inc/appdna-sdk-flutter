/// Additional context for paywall presentation.
///
/// All four fields now cross to native. Before iOS 1.0.70 / Android 1.0.42 the
/// halves were disjoint: Dart declared `{placement, customData}` while the native plugins read only
/// `{placement, experiment, variant}`. So a host could set **neither** `experiment`/`variant` (not
/// declared here) nor `customData` (declared here, silently dropped at the channel).
class PaywallContext {
  final String? placement;

  /// Experiment id this presentation belongs to, when the host drives its own assignment.
  final String? experiment;

  /// Variant within [experiment].
  final String? variant;

  /// Arbitrary per-presentation attributes. Merged into the `paywall_view` event's properties by
  /// the native SDK, so they are queryable in the warehouse alongside `paywall_id` and `placement`.
  /// Keys colliding with a reserved property (`paywall_id`, `placement`) are dropped by native.
  final Map<String, dynamic>? customData;

  const PaywallContext({
    this.placement,
    this.experiment,
    this.variant,
    this.customData,
  });

  Map<String, dynamic> toMap() => {
        if (placement != null) 'placement': placement,
        if (experiment != null) 'experiment': experiment,
        if (variant != null) 'variant': variant,
        if (customData != null) 'customData': customData,
      };
}
