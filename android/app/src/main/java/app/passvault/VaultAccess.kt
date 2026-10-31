package app.passvault

/**
 * All engines in this process share the same vault files and Keystore aliases. Hold this reentrant lock for the whole transaction,
 * including password derivation: an observer must never interpret a reserved final attempt as a completed failed attempt, or let
 * AtomicFile.openRead discard another engine's pending write. Storage entry points use the same lock as a second boundary.
 */
internal object VaultAccess {
    private val monitor = Any()
    fun <T> serialized(action: () -> T): T = synchronized(monitor, action)
}
