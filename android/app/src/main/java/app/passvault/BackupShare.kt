package app.passvault

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import androidx.core.content.FileProvider
import java.io.File

/**
 * Sending an encrypted backup straight to a nearby device. Only phone-to-phone sharing apps are offered (Quick Share and the phone
 * makers' own), never mail, chat or cloud apps: the file is protected only by the app password, so it should go to a device the user
 * owns or trusts, not to a server. When none is installed, the export saves to a file as before.
 */
object NearbyShare {
    /** Google Play services, whose Quick Share (formerly Nearby Share) activities live under [GOOGLE_ACTIVITY_PREFIX]. */
    const val GOOGLE = "com.google.android.gms"
    const val GOOGLE_ACTIVITY_PREFIX = "com.google.android.gms.nearby."
    /** Phone makers' nearby-sharing apps. Each is preinstalled; the manifest's <queries> lets the app see their share activities. */
    val OEM_PACKAGES = setOf(
        "com.samsung.android.app.sharelive", // Samsung Quick Share
        "com.huawei.android.instantshare", // Huawei Share
        "com.hihonor.android.instantshare", // Honor Share
        "com.miui.mishare.connectivity", // Xiaomi Share
        "com.coloros.oshare", // OPPO Share (also OnePlus and realme)
        "com.oplus.oshare", // OPPO Share on newer ColorOS
        "com.vivo.share", // vivo Share
    )
    /** The MIME type a backup is sent as. */
    const val TYPE = "application/octet-stream"

    data class Target(val packageName: String, val activityName: String, val label: String)

    /**
     * Whether a share activity may receive a backup. [system]: the app came with the phone (or is an update of one that did), so a
     * sideloaded app cannot claim one of these package names on a phone that lacks it.
     */
    fun trusted(packageName: String, activityName: String, system: Boolean): Boolean =
        system && (packageName in OEM_PACKAGES || (packageName == GOOGLE && activityName.startsWith(GOOGLE_ACTIVITY_PREFIX)))

    /** The installed apps a backup may be sent with, by label; empty when there are none (the Send choice is then not shown). */
    fun targets(pm: PackageManager): List<Target> =
        pm.queryIntentActivities(Intent(Intent.ACTION_SEND).setType(TYPE), 0).mapNotNull { info ->
            val activity = info.activityInfo ?: return@mapNotNull null
            val app = activity.applicationInfo
            val system = app.flags and (ApplicationInfo.FLAG_SYSTEM or ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0
            if (!activity.exported || !activity.enabled || !trusted(activity.packageName, activity.name, system)) return@mapNotNull null
            Target(activity.packageName, activity.name, info.loadLabel(pm).toString())
        }.distinctBy { it.packageName to it.activityName }.sortedBy { it.label }

    /** Sends [uri] to exactly [target]; the receiving app is allowed to read only this one file. */
    fun intent(uri: Uri, name: String, target: Target): Intent = Intent(Intent.ACTION_SEND).setType(TYPE)
        .putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION).setClassName(target.packageName, target.activityName)
        .apply { clipData = ClipData.newRawUri(name, uri) }
}

/**
 * The copy of an encrypted backup handed to a sharing app, in the app's own cache. The sharing app may read it after PassVault has
 * left the foreground, so it stays until the user says whether it arrived, the next export, the next start, or the vault's erasure.
 */
object BackupShareFiles {
    const val FOLDER = "backup-share"
    fun folder(cache: File) = File(cache, FOLDER)
    /** Removes earlier copies and writes [bytes] as [name]. */
    fun write(cache: File, name: String, bytes: ByteArray): File {
        sweep(cache)
        val dir = folder(cache).apply { mkdirs() }
        val file = File(dir, File(name).name)
        file.writeBytes(bytes)
        return file
    }
    /** Deletes every copy; true when none is left. */
    fun sweep(cache: File): Boolean { folder(cache).listFiles()?.forEach { it.delete() }; return folder(cache).listFiles().isNullOrEmpty() }
    fun uri(context: Context, file: File): Uri = FileProvider.getUriForFile(context, context.packageName + ".backupshare", file)
}

/** Serves only [BackupShareFiles.FOLDER] (see res/xml/backup_share_paths.xml), apart from the update installer's provider. */
class BackupShareProvider : FileProvider()
