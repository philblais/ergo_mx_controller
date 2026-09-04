public struct BoundedRingBuffer<Element: Sendable>: Sendable {
    public let capacity: Int
    private var storage: [Element]
    private var nextInsertionIndex = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "A ring buffer must have a positive capacity")
        self.capacity = capacity
        storage = []
        storage.reserveCapacity(capacity)
    }

    public var count: Int { storage.count }

    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
            return
        }

        storage[nextInsertionIndex] = element
        nextInsertionIndex = (nextInsertionIndex + 1) % capacity
    }

    public var elements: [Element] {
        guard storage.count == capacity, nextInsertionIndex != 0 else {
            return storage
        }

        return Array(storage[nextInsertionIndex...]) + Array(storage[..<nextInsertionIndex])
    }
}

