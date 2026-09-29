import WidgetKit
import SwiftUI

@main
struct PaceLabWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextSessionWidget()
        WeekProgressWidget()
        LastRunWidget()
    }
}
