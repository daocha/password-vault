package app.passvault

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.CancellationSignal
import android.service.autofill.AutofillService
import android.service.autofill.Dataset
import android.service.autofill.FillCallback
import android.service.autofill.FillRequest
import android.service.autofill.FillResponse
import android.service.autofill.SaveCallback
import android.service.autofill.SaveRequest
import android.view.autofill.AutofillValue
import android.widget.RemoteViews

/**
 * Offers PassVault on other apps' login forms. The service never opens the vault: every suggestion is a locked dataset whose
 * authentication is [AutofillActivity], which unlocks, lets the user pick an entry, fills it and locks again.
 */
class PassVaultAutofillService : AutofillService() {
    override fun onFillRequest(request: FillRequest, cancellationSignal: CancellationSignal, callback: FillCallback) {
        val structure = request.fillContexts.lastOrNull()?.structure ?: return callback.onSuccess(null)
        val form = AutofillForm.parse(structure)
        if (form == null || form.target.packageName == packageName || !vaultExists()) return callback.onSuccess(null)
        val unlock = presentation(this, getString(R.string.autofill_unlock), form.target.site ?: appLabel(this, form.target.packageName))
        // Mutable: the system adds the form's structure to the intent when the user taps the suggestion.
        val sender = PendingIntent.getActivity(this, REQUEST, Intent(this, AutofillActivity::class.java),
            PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_MUTABLE).intentSender
        @Suppress("DEPRECATION")
        val dataset = Dataset.Builder().apply { form.ids.forEach { setValue(it, null, unlock) } }.setAuthentication(sender).build()
        callback.onSuccess(FillResponse.Builder().addDataset(dataset).build())
    }

    // No save info is ever requested, so there is nothing to save; new logins are added in the app.
    override fun onSaveRequest(request: SaveRequest, callback: SaveCallback) = callback.onSuccess()

    /** Whether there is a vault to unlock. Only checks that state exists; nothing is decrypted with a vault key. */
    private fun vaultExists() = runCatching { VaultEngine(ProtectedStorage(this)).exists() }.getOrDefault(false)

    companion object {
        private const val REQUEST = 1001
        /** One suggestion row in the keyboard's dropdown: a title and a smaller line under it. */
        fun presentation(context: Context, title: String, subtitle: String?) = RemoteViews(context.packageName, R.layout.autofill_item).apply {
            setTextViewText(R.id.autofill_title, title)
            setTextViewText(R.id.autofill_subtitle, subtitle.orEmpty())
            setViewVisibility(R.id.autofill_subtitle, if (subtitle.isNullOrEmpty()) android.view.View.GONE else android.view.View.VISIBLE)
        }
        fun appLabel(context: Context, packageName: String): String = runCatching {
            val pm = context.packageManager; pm.getApplicationLabel(pm.getApplicationInfo(packageName, 0)).toString()
        }.getOrDefault(packageName)
        /** The values that fill [form] from [record]; null when the record has nothing for its fields. */
        @Suppress("DEPRECATION")
        fun dataset(context: Context, form: AutofillForm, record: VaultRecord): Dataset? {
            val shown = presentation(context, record.name, AutofillMatch.username(record))
            val values = listOfNotNull(form.username?.let { id -> AutofillMatch.username(record)?.let { id to it } }, form.password?.let { id -> AutofillMatch.password(record)?.let { id to it } })
            if (values.isEmpty()) return null
            return Dataset.Builder().apply { values.forEach { (id, value) -> setValue(id, AutofillValue.forText(value), shown) } }.build()
        }
    }
}
