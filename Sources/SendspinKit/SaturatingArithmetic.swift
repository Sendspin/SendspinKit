/// Saturating integer arithmetic for unvalidated wire values.
///
/// Server timestamps arrive as raw `Int64` and are combined with local anchors,
/// latencies, and delays before anyone checks them. Swift's `+`/`-` trap on
/// overflow, so on a real-time or actor-hosted path a single malformed timestamp
/// becomes a crash. These helpers clamp to the representable range instead.
///
/// Saturating is the right default only where a clamped result is harmless — a
/// timestamp already so extreme that it cannot describe a real schedule. Where
/// the caller can act on the distinction, use `addingReportingOverflow` /
/// `subtractingReportingOverflow` directly and reject the value.
extension FixedWidthInteger {
    /// `self + other`, clamped to the representable range instead of trapping.
    func saturatingAdding(_ other: Self) -> Self {
        let result = addingReportingOverflow(other)
        guard result.overflow else { return result.partialValue }
        return other > 0 ? Self.max : Self.min
    }

    /// `self - other`, clamped to the representable range instead of trapping.
    func saturatingSubtracting(_ other: Self) -> Self {
        let result = subtractingReportingOverflow(other)
        guard result.overflow else { return result.partialValue }
        return other > 0 ? Self.min : Self.max
    }
}
