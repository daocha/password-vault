package app.passvault

import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import android.util.Size
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.SurfaceOrientedMeteringPointFactory
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.LuminanceSource
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/** QR decoding runs entirely on the device (ZXing); nothing is sent anywhere and the app has no network permission. */
object QrDecoder {
    private fun reader() = MultiFormatReader().apply { setHints(mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE), DecodeHintType.TRY_HARDER to true)) }
    /** Tries the image as is, then with [invert] inverted (light-on-dark codes, e.g. a site in dark mode). */
    fun decode(source: LuminanceSource, reader: MultiFormatReader = reader(), invert: Boolean = true): String? {
        for (candidate in if (invert) listOf(source, source.invert()) else listOf(source)) {
            try { return reader.decodeWithState(BinaryBitmap(HybridBinarizer(candidate))).text } catch (_: Exception) { } finally { reader.reset() }
        }
        return null
    }
    /** Decodes a QR code from a picture, such as a screenshot of a site's 2FA setup page. */
    fun decode(context: Context, uri: Uri): String? {
        val bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, uri)) { decoder, info, _ ->
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            val longest = maxOf(info.size.width, info.size.height)
            if (longest > 2048) decoder.setTargetSize(info.size.width * 2048 / longest, info.size.height * 2048 / longest)
        }.copy(Bitmap.Config.ARGB_8888, false)
        val pixels = IntArray(bitmap.width * bitmap.height); bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        return decode(RGBLuminanceSource(bitmap.width, bitmap.height, pixels)).also { bitmap.recycle() }
    }
}

/**
 * Live camera preview that reports the first QR code it reads, once, or with [continuous] every code it reads (a transfer's stream of
 * frames, always dark on light, so a failed picture is not tried again inverted). [analyzed] counts the camera pictures decoded.
 * The camera is released when this leaves the composition.
 *
 * A transfer's code changes four times a second, which keeps a camera's continuous focus and exposure hunting: it read every frame for a
 * moment, then none for long stretches. So in [continuous] mode focus and exposure are locked on the centre, again whenever nothing has been
 * read for [REFOCUS_MILLIS], and the camera works at 1280×720, decoding only the centre square the preview shows.
 *
 * Every scan starts at [SCAN_ZOOM]: to fit the code in the preview, the phone is then held twice as far away, where every main camera can
 * focus (a Galaxy S23 Ultra's cannot at the distance that fills the preview at 1×; Samsung's own camera app switches to the ultra-wide
 * there). A 2FA setup code on a computer screen is then read from a comfortable distance, too.
 */
private const val REFOCUS_MILLIS = 2000L
private const val SCAN_ZOOM = 2f
/** [SCAN_ZOOM], limited to what the camera supports ([maxZoomRatio] is null until the camera reports it); never below 1×. Matches iOS's QRScanZoom. */
internal fun scanZoom(maxZoomRatio: Float?) = SCAN_ZOOM.coerceAtMost(maxZoomRatio ?: SCAN_ZOOM).coerceAtLeast(1f)

@Composable
fun QrScanner(owner: LifecycleOwner, onCode: (String) -> Unit, modifier: Modifier = Modifier, continuous: Boolean = false, analyzed: AtomicInteger? = null) {
    val executor = remember { Executors.newSingleThreadExecutor() }
    val done = remember { AtomicBoolean(false) }
    val bound = remember { arrayOfNulls<Pair<ProcessCameraProvider, Array<androidx.camera.core.UseCase>>>(1) }
    val focus = remember { arrayOfNulls<() -> Unit>(1) }
    val lastRead = remember { AtomicLong(0) }; val lastFocus = remember { AtomicLong(0) }
    AndroidView(modifier = modifier, factory = { context ->
        PreviewView(context).also { view ->
            val future = ProcessCameraProvider.getInstance(context)
            future.addListener({
                if (done.get()) return@addListener // Left the screen before the camera was ready.
                val provider = future.get()
                val preview = Preview.Builder().build().also { it.surfaceProvider = view.surfaceProvider }
                val reader = MultiFormatReader().apply { setHints(mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE))) }
                val analysis = ImageAnalysis.Builder().setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).apply {
                    if (continuous) setResolutionSelector(ResolutionSelector.Builder().setResolutionStrategy(ResolutionStrategy(Size(1280, 720), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER)).build())
                }.build()
                analysis.setAnalyzer(executor) { image ->
                    try {
                        if (done.get()) return@setAnalyzer
                        val plane = image.planes[0]; val buffer = plane.buffer
                        val data = ByteArray(buffer.remaining()).also { buffer.get(it) }
                        val rows = minOf(image.height, (data.size + plane.rowStride - 1) / plane.rowStride)
                        val side = if (continuous) minOf(image.width, rows) else 0
                        val source = if (continuous) PlanarYUVLuminanceSource(data, plane.rowStride, rows, (image.width - side) / 2, (rows - side) / 2, side, side, false)
                            else PlanarYUVLuminanceSource(data, plane.rowStride, rows, 0, 0, image.width, rows, false)
                        val text = QrDecoder.decode(source, reader, invert = !continuous)
                        data.fill(0); analyzed?.incrementAndGet()
                        val now = System.currentTimeMillis()
                        if (text != null) lastRead.set(now)
                        else if (continuous && now - maxOf(lastRead.get(), lastFocus.get()) > REFOCUS_MILLIS) { lastFocus.set(now); ContextCompat.getMainExecutor(context).execute { focus[0]?.invoke() } }
                        if (text != null && (continuous || done.compareAndSet(false, true))) ContextCompat.getMainExecutor(context).execute { if (!continuous || !done.get()) onCode(text) }
                    } finally { image.close() }
                }
                runCatching {
                    val camera = provider.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
                    bound[0] = provider to arrayOf(preview, analysis)
                    if (continuous) {
                        val centre = SurfaceOrientedMeteringPointFactory(1f, 1f).createPoint(0.5f, 0.5f)
                        val action = FocusMeteringAction.Builder(centre, FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE).disableAutoCancel().build()
                        focus[0] = { if (!done.get()) runCatching { camera.cameraControl.startFocusAndMetering(action) } }
                        lastFocus.set(System.currentTimeMillis()); focus[0]?.invoke()
                    }
                    // The zoom range may not be known yet; a ratio out of range is then refused and the camera stays at 1x.
                    runCatching { camera.cameraControl.setZoomRatio(scanZoom(camera.cameraInfo.zoomState.value?.maxZoomRatio)) }
                }
            }, ContextCompat.getMainExecutor(context))
        }
    })
    DisposableEffect(Unit) { onDispose { done.set(true); bound[0]?.let { (provider, cases) -> provider.unbind(*cases) }; executor.shutdown() } }
}
