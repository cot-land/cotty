import CCottyCore

/// Swift wrapper around the opaque cotty_app_t handle.
/// One global App per process, owns all surfaces.
final class CottyApp {
    let handle: cotty_app_t

    init() {
        handle = cotty_app_new()
    }

    deinit {
        cotty_app_free(handle)
    }

    func tick() {
        cotty_app_tick(handle)
    }

    var surfaceCount: Int {
        Int(cotty_app_surface_count(handle))
    }

    var isRunning: Bool {
        cotty_app_is_running(handle) != 0
    }

    func createSurface() -> CottySurface {
        CottySurface(app: self, handle: cotty_surface_new(handle))
    }

    /// Poll the action queue. Returns nil if no action pending.
    func nextAction() -> (tag: Int64, payload: Int64, surface: Int64)? {
        let tag = cotty_app_next_action(handle)
        guard tag != COTTY_ACTION_NONE else { return nil }
        let payload = cotty_app_action_payload(handle)
        let surface = cotty_app_action_surface(handle)
        return (tag, payload, surface)
    }
}
