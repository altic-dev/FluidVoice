import Charts
import SwiftUI

extension View {
    /// A local pointer surface: no polling, history access, or persistent selection.
    func statsChartInteraction(onInspect: @escaping (CGFloat, ChartProxy, Bool) -> Void, onExit: @escaping () -> Void) -> some View {
        self.chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            guard let frame = proxy.plotFrame, geometry[frame].contains(location) else {
                                onExit()
                                return
                            }
                            onInspect(location.x - geometry[frame].minX, proxy, false)
                        case .ended:
                            onExit()
                        }
                    }
                    .onTapGesture { location in
                        guard let frame = proxy.plotFrame, geometry[frame].contains(location) else { return }
                        onInspect(location.x - geometry[frame].minX, proxy, true)
                    }
            }
            .accessibilityHidden(true)
        }
    }
}
