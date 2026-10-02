package com.haoxiguan.haoxiguan

import android.app.Activity
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private var source: File? = null
    private var expectedDigest: String? = null
    private val saveRequest = 50210

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.haoxiguan.haoxiguan/documents")
            .setMethodCallHandler { call, result ->
                if (call.method != "save") { result.notImplemented(); return@setMethodCallHandler }
                if (pending != null) { result.error("busy", "另一个文件操作尚未结束", null); return@setMethodCallHandler }
                val path = call.argument<String>("sourcePath")
                val name = call.argument<String>("name")
                val digest = call.argument<String>("sha256")
                if (path == null || name == null || digest == null || !digest.matches(Regex("[0-9a-f]{64}"))) {
                    result.error("invalid", "文件参数无效", null); return@setMethodCallHandler
                }
                val file = File(path)
                if (!file.canonicalPath.startsWith(cacheDir.canonicalPath + File.separator) || !file.isFile || file.length() > 50L * 1024 * 1024) {
                    result.error("invalid", "导出文件无效", null); return@setMethodCallHandler
                }
                pending = result; source = file; expectedDigest = digest
                try {
                    startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "application/octet-stream"
                        putExtra(Intent.EXTRA_TITLE, name)
                    }, saveRequest)
                } catch (error: Exception) {
                    pending = null; source = null; expectedDigest = null
                    result.error("unavailable", "系统文件选择器不可用", null)
                }
            }
    }

    @Deprecated("Android legacy result API, required by this FlutterActivity port")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != saveRequest) return
        val result = pending ?: return
        val file = source
        val expected = expectedDigest
        pending = null; source = null; expectedDigest = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(false); return }
        if (file == null || expected == null) { result.error("interrupted", "导出已中断，请重试", null); return }
        Thread {
            try {
                val output = contentResolver.openOutputStream(uri, "wt") ?: error("No output stream")
                output.use { target -> file.inputStream().use { it.copyTo(target) }; target.flush() }
                val digest = MessageDigest.getInstance("SHA-256")
                (contentResolver.openInputStream(uri) ?: error("No verification stream")).use { input ->
                    val buffer = ByteArray(64 * 1024)
                    var total = 0L
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        if (total > 50L * 1024 * 1024) error("File too large")
                        digest.update(buffer, 0, count)
                    }
                }
                val actual = digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
                if (actual != expected) error("Digest mismatch")
                runOnUiThread { result.success(true) }
            } catch (error: Exception) {
                runOnUiThread { result.error("verification_failed", "文件未通过写入与读回校验，请重新导出。应用数据未修改。", null) }
            }
        }.start()
    }
}
