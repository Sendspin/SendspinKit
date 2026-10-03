@testable import SendspinKit

extension SendspinConnection {
    func establishTestClockSync() async {
        await handleServerTime(
            ServerTimeMessage(payload: ServerTimePayload(clientTransmitted: 0, serverReceived: 0, serverTransmitted: 0)),
            clientReceived: 0
        )
    }
}
