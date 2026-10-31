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
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Offers PassVault on other apps' login forms. The service never opens the vault: every suggestion is a locked dataset whose
 * authentication is [AutofillActivity], which unlocks, lets the user pick an entry, fills it and locks again.
 */
class PassVaultAutofillService : AutofillService() {
    private val requests = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    override fun onFillRequest(request: FillRequest, cancellationSignal: CancellationSignal, callback: FillCallback) {
        val job = requests.launch {
            val response = try { response(request) } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
            if (!cancellationSignal.isCanceled) callback.onSuccess(response)
        }
        cancellationSignal.setOnCancelListener { job.cancel() }
    }
    private suspend fun response(request: FillRequest): FillResponse? {
        val structure = request.fillContexts.lastOrNull()?.structure ?: return null
        val form = withContext(Dispatchers.Default) { AutofillForm.parse(structure) { AutofillBrowsers.verify(this@PassVaultAutofillService, it) } }
        if (form == null || form.target.packageName == packageName || !withContext(Dispatchers.IO) { ProtectedStorage.mayHaveVault(this@PassVaultAutofillService) }) return null
        val unlock = presentation(this, getString(R.string.autofill_unlock), form.target.description(appLabel(this, form.target.packageName)))
        // Mutable: the system adds the form's structure to the intent when the user taps the suggestion.
        val sender = PendingIntent.getActivity(this, REQUEST, Intent(this, AutofillActivity::class.java),
            PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_MUTABLE).intentSender
        @Suppress("DEPRECATION")
        val dataset = Dataset.Builder().apply { form.ids.forEach { setValue(it, null, unlock) } }.setAuthentication(sender).build()
        return FillResponse.Builder().addDataset(dataset).build()
    }
    override fun onDestroy() { requests.cancel(); super.onDestroy() }

    // No save info is ever requested, so there is nothing to save; new logins are added in the app.
    override fun onSaveRequest(request: SaveRequest, callback: SaveCallback) = callback.onSuccess()

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
