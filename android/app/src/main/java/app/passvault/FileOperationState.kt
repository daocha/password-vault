package app.passvault

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.first

/** One file output operation per process, including cleanup and across activity recreation. */
internal class FileJobs {
    class Ticket {
        @Volatile var cancelled = false
            private set
        fun cancel() { cancelled = true }
    }

    private var active: Ticket? = null
    private val state = MutableStateFlow(false)
    val running = state.asStateFlow()

    @Synchronized fun start(): Ticket? {
        if (active != null) return null
        return Ticket().also { active = it; state.value = true }
    }

    /** Cancellation hides the UI but does not release ownership: the worker still owns its output until cleanup ends. */
    @Synchronized fun finish(ticket: Ticket) {
        if (active === ticket) { active = null; state.value = false }
    }

    /** Backups, transfers, original deletion and unwritten-target cleanup share ownership with streaming jobs. */
    suspend fun <T> withOutput(action: suspend () -> T): T {
        while (true) {
            currentCoroutineContext().ensureActive()
            val ticket = start()
            if (ticket != null) {
                try { return action() } finally { finish(ticket) }
            }
            running.first { !it }
        }
    }

    companion object { val shared = FileJobs() }
}

/** Backup history's instance changes whenever a vault is removed; a new decoy or reset real vault is a different source. */
internal data class FileVault(val decoy: Boolean, val instance: Long)

/** Cleanup warnings survive locks and activity recreation, and remain until explicitly acknowledged in their source vault. */
internal class FileNotices {
    class Notice(val source: FileVault, val text: String, val recoveryId: String? = null)
    private val state = MutableStateFlow<List<Notice>>(emptyList())
    val pending = state.asStateFlow()
    private val oldestInstance = mutableMapOf<Boolean, Long>()

    @Synchronized fun add(source: FileVault, text: String, recoveryId: String? = null) {
        if (source.instance < (oldestInstance[source.decoy] ?: 0L)) return
        if (recoveryId != null && state.value.any { it.recoveryId == recoveryId }) return
        state.value += Notice(source, text, recoveryId)
    }

    @Synchronized fun retainRecovery(ids: Set<String>) { state.value = state.value.filter { it.recoveryId == null || it.recoveryId in ids } }

    @Synchronized fun acknowledge(notice: Notice) { state.value = state.value.filterNot { it === notice } }

    /** Also rejects warnings arriving later from a worker that outlived the removed vault. */
    @Synchronized fun forgetBefore(source: FileVault) {
        val oldest = maxOf(source.instance, oldestInstance[source.decoy] ?: 0L)
        oldestInstance[source.decoy] = oldest
        state.value = state.value.filterNot { it.source.decoy == source.decoy && it.source.instance < oldest }
    }

    companion object { val shared = FileNotices() }
}
