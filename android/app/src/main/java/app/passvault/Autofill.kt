package app.passvault

import android.app.assist.AssistStructure
import android.text.InputType
import android.view.View
import android.view.autofill.AutofillId

/** What another app's login form is: which of its fields take a username and a password, and who is asking. */
class AutofillForm(val username: AutofillId?, val password: AutofillId?, val target: AutofillTarget) {
    val ids get() = listOfNotNull(username, password)
    companion object {
        private val INPUT_CLASSES = setOf(InputType.TYPE_CLASS_TEXT, InputType.TYPE_CLASS_PHONE, InputType.TYPE_CLASS_NUMBER)
        /** The login fields in [structure], or null when it has none. [verifyBrowser] checks a package's signature ([AutofillBrowsers.verify]). */
        fun parse(structure: AssistStructure, verifyBrowser: (String) -> Boolean = { false }): AutofillForm? {
            val packageName = structure.activityComponent?.packageName ?: return null
            class Candidate(val id: AutofillId, val field: AutofillField, val domain: String?)
            val text = mutableListOf<Candidate>(); var visited = 0; var overLimit = false
            fun visit(node: AssistStructure.ViewNode, parentDomain: String?, depth: Int) {
                if (++visited > 10_000 || depth > 64) { overLimit = true; return }
                val domain = node.webDomain?.takeIf { it.isNotBlank() } ?: parentDomain
                val id = node.autofillId
                if (id != null && node.autofillType == View.AUTOFILL_TYPE_TEXT && node.importantForAutofill.let { it != View.IMPORTANT_FOR_AUTOFILL_NO && it != View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS }) {
                    val html = node.htmlInfo?.attributes.orEmpty().associate { it.first.lowercase() to it.second.orEmpty() }
                    val field = AutofillFields.classify(node.autofillHints?.toList().orEmpty(), node.inputType, html["type"].orEmpty(), html["autocomplete"].orEmpty(),
                        listOfNotNull(node.idEntry, node.hint, html["name"], html["id"], node.contentDescription?.toString()))
                    // A field that says nothing of itself is kept as a possible username: native views if they take text (a phone number or
                    // account number is a username too), and HTML inputs.
                    if (field != null && (field != AutofillField.other || (node.inputType and InputType.TYPE_MASK_CLASS) in INPUT_CLASSES || node.htmlInfo?.tag.equals("input", true))) text += Candidate(id, field, domain)
                }
                if (node.importantForAutofill != View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS && node.importantForAutofill != View.IMPORTANT_FOR_AUTOFILL_YES_EXCLUDE_DESCENDANTS)
                    for (i in 0 until node.childCount) { if (overLimit) return; visit(node.getChildAt(i), domain, depth + 1) }
            }
            for (i in 0 until structure.windowNodeCount) { if (overLimit) return null; visit(structure.getWindowNodeAt(i).rootViewNode, null, 0) }
            if (overLimit) return null
            val chosen = AutofillFields.pick(text.map { it.field }) ?: return null
            // The selected fields, rather than an unrelated first node, determine the claimed origin. Never fill across frames/origins.
            val origin = AutofillOrigin.resolve(listOfNotNull(chosen.first, chosen.second).map { text[it].domain }) ?: return null
            return AutofillForm(chosen.first?.let { text[it].id }, chosen.second?.let { text[it].id }, AutofillTarget(packageName, origin.host, origin.host != null && verifyBrowser(packageName)))
        }
    }
}

enum class AutofillField { username, password, other }

/** Recognises login fields from what a view says about itself. Kept free of Android views so it can be unit tested. */
object AutofillFields {
    private val passwordWords = listOf("password", "passwd", "pwd", "passcode", "密码", "密碼")
    private val usernameWords = listOf("username", "user", "login", "email", "e-mail", "account", "phone", "mobile", "用户", "用戶", "帐号", "帳號", "账号", "邮箱", "郵箱", "手机", "手機")
    // A one-time code, search box or card field is never a login field, whatever else it says.
    private val excludedWords = listOf("otp", "one-time", "2fa", "totp", "verification", "captcha", "search", "card", "cvv", "cvc", "confirm", "repeat", "retype", "newpassword", "new-password", "new_password", "验证码", "驗證碼")
    private val passwordVariations = setOf(InputType.TYPE_TEXT_VARIATION_PASSWORD, InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD, InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD)
    private val emailVariations = setOf(InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS, InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS)

    /**
     * [words]: the view's resource id, hint, HTML name and id, and description. Autofill hints win over HTML attributes, which win over guesses.
     * Null for a field that must never be filled (a one-time code, a new password); [AutofillField.other] when nothing says what it is.
     */
    fun classify(hints: List<String>, inputType: Int, htmlType: String, autocomplete: String, words: List<String>): AutofillField? {
        val h = hints.map { it.lowercase() }
        if (h.any { it == "newpassword" || it == "new-password" || "otp" in it || "creditcard" in it }) return null
        if (h.any { it == View.AUTOFILL_HINT_PASSWORD.lowercase() || it == "current-password" }) return AutofillField.password
        if (h.any { it == View.AUTOFILL_HINT_USERNAME.lowercase() || it == View.AUTOFILL_HINT_EMAIL_ADDRESS.lowercase() || it == "email" || it == View.AUTOFILL_HINT_PHONE.lowercase() }) return AutofillField.username
        val ac = autocomplete.lowercase()
        if ("new-password" in ac || "one-time-code" in ac || ac.startsWith("cc-")) return null
        if ("current-password" in ac) return AutofillField.password
        if ("username" in ac || ac == "email" || ac == "tel") return AutofillField.username
        val text = words.joinToString(" ").lowercase()
        if (excludedWords.any { it in text }) return null
        val variation = inputType and InputType.TYPE_MASK_VARIATION
        val inputClass = inputType and InputType.TYPE_MASK_CLASS; val isText = inputClass == InputType.TYPE_CLASS_TEXT
        val numberPassword = inputClass == InputType.TYPE_CLASS_NUMBER && variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
        if (htmlType.equals("password", true) || (isText && variation in passwordVariations) || numberPassword) return AutofillField.password
        if (htmlType.equals("email", true) || htmlType.equals("tel", true) || (isText && variation in emailVariations) || inputClass == InputType.TYPE_CLASS_PHONE) return AutofillField.username
        if (passwordWords.any { it in text }) return AutofillField.password
        if (usernameWords.any { it in text }) return AutofillField.username
        return AutofillField.other
    }

    /**
     * Indexes into [fields] (in screen order) of the username and password to fill, or null when there is no login form. Without a marked
     * username, the text field just before the password is taken for it. A form with two password fields is a sign-up or change form and is
     * left alone; a username on its own (the first step of a two-step sign-in) is enough.
     */
    fun pick(fields: List<AutofillField>): Pair<Int?, Int?>? {
        val passwords = fields.indices.filter { fields[it] == AutofillField.password }
        if (passwords.size > 1) return null
        val password = passwords.firstOrNull()
        val username = fields.indices.lastOrNull { fields[it] == AutofillField.username && (password == null || it < password) }
            ?: fields.indices.firstOrNull { fields[it] == AutofillField.username }
            ?: password?.let { p -> (p - 1 downTo 0).firstOrNull { fields[it] == AutofillField.other } }
        return if (password == null && username == null) null else username to password
    }
}

/** Who wants to be filled: an app, and for browsers the site shown. */
data class AutofillTarget(val packageName: String, val webDomain: String?, val verifiedBrowser: Boolean = false) {
    val reportedSite: String? get() = webDomain?.let(AutofillDomains::host)
    /**
     * The address shown by a browser whose signing certificate was checked ([AutofillBrowsers.verify]); null for any other app, whose
     * claimed address is neither shown nor used. It ranks suggestions; every selection still needs the destination confirmation.
     */
    val site: String? get() = reportedSite?.takeIf { verifiedBrowser && packageName in BROWSERS }
    /** Display the package as well as its unverified label, without allowing a label to hide it with control characters. */
    fun description(label: String): String {
        val name = label.map { if (it.isWhitespace()) ' ' else it }.filterNot { it.isISOControl() || Character.getType(it) == Character.FORMAT.toInt() }
            .joinToString("").replace(Regex(" +"), " ").trim().take(80)
        // Isolate these app-controlled identifiers from surrounding right-to-left text in the label or the UI language.
        fun identifier(value: String) = "\u2066$value\u2069"
        return listOfNotNull(site?.let(::identifier), "$name (${identifier(packageName)})").joinToString(" · ")
    }
    companion object {
        /** Browsers whose address is believed once [AutofillBrowsers] has checked the signature; those missing from its list never are. */
        val BROWSERS = setOf(
            "com.android.chrome", "com.chrome.beta", "com.chrome.dev", "com.chrome.canary", "org.chromium.chrome", "com.google.android.apps.chrome",
            "org.mozilla.firefox", "org.mozilla.firefox_beta", "org.mozilla.fenix", "org.mozilla.fennec_fdroid", "org.mozilla.focus", "org.mozilla.klar", "org.torproject.torbrowser",
            "com.brave.browser", "com.brave.browser_beta", "com.microsoft.emmx", "com.opera.browser", "com.opera.browser.beta", "com.opera.mini.native", "com.opera.gx",
            "com.sec.android.app.sbrowser", "com.sec.android.app.sbrowser.beta", "com.duckduckgo.mobile.android", "com.vivaldi.browser", "com.kiwibrowser.browser",
            "app.vanadium.browser", "org.bromite.bromite", "org.cromite.cromite", "com.ecosia.android", "us.spotco.fennec_dos", "io.github.forkmaintainers.iceraven",
            "com.mi.globalbrowser", "com.huawei.browser", "com.heytap.browser", "com.UCMobile.intl", "com.yandex.browser", "mark.via.gp", "com.mmbox.xbrowser",
        )
    }
}

/** Suggestion ranking only; names, package fragments and claimed domains never authorize releasing a credential. */
object AutofillMatch {
    // Package name parts that say nothing about whose app it is.
    private val genericParts = setOf("com", "org", "net", "io", "co", "app", "apps", "android", "mobile", "client", "www", "main", "prod", "release", "lite", "global", "intl")

    fun candidates(records: List<VaultRecord>) = records.filter { r -> r.type == RecordType.login && r.fields.any { (it.kind == FieldKind.password || it.kind == FieldKind.username) && it.value.isNotEmpty() } }

    /** Includes private hosting suffixes and treats IP addresses as complete literals. */
    fun baseDomain(host: String): String? = AutofillDomains.host(host)?.let(AutofillDomains::registrable)

    /** "Dive+" and "dive +" alike: lowercase letters and digits only. */
    private fun plain(value: String) = value.lowercase().filter { it.isLetterOrDigit() }

    /** [appLabel]: the requesting app's name as the launcher shows it; a record whose name or "Website/App name" is that name matches. */
    fun suggests(record: VaultRecord, target: AutofillTarget, appLabel: String? = null): Boolean {
        val website = record.website.trim()
        if (website.startsWith("androidapp://", ignoreCase = true)) return website.substringAfter("://").trimEnd('/').equals(target.packageName, ignoreCase = true)
        val host = AutofillDomains.host(website)
        target.site?.let { site -> return AutofillDomains.sameSite(website, site) }
        // An app: its name, or its package name ("com.netflix.mediaclient"), names the service the record is for.
        val label = appLabel?.let(::plain)?.takeIf { it.length >= 3 }
        if (label != null && (plain(record.name) == label || (host == null && plain(website) == label))) return true
        val parts = target.packageName.lowercase().split('.', '_').filter { it.length >= 3 && it !in genericParts }.toSet()
        val domainLabel = host?.let { baseDomain(it)?.substringBefore('.') }
        if (domainLabel != null && domainLabel.length >= 3 && domainLabel in parts) return true
        val name = record.name.lowercase().filter { it.isLetterOrDigit() }
        if (name.length >= 4 && name in parts) return true
        return findBrand(website, record.name)?.let { brand -> brand.names.any { it.length >= 3 && it in parts } || brand.domains.any { baseDomain(it)?.substringBefore('.') in parts } } == true
    }

    fun username(record: VaultRecord) = record.fields.firstOrNull { it.kind == FieldKind.username && it.value.isNotEmpty() }?.value
    fun password(record: VaultRecord) = record.fields.firstOrNull { it.kind == FieldKind.password && it.value.isNotEmpty() }?.value
}
