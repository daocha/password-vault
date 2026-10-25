package app.passvault

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.LifecycleOwner
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import kotlinx.coroutines.delay

/** A QR code one pixel per module (with a 4-module quiet zone); drawn scaled up without smoothing. */
private fun qrBitmap(text: String): ImageBitmap {
    // ZXing picks the mask pattern that is easiest to read; forcing each of the 8 in turn made a camera read under a quarter of the frames.
    val matrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, 0, 0, mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.L, EncodeHintType.MARGIN to 4))
    val pixels = IntArray(matrix.width * matrix.height) { if (matrix.get(it % matrix.width, it / matrix.width)) 0xFF000000.toInt() else 0xFFFFFFFF.toInt() }
    return android.graphics.Bitmap.createBitmap(pixels, matrix.width, matrix.height, android.graphics.Bitmap.Config.ARGB_8888).asImageBitmap()
}

/** Keeps the screen on while it is shown. */
@Composable private fun KeepScreenOn() {
    val view = LocalView.current
    DisposableEffect(view) { view.keepScreenOn = true; onDispose { view.keepScreenOn = false } }
}

/**
 * The old phone: an animated QR code of the encrypted transfer, every chunk once and then fresh mixes of them (see [TransferFrames]).
 * The one-time code is shown only on request, and the QR code is hidden while it is, so one photo never holds both.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TransferSendScreen(frames: TransferFrames.Sender?, code: String, onSaveFile: () -> Unit, onDone: () -> Unit) {
    KeepScreenOn()
    var index by remember { mutableIntStateOf(0) }
    var showCode by remember { mutableStateOf(false) }
    LaunchedEffect(frames, showCode) { if (frames != null && !showCode) while (true) { delay(250); index++ } }
    Scaffold(containerColor = MaterialTheme.colorScheme.background,
        topBar = { TopAppBar(title = { Text(stringResource(R.string.transfer_send)) }, navigationIcon = { IconButton(onClick = onDone) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.main_back)) } },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background)) }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().padding(horizontal = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Text(stringResource(R.string.transfer_instructions), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
            Spacer(Modifier.height(16.dp))
            if (showCode) {
                Card(Modifier.fillMaxWidth(), shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)) {
                    Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(stringResource(R.string.transfer_code_label), style = MaterialTheme.typography.labelLarge)
                        Text(Transfer.display(code), Modifier.padding(vertical = 12.dp), fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold, fontSize = 30.sp)
                        Text(stringResource(R.string.transfer_code_body), style = MaterialTheme.typography.bodySmall, textAlign = TextAlign.Center)
                    }
                }
            } else if (frames != null) {
                val bitmap = remember(frames, index) { qrBitmap(frames.frame(index)) }
                Box(Modifier.fillMaxWidth().aspectRatio(1f).background(Color.White, RoundedCornerShape(12.dp)), contentAlignment = Alignment.Center) {
                    Image(bitmap, null, Modifier.fillMaxSize(), filterQuality = FilterQuality.None)
                }
                Text(stringResource(R.string.transfer_frame, index % frames.count + 1, frames.count), Modifier.padding(top = 8.dp), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else Text(stringResource(R.string.transfer_too_large), textAlign = TextAlign.Center)
            Spacer(Modifier.height(16.dp))
            Button(onClick = { showCode = !showCode }, Modifier.fillMaxWidth().height(52.dp)) {
                Icon(if (showCode) Icons.Outlined.QrCode2 else Icons.Outlined.Password, null); Text("  " + stringResource(if (showCode) R.string.transfer_hide_code else R.string.transfer_show_code))
            }
            OutlinedButton(onClick = onSaveFile, Modifier.fillMaxWidth().padding(top = 8.dp).height(52.dp)) { Icon(Icons.Outlined.SaveAlt, null); Text("  " + stringResource(R.string.transfer_save_file)) }
            Text(stringResource(R.string.transfer_keep_hint), Modifier.padding(top = 8.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
            TextButton(onClick = onDone, Modifier.padding(top = 8.dp)) { Text(stringResource(R.string.main_done)) }
        }
    }
}

/** The new phone: scans the old phone's looping QR code, frames in any order, until the whole encrypted transfer has arrived. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TransferReceiveScreen(owner: LifecycleOwner, onComplete: (ByteArray) -> Unit, onCancel: () -> Unit) {
    KeepScreenOn()
    val collector = remember { TransferFrames.Collector() }
    var received by remember { mutableIntStateOf(0) }; var total by remember { mutableIntStateOf(0) }; var finished by remember { mutableStateOf(false) }
    Scaffold(containerColor = MaterialTheme.colorScheme.background,
        topBar = { TopAppBar(title = { Text(stringResource(R.string.transfer_receive)) }, navigationIcon = { IconButton(onClick = onCancel) { Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.main_back)) } },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background)) }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().padding(horizontal = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Text(stringResource(R.string.transfer_receive_body), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
            Spacer(Modifier.height(16.dp))
            QrScanner(owner, onCode = { text ->
                if (finished || !collector.add(text)) return@QrScanner
                received = collector.received; total = collector.total
                collector.result()?.let { finished = true; onComplete(it) }
            }, Modifier.fillMaxWidth().aspectRatio(1f).background(Color.Black, RoundedCornerShape(12.dp)), continuous = true)
            Spacer(Modifier.height(16.dp))
            if (total == 0) Text(stringResource(R.string.transfer_waiting))
            else {
                LinearProgressIndicator(progress = { received / total.toFloat() }, Modifier.fillMaxWidth())
                Text(stringResource(R.string.transfer_received, received, total), Modifier.padding(top = 8.dp))
            }
            TextButton(onClick = onCancel, Modifier.padding(top = 16.dp)) { Text(stringResource(R.string.main_cancel)) }
        }
    }
}
