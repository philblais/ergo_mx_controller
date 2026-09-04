import Testing
@testable import MXErgoCore

@Test func ringBufferKeepsOnlyTheNewestElementsInOrder() {
    var buffer = BoundedRingBuffer<Int>(capacity: 3)
    buffer.append(1)
    buffer.append(2)
    buffer.append(3)
    buffer.append(4)
    buffer.append(5)

    #expect(buffer.count == 3)
    #expect(buffer.elements == [3, 4, 5])
}

