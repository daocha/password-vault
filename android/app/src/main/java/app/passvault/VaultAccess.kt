package app.passvault

/**
 * All engines in this process share the same vault files and Keystore aliases. Hold this reentrant lock for the whole transaction,
 * including password derivation: an observer must never interpret a reserved final attempt as a completed failed attempt, or let
 * AtomicFile.openRead discard another engine's pending write. Storage entry points use the same lock as a second boundary.
 */
internal object VaultAccess {
    private val monitor = Any()
    private var depth = 0
    /**
     * The protected state as decrypted during the current transaction (the outermost [serialized] block), so one transaction asks
     * Keystore once instead of once per status check: on some phones each decryption takes hundreds of milliseconds. Nothing else can
     * change the state while the lock is held, every write here replaces it, and it is zeroed when the transaction ends, so the next
     * transaction decrypts through Keystore again (which still checks that the device is unlocked and refuses rolled-back files).
     */
    var cachedState: ByteArray? = null
        set(value) { field?.fill(0); field = value }
    fun <T> serialized(action: () -> T): T = synchronized(monitor) {
        depth++
        try { action() } finally { if (--depth == 0) cachedState = null }
    }
}
