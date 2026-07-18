import SwiftUI
import WidgetKit

@main
struct MultiplexWidgetsBundle: WidgetBundle {
    var body: some Widget {
        HostWidget()
        FleetWidget()
    }
}
