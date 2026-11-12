import WidgetKit
import SwiftUI

@main
struct PacelyWidgetBundle: WidgetBundle {
    var body: some Widget {
        RunningLateControl()
        QuickAddControl()
        PacelyWidget()
        PacelyFocusWidget()
        PacelyLiveActivity()
    }
}
