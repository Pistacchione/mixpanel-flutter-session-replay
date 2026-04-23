import 'package:flutter/widgets.dart';

import '../internal/widget_coordinator.dart';

/// Observes app lifecycle state changes and flushes queued events when the app
/// is backgrounded or minimized.
///
/// The observer treats [AppLifecycleState.inactive] as still foreground.
/// Only transitions into [AppLifecycleState.hidden], [AppLifecycleState.paused]
/// or [AppLifecycleState.detached] are reported as backgrounding, which
/// prevents transient inactive states (e.g. presenting a native full-screen
/// component, pulling down the notification shade, incoming call overlay)
/// from terminating the current replay session.
///
/// When the app becomes non-visible, all queued session replay events are
/// flushed so data isn't lost.
class LifecycleObserver extends StatefulWidget {
  const LifecycleObserver({
    super.key,
    required this.coordinator,
    required this.child,
  });

  /// The session replay coordinator that manages event flushing
  final WidgetCoordinator coordinator;

  /// The child widget to wrap
  final Widget child;

  @override
  State<LifecycleObserver> createState() => _LifecycleObserverState();
}

class _LifecycleObserverState extends State<LifecycleObserver>
    with WidgetsBindingObserver {
  AppLifecycleState? _lastState;

  /// Latch set when a real backgrounding has been reported.
  ///
  /// Cleared when the matching [onAppForegrounded] is fired. This is needed
  /// because on iOS the foreground sequence is typically
  /// `paused → hidden → inactive → resumed`, and when the final `resumed`
  /// arrives the immediately previous state is `inactive` (level 2, equal to
  /// the visibility threshold), which would miss the "non-visible → resumed"
  /// condition on its own. The latch carries the "we already backgrounded"
  /// signal across the intermediate states.
  bool _wasBackgrounded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Check initial lifecycle state and start uploads if resumed
    final initialState = WidgetsBinding.instance.lifecycleState;
    if (initialState == AppLifecycleState.resumed) {
      widget.coordinator.logger.info(
        'LifecycleObserver detected initial resume state',
      );
      widget.coordinator.onAppForegrounded();
    } else {
      // Observer was mounted while the app was NOT in `resumed` (could be
      // `inactive`, `hidden`, `paused`, or `null`). Prime the latch so the
      // next `resumed` fires onAppForegrounded even when the interim state
      // sits on the visibility threshold (e.g. `inactive → resumed`, which
      // otherwise would not satisfy `lastLevel < visibleThreshold`).
      _wasBackgrounded = true;
    }
    _lastState = initialState;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _handleLifecycleTransition(state);
  }

  /// Handle lifecycle state transitions and trigger appropriate actions
  void _handleLifecycleTransition(AppLifecycleState state) {
    widget.coordinator.logger.debug(
      'LifecycleObserver detected state change: $_lastState → $state',
    );

    // Get visibility levels for comparison
    final currentLevel = _getVisibilityLevel(state);
    final lastLevel = _lastState != null
        ? _getVisibilityLevel(_lastState!)
        : null;

    // Visibility threshold: states at or above are considered "visible".
    // `inactive` is intentionally treated as visible so that transient
    // inactive states (native full-screen components, notification shade,
    // incoming call UI, app switcher) don't terminate the current session.
    const visibleThreshold = 2;

    // Detect transition to a non-visible state from a visible one.
    if (currentLevel < visibleThreshold &&
        lastLevel != null &&
        lastLevel >= visibleThreshold) {
      widget.coordinator.logger.info(
        'LifecycleObserver detected app becoming non-visible',
      );
      widget.coordinator.onAppBackgrounded();
      _wasBackgrounded = true;
    }

    // Detect transition to resumed. Fire onAppForegrounded if either:
    //   - this is the first resume (lastLevel == null), or
    //   - the previous state was below the visibility threshold (direct
    //     non-visible → resumed), or
    //   - a real backgrounding has already been reported earlier in the
    //     chain (iOS returns via paused → hidden → inactive → resumed;
    //     without the latch the condition above would miss this final leg
    //     because `inactive` sits on the threshold).
    //
    // The latch is cleared on every actual fire so that a later
    // `inactive → resumed` bounce (notification shade, app-switcher peek)
    // does not re-trigger onAppForegrounded and create a duplicate session.
    if (state == AppLifecycleState.resumed &&
        (lastLevel == null ||
            lastLevel < visibleThreshold ||
            _wasBackgrounded)) {
      widget.coordinator.logger.info(
        'LifecycleObserver detected app resuming'
        '${_wasBackgrounded ? ' (after prior backgrounding)' : ''}',
      );
      widget.coordinator.onAppForegrounded();
      _wasBackgrounded = false;
    }

    _lastState = state;
  }

  @override
  Widget build(BuildContext context) => widget.child;

  /// Assign visibility levels to lifecycle states
  /// Higher values = more visible/active
  /// resumed (3) > inactive (2) > hidden (1) > paused (0) > detached (-1)
  int _getVisibilityLevel(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        return 3; // Fully visible and interactive
      case AppLifecycleState.inactive:
        return 2; // Visible but not interactive (e.g., notification shade pulled down)
      case AppLifecycleState.hidden:
        return 1; // Not visible but app still running
      case AppLifecycleState.paused:
        return 0; // Backgrounded, may be suspended
      case AppLifecycleState.detached:
        return -1; // Initial state or app being terminated
    }
  }
}
