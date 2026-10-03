@testable import SendspinKit

extension SendspinConnection {
    func armRouteInvalidationForTesting() {
        routeInvalidationPending = true
        audioEngine.beginRouteInvalidation()
    }
}
