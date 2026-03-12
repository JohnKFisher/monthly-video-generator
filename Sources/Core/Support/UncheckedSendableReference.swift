import Foundation

final class UncheckedSendableReference<Value: AnyObject>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
