package app.passvault

/** The username and password fields to fill (indexes into a form's candidate fields) and, in a verified browser, the site they belong to. */
internal data class AutofillChoice(val username: Int?, val password: Int?, val host: String?) {
    companion object {
        /**
         * [fields] and [domains]: each candidate field's kind and reported web domain, in screen order. [browser]: the form is in a browser
         * whose signature was checked ([AutofillBrowsers.verify]). Null when there is nothing to fill.
         */
        fun choose(fields: List<AutofillField>, domains: List<String?>, browser: Boolean): AutofillChoice? {
            val (username, password) = AutofillFields.pick(fields) ?: return null
            // In an app, the app itself is the destination: its WebViews are its own (it can read them anyway), and the domains it reports
            // are neither shown nor used. A native username field above a WebView password field is still one login.
            if (!browser) return AutofillChoice(username, password, null)
            // In a browser the selected password (or the username, without one) names the site, and only fields from that same site are
            // filled, never across frames. Fields with no web domain are the browser's own, filled only alongside each other. A domain that
            // cannot be named exactly (malformed, or one that Java's IDNA2003 would change) is not filled at all.
            val anchor = domains[password ?: username!!]
            val host = anchor?.let { AutofillDomains.host(it) ?: return null }
            val same = fields.indices.filter { i -> domains[i].let { if (it == null) host == null else host != null && AutofillDomains.host(it) == host } }
            val (u, p) = AutofillFields.pick(same.map { fields[it] }) ?: return null
            return AutofillChoice(u?.let { same[it] }, p?.let { same[it] }, host)
        }
    }
}
