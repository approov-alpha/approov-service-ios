//
// MIT License
// 
// Copyright (c) 2016-present, Approov Ltd.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files
// (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge,
// publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so,
// subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR
// ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH
// THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

import Foundation

// BoundedExecutor runs work on a dispatch queue at most limit items at a time, in submission order. Work
// beyond the limit waits without holding a thread and can be cancelled before it starts. All state is
// guarded by lock, hence @unchecked.
final class BoundedExecutor: @unchecked Sendable {

    // one submitted item of work, which may be passed to cancel to withdraw it before it starts
    final class Job: @unchecked Sendable {
        // the work, guarded by the executor's lock, or nil once started or cancelled
        fileprivate var work: (@Sendable () -> Void)?

        fileprivate init(_ work: @escaping @Sendable () -> Void) {
            self.work = work
        }
    }

    // the most items run at once and the queue they run on
    let limit: Int
    private let queue: DispatchQueue

    // the lock guarding the running count and the waiting items
    private let lock = NSLock()
    private var running = 0
    private var waiting: [Job] = []

    init(limit: Int, queue: DispatchQueue) {
        precondition(limit > 0, "BoundedExecutor limit must be positive")
        self.limit = limit
        self.queue = queue
    }

    /**
     * Submits work to be run now if fewer than limit items are running, or otherwise once every
     * item submitted before it has started and a running one has finished.
     *
     * @param work is the work to be run
     * @return Job that may be used to cancel the work
     */
    @discardableResult
    func submit(_ work: @escaping @Sendable () -> Void) -> Job {
        let job = Job(work)
        lock.lock()
        if running < limit {
            running += 1
            let start = job.work
            job.work = nil
            lock.unlock()
            if let start { run(start) }
        } else {
            waiting.append(job)
            lock.unlock()
        }
        return job
    }

    /**
     * Cancels a job that is still waiting, so it never runs and its work is released.
     *
     * @param job is the job to be cancelled
     * @return true if the job was withdrawn, false if it had already started or was cancelled
     */
    @discardableResult
    func cancel(_ job: Job) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let index = waiting.firstIndex(where: { $0 === job }) else { return false }
        waiting.remove(at: index)
        job.work = nil
        return true
    }

    // the number of items waiting for a slot
    var waitingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiting.count
    }

    // the number of items running now
    var runningCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    // runs the work on the queue and then frees its slot
    private func run(_ work: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            work()
            finished()
        }
    }

    // hands the slot of a finished item to the oldest waiting item, or frees it
    private func finished() {
        lock.lock()
        guard !waiting.isEmpty else {
            running -= 1
            lock.unlock()
            return
        }
        let next = waiting.removeFirst()
        let work = next.work
        next.work = nil
        lock.unlock()
        // a waiting job always has its work, since cancel removes it from the list
        if let work { run(work) } else { finished() }
    }
}
