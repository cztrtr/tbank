package com.example.tbank

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * SAF（Storage Access Framework）桥接。
 *
 * 应用不再申请 MANAGE_EXTERNAL_STORAGE，而是让用户通过系统目录选择器
 * 授权某个文件夹，拿到持久的 tree URI 后用 ContentResolver 读写。
 *
 * 通道方法：
 * - pickDirectory       弹出目录选择器，返回 {uri, name}
 * - listChildren        列出目录下的文件（可按扩展名过滤）
 * - readText            按 URI 读 UTF-8 文本
 * - writeText           按 URI 覆盖写 UTF-8 文本
 * - writeChildText      在目录里按文件名新建/覆盖 UTF-8 文本（返回文档 URI）
 * - readChildBytes      在目录里按文件名找子文件并读成字节（配图用）
 * - releasePermission   释放某个 tree 的持久授权
 *
 * 另一个通道 `tbank/app_update` 负责应用内更新：
 * - installApk          按文件路径拉起系统安装器（需要 FileProvider）
 */
class MainActivity : FlutterActivity() {
    private val channelName = "tbank/saf"
    private val updateChannelName = "tbank/app_update"
    private val requestPickDirectory = 0x5AF1

    private var pendingPickResult: MethodChannel.Result? = null

    private val io: ExecutorService = Executors.newSingleThreadExecutor()
    private val main: Handler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "pickDirectory" -> pickDirectory(result)
                        "listChildren" -> {
                            val uri = call.argument<String>("uri")
                            if (uri == null) result.error("bad_args", "缺少 uri", null)
                            else listChildren(uri, call.argument<String>("ext"), result)
                        }
                        "readText" -> {
                            val uri = call.argument<String>("uri")
                            if (uri == null) result.error("bad_args", "缺少 uri", null)
                            else runIo(result) { readText(uri) }
                        }
                        "writeText" -> {
                            val uri = call.argument<String>("uri")
                            val text = call.argument<String>("text")
                            if (uri == null || text == null) {
                                result.error("bad_args", "缺少 uri 或 text", null)
                            } else {
                                runIo(result) { writeText(uri, text); true }
                            }
                        }
                        "writeChildText" -> {
                            val dir = call.argument<String>("uri")
                            val name = call.argument<String>("name")
                            val text = call.argument<String>("text")
                            if (dir == null || name == null || text == null) {
                                result.error("bad_args", "缺少 uri、name 或 text", null)
                            } else {
                                runIo(result) { writeChildText(dir, name, text) }
                            }
                        }
                        "readChildBytes" -> {
                            val dir = call.argument<String>("uri")
                            val name = call.argument<String>("name")
                            if (dir == null || name == null) {
                                result.error("bad_args", "缺少 uri 或 name", null)
                            } else {
                                runIo(result) { readChildBytes(dir, name) }
                            }
                        }
                        "releasePermission" -> {
                            val uri = call.argument<String>("uri")
                            if (uri == null) result.error("bad_args", "缺少 uri", null)
                            else runIo(result) { releasePermission(uri); true }
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("saf_error", e.message ?: e.toString(), null)
                }
            }

        // ---- 应用内更新：下载完成后拉起系统安装器 ----
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, updateChannelName)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "installApk" -> {
                            val path = call.argument<String>("path")
                            if (path == null) {
                                result.error("bad_args", "缺少 path", null)
                            } else {
                                result.success(installApk(path))
                            }
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("update_error", e.message ?: e.toString(), null)
                }
            }
    }

    // ---------------------------------------------------------------- 目录选择

    private fun pickDirectory(result: MethodChannel.Result) {
        if (pendingPickResult != null) {
            result.error("busy", "已有目录选择正在进行", null)
            return
        }
        pendingPickResult = result

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        }

        try {
            startActivityForResult(intent, requestPickDirectory)
        } catch (e: Exception) {
            pendingPickResult = null
            result.error("no_picker", "无法打开目录选择器：${e.message}", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == requestPickDirectory) {
            val result = pendingPickResult
            pendingPickResult = null

            if (result == null) return

            val treeUri: Uri? = data?.data
            if (resultCode != Activity.RESULT_OK || treeUri == null) {
                // 用户取消：返回 null，Dart 侧当作"没选"
                result.success(null)
                return
            }

            try {
                contentResolver.takePersistableUriPermission(
                    treeUri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
            } catch (e: SecurityException) {
                // 某些 ROM 不允许持久化，但不影响本次会话
            }

            result.success(
                mapOf(
                    "uri" to treeUri.toString(),
                    "name" to displayNameOfTree(treeUri)
                )
            )
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    // ---------------------------------------------------------------- 读写实现

    private fun listChildren(dirUri: String, ext: String?, result: MethodChannel.Result) {
        runIo(result) {
            val tree = Uri.parse(dirUri)
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                tree,
                DocumentsContract.getTreeDocumentId(tree)
            )

            val projection = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED
            )

            val out = ArrayList<Map<String, Any?>>()

            contentResolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    val docId = cursor.getString(0)
                    val name = cursor.getString(1) ?: continue
                    val mime = cursor.getString(2)

                    // 跳过子目录
                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) continue
                    if (ext != null && !name.lowercase().endsWith(ext.lowercase())) continue

                    out.add(
                        mapOf(
                            "name" to name,
                            "uri" to DocumentsContract
                                .buildDocumentUriUsingTree(tree, docId).toString(),
                            "size" to if (cursor.isNull(3)) null else cursor.getLong(3),
                            "lastModified" to if (cursor.isNull(4)) null else cursor.getLong(4)
                        )
                    )
                }
            }
            out
        }
    }

    private fun readText(uriString: String): String {
        val uri = Uri.parse(uriString)
        val text = contentResolver.openInputStream(uri)?.use { input ->
            input.bufferedReader(Charsets.UTF_8).readText()
        } ?: throw IllegalStateException("无法打开文件：$uriString")

        // 去掉 UTF-8 BOM，否则 jsonDecode 会失败
        return if (text.startsWith('\uFEFF')) text.substring(1) else text
    }

    private fun writeText(uriString: String, text: String) {
        val uri = Uri.parse(uriString)
        // "wt" = write + truncate，避免覆盖后残留旧内容
        contentResolver.openOutputStream(uri, "wt")?.use { output ->
            output.write(text.toByteArray(Charsets.UTF_8))
            output.flush()
        } ?: throw IllegalStateException("无法写入文件：$uriString")
    }

    /**
     * 在 [dirUriString] 指向的目录里新建或覆盖 [fileName]，写入 UTF-8 文本。
     *
     * 先查同名字档：存在就覆盖内容；不存在就用 createDocument 新建
     * （MIME 用 application/json，文件提供方会据此补 .json 扩展名）。
     * 返回最终文档 URI，方便调用方后续直接读写。
     */
    private fun writeChildText(dirUriString: String, fileName: String, text: String): String {
        val tree = Uri.parse(dirUriString)
        val parentDocId = DocumentsContract.getTreeDocumentId(tree)
        val parentDocUri = DocumentsContract.buildDocumentUriUsingTree(tree, parentDocId)
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentDocId)

        var existingId: String? = null
        contentResolver.query(
            childrenUri,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME
            ),
            null,
            null,
            null
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val name = cursor.getString(1) ?: continue
                if (name == fileName) {
                    existingId = cursor.getString(0)
                    break
                }
            }
        }

        val docUri = if (existingId != null) {
            DocumentsContract.buildDocumentUriUsingTree(tree, existingId!!)
        } else {
            DocumentsContract.createDocument(
                contentResolver,
                parentDocUri,
                "application/json",
                fileName
            ) ?: throw IllegalStateException("无法创建文件：$fileName")
        }

        // "wt" = write + truncate，避免覆盖后残留旧内容
        contentResolver.openOutputStream(docUri, "wt")?.use { output ->
            output.write(text.toByteArray(Charsets.UTF_8))
            output.flush()
        } ?: throw IllegalStateException("无法写入文件：$fileName")

        return docUri.toString()
    }

    private fun readChildBytes(dirUriString: String, fileName: String): ByteArray? {
        val tree = Uri.parse(dirUriString)
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            tree,
            DocumentsContract.getTreeDocumentId(tree)
        )

        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME
        )

        var exactId: String? = null
        var looseId: String? = null

        contentResolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val docId = cursor.getString(0)
                val name = cursor.getString(1) ?: continue
                if (name == fileName) {
                    exactId = docId
                    break
                }
                if (looseId == null && name.equals(fileName, ignoreCase = true)) {
                    looseId = docId
                }
            }
        }

        val docId = exactId ?: looseId ?: return null
        val docUri = DocumentsContract.buildDocumentUriUsingTree(tree, docId)
        return contentResolver.openInputStream(docUri)?.use { it.readBytes() }
    }

    private fun releasePermission(uriString: String) {
        try {
            contentResolver.releasePersistableUriPermission(
                Uri.parse(uriString),
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
        } catch (_: SecurityException) {
            // 没授权过就不用管
        }
    }

    // ---------------------------------------------------------------- 应用更新

    /**
     * 拉起系统安装器安装 [path] 指向的 APK。
     *
     * Android 8+ 需要「安装未知应用」权限；没有时跳到授权页并返回 "permission"。
     * 返回 "ok" 表示安装界面已经打开。
     */
    private fun installApk(path: String): String {
        val file = File(path)
        if (!file.exists()) {
            throw IllegalStateException("安装包不存在：$path")
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            val settingsIntent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                .setData(Uri.parse("package:$packageName"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(settingsIntent)
            return "permission"
        }

        val apkUri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            file
        )
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(apkUri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
        return "ok"
    }

    private fun displayNameOfTree(uri: Uri): String {
        return try {
            val docUri = DocumentsContract.buildDocumentUriUsingTree(
                uri,
                DocumentsContract.getTreeDocumentId(uri)
            )
            contentResolver.query(
                docUri,
                arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                null,
                null,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            } ?: uri.lastPathSegment ?: uri.toString()
        } catch (_: Exception) {
            uri.lastPathSegment ?: uri.toString()
        }
    }

    // ---------------------------------------------------------------- 线程封装

    /** IO 放到单线程队列执行，结果切回主线程，避免阻塞 UI。 */
    private fun <T> runIo(result: MethodChannel.Result, block: () -> T) {
        io.execute {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error("saf_error", e.message ?: e.toString(), null) }
            }
        }
    }

    override fun onDestroy() {
        io.shutdown()
        super.onDestroy()
    }
}
