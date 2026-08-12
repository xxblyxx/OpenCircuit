// WorkoutWidgetBundle.swift — entry point of the WorkoutWidget app-extension.
//
// The extension renders the workout Live Activity (Lock Screen + Dynamic Island), hosts the
// Control Centre / Lock Screen "Log a Headache" control, AND (docs/WIDGETS_HOME_SCREEN.md) the
// Home Screen / Lock Screen ring-snapshot widget (`RingSnapshotWidget.swift`). The app target
// starts/updates/ends the Live Activity via `WorkoutLiveActivityController` and separately writes
// the ring snapshot the widget reads (`RingSnapshotWriter`, app target only); the system hands
// each `ContentState`/timeline to THIS process to render.
//
// (The extension's name is now narrower than its contents. It is deliberately NOT renamed: the
// bundle id com.standardsoftwaresolutions.opencircuit.WorkoutWidget is a registered App ID under
// the paid team and is embedded in shipped builds, so renaming it costs a provisioning round-trip
// and buys nothing.)

import WidgetKit
import SwiftUI

@main
struct WorkoutWidgetBundle: WidgetBundle {
    var body: some Widget {
        WorkoutLiveActivity()
        RingSnapshotWidget()
        // `ControlWidget` is iOS 18+ while this extension deploys to iOS 17 alongside the app, so
        // the control is registered behind an availability check. On iOS 17 the bundle contains
        // just the Live Activity + ring-snapshot widget, exactly as they ship — the control's
        // absence changes nothing about either. (`WidgetBundleBuilder.buildOptional` accepts the
        // limited-availability widget this produces.)
        if #available(iOS 18.0, *) {
            HeadacheLogControl()
        }
    }
}
