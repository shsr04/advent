# F-051 HIR-Native Cutover Closure

## Target

F-051 closes the last HIR-native cutover gaps after the F-053/F-054 backend work:

- HIR operation metadata owns stable `backend_emitter` ids.
- Backend-owned modules implement C emission for those emitter ids.
- Unknown or malformed backend-reachable HIR still produces explicit backend diagnostic comments instead of semantic recovery.
- Legacy operation-id fallback dispatch is not allowed.

## Boundary

The HIR node registry is the metadata authority. It records operation ids, typing/effect metadata, and backend emitter ids.

Concrete C emission remains in `compiler/lib/MetaC/Backend/` modules. The backend may use the emitter id to select implementation routines, but the HIR registry must not contain C text or C-specific helper bodies.

## Verification

Required checks:

- every builtin, method, and user-call operation has explicit `backend_emitter` metadata;
- unknown operation ids do not resolve through a fallback;
- backend expression dispatch does not branch on `$op_id` or `$emitter_id`, and uses the backend emitter table.;
- malformed-HIR backend diagnostics remain stable;
- the full compiler regression suite remains green.
