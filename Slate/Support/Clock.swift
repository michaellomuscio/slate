import QuartzCore

/// The single monotonic host clock for the whole app.
///
/// This is the "slate clap": every stream and every event is timed against `now()` and
/// stored as an offset from the recording's `t0`. Because all four producers (screen,
/// camera, mic, event log) read the *same* clock, their timelines are reconcilable after
/// the fact with no manual re-syncing.
///
/// `CACurrentMediaTime()` is `mach_absolute_time` expressed in seconds — monotonic, not
/// affected by wall-clock changes, and identical across threads.
enum HostClock {
    static func now() -> Double { CACurrentMediaTime() }
}
