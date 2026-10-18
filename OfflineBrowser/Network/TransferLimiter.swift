import Foundation
actor TransferLimiter {
    static let shared=TransferLimiter()
    private var active=0
    private var waiters:[(UUID,CheckedContinuation<Void,Error>)]=[]
    func acquire() async throws {
        try Task.checkCancellation()
        if active<3 { active+=1; return }
        let id=UUID()
        try await withTaskCancellationHandler(operation:{ try await withCheckedThrowingContinuation { waiters.append((id,$0)) } },onCancel:{ Task { await self.cancel(id) } })
    }
    private func cancel(_ id:UUID) { if let i=waiters.firstIndex(where:{$0.0==id}) { waiters.remove(at:i).1.resume(throwing:CancellationError()) } }
    func release() { if !waiters.isEmpty { waiters.removeFirst().1.resume() } else { active=max(0,active-1) } }
}
