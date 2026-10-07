package app.passvault

import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import androidx.camera.core.CameraSelector
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

/** QR decoding runs entirely on the device (ZXing); nothing is sent anywhere and the app has no network permission. */
object QrDecoder {
    private fun reader() = MultiFormatReader().apply { setHints(mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE), DecodeHintType.TRY_HARDER to true)) }
    /** Tries the image as is, then inverted (light-on-dark codes, e.g. a site in dark mode). */
    fun decode(source: LuminanceSource, reader: MultiFormatReader = reader()): String? {
        for (candidate in listOf(source, source.invert())) {
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

/** Live camera preview that reports the first QR code it reads, once. The camera is released when this leaves the composition. */
@Composable
fun QrScanner(owner: LifecycleOwner, onCode: (String) -> Unit, modifier: Modifier = Modifier) {
    val executor = remember { Executors.newSingleThreadExecutor() }
    val done = remember { AtomicBoolean(false) }
    val bound = remember { arrayOfNulls<Pair<ProcessCameraProvider, Array<androidx.camera.core.UseCase>>>(1) }
    AndroidView(modifier = modifier, factory = { context ->
        PreviewView(context).also { view ->
            val future = ProcessCameraProvider.getInstance(context)
            future.addListener({
                if (done.get()) return@addListener // Left the screen before the camera was ready.
                val provider = future.get()
                val preview = Preview.Builder().build().also { it.surfaceProvider = view.surfaceProvider }
                val reader = MultiFormatReader().apply { setHints(mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE))) }
                val analysis = ImageAnalysis.Builder().setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
                analysis.setAnalyzer(executor) { image ->
                    try {
                        if (done.get()) return@setAnalyzer
                        val plane = image.planes[0]; val buffer = plane.buffer
                        val data = ByteArray(buffer.remaining()).also { buffer.get(it) }
                        val rows = minOf(image.height, (data.size + plane.rowStride - 1) / plane.rowStride)
                        val text = QrDecoder.decode(PlanarYUVLuminanceSource(data, plane.rowStride, rows, 0, 0, image.width, rows, false), reader)
                        data.fill(0)
                        if (text != null && done.compareAndSet(false, true)) ContextCompat.getMainExecutor(context).execute { onCode(text) }
                    } finally { image.close() }
                }
                runCatching {
                    provider.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
                    bound[0] = provider to arrayOf(preview, analysis)
                }
            }, ContextCompat.getMainExecutor(context))
        }
    })
    DisposableEffect(Unit) { onDispose { done.set(true); bound[0]?.let { (provider, cases) -> provider.unbind(*cases) }; executor.shutdown() } }
}
