package app.passvault

/** A common origin for the selected username/password fields. Null from [resolve] means conflicting or invalid origins. */
internal data class AutofillOrigin(val host: String?) {
    companion object {
        fun resolve(domains: List<String?>): AutofillOrigin? {
            if (domains.isEmpty()) return null
            val hosts = domains.map { domain -> domain?.let { AutofillDomains.host(it) ?: return null } }.distinct()
            return if (hosts.size == 1) AutofillOrigin(hosts.single()) else null
        }
    }
}
