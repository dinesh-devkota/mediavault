import SwiftUI

enum TVRemoteDirection {
    case up, down, left, right
}

extension View {
    func onTVExit(_ action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        onExitCommand(perform: action)
        #else
        self
        #endif
    }

    func onTVMove(_ action: @escaping (TVRemoteDirection) -> Void) -> some View {
        #if os(tvOS)
        onMoveCommand { direction in
            switch direction {
            case .up: action(.up)
            case .down: action(.down)
            case .left: action(.left)
            case .right: action(.right)
            @unknown default: break
            }
        }
        #else
        self
        #endif
    }

    func tvFocusSection() -> some View {
        #if os(tvOS)
        focusSection()
        #else
        self
        #endif
    }
}
