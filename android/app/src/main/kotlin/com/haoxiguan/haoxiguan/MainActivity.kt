package com.haoxiguan.haoxiguan

import android.app.Activity
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private var source: File? = null
    private var expectedDigest: String? = null
    private val saveRequest = 50210
    private val openRequest = 50211
    private val maxBytes = 50L * 1024 * 1024
    private class TooLarge : Exception()

    private fun finish(action: (MethodChannel.Result) -> Unit) {
        val result = pending ?: return
        pending = null
        source = null
        expectedDigest = null
        action(result)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.haoxiguan.haoxiguan/documents")
            .setMethodCallHandler { call, result ->
                if (call.method != "save" && call.method != "open") {
                    result.notImplemented(); return@setMethodCallHandler
                }
                if (pending != null) {
                    result.error("busy", "另一个文件操作尚未结束", null); return@setMethodCallHandler
                }
                try {
                    val intent: Intent
                    val request: Int
                    if (call.method == "save") {
                        val path = call.argument<String>("sourcePath")
                        val name = call.argument<String>("name")
                        val digest = call.argument<String>("sha256")
                        require(path != null && name != null && digest != null && digest.matches(Regex("[0-9a-f]{64}")))
                        val file = File(path)
                        require(file.canonicalPath.startsWith(cacheDir.canonicalPath + File.separator) && file.isFile && file.length() <= maxBytes)
                        source = file
                        expectedDigest = digest
                        intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "application/octet-stream"
                            putExtra(Intent.EXTRA_TITLE, name)
                        }
                        request = saveRequest
                    } else {
                        // hgb/hgr have no registered MIME type. Validate the bounded
                        // contents in Dart instead of silently hiding valid backups.
                        intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                        }
                        request = openRequest
                    }
                    pending = result
                    startActivityForResult(intent, request)
                } catch (error: Exception) {
                    pending = null; source = null; expectedDigest = null
                    result.error("unavailable", "无法打开系统文件选择器，请重试", null)
                }
            }
    }

    @Deprecated("Android legacy result API, required by this FlutterActivity port")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != saveRequest && requestCode != openRequest) return
        if (pending == null) return
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            finish { it.success(if (requestCode == saveRequest) false else null) }
            return
        }
        val file = source
        val expected = expectedDigest
        // Keep pending until IO completes so a second picker cannot race this one.
        Thread {
            var imported: File? = null
            try {
                if (requestCode == openRequest) {
                    val temporary = File.createTempFile("import-", ".tmp", cacheDir)
                    imported = temporary
                    (contentResolver.openInputStream(uri) ?: error("No input stream")).use { input ->
                        FileOutputStream(temporary).use { output ->
                            val buffer = ByteArray(64 * 1024)
                            var total = 0L
                            while (true) {
                                val count = input.read(buffer)
                                if (count < 0) break
                                total += count
                                if (total > maxBytes) throw TooLarge()
                                output.write(buffer, 0, count)
                            }
                            output.fd.sync()
                        }
                    }
                    // Never trust provider SIZE metadata or allocate a provider-sized
                    // byte array. Unknown lengths and falsely reported sizes work too.
                    runOnUiThread { finish { it.success(temporary.path) } }
                } else {
                    check(file != null && expected != null)
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
                            if (total > maxBytes) throw TooLarge()
                            digest.update(buffer, 0, count)
                        }
                    }
                    val actual = digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
                    check(actual == expected)
                    runOnUiThread { finish { it.success(true) } }
                }
            } catch (error: Exception) {
                imported?.delete()
                runOnUiThread {
                    finish {
                        if (error is TooLarge) it.error("too_large", "文件超过 50 MiB", null)
                        else it.error("verification_failed", "文件未通过读取或写入校验，请重试。应用数据未修改。", null)
                    }
                }
            }
        }.start()
    }
}
